import java.io.*;
import java.nio.file.*;
import java.security.*;
import java.security.cert.*;
import java.security.interfaces.RSAPrivateCrtKey;
import java.security.spec.*;
import java.util.*;

/** Imports a PEM key over stdin directly into BCFKS; never creates PKCS12 intermediates. */
public class StoreTool {
  static char[] password(String name) {
    String value=System.getenv(name);
    if (value==null || value.length()<14) throw new IllegalArgumentException("Missing/short " + name);
    return value.toCharArray();
  }
  static KeyStore store(String type) throws Exception {
    if (Boolean.parseBoolean(System.getenv("AUTO_TLS_REQUIRE_FIPS_STORES")))
      return KeyStore.getInstance(type,"CCJ");
    return KeyStore.getInstance(type);
  }
  static List<java.security.cert.Certificate> certs(String path) throws Exception {
    try (InputStream in=Files.newInputStream(Path.of(path))) {
      return new ArrayList<>(CertificateFactory.getInstance("X.509").generateCertificates(in));
    }
  }
  static KeyStore load(String file,String type,char[] pass) throws Exception {
    KeyStore value=store(type);
    try (InputStream in=Files.newInputStream(Path.of(file))) {value.load(in,pass);}
    return value;
  }
  static void write(KeyStore value,String file,char[] pass) throws Exception {
    try (OutputStream out=Files.newOutputStream(Path.of(file))) {value.store(out,pass);}
  }
  public static void main(String[] args) throws Exception {
    String type=System.getenv("AUTO_TLS_STORE_TYPE");
    char[] keyPass=password("AUTO_TLS_KEYSTORE_PASSWORD"), trustPass=password("AUTO_TLS_TRUSTSTORE_PASSWORD");
    String mode=args[0],alias=args[1],leaf=args[2],chainFile=args[3],keyFile=args[4],trustFile=args[5];
    List<java.security.cert.Certificate> leafCerts=certs(leaf),chain=certs(chainFile);
    if (leafCerts.size()!=1 || chain.isEmpty()) throw new IllegalArgumentException("Invalid leaf/CA chain");
    String caAlias=System.getenv("AUTO_TLS_CA_STORE_ALIAS");
    if (mode.equals("build")) {
      byte[] encoded=System.in.readAllBytes();
      KeyFactory factory=Boolean.parseBoolean(System.getenv("AUTO_TLS_REQUIRE_FIPS_STORES"))
          ? KeyFactory.getInstance("RSA","CCJ") : KeyFactory.getInstance("RSA");
      PrivateKey key=factory.generatePrivate(new PKCS8EncodedKeySpec(encoded));
      Arrays.fill(encoded,(byte)0);
      KeyStore keys=store(type);keys.load(null,keyPass);
      List<java.security.cert.Certificate> full=new ArrayList<>(leafCerts);full.addAll(chain);
      keys.setKeyEntry(alias,key,keyPass,full.toArray(new java.security.cert.Certificate[0]));
      write(keys,keyFile,keyPass);
      KeyStore trust=store(type);trust.load(null,trustPass);
      for (int i=0;i<chain.size();i++) trust.setCertificateEntry(caAlias+"-"+(i+1),chain.get(i));
      write(trust,trustFile,trustPass);
    }
    KeyStore keys=load(keyFile,type,keyPass),trust=load(trustFile,type,trustPass);
    if (keys.size()!=1 || !keys.isKeyEntry(alias) || !keys.getCertificate(alias).equals(leafCerts.get(0)))
      throw new IllegalStateException("Keystore alias/leaf mismatch");
    java.security.cert.Certificate[] full=keys.getCertificateChain(alias);
    if (full.length!=chain.size()+1) throw new IllegalStateException("Keystore chain length mismatch");
    for (int i=0;i<chain.size();i++) if (!full[i+1].equals(chain.get(i)))
      throw new IllegalStateException("Keystore chain order mismatch");
    RSAPrivateCrtKey key=(RSAPrivateCrtKey)keys.getKey(alias,keyPass);
    KeyFactory rsa=KeyFactory.getInstance("RSA");
    PublicKey derived=rsa.generatePublic(new RSAPublicKeySpec(key.getModulus(),key.getPublicExponent()));
    if (!Arrays.equals(derived.getEncoded(),leafCerts.get(0).getPublicKey().getEncoded()))
      throw new IllegalStateException("Keystore private key and leaf certificate mismatch");
    if (trust.size()!=chain.size()) throw new IllegalStateException("Truststore chain length mismatch");
    for (int i=0;i<chain.size();i++) if (!chain.get(i).equals(trust.getCertificate(caAlias+"-"+(i+1))))
      throw new IllegalStateException("Truststore CA alias/content mismatch");
    Arrays.fill(keyPass,'\0');Arrays.fill(trustPass,'\0');
    System.out.println("[OK] Verified " + type + " private key, leaf, full chain, and CA trust: " + alias);
  }
}
