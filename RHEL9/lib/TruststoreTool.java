import java.io.*;
import java.nio.file.*;
import java.security.*;
import java.security.cert.*;
import java.util.*;

/** Build runtime BCFKS trust from approved vendor roots and explicit CA PEMs. */
public class TruststoreTool {
  static String hash(java.security.cert.Certificate cert) throws Exception {
    return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(cert.getEncoded()));
  }
  static Map<String,java.security.cert.Certificate> collect(String[] args) throws Exception {
    Map<String,java.security.cert.Certificate> certificates=new LinkedHashMap<>();
    if (Boolean.parseBoolean(System.getenv("JAVA_TRUST_INCLUDE_VENDOR_CACERTS"))) {
      KeyStore vendor=KeyStore.getInstance("JKS","SUN");
      String configured=System.getenv("JAVA_CACERTS_FILE");
      Path source=configured==null || configured.isEmpty()
          ? Path.of(System.getProperty("java.home"),"lib","security","cacerts") : Path.of(configured);
      char[] sourcePass=System.getenv("JAVA_CACERTS_PASSWORD").toCharArray();
      try (InputStream in=Files.newInputStream(source)) {vendor.load(in,sourcePass);}
      Arrays.fill(sourcePass,'\0');
      Enumeration<String> aliases=vendor.aliases();
      while (aliases.hasMoreElements()) {
        java.security.cert.Certificate cert=vendor.getCertificate(aliases.nextElement());
        if (cert!=null) certificates.put(hash(cert),cert);
      }
    }
    for (String file:args) {
      if (file.isEmpty()) continue;
      Collection<? extends java.security.cert.Certificate> added;
      try (InputStream in=Files.newInputStream(Path.of(file))) {
        added=CertificateFactory.getInstance("X.509").generateCertificates(in);
      }
      if (added.isEmpty()) throw new IllegalArgumentException("Empty CA PEM input");
      for (java.security.cert.Certificate cert:added) {
        if (((X509Certificate)cert).getBasicConstraints()<0) throw new IllegalArgumentException("Non-CA certificate in explicit CA PEM input");
        certificates.put(hash(cert),cert);
      }
    }
    if (certificates.isEmpty()) throw new IllegalArgumentException("No trusted CA certificates");
    return certificates;
  }
  public static void main(String[] args) throws Exception {
    if (args.length>0 && args[0].equals("--inspect-inputs")) {
      Map<String,java.security.cert.Certificate> certificates=collect(Arrays.copyOfRange(args,1,args.length));
      System.out.println("[OK] CA input collection contains "+certificates.size()+" unique certificates");
      return;
    }
    String password=System.getenv("JAVA_PUBLIC_TRUSTSTORE_PASSWORD");
    if (password==null || password.length()<14) throw new IllegalArgumentException("Short runtime truststore password");
    char[] targetPass=password.toCharArray();
    Map<String,java.security.cert.Certificate> certificates=collect(Arrays.copyOfRange(args,1,args.length));
    KeyStore output=KeyStore.getInstance("BCFKS","CCJ");output.load(null,targetPass);
    for (Map.Entry<String,java.security.cert.Certificate> entry:certificates.entrySet())
      output.setCertificateEntry("trusted-"+entry.getKey(),entry.getValue());
    try (OutputStream out=Files.newOutputStream(Path.of(args[0]))) {output.store(out,targetPass);}
    Arrays.fill(targetPass,'\0');
    System.out.println("[OK] BCFKS runtime truststore contains "+certificates.size()+" unique approved CA certificates");
  }
}
