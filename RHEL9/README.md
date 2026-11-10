# RHEL 9.8 HTTP lab with OS and Java FIPS

This profile uses RHEL 9.8 x86_64 with OS FIPS enabled and SafeLogic CCJ 4 for Java. The NiFi and Registry HTTP endpoints allow unauthenticated access in the lab. PostgreSQL uses SCRAM on port 5432 with SSL disabled.

| Component | Version | Java home | Lab endpoint |
|---|---|---|---|
| Cloudera Manager | 7.13.2.10000 | `/opt/java/jdk-17` | HTTP 7180 |
| CDP Runtime | 7.3.2.10000 | `/opt/java/jdk-17` | ZooKeeper client port 2181 |
| CFM / NiFi | 4.12.0.10001 / 2.6.0 | `/opt/java/jdk-21` | HTTP 8080 |
| NiFi Registry | CFM 4.12.0.10001 | `/opt/java/jdk-21` | HTTP 18080 |

The public CFM guide lists RHEL 9.6 for the documented 4.12 SP1 FIPS 140-3 configuration. This directory targets the RHEL 9.8 lab. [Cloudera CFM FIPS guide](https://docs.cloudera.com/cfm/4.12.0/cfm-security/topics/cfm-deploy-on-fips-clusters.html)

## Install the manager and agents

1. Enable OS FIPS and reboot each host before running the installer. Edit `EXPORTS` for each host and stage the approved SafeLogic bundle with its SHA-256 sidecars. [Installation guide](INSTALL.md)
2. From `RHEL9/`, run `sudo -E bash RUN_MANAGER` on the manager, then `sudo -E bash RUN_AGENT` on each worker. Step 04 installs the RHEL OpenJDK 17 and 21 RPMs, stages CCJ 4 under `/opt/cloudera/fips`, and builds `/opt/cloudera/java-public-roots.bcfks`. Steps 10 and 12 apply the Java version probe fix before starting the agent. Step 13 loads the matching CFM CSDs on the manager.
3. In CM, activate the locked CDP and CFM parcels. Run step 14 on each host receiving both parcels before starting roles, then add and start the CM-managed ZooKeeper service.

   ```bash
   sudo -E bash 14_install_cfm_fips_jars.sh all
   ```

## Configure NiFi before first start

On the manager, run the generator from `RHEL9/`.

```bash
sudo -E bash 16_generate_cfm_fips_config.sh
```

In CM, add NiFi with the running ZooKeeper service as its dependency. Set **Custom Java Home** to `/opt/java/jdk-21` and leave **Enable TLS/SSL for NiFi Node** unchecked. Apply the safety valves to each NiFi role configuration group.

| CM safety valve | Content |
|---|---|
| NiFi Node `staging/bootstrap.conf.xml` | The XML block below, in XML view |
| NiFi Node `staging/nifi.properties.xml` | `/var/lib/cloudera-bootstrap/cfm-config/nifi-properties.xml`, in XML view |
| NiFi Service Environment | `HADOOP_SASL_MECHANISM=DIGEST-SHA` as plain text |

The properties snippet binds HTTP on `0.0.0.0:8080` and sets `NIFI_PBKDF2_AES_GCM_256` with the `NIFI_SENSITIVE_PROPS_KEY` from `EXPORTS`.

### NiFi bootstrap safety valve

The working capture used the CCJ 3.0.2.1 module path from CFM 2.1.7.3000-45. This RHEL 9 block uses the CCJ 4 directory staged by step 04 and includes the three JVM TLS flags from the capture. Replace the previous FIPS entries in the safety valve with this block.

```xml
<property>
  <name>java.arg.fips.modulepath</name>
  <value>--module-path=/opt/cloudera/fips</value>
</property>
<property>
  <name>java.arg.fips.modules</name>
  <value>--add-modules=ALL-MODULE-PATH</value>
</property>
<property>
  <name>java.arg.fips.exports</name>
  <value>--add-exports=java.base/sun.security.provider=com.safelogic.cryptocomply.fips.core</value>
</property>
<property>
  <name>java.arg.fips.ccj</name>
  <value>-Dcom.safelogic.cryptocomply.fips.approved_only=true</value>
</property>
<property>
  <name>java.arg.fips.bc</name>
  <value>-Dorg.bouncycastle.fips.approved_only=true</value>
</property>
<property>
  <name>java.arg.fips.trustnameservice</name>
  <value>-Djdk.tls.trustNameService=true</value>
</property>
<property>
  <name>java.arg.fips.ephemeraldhkeysize</name>
  <value>-Djdk.tls.ephemeralDHKeySize=2048</value>
</property>
<property>
  <name>java.arg.fips.assumeoriginalhostname</name>
  <value>-Dorg.bouncycastle.jsse.client.assumeOriginalHostName=true</value>
</property>
<property>
  <name>java.arg.fips.truststore</name>
  <value>-Djavax.net.ssl.trustStore=/opt/cloudera/java-public-roots.bcfks</value>
</property>
<property>
  <name>java.arg.fips.truststoretype</name>
  <value>-Djavax.net.ssl.trustStoreType=BCFKS</value>
</property>
<property>
  <name>java.arg.fips.truststorepassword</name>
  <value>-Djavax.net.ssl.trustStorePassword=REPLACE_WITH_JAVA_PUBLIC_TRUSTSTORE_PASSWORD</value>
</property>
```

Use the `JAVA_PUBLIC_TRUSTSTORE_PASSWORD` that step 04 used to create the BCFKS file on the NiFi host. All hosts sharing a CM role group need a matching truststore password. Step 16 writes the manager's password as an XML-escaped value in `nifi-bootstrap.xml`. Use that value when it matches the NiFi hosts. The JVM uses this store to initialize its default SSL context for internal clients while NiFi serves its UI over HTTP.

## Start and verify NiFi

Save the safety valves, start NiFi in CM, and open `http://<nifi-host>:8080/nifi/`. On the NiFi host, run the runtime check from `RHEL9/`.

```bash
sudo -E bash 17_validate_cfm_runtime.sh nifi
```

If startup logs show `DER length more than 4 bytes: 109`, check that the JVM truststore path points to the BCFKS file and that its type is `BCFKS`. For `BCFKS KeyStore corrupted: MAC calculation failed`, verify the password against the file on the NiFi host.

```bash
source ./lib/common.sh
JAVA_HOME_TARGET="$CFM_JAVA_HOME" fips_keytool -list \
  -keystore "$JAVA_PUBLIC_TRUSTSTORE" -storetype BCFKS \
  -storepass:env JAVA_PUBLIC_TRUSTSTORE_PASSWORD >/dev/null
```

## Add and configure NiFi Registry

In CM, select **Add Service → NiFi Registry**. For the two-host lab, place the Registry role on the NiFi worker and select **No Optional Dependencies**. [Cloudera Registry installation guide](https://docs.cloudera.com/cfm/4.12.0/deployment/topics/cfm-add-nifi-registry-hybrid.html)

Set these values on the **NiFi Registry → Configuration** page.

| CM setting | Lab value |
|---|---|
| Custom Java Home | `/opt/java/jdk-21` |
| Enable TLS/SSL | Unchecked |
| Initial Admin Identity | Blank |
| NiFi Registry JDBC URL | `jdbc:postgresql://<db-host>:5432/nifireg?sslmode=disable` |
| NiFi Registry JDBC Driver | `org.postgresql.Driver` |
| NiFi Registry H2 directory storage location | `/usr/share/java` |
| NiFi Registry Database Username | `nifireg` |
| NiFi Registry Database Password | `REG_DB_PASS` from the manager's `EXPORTS` |

Use the manager's `DB_HOST` from `EXPORTS` for `<db-host>`. Step 07 creates the `nifireg` database and user, and step 09 installs the PostgreSQL JDBC driver on the worker. The field labeled **H2 directory storage location** supplies the PostgreSQL JDBC driver directory. [Cloudera Registry PostgreSQL settings](https://docs.cloudera.com/cfm/4.12.0/deployment/topics/cfm-configuring-nif-registry-metadata-stores-postgres.html)

In **NiFi Registry → Configuration → Advanced**, apply both safety valves in **XML view**.

| CM safety valve | Content |
|---|---|
| Registry `staging/bootstrap.conf.xml` | The same working FIPS bootstrap XML as NiFi, including the BCFKS path, type, and password |
| Registry properties safety valve | `/var/lib/cloudera-bootstrap/cfm-config/registry-properties.xml` from the manager |

Step 16 generates the Registry properties snippet with HTTP on `0.0.0.0:18080`. Use the BCFKS password that was used to create the truststore on the Registry host. [NiFi bootstrap safety valve](#nifi-bootstrap-safety-valve)

Save and start Registry, then open `http://<registry-host>:18080/nifi-registry/`. Run the runtime check from `RHEL9/` on the Registry host.

```bash
sudo -E bash 17_validate_cfm_runtime.sh registry
```

To connect NiFi, open **Controller Settings → Registry Clients** in the NiFi UI. Add a client for this Registry and set its URL to the base address `http://<registry-host>:18080`. [Cloudera Registry client setup](https://docs.cloudera.com/cfm/4.12.0/deployment/topics/cfm-connect-nifi-to-registry.html)

## References

- Full install sequence, parcel activation, and Registry configuration. [INSTALL.md](INSTALL.md)
- Site inputs and version pins. [EXPORTS](EXPORTS)
- Deployment notes and validation checks. [MERGE_NOTES.md](MERGE_NOTES.md) · [VALIDATION.md](VALIDATION.md) · [SOURCES.md](SOURCES.md)
- Optional TLS setup. [TLS add-on](../TLS/README.md)
