import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import javax.net.ssl.*;

/** Checks a real mutual TLS handshake with hostname verification and BCJSSE. */
public class TlsProbe {
  public static void main(String[] args) throws Exception {
    KeyStore keys=KeyStore.getInstance("BCFKS", "CCJ");
    KeyStore trust=KeyStore.getInstance("BCFKS", "CCJ");
    char[] keyPass=System.getenv("CFM_PROBE_KEY_PASSWORD").toCharArray();
    try (InputStream in=Files.newInputStream(Path.of(args[0]))) {
      keys.load(in, System.getenv("CFM_PROBE_STORE_PASSWORD").toCharArray());
    }
    try (InputStream in=Files.newInputStream(Path.of(args[1]))) {
      trust.load(in, System.getenv("CFM_PROBE_TRUST_PASSWORD").toCharArray());
    }
    KeyManagerFactory km=KeyManagerFactory.getInstance("PKIX", "BCJSSE");
    km.init(keys,keyPass);
    TrustManagerFactory tm=TrustManagerFactory.getInstance("PKIX", "BCJSSE");
    tm.init(trust);
    SSLContext context=SSLContext.getInstance("TLS", "BCJSSE");
    context.init(km.getKeyManagers(),tm.getTrustManagers(),null);
    java.net.Socket tcp=new java.net.Socket();
    tcp.connect(new java.net.InetSocketAddress(args[2],Integer.parseInt(args[3])),10000);
    try (SSLSocket socket=(SSLSocket)context.getSocketFactory().createSocket(tcp,args[2],Integer.parseInt(args[3]),true)) {
      socket.setSoTimeout(15000);
      SSLParameters params=socket.getSSLParameters();
      params.setEndpointIdentificationAlgorithm("HTTPS");
      socket.setSSLParameters(params);
      socket.startHandshake();
      SSLSession session=socket.getSession();
      System.out.println("[OK] BCJSSE verified mutual TLS: "+session.getProtocol()+" "+session.getCipherSuite());
    }
    java.util.Arrays.fill(keyPass,'\0');
  }
}
