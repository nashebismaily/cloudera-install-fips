import java.nio.file.*;
import java.io.InputStream;
import java.security.cert.*;

/** Use the same RFC2253 DN representation as NiFi's Java certificate identity. */
public class SubjectDN {
  public static void main(String[] args) throws Exception {
    for (int i=0;i<args.length;i+=2) {
      try (InputStream input=Files.newInputStream(Path.of(args[i+1]))) {
        X509Certificate cert=(X509Certificate)CertificateFactory.getInstance("X.509").generateCertificate(input);
        System.out.println(args[i]+"\t"+cert.getSubjectX500Principal().getName());
      }
    }
  }
}
