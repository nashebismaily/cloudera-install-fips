#!/usr/bin/env bash
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORTS_FILE="${EXPORTS_FILE:-${SCRIPT_DIR}/EXPORTS}"

if [[ ! -f "${EXPORTS_FILE}" ]]; then
  echo "[ERROR] Configuration file not found: ${EXPORTS_FILE}" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${EXPORTS_FILE}"

load_artifact_lock() {
  [[ -f "${ARTIFACT_LOCK_FILE}" ]] || return 0
  local assignments
  assignments="$("${BOOTSTRAP_PYTHON_BIN}" "${SCRIPT_DIR}/lib/prepare_artifacts.py" --shell)" || return 1
  eval "${assignments}"
}
load_artifact_lock
require_artifact_lock() {
  [[ -s "${ARTIFACT_LOCK_FILE}" && -n "${CFM_BUILD}" && -n "${FIPS_SASL_JAR}" ]] || {
    echo '[ERROR] Run 00_prepare_artifacts.sh first to verify inputs and lock release builds.'; return 1;
  }
}

log_init() {
  local name="$1"
  umask 077
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/${name}_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "${LOG_FILE}") 2>&1
  echo "==== ${name} ===="
  echo "Timestamp: $(date -Is)"
  echo "Host: $(hostname -f 2>/dev/null || hostname)"
  echo "OS: $(cat "${REDHAT_RELEASE_FILE}" 2>/dev/null || echo unknown)"
  echo "Configuration: ${EXPORTS_FILE}"
  echo "Log: ${LOG_FILE}"
  echo
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] Run as root or with sudo -E."
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[ERROR] Required command missing: ${cmd}"
    exit 1
  fi
}

warn_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    echo "[OK] command present: ${cmd}"
  else
    echo "[WARN] command missing: ${cmd}"
  fi
}

service_exists() {
  systemctl list-unit-files --type=service --no-legend "${1%.service}.service" 2>/dev/null | awk '{print $1}' | grep -qx "${1%.service}.service"
}

rhel_major() {
  rpm -E '%{rhel}' 2>/dev/null || echo unknown
}

rhel_minor() {
  if [[ -f "${OS_RELEASE_FILE}" ]]; then
    # shellcheck disable=SC1090
    . "${OS_RELEASE_FILE}"
    if [[ "${VERSION_ID:-}" == *.* ]]; then
      echo "${VERSION_ID#*.}"
    else
      echo ""
    fi
  else
    echo unknown
  fi
}

validate_platform() {
  local arch major minor fips
  arch="$(uname -m 2>/dev/null || echo unknown)"
  major="$(rhel_major)"
  minor="$(rhel_minor)"

  local os_id
  os_id="$(awk -F= '$1=="ID" {gsub(/"/,"",$2);print $2}' "${OS_RELEASE_FILE}")"
  [[ "${os_id}" == "${EXPECTED_OS_ID}" ]] || { echo "[ERROR] Expected ${EXPECTED_OS_ID}, detected ${os_id}"; return 1; }
  echo "==== Platform validation ===="
  echo "Architecture: ${arch}"
  echo "RHEL major: ${major}"
  echo "RHEL minor: ${minor}"

  if [[ "${REQUIRE_X86_64}" == "true" && "${arch}" != "${REQUIRED_ARCH}" ]]; then
    echo "[ERROR] Expected ${REQUIRED_ARCH} but detected ${arch}"
    exit 1
  fi
  if [[ "${major}" != "${EXPECTED_RHEL_MAJOR}" ]]; then
    echo "[ERROR] Expected RHEL major ${EXPECTED_RHEL_MAJOR} but detected ${major}"
    exit 1
  fi
  if [[ -n "${EXPECTED_RHEL_MINOR}" && "${minor}" != "${EXPECTED_RHEL_MINOR}" ]]; then
    echo "[ERROR] Expected RHEL ${EXPECTED_RHEL_MAJOR}.${EXPECTED_RHEL_MINOR} but detected ${major}.${minor}"
    exit 1
  fi

  fips="$(cat "${FIPS_KERNEL_FLAG_FILE}" 2>/dev/null || echo 0)"
  echo "FIPS kernel flag: ${fips}"
  if [[ "${REQUIRE_FIPS}" == "true" && "${fips}" != "1" ]]; then
    echo "[ERROR] FIPS is not enabled. Enable operating-system FIPS before installing Cloudera software."
    exit 1
  fi
  if command -v fips-mode-setup >/dev/null 2>&1; then
    fips-mode-setup --check || return 1
  fi
  if [[ "${REQUIRE_FIPS}" == "true" ]]; then
    local policy
    policy="$("${CRYPTO_POLICY_COMMAND}" --show)"
    [[ "${policy}" == "${FIPS_CRYPTO_POLICY}" || "${policy}" == "${FIPS_CRYPTO_POLICY}:"* ]] || {
      echo "[ERROR] Expected FIPS crypto policy; detected ${policy}"; return 1;
    }
  fi
  echo "[OK] Platform validation passed"
  echo
}

require_cloudera_credentials() {
  if [[ -z "${CLOUDERA_REPO_USER}" || -z "${CLOUDERA_REPO_PASS}" ]]; then
    echo "[ERROR] CLOUDERA_REPO_USER and CLOUDERA_REPO_PASS must be set in EXPORTS."
    exit 1
  fi
}

curl_tls_args() {
  if [[ "${CURL_INSECURE}" == "true" ]]; then
    printf '%s\n' '-k'
  fi
}

curl_head_public() {
  local url="$1" args=()
  if [[ "${CURL_INSECURE}" == "true" ]]; then args+=('-k'); fi
  curl "${args[@]}" --fail -I -L \
    --connect-timeout "${CURL_PREFLIGHT_CONNECT_TIMEOUT_SECONDS}" \
    --max-time "${CURL_PREFLIGHT_MAX_TIME_SECONDS}" \
    "${url}" >/dev/null 2>&1
}

curl_head_auth() {
  local url="$1" args=()
  if [[ "${CURL_INSECURE}" == "true" ]]; then args+=('-k'); fi
  curl "${args[@]}" --fail -I -L \
    --connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" \
    --max-time "${CURL_HEAD_MAX_TIME_SECONDS}" \
    -u "${CLOUDERA_REPO_USER}:${CLOUDERA_REPO_PASS}" \
    "${url}" >/dev/null 2>&1
}

curl_download_auth() {
  local url="$1" out="$2" args=()
  if [[ "${CURL_INSECURE}" == "true" ]]; then args+=('-k'); fi
  curl "${args[@]}" -f -L \
    --connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" \
    --max-time "${CURL_DOWNLOAD_MAX_TIME_SECONDS}" \
    -u "${CLOUDERA_REPO_USER}:${CLOUDERA_REPO_PASS}" \
    -o "${out}" "${url}"
}

pg_service_name() { echo "${PG_SERVICE_NAME}"; }
pg_bin_dir() { echo "${PG_BIN_DIR}"; }
pg_default_data_dir() { echo "${PG_DEFAULT_DATA_DIR}"; }

ensure_java_default() {
  [[ "${JAVA_INSTALL_MODE}" == custom ]] || {
    echo '[ERROR] RHEL9 FIPS requires JAVA_INSTALL_MODE=custom; upstream JDK installation is automatic.'; return 1;
  }
  export JAVA_HOME="${JAVA_HOME_TARGET}"
  export JDK_JAVA_OPTIONS="$(fips_java_options)"
  export PATH="${JAVA_HOME}/bin:${PATH}"
}

validate_java_home() {
  local java_home="$1" major="$2" output
  [[ -x "${java_home}/bin/java" && -x "${java_home}/bin/keytool" && -x "${java_home}/bin/jar" ]] || {
    echo "[ERROR] Complete upstream JDK ${major} is missing at ${java_home} after the Java installation step."; return 1;
  }
  output="$(env -u JDK_JAVA_OPTIONS -u JAVA_TOOL_OPTIONS "${java_home}/bin/java" -version 2>&1)" || return 1
  [[ "${output}" =~ version\ \"${major}([.\"]|$) ]] || {
    echo "[ERROR] Expected JDK ${major} at ${java_home}: ${output}"; return 1;
  }
  echo "[OK] JDK ${major}: ${java_home}"
}
validate_cm_java() { validate_java_home "${JAVA_HOME_TARGET}" "${JAVA_MAJOR}"; }
validate_cfm_java() { validate_java_home "${CFM_JAVA_HOME}" "${CFM_JAVA_MAJOR}"; }
normalize_legacy_java_home_files() { :; }

install_jdk_archive() {
  local archive="$1" checksum="$2" target="$3"
  [[ -n "${archive}" ]] || return 0
  [[ -f "${archive}" && "${checksum}" =~ ^[[:xdigit:]]{64}$ ]] || {
    echo '[ERROR] JDK archive path and trusted SHA256 must both be configured.'; return 1;
  }
  [[ "$(sha256sum "${archive}" | awk '{print $1}')" == "${checksum,,}" ]] || {
    echo "[ERROR] JDK archive checksum mismatch: ${archive}"; return 1;
  }
  [[ ! -e "${target}" ]] || { echo "[INFO] Reusing existing JDK home: ${target}"; return 0; }
  local stage
  install -d -m 0755 "$(dirname "${target}")"
  stage="$(mktemp -d "${target}.stage.XXXXXX")"
  # Archives are authenticated above; reject unsafe members before extracting.
  if ! "${SYSTEM_PYTHON_BIN}" - "${archive}" <<'PY'
from pathlib import PurePosixPath
import sys, tarfile, posixpath
with tarfile.open(sys.argv[1]) as tf:
    for member in tf:
        p = PurePosixPath(member.name)
        if p.is_absolute() or '..' in p.parts or member.isdev() or member.isfifo():
            raise SystemExit('Unsafe JDK archive member: ' + member.name)
        if member.issym() or member.islnk():
            link = PurePosixPath(member.linkname)
            if member.issym():
                resolved = PurePosixPath(posixpath.normpath(str(p.parent / link)))
            else:
                resolved = PurePosixPath(posixpath.normpath(str(link)))
            if link.is_absolute() or not resolved.parts or resolved.parts[0] != p.parts[0]:
                raise SystemExit('Unsafe JDK archive link: ' + member.name)
PY
  then rm -rf -- "${stage}"; return 1; fi
  if ! tar -xf "${archive}" -C "${stage}" --strip-components=1 --no-same-owner; then
    rm -rf -- "${stage}"; return 1
  fi
  [[ -x "${stage}/bin/java" ]] || { rm -rf -- "${stage}"; echo '[ERROR] JDK archive must have one top-level directory.'; return 1; }
  chmod 0755 "${stage}"
  mv -- "${stage}" "${target}"
}

install_required_agent_python() {
  if [[ ! -x "${CM_AGENT_PYTHON_BIN}" ]]; then
    local packages=()
    read -r -a packages <<< "${CM_AGENT_PYTHON_PACKAGES}"
    dnf install -y "${packages[@]}"
  fi
  local version
  version="$("${CM_AGENT_PYTHON_BIN}" --version 2>&1)"
  [[ "${version}" == "${CM_AGENT_PYTHON_EXPECTED_VERSION}"* ]] || {
    echo "[ERROR] CM agent needs ${CM_AGENT_PYTHON_EXPECTED_VERSION}; got ${version}"; return 1;
  }
  echo "[OK] ${version}: ${CM_AGENT_PYTHON_BIN}"
}
validate_cm_agent_python_wrapper() {
  [[ -x "${CM_AGENT_PYTHON_WRAPPER}" ]] || { echo '[ERROR] CM agent Python wrapper is missing'; return 1; }
  local version
  version="$("${CM_AGENT_PYTHON_WRAPPER}" --version 2>&1)" || return 1
  [[ "${CM_AGENT_PYTHON_STRICT_VERSION}" != true || "${version}" == "${CM_AGENT_PYTHON_EXPECTED_VERSION}"* ]] || {
    echo "[ERROR] Agent wrapper selected ${version}, expected ${CM_AGENT_PYTHON_EXPECTED_VERSION}"; return 1;
  }
  echo "[OK] CM agent wrapper: ${version}"
}
install_hue_fips_psycopg2() {
  [[ "${INSTALL_HUE_FIPS_PSYCOPG2}" == true ]] || return 0
  local packages=()
  read -r -a packages <<< "${HUE_PSYCOPG2_BUILD_PACKAGES}"
  dnf install -y "${packages[@]}"
  export PATH="${PG_BIN_DIR}:${PATH}" PG_CONFIG="${PG_BIN_DIR}/pg_config"
  if "${HUE_PSYCOPG2_PYTHON_BIN}" -c 'import psycopg2; assert psycopg2.__version__.split()[0] == "'"${HUE_PSYCOPG2_VERSION}"'"' 2>/dev/null; then
    echo '[INFO] psycopg2 is already installed; validating its native libraries.'
    validate_hue_fips_psycopg2
    return
  fi
  "${HUE_PSYCOPG2_PYTHON_BIN}" -m pip uninstall -y psycopg2 psycopg2-binary || true
  "${HUE_PSYCOPG2_PYTHON_BIN}" -m pip install --upgrade "${HUE_PIP_VERSION_SPEC}" setuptools wheel
  "${HUE_PSYCOPG2_PYTHON_BIN}" -m pip install --no-binary=:all: "psycopg2==${HUE_PSYCOPG2_VERSION}"
  validate_hue_fips_psycopg2
}
validate_hue_fips_psycopg2() {
  [[ "${INSTALL_HUE_FIPS_PSYCOPG2}" == true ]] || return 0
  local out
  out="$("${HUE_PSYCOPG2_PYTHON_BIN}" -c 'import psycopg2; print(psycopg2.__version__)' 2>&1)" || {
    echo "[ERROR] psycopg2 import failed: ${out}"; return 1;
  }
  [[ "${out}" == "${HUE_PSYCOPG2_VERSION}"* ]] || { echo "[ERROR] Wrong psycopg2 version: ${out}"; return 1; }
  local extension linked
  extension="$("${HUE_PSYCOPG2_PYTHON_BIN}" -c 'import psycopg2._psycopg as p; print(p.__file__)')"
  linked="$(ldd "${extension}")"
  [[ "${linked}" != *psycopg2_binary.libs* && "${linked}" != *psycopg2.libs* && "${linked}" != *'not found'* ]] || {
    echo '[ERROR] psycopg2 uses private/broken native libraries; rebuild from source against the OS libpq/OpenSSL.'; return 1;
  }
  if [[ -x "${CM_AGENT_PYTHON_WRAPPER}" ]]; then
    "${CM_AGENT_PYTHON_WRAPPER}" -c 'import psycopg2; print("[OK] Agent-wrapper psycopg2:", psycopg2.__version__)'
  fi
}
prepare_postgres_jdbc() {
  dnf install -y "${POSTGRES_JDBC_PACKAGE}"
  local candidate=''
  if [[ ! -f "${POSTGRES_JDBC_LINK}" ]]; then
    while IFS= read -r path; do
      if [[ -f "${path}" && "${path}" == *.jar ]]; then candidate="${path}"; break; fi
    done < <(rpm -ql "${POSTGRES_JDBC_PACKAGE}")
    [[ -n "${candidate}" ]] || { echo '[ERROR] PostgreSQL JDBC RPM did not install a driver JAR'; return 1; }
    ln -sfn "${candidate}" "${POSTGRES_JDBC_LINK}"
  fi
  [[ -r "${POSTGRES_JDBC_LINK}" ]] || { echo '[ERROR] CM PostgreSQL JDBC driver link is not readable'; return 1; }
  "${SYSTEM_PYTHON_BIN}" - "${POSTGRES_JDBC_LINK}" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as jar:
    if 'org/postgresql/Driver.class' not in jar.namelist() or jar.testzip() is not None:
        raise SystemExit('Invalid PostgreSQL JDBC driver')
PY
}
ensure_line() { grep -qxF "$2" "$1" 2>/dev/null || printf '%s\n' "$2" >> "$1"; }
timestamped_backup() { [[ ! -f "$1" ]] || cp -a -- "$1" "$1.bak.$(date +%Y%m%d_%H%M%S_%N)"; }

resolve_fips_jars() {
  [[ "${REQUIRE_FIPS_CHECKSUMS}" == true ]] || { echo '[ERROR] Approved FIPS bundle checksums are mandatory in the RHEL9 install profile'; return 1; }
  [[ -d "${FIPS_JAR_SOURCE_DIR}" ]] || { echo "[ERROR] Stage approved FIPS jars: ${FIPS_JAR_SOURCE_DIR}"; return 1; }
  if [[ -z "${FIPS_SASL_JAR}" ]]; then
    local matches=()
    mapfile -t matches < <(compgen -G "${FIPS_JAR_SOURCE_DIR}/${FIPS_SASL_JAR_GLOB}" | sort || true)
    [[ ${#matches[@]} -eq 1 ]] || {
      echo "[ERROR] Expected exactly one ${FIPS_SASL_JAR_GLOB} in ${FIPS_JAR_SOURCE_DIR}; set FIPS_SASL_JAR to the approved build."; return 1;
    }
    FIPS_SASL_JAR="${matches[0]##*/}"
    export FIPS_SASL_JAR
  fi
  "${BOOTSTRAP_PYTHON_BIN}" "${SCRIPT_DIR}/lib/fips_artifacts.py"
}
fips_java_options() {
  printf '%s' "--module-path=${JAVA_FIPS_DIR} --add-modules=${JAVA_FIPS_MODULES} --add-exports=${JAVA_FIPS_ADD_EXPORT}=${JAVA_FIPS_CCJ_MODULE} -Dcom.safelogic.cryptocomply.fips.approved_only=true -Dorg.bouncycastle.fips.approved_only=true"
}
stage_java_fips_jars() {
  resolve_fips_jars
  mkdir -p "${JAVA_FIPS_DIR}"
  chmod "${JAVA_FIPS_DIR_MODE}" "${JAVA_FIPS_DIR}"
  local jar
  for jar in "${FIPS_CCJ_JAR}" "${FIPS_BCTLS_JAR}" "${FIPS_BCUTIL_JAR}" "${FIPS_SASL_JAR}"; do
    if [[ "${FIPS_JAR_SOURCE_DIR}/${jar}" != "${JAVA_FIPS_DIR}/${jar}" ]]; then
      cp -af -- "${FIPS_JAR_SOURCE_DIR}/${jar}" "${JAVA_FIPS_DIR}/${jar}"
    fi
    chown "${JAVA_FIPS_OWNER}" "${JAVA_FIPS_DIR}/${jar}"
    chmod "${JAVA_FIPS_JAR_MODE}" "${JAVA_FIPS_DIR}/${jar}"
  done
  # A legacy provider on this module path could shadow the approved bundle.
  for jar in "${JAVA_FIPS_DIR}"/*.jar; do
    case "${jar##*/}" in
      "${FIPS_CCJ_JAR}"|"${FIPS_BCTLS_JAR}"|"${FIPS_BCUTIL_JAR}"|"${FIPS_SASL_JAR}") ;;
      *) echo "[ERROR] Unexpected/legacy jar on the FIPS module path: ${jar}. Review it before proceeding."; return 1 ;;
    esac
  done
  restorecon -Rv "${JAVA_FIPS_DIR}" 2>/dev/null || true
}
validate_fips_module_name() {
  local filename="$1" expected="$2" output release
  local jar_command=(env -u JDK_JAVA_OPTIONS -u JAVA_TOOL_OPTIONS -u _JAVA_OPTIONS
    "${JAVA_HOME_TARGET}/bin/jar" "--file=${JAVA_FIPS_DIR}/${filename}" --describe-module)
  if ! output="$("${jar_command[@]}" 2>&1)"; then
    printf '%s\n' "[ERROR] Cannot read module descriptor: ${filename}" "${output}"; return 1
  fi
  # Multi-release JARs can store module-info.class only under META-INF/versions.
  # In that case jar exits successfully but asks for --release instead of
  # printing the module name. Read the newest advertised descriptor supported
  # by the CM JDK, which is also the minimum Java version used by this profile.
  release="$(awk -v maximum="${JAVA_MAJOR}" '
    $1 == "releases:" {
      for (i=2; i<=NF; i++)
        if ($i ~ /^[0-9]+$/ && $i <= maximum && $i > best) best=$i
    }
    END { if (best) print best }
  ' <<< "${output}")"
  if [[ -n "${release}" ]]; then
    if ! output="$("${jar_command[@]}" --release "${release}" 2>&1)"; then
      printf '%s\n' "[ERROR] Cannot read ${filename} module descriptor for release ${release}" "${output}"; return 1
    fi
  fi
  if ! awk -v expected="${expected}" '
    $1 == expected || index($1, expected "@") == 1 { found=1 }
    END { exit !found }
  ' <<< "${output}"; then
    printf '%s\n' "[ERROR] Module name mismatch for ${filename}; expected ${expected}" "${output}"; return 1
  fi
  echo "[OK] ${filename}: module ${expected}${release:+ (release ${release})}"
}
validate_fips_module_names() {
  validate_fips_module_name "${FIPS_CCJ_JAR}" "${JAVA_FIPS_CCJ_MODULE}" || return 1
  validate_fips_module_name "${FIPS_BCTLS_JAR}" "${JAVA_FIPS_BCTLS_MODULE}"
}
write_jdk_java_options_profile() {
  export JDK_JAVA_OPTIONS="$(fips_java_options)"
  mkdir -p "$(dirname "${JAVA_FIPS_PROFILE_FILE}")"
  printf "export JDK_JAVA_OPTIONS='%s'\n" "${JDK_JAVA_OPTIONS}" > "${JAVA_FIPS_PROFILE_FILE}"
  chmod "${JAVA_FIPS_PROFILE_MODE}" "${JAVA_FIPS_PROFILE_FILE}"
  printf "export JAVA_HOME='%s'\nexport PATH=\$JAVA_HOME/bin:\$PATH\n" "${JAVA_HOME_TARGET}" > "${JAVA_PROFILE_FILE}"
  printf "export JAVA_HOME='%s'\n" "${JAVA_HOME_TARGET}" > "${JAVA_DEFAULT_FILE}"
}
configure_java_fips_safelogic() {
  [[ "${CONFIGURE_JAVA_FIPS}" == true ]] || { echo '[ERROR] RHEL9 FIPS profile requires CONFIGURE_JAVA_FIPS=true'; return 1; }
  ensure_java_default
  validate_cm_java
  validate_cfm_java
  stage_java_fips_jars
  validate_fips_module_names
  "${SYSTEM_PYTHON_BIN}" "${SCRIPT_DIR}/lib/java_fips.py" "${JAVA_HOME_TARGET}" "${CFM_JAVA_HOME}"
  write_jdk_java_options_profile
  validate_java_fips_providers
}
validate_java_fips_providers() {
  local tmpdir java_home out
  tmpdir="$(mktemp -d)"
  chmod 0755 "${tmpdir}"
  cat > "${tmpdir}/CheckProviders.java" <<'JAVA'
import java.security.*;
import javax.crypto.Cipher;
import javax.net.ssl.SSLContext;
public class CheckProviders {
  public static void main(String[] args) throws Exception {
    boolean sasl=false;
    for (Provider p : Security.getProviders()) {
      System.out.println("Provider: " + p.getName() + " class=" + p.getClass().getName());
      sasl |= p.getClass().getName().equals(args[0]);
    }
    if (Security.getProvider("CCJ")==null || Security.getProvider("BCJSSE")==null || !sasl)
      throw new IllegalStateException("Required CCJ, BCJSSE, or Cloudera SASL provider missing");
    if (!Security.getProviders()[0].getName().equals("CCJ") || !Security.getProviders()[1].getName().equals("BCJSSE"))
      throw new IllegalStateException("CCJ and BCJSSE must be the first providers");
    Object approved=Class.forName("com.safelogic.cryptocomply.crypto.CryptoServicesRegistrar")
      .getMethod("isInApprovedOnlyMode").invoke(null);
    if (!Boolean.TRUE.equals(approved)) throw new IllegalStateException("CCJ approved-only mode is not active");
    KeyStore.getInstance("BCFKS", "CCJ");
    Cipher.getInstance("AES/GCM/NoPadding", "CCJ");
    SSLContext.getInstance("TLS", "BCJSSE");
    if (!KeyStore.getDefaultType().equalsIgnoreCase("BCFKS"))
      throw new IllegalStateException("Default store must be BCFKS");
    System.out.println("[OK] BCFKS and AES-GCM are available through CCJ");
  }
}
JAVA
  chmod 0644 "${tmpdir}/CheckProviders.java"
  local opts=()
  read -r -a opts <<< "$(fips_java_options)"
  for java_home in "${JAVA_HOME_TARGET}" "${CFM_JAVA_HOME}"; do
    if ! out="$(env -u JDK_JAVA_OPTIONS "${java_home}/bin/java" "${opts[@]}" "${tmpdir}/CheckProviders.java" "${JAVA_FIPS_SASL_PROVIDER_CLASS}" 2>&1)"; then
      printf '%s\n' "${out}"; rm -rf -- "${tmpdir}"; return 1
    fi
    printf '%s\n' "[OK] FIPS providers in ${java_home}" "${out}"
    if id "${CLOUDERA_SERVICE_USER}" >/dev/null 2>&1; then
      if ! runuser -u "${CLOUDERA_SERVICE_USER}" -- env -u JDK_JAVA_OPTIONS "${java_home}/bin/java" \
          "${opts[@]}" "${tmpdir}/CheckProviders.java" "${JAVA_FIPS_SASL_PROVIDER_CLASS}"; then
        echo "[ERROR] Service user cannot load ${java_home} FIPS providers; check fapolicyd, SELinux and directory traversal."
        rm -rf -- "${tmpdir}"; return 1
      fi
    fi
  done
  rm -rf -- "${tmpdir}"
}
configure_cm_server_fips_opts() {
  local ccj="${JAVA_FIPS_DIR}/${FIPS_CCJ_JAR}" bctls="${JAVA_FIPS_DIR}/${FIPS_BCTLS_JAR}"
  mkdir -p "$(dirname "${CM_SERVER_DEFAULTS_FILE}")" "${CM_AGENT_SYSTEMD_FIPS_DIR}"
  touch "${CM_SERVER_DEFAULTS_FILE}"
  local tmp
  tmp="$(mktemp)"
  awk '/# BEGIN MANAGED RHEL9 FIPS/{skip=1;next} /# END MANAGED RHEL9 FIPS/{skip=0;next} !skip{print}' "${CM_SERVER_DEFAULTS_FILE}" > "${tmp}"
  cat >> "${tmp}" <<EOF
# BEGIN MANAGED RHEL9 FIPS
export JAVA_HOME='${JAVA_HOME_TARGET}'
export JDK_JAVA_OPTIONS='$(fips_java_options)'
export CMF_ADD_TO_CLASSPATH="\${CMF_ADD_TO_CLASSPATH:-}:${JAVA_FIPS_DIR}/${FIPS_BCUTIL_JAR}"
export CMF_JAVA_OPTS="\${CMF_JAVA_OPTS:-} -D${CM_FIPS_MODE_PROPERTY}=true -D${CM_FIPS_SASL_PROPERTY}=true -D${CM_FIPS_APPROVED_ONLY_PROPERTY}=true"
export CMF_JAVA_OPTS="\${CMF_JAVA_OPTS} -D${CM_FIPS_JDK_PROPERTY_PREFIX}.ccj.jar.path=${ccj} -D${CM_FIPS_JDK_PROPERTY_PREFIX}.ccj.moduleName=${JAVA_FIPS_CCJ_MODULE}"
export CMF_JAVA_OPTS="\${CMF_JAVA_OPTS} -D${CM_FIPS_JDK_PROPERTY_PREFIX}.bctls.jar.path=${bctls} -D${CM_FIPS_JDK_PROPERTY_PREFIX}.bctls.moduleName=${JAVA_FIPS_BCTLS_MODULE}"
EOF
  if [[ -f "${JAVA_PUBLIC_TRUSTSTORE}" ]]; then
    printf 'export CMF_JAVA_OPTS="${CMF_JAVA_OPTS:-} -Djavax.net.ssl.trustStoreType=%s -Djavax.net.ssl.trustStore=%s -Djavax.net.ssl.trustStorePassword=%s"\n' \
      "${JAVA_FIPS_KEYSTORE_TYPE}" "${JAVA_PUBLIC_TRUSTSTORE}" "${JAVA_PUBLIC_TRUSTSTORE_PASSWORD}" >> "${tmp}"
  fi
  echo '# END MANAGED RHEL9 FIPS' >> "${tmp}"
  if ! cmp -s "${tmp}" "${CM_SERVER_DEFAULTS_FILE}"; then
    timestamped_backup "${CM_SERVER_DEFAULTS_FILE}"
    cat "${tmp}" > "${CM_SERVER_DEFAULTS_FILE}"
  fi
  rm -f -- "${tmp}"

  chown "root:${CLOUDERA_SERVICE_GROUP}" "${CM_SERVER_DEFAULTS_FILE}"
  chmod 0640 "${CM_SERVER_DEFAULTS_FILE}"
  configure_agent_fips_environment
}
configure_agent_fips_environment() {
  mkdir -p "${CM_AGENT_SYSTEMD_FIPS_DIR}" "${CM_SUPERVISORD_SYSTEMD_FIPS_DIR}"
  local file
  for file in "${CM_AGENT_SYSTEMD_FIPS_FILE}" "${CM_SUPERVISORD_SYSTEMD_FIPS_FILE}"; do
  cat > "${file}" <<EOF
[Service]
Environment="JAVA_HOME=${JAVA_HOME_TARGET}"
Environment="JDK_JAVA_OPTIONS=$(fips_java_options)"
EOF
  done
}
cm_local_url() { printf '%s://%s:%s' "${CM_RUNTIME_PROTOCOL}" "${LOCALHOST_NAME}" "${CM_RUNTIME_PORT}"; }
wait_for_cm() {
  local attempt url args=(--fail --silent --show-error --location --proto '=http' --proto-redir '=http' --noproxy '*'
    --connect-timeout "${TCP_CONNECT_TIMEOUT_SECONDS}" --max-time "${CURL_HEAD_MAX_TIME_SECONDS}")
  url="${CM_RUNTIME_PROTOCOL}://${MANAGER_HOST}:${CM_RUNTIME_PORT}"
  for ((attempt=1; attempt<=CM_WAIT_ATTEMPTS; attempt++)); do
    if curl "${args[@]}" --output /dev/null "${url}" 2>/dev/null; then
      echo "[OK] CM responds at ${url}"; return 0
    fi
    systemctl is-active --quiet "${CM_SERVER_SERVICE}" || {
      echo '[ERROR] CM server stopped during startup; inspect its journal and server log'; return 1;
    }
    sleep "${CM_WAIT_INTERVAL_SECONDS}"
  done
  echo "[ERROR] CM did not respond at ${url}; inspect ${CM_SERVER_LOG_FILE}"; return 1
}
fips_keytool() {
  local opts=() jvm=() item
  read -r -a opts <<< "$(fips_java_options)"
  for item in "${opts[@]}"; do jvm+=("-J${item}"); done
  "${JAVA_HOME_TARGET}/bin/keytool" "${jvm[@]}" "$@"
}
prepare_java_public_roots() {
  # Java defaults to BCFKS in FIPS mode. Preserve the JDK's existing public roots
  # for outbound archive downloads without requiring any customer CA or key.
  local temp opts=()
  temp="$(mktemp -d)"
  read -r -a opts <<< "$(fips_java_options)"
  if ! env -u JDK_JAVA_OPTIONS "${JAVA_HOME_TARGET}/bin/java" "${opts[@]}" \
      "${SCRIPT_DIR}/lib/TruststoreTool.java" "${temp}/public-roots.bcfks"; then
    rm -rf -- "${temp}"; return 1
  fi
  install -o root -g root -m "${JAVA_RUNTIME_TRUSTSTORE_MODE}" \
    "${temp}/public-roots.bcfks" "${JAVA_PUBLIC_TRUSTSTORE}"
  rm -rf -- "${temp}"
}
validate_install_inputs() {
  local install_role="${1:-agent}"
  (( MIN_FIPS_PASSWORD_LENGTH >= 14 )) || { echo '[ERROR] FIPS password minimum cannot be below 14'; return 1; }
  require_cloudera_credentials
  [[ -n "${MANAGER_HOST}" && "${MANAGER_HOST}" != *[[:space:]/]* ]] || { echo '[ERROR] Set MANAGER_HOST to the cluster DNS hostname in EXPORTS'; return 1; }
  [[ "${REQUIRE_FIPS}" == true && "${CONFIGURE_JAVA_FIPS}" == true && "${JAVA_INSTALL_MODE}" == custom ]] || { echo '[ERROR] RHEL9 profile requires OS FIPS, configured FIPS providers, and upstream JDKs'; return 1; }
  [[ "${INSTALL_PROFILE}" == http-lab && "${DB_SSLMODE}" == disable && "${CM_RUNTIME_PROTOCOL}" == http ]] || {
    echo '[ERROR] Use the new HTTP lab EXPORTS: INSTALL_PROFILE=http-lab, DB_SSLMODE=disable, CM_RUNTIME_PROTOCOL=http'; return 1;
  }
  local name value
  for name in CM_DB_PASS RM_DB_PASS REG_DB_PASS NIFI_SENSITIVE_PROPS_KEY; do
    value="${!name}"
    [[ ${#value} -ge ${MIN_FIPS_PASSWORD_LENGTH} && "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || {
      echo "[ERROR] ${name} must be single-line and have at least ${MIN_FIPS_PASSWORD_LENGTH} characters"; return 1;
    }
  done
  # Java is installed by step 04. Preflight must work on a clean host without
  # JDK homes, JDK archives or archive checksums; validate those only in step 04.
}

