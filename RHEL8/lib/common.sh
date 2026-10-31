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

log_init() {
  local name="$1"
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
  systemctl list-unit-files --type=service --no-legend "${1}" 2>/dev/null | awk '{print $1}' | grep -qx "${1}"
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
    fips-mode-setup --check || true
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
  curl "${args[@]}" -I -L \
    --connect-timeout "${CURL_PREFLIGHT_CONNECT_TIMEOUT_SECONDS}" \
    --max-time "${CURL_PREFLIGHT_MAX_TIME_SECONDS}" \
    "${url}" >/dev/null 2>&1
}

curl_head_auth() {
  local url="$1" args=()
  if [[ "${CURL_INSECURE}" == "true" ]]; then args+=('-k'); fi
  curl "${args[@]}" -I -L \
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

java_home_target() {
  if [[ -n "${CUSTOM_JAVA_HOME}" ]]; then
    echo "${CUSTOM_JAVA_HOME}"
  else
    echo "${JAVA_HOME_TARGET}"
  fi
}

find_registered_java_binary() {
  local desired_major="$1"
  if command -v "${JAVA_ALTERNATIVES_COMMAND}" >/dev/null 2>&1; then
    "${JAVA_ALTERNATIVES_COMMAND}" --display java 2>/dev/null \
      | awk -v root="${JAVA_SEARCH_ROOT}" -v major="${desired_major}" '
          $1 ~ "^" root "/java-" major "-openjdk" && $1 ~ "/bin/java$" { print $1; exit }
        '
  fi
}

find_java_binary_on_disk() {
  local desired_major="$1"
  find "${JAVA_SEARCH_ROOT}" -path '*/bin/java' \( -type f -o -type l \) -print 2>/dev/null \
    | grep -E "/java-${desired_major}-openjdk[^/]*/bin/java$" \
    | grep -v '/jre/bin/java$' \
    | sort \
    | head -n 1
}

normalize_legacy_java_home_files() {
  [[ "${JAVA_NORMALIZE_LEGACY_HOME}" == "true" ]] || return 0
  local file escaped_target
  escaped_target="$(printf '%s' "${JAVA_HOME_TARGET}" | sed 's/[][\\.^$*+?{}|()]/\\&/g')"
  for file in "${JAVA_PROFILE_FILE}" "${JAVA_DEFAULT_FILE}" "${CM_SERVER_DEFAULTS_FILE}"; do
    [[ -f "${file}" ]] || continue
    sed -E -i "s#${escaped_target}-[^ '\"[:space:]]+#${JAVA_HOME_TARGET}#g" "${file}" || true
  done
}

ensure_java_default() {
  local desired_major java_bin java_home javac_bin
  desired_major="${JAVA_MAJOR}"

  case "${JAVA_INSTALL_MODE}" in
    custom)
      java_home="$(java_home_target)"
      java_bin="${java_home}/bin/java"
      [[ -x "${java_bin}" ]] || { echo "[ERROR] Custom Java binary is missing: ${java_bin}"; exit 1; }
      ;;
    system)
      java_bin="$(find_registered_java_binary "${desired_major}")"
      if [[ -z "${java_bin}" || ! -x "${java_bin}" ]]; then
        java_bin="$(find_java_binary_on_disk "${desired_major}")"
      fi
      if [[ -z "${java_bin}" || ! -x "${java_bin}" ]]; then
        echo "[ERROR] Could not find Java ${desired_major} under ${JAVA_SEARCH_ROOT}."
        find "${JAVA_SEARCH_ROOT}" -path '*/bin/java' \( -type f -o -type l \) -print 2>/dev/null || true
        "${JAVA_ALTERNATIVES_COMMAND}" --display java 2>/dev/null || true
        exit 1
      fi

      if command -v "${JAVA_ALTERNATIVES_COMMAND}" >/dev/null 2>&1; then
        echo "[INFO] Setting java alternative to registered/versioned binary: ${java_bin}"
        if ! "${JAVA_ALTERNATIVES_COMMAND}" --set java "${java_bin}"; then
          "${JAVA_ALTERNATIVES_COMMAND}" --install "${JAVA_ALTERNATIVE_LINK}" java "${java_bin}" "${JAVA_ALTERNATIVE_PRIORITY}"
          "${JAVA_ALTERNATIVES_COMMAND}" --set java "${java_bin}"
        fi
        javac_bin="${java_bin%/java}/javac"
        if [[ -x "${javac_bin}" ]]; then
          if ! "${JAVA_ALTERNATIVES_COMMAND}" --set javac "${javac_bin}" >/dev/null 2>&1; then
            "${JAVA_ALTERNATIVES_COMMAND}" --install "${JAVAC_ALTERNATIVE_LINK}" javac "${javac_bin}" "${JAVA_ALTERNATIVE_PRIORITY}" >/dev/null 2>&1 || true
            "${JAVA_ALTERNATIVES_COMMAND}" --set javac "${javac_bin}" >/dev/null 2>&1 || true
          fi
        fi
      fi

      # Critical live-install fix: alternatives uses the full versioned binary,
      # but Cloudera Manager receives the stable unversioned JAVA_HOME.
      java_home="${JAVA_HOME_TARGET}"
      [[ -x "${java_home}/bin/java" ]] || {
        echo "[ERROR] Stable JAVA_HOME is missing its Java binary: ${java_home}/bin/java"
        echo "[INFO] Versioned Java selected for alternatives: ${java_bin}"
        exit 1
      }
      ;;
    skip)
      return 0
      ;;
    *)
      echo "[ERROR] Invalid JAVA_INSTALL_MODE=${JAVA_INSTALL_MODE}. Use system, custom, or skip."
      exit 1
      ;;
  esac

  export JAVA_HOME="${java_home}"
  export PATH="${JAVA_HOME}/bin:${PATH}"

  mkdir -p "$(dirname "${JAVA_PROFILE_FILE}")" "$(dirname "${JAVA_DEFAULT_FILE}")"
  cat >"${JAVA_PROFILE_FILE}" <<EOFJAVA
export JAVA_HOME='${JAVA_HOME}'
export PATH=\$JAVA_HOME/bin:\$PATH
EOFJAVA
  cat >"${JAVA_DEFAULT_FILE}" <<EOFJAVADEFAULT
export JAVA_HOME='${JAVA_HOME}'
EOFJAVADEFAULT
  normalize_legacy_java_home_files

  echo "[OK] JAVA_HOME=${JAVA_HOME}"
  echo "[OK] Active java=$(readlink -f "$(command -v java)")"
}

validate_java_11() {
  local java_bin version_output version_line detected
  if [[ -n "${CUSTOM_JAVA_HOME}" ]]; then
    java_bin="${CUSTOM_JAVA_HOME}/bin/java"
  elif [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    java_bin="${JAVA_HOME}/bin/java"
  else
    java_bin="$(command -v java || true)"
  fi

  [[ -n "${java_bin}" && -x "${java_bin}" ]] || { echo "[ERROR] Java executable not found."; exit 1; }
  version_output="$(${java_bin} -version 2>&1 || true)"
  version_line="$(printf '%s\n' "${version_output}" | grep -E '^(openjdk|java) version ' | head -1)"
  echo "Java executable: ${java_bin}"
  echo "Java version: ${version_line:-unknown}"

  if [[ "${version_line}" =~ version\ \"1\.([0-9]+)\. ]]; then
    detected="${BASH_REMATCH[1]}"
  elif [[ "${version_line}" =~ version\ \"([0-9]+)\. ]]; then
    detected="${BASH_REMATCH[1]}"
  else
    detected='unknown'
  fi
  if [[ "${detected}" != "${JAVA_MAJOR}" ]]; then
    echo "${version_output}"
    echo "[ERROR] Java ${JAVA_MAJOR} required, detected Java major version: ${detected}"
    "${JAVA_ALTERNATIVES_COMMAND}" --display java 2>/dev/null || true
    exit 1
  fi
  echo "[OK] Java ${JAVA_MAJOR} validation passed"
}

required_agent_python_bin() { echo "${CM_AGENT_PYTHON_BIN}"; }

install_required_agent_python() {
  local pybin packages=()
  pybin="$(required_agent_python_bin)"
  if [[ -x "${pybin}" ]]; then
    echo "[OK] Required CM agent Python present: ${pybin} ($(${pybin} --version 2>&1))"
    return 0
  fi

  echo "==== Installing required CM agent Python runtime ===="
  if [[ -n "${CM_AGENT_PYTHON_MODULE}" ]]; then
    dnf module enable -y "${CM_AGENT_PYTHON_MODULE}" >/dev/null 2>&1 || true
  fi
  read -r -a packages <<< "${CM_AGENT_PYTHON_PACKAGES}"
  [[ ${#packages[@]} -gt 0 ]] || { echo "[ERROR] CM_AGENT_PYTHON_PACKAGES is empty."; exit 1; }
  dnf install -y "${packages[@]}"
  [[ -x "${pybin}" ]] || { echo "[ERROR] Required Python binary is still missing: ${pybin}"; exit 1; }
  echo "[OK] Required CM agent Python installed: ${pybin} ($(${pybin} --version 2>&1))"
}

validate_cm_agent_python_wrapper() {
  local wrapper version rc
  wrapper="${CM_AGENT_PYTHON_WRAPPER}"
  if [[ ! -e "${wrapper}" ]]; then
    echo "[INFO] CM agent Python wrapper not present yet: ${wrapper}"
    return 0
  fi
  set +e
  version="$(${wrapper} --version 2>&1)"
  rc=$?
  set -e
  echo "CM agent Python wrapper: ${wrapper}"
  echo "CM agent Python wrapper version output: ${version}"
  if [[ ${rc} -ne 0 ]]; then
    echo "[ERROR] CM agent Python wrapper failed with exit code ${rc}."
    echo "[INFO] Required Python binary: ${CM_AGENT_PYTHON_BIN}"
    exit 1
  fi
  if [[ "${CM_AGENT_PYTHON_STRICT_VERSION}" == "true" && "${version}" != *"${CM_AGENT_PYTHON_EXPECTED_VERSION}"* ]]; then
    echo "[ERROR] Expected ${CM_AGENT_PYTHON_EXPECTED_VERSION}, got: ${version}"
    exit 1
  fi
  echo "[OK] CM agent Python wrapper is usable."
}

install_hue_fips_psycopg2() {
  [[ "${INSTALL_HUE_FIPS_PSYCOPG2}" == "true" ]] || { echo "[INFO] Skipping Hue psycopg2 installation."; return 0; }
  local pybin pg_config import_out wrapper_out packages=()
  pybin="${HUE_PSYCOPG2_PYTHON_BIN}"
  pg_config="${PG_BIN_DIR}/pg_config"
  echo "==== Installing FIPS-safe psycopg2 for Hue/PostgreSQL readiness ===="
  [[ -x "${pybin}" ]] || { echo "[ERROR] Python binary missing: ${pybin}"; exit 1; }
  read -r -a packages <<< "${HUE_PSYCOPG2_BUILD_PACKAGES}"
  dnf install -y "${packages[@]}"
  [[ -x "${pg_config}" ]] || { echo "[ERROR] pg_config not found: ${pg_config}"; exit 1; }

  export PATH="${PG_BIN_DIR}:${PATH}"
  export PG_CONFIG="${pg_config}"
  "${pybin}" -m pip uninstall -y psycopg2 psycopg2-binary || true
  "${pybin}" -m pip install --upgrade "${HUE_PIP_VERSION_SPEC}" setuptools wheel
  "${pybin}" -m pip install --no-binary=:all: "psycopg2==${HUE_PSYCOPG2_VERSION}"
  import_out="$(${pybin} - <<'PY'
import psycopg2
print(psycopg2.__version__)
PY
)"
  [[ "${import_out}" == "${HUE_PSYCOPG2_VERSION}"* ]] || { echo "[ERROR] Unexpected psycopg2 version: ${import_out}"; exit 1; }

  if [[ -x "${CM_AGENT_PYTHON_WRAPPER}" ]]; then
    wrapper_out="$(${CM_AGENT_PYTHON_WRAPPER} - <<'PY'
import psycopg2
print(psycopg2.__version__)
PY
)"
    [[ "${wrapper_out}" == "${HUE_PSYCOPG2_VERSION}"* ]] || { echo "[ERROR] CM wrapper cannot see expected psycopg2."; exit 1; }
  fi
  echo "[OK] FIPS-safe psycopg2 ${HUE_PSYCOPG2_VERSION} installed from source."
}

validate_hue_fips_psycopg2() {
  [[ "${INSTALL_HUE_FIPS_PSYCOPG2}" == "true" ]] || return 0
  local pybin out rc
  pybin="${HUE_PSYCOPG2_PYTHON_BIN}"
  [[ -x "${pybin}" ]] || { echo "[WARN] psycopg2 validation skipped; Python missing: ${pybin}"; return 0; }
  set +e
  out="$(${pybin} - <<'PY'
import psycopg2
print(psycopg2.__version__)
PY
 2>&1)"
  rc=$?
  set -e
  echo "psycopg2 via ${pybin}: ${out}"
  if [[ ${rc} -ne 0 || "${out}" != "${HUE_PSYCOPG2_VERSION}"* ]]; then
    echo "[WARN] Expected source-built psycopg2 ${HUE_PSYCOPG2_VERSION}."
  fi
}

ensure_line() {
  local file="$1" line="$2"
  grep -qxF "${line}" "${file}" 2>/dev/null || echo "${line}" >> "${file}"
}

timestamped_backup() {
  local file="$1" backup
  [[ -f "${file}" ]] || { echo "[ERROR] Cannot back up missing file: ${file}"; exit 1; }
  backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "${file}" "${backup}"
  echo "[OK] Backed up ${file} to ${backup}"
}

java_fips_dir() { echo "${JAVA_FIPS_DIR}"; }
java_fips_ccj_jar() { echo "${JAVA_FIPS_CCJ_JAR}"; }
java_fips_bctls_jar() { echo "${JAVA_FIPS_BCTLS_JAR}"; }
java_fips_ccj_module() { echo "${JAVA_FIPS_CCJ_MODULE}"; }
java_fips_bctls_module() { echo "${JAVA_FIPS_BCTLS_MODULE}"; }

stage_java_fips_jars() {
  local active_dir ccj_src bctls_src ccj_dest bctls_dest
  active_dir="${JAVA_FIPS_DIR}"
  ccj_src="${FIPS_JAR_SOURCE_DIR}/${FIPS_CCJ_JAR}"
  bctls_src="${FIPS_JAR_SOURCE_DIR}/${FIPS_BCTLS_JAR}"
  ccj_dest="${active_dir}/${JAVA_FIPS_CCJ_JAR}"
  bctls_dest="${active_dir}/${JAVA_FIPS_BCTLS_JAR}"

  [[ -f "${ccj_src}" ]] || { echo "[ERROR] Missing SafeLogic CCJ jar: ${ccj_src}"; exit 1; }
  [[ -f "${bctls_src}" ]] || { echo "[ERROR] Missing SafeLogic BCTLS jar: ${bctls_src}"; exit 1; }

  mkdir -p "${active_dir}"
  chmod "${JAVA_FIPS_DIR_MODE}" "${active_dir}"
  cp -af "${ccj_src}" "${ccj_dest}"
  cp -af "${bctls_src}" "${bctls_dest}"
  chown "${JAVA_FIPS_OWNER}" "${ccj_dest}" "${bctls_dest}"
  chmod "${JAVA_FIPS_JAR_MODE}" "${ccj_dest}" "${bctls_dest}"
  restorecon -Rv "${active_dir}" 2>/dev/null || true
  echo "[OK] Active Java FIPS jars staged:"
  ls -lh "${active_dir}"
}

write_jdk_java_options_profile() {
  local ccj_jar bctls_jar opts
  ccj_jar="${JAVA_FIPS_DIR}/${JAVA_FIPS_CCJ_JAR}"
  bctls_jar="${JAVA_FIPS_DIR}/${JAVA_FIPS_BCTLS_JAR}"
  opts="--module-path=${ccj_jar}:${bctls_jar} --add-exports ${JAVA_FIPS_ADD_EXPORT}=${JAVA_FIPS_CCJ_MODULE} --add-modules ${JAVA_FIPS_CCJ_MODULE},${JAVA_FIPS_BCTLS_MODULE}"
  mkdir -p "$(dirname "${JAVA_FIPS_PROFILE_FILE}")"
  cat >"${JAVA_FIPS_PROFILE_FILE}" <<EOFCCJ
export JDK_JAVA_OPTIONS='${opts}'
EOFCCJ
  chmod "${JAVA_FIPS_PROFILE_MODE}" "${JAVA_FIPS_PROFILE_FILE}"
  export JDK_JAVA_OPTIONS="${opts}"
  echo "[OK] Wrote ${JAVA_FIPS_PROFILE_FILE}"
}

patch_java_policy_for_fips() {
  local policy_file ccj_jar bctls_jar tmp
  policy_file="${JAVA_HOME}/${JAVA_POLICY_RELATIVE_PATH}"
  ccj_jar="${JAVA_FIPS_DIR}/${JAVA_FIPS_CCJ_JAR}"
  bctls_jar="${JAVA_FIPS_DIR}/${JAVA_FIPS_BCTLS_JAR}"
  [[ -f "${policy_file}" ]] || { echo "[ERROR] Missing Java policy file: ${policy_file}"; exit 1; }
  timestamped_backup "${policy_file}"
  tmp="$(mktemp)"
  awk '
    /BEGIN MANAGED BY cfm_fips_install - SafeLogic permissions/ {skip=1; next}
    /END MANAGED BY cfm_fips_install - SafeLogic permissions/ {skip=0; next}
    skip != 1 {print}
  ' "${policy_file}" > "${tmp}"
  cat >>"${tmp}" <<EOFPOLICY

// BEGIN MANAGED BY cfm_fips_install - SafeLogic permissions
grant codeBase "file:${ccj_jar}" {
    permission java.security.AllPermission;
};
grant codeBase "file:${bctls_jar}" {
    permission java.security.AllPermission;
};
// END MANAGED BY cfm_fips_install - SafeLogic permissions
EOFPOLICY
  cat "${tmp}" > "${policy_file}"
  rm -f "${tmp}"
  echo "[OK] Patched ${policy_file}"
}

patch_java_security_for_fips() {
  local security_file
  security_file="${JAVA_HOME}/${JAVA_SECURITY_RELATIVE_PATH}"
  [[ -f "${security_file}" ]] || { echo "[ERROR] Missing Java security file: ${security_file}"; exit 1; }
  timestamped_backup "${security_file}"

  JAVA_SECURITY_FILE="${security_file}" \
  JAVA_FIPS_CCJ_PROVIDER_CLASS="${JAVA_FIPS_CCJ_PROVIDER_CLASS}" \
  JAVA_FIPS_BCTLS_PROVIDER_CLASS="${JAVA_FIPS_BCTLS_PROVIDER_CLASS}" \
  JAVA_FIPS_BCTLS_PROVIDER_ARGUMENT="${JAVA_FIPS_BCTLS_PROVIDER_ARGUMENT}" \
  JAVA_FIPS_STANDARD_PROVIDERS="${JAVA_FIPS_STANDARD_PROVIDERS}" \
  JAVA_FIPS_KEY_MANAGER_ALGORITHM="${JAVA_FIPS_KEY_MANAGER_ALGORITHM}" \
  JAVA_FIPS_TRUST_MANAGER_ALGORITHM="${JAVA_FIPS_TRUST_MANAGER_ALGORITHM}" \
  JAVA_SECURITY_USE_SYSTEM_PROPERTIES_FILE="${JAVA_SECURITY_USE_SYSTEM_PROPERTIES_FILE}" \
  "${SYSTEM_PYTHON_BIN}" - <<'PY'
from pathlib import Path
import os

p = Path(os.environ["JAVA_SECURITY_FILE"])
lines = p.read_text().splitlines()
begin = "# BEGIN MANAGED BY cfm_fips_install - SafeLogic providers"
end = "# END MANAGED BY cfm_fips_install - SafeLogic providers"
filtered = []
skip = False
for line in lines:
    if line.strip() == begin:
        skip = True
        continue
    if line.strip() == end:
        skip = False
        continue
    if not skip:
        filtered.append(line)

new_lines = []
for line in filtered:
    stripped = line.strip()
    managed_prefixes = (
        "security.useSystemPropertiesFile=", "security.provider.", "fips.provider.",
        "ssl.KeyManagerFactory.algorithm=", "ssl.TrustManagerFactory.algorithm=",
    )
    if stripped.startswith(managed_prefixes) and not line.lstrip().startswith("#"):
        new_lines.append("# " + line)
    else:
        new_lines.append(line)

ccj = os.environ["JAVA_FIPS_CCJ_PROVIDER_CLASS"]
bctls = os.environ["JAVA_FIPS_BCTLS_PROVIDER_CLASS"] + " " + os.environ["JAVA_FIPS_BCTLS_PROVIDER_ARGUMENT"]
providers = [ccj, bctls] + os.environ["JAVA_FIPS_STANDARD_PROVIDERS"].split()
block = ["", begin, f"security.useSystemPropertiesFile={os.environ['JAVA_SECURITY_USE_SYSTEM_PROPERTIES_FILE']}", ""]
for prefix in ("security.provider", "fips.provider"):
    for index, provider in enumerate(providers, 1):
        block.append(f"{prefix}.{index}={provider}")
    block.append("")
block.extend([
    f"ssl.KeyManagerFactory.algorithm={os.environ['JAVA_FIPS_KEY_MANAGER_ALGORITHM']}",
    f"ssl.TrustManagerFactory.algorithm={os.environ['JAVA_FIPS_TRUST_MANAGER_ALGORITHM']}",
    end,
])
p.write_text("\n".join(new_lines).rstrip() + "\n" + "\n".join(block) + "\n")
PY
  echo "[OK] Patched ${security_file}"
}

validate_fips_jar_readability_as_cm_user() {
  local ccj_jar bctls_jar output
  ccj_jar="${JAVA_FIPS_DIR}/${JAVA_FIPS_CCJ_JAR}"
  bctls_jar="${JAVA_FIPS_DIR}/${JAVA_FIPS_BCTLS_JAR}"
  if ! id "${CLOUDERA_SERVICE_USER}" >/dev/null 2>&1; then
    echo "[INFO] ${CLOUDERA_SERVICE_USER} user does not exist yet; skipping service-user jar-readability test."
    return 0
  fi
  set +e
  output="$(runuser -u "${CLOUDERA_SERVICE_USER}" -- env -u JDK_JAVA_OPTIONS "${JAVA_HOME}/bin/java" \
    --module-path="${ccj_jar}:${bctls_jar}" --list-modules 2>&1)"
  local rc=$?
  set -e
  echo "${output}" | grep -E 'safelogic|bctls|cryptocomply' || true
  if [[ ${rc} -ne 0 || "${output}" != *"${JAVA_FIPS_CCJ_MODULE}"* || "${output}" != *"${JAVA_FIPS_BCTLS_MODULE}"* ]]; then
    echo "[ERROR] ${CLOUDERA_SERVICE_USER} cannot load the SafeLogic modules."
    echo "[INFO] Check ${FAPOLICYD_SERVICE}, SELinux, ownership, and modes under ${JAVA_FIPS_DIR}."
    exit 1
  fi
  echo "[OK] ${CLOUDERA_SERVICE_USER} can read and load both SafeLogic modules."
}

validate_java_fips_providers() {
  local tmpdir out
  ensure_java_default
  validate_java_11
  [[ -f "${JAVA_FIPS_PROFILE_FILE}" ]] && source "${JAVA_FIPS_PROFILE_FILE}"
  tmpdir="$(mktemp -d)"
  cat >"${tmpdir}/ListSecurityProviders.java" <<'EOFJAVA'
import java.security.Provider;
import java.security.Security;
public class ListSecurityProviders {
  public static void main(String[] args) {
    for (Provider provider : Security.getProviders()) {
      System.out.println("Provider: " + provider.getName());
    }
  }
}
EOFJAVA
  out="$(java "${tmpdir}/ListSecurityProviders.java" 2>&1 || true)"
  rm -rf "${tmpdir}"
  echo "${out}" | grep 'Provider:' || true
  [[ "${out}" == *"Provider: ${JAVA_FIPS_EXPECTED_CCJ_PROVIDER_NAME}"* ]] || { echo "[ERROR] ${JAVA_FIPS_EXPECTED_CCJ_PROVIDER_NAME} provider not loaded."; exit 1; }
  [[ "${out}" == *"Provider: ${JAVA_FIPS_EXPECTED_BCTLS_PROVIDER_NAME}"* ]] || { echo "[ERROR] ${JAVA_FIPS_EXPECTED_BCTLS_PROVIDER_NAME} provider not loaded."; exit 1; }
  validate_fips_jar_readability_as_cm_user
  echo "[OK] Java FIPS providers loaded: ${JAVA_FIPS_EXPECTED_CCJ_PROVIDER_NAME} and ${JAVA_FIPS_EXPECTED_BCTLS_PROVIDER_NAME}"
}

configure_java_fips_safelogic() {
  [[ "${CONFIGURE_JAVA_FIPS}" == "true" ]] || { echo "[INFO] Skipping Java SafeLogic FIPS configuration."; return 0; }
  echo "==== Configuring Java SafeLogic FIPS providers ===="
  ensure_java_default
  validate_java_11
  stage_java_fips_jars
  write_jdk_java_options_profile
  patch_java_policy_for_fips
  patch_java_security_for_fips
  validate_java_fips_providers
}

configure_cm_server_fips_opts() {
  [[ "${CONFIGURE_JAVA_FIPS}" == "true" ]] || return 0
  local defaults ccj_jar bctls_jar tmp
  defaults="${CM_SERVER_DEFAULTS_FILE}"
  ccj_jar="${JAVA_FIPS_DIR}/${JAVA_FIPS_CCJ_JAR}"
  bctls_jar="${JAVA_FIPS_DIR}/${JAVA_FIPS_BCTLS_JAR}"
  mkdir -p "$(dirname "${defaults}")"
  touch "${defaults}"
  timestamped_backup "${defaults}"
  tmp="$(mktemp)"
  awk '
    /BEGIN MANAGED BY cfm_fips_install - CM Server FIPS options/ {skip=1; next}
    /END MANAGED BY cfm_fips_install - CM Server FIPS options/ {skip=0; next}
    skip != 1 {print}
  ' "${defaults}" > "${tmp}"
  cat >>"${tmp}" <<EOFCMF

# BEGIN MANAGED BY cfm_fips_install - CM Server FIPS options
export JAVA_HOME='${JAVA_HOME_TARGET}'
export JDK_JAVA_OPTIONS="\${JDK_JAVA_OPTIONS:-} --module-path=${ccj_jar}:${bctls_jar} --add-exports ${JAVA_FIPS_ADD_EXPORT}=${JAVA_FIPS_CCJ_MODULE} --add-modules ${JAVA_FIPS_CCJ_MODULE},${JAVA_FIPS_BCTLS_MODULE}"
export CMF_JAVA_OPTS="\${CMF_JAVA_OPTS:-} -D${CM_FIPS_MODE_PROPERTY}=true -D${CM_FIPS_APPROVED_ONLY_PROPERTY}=true"
export CMF_JAVA_OPTS="\${CMF_JAVA_OPTS} -D${CM_FIPS_JDK_PROPERTY_PREFIX}.ccj.jar.path=${ccj_jar} -D${CM_FIPS_JDK_PROPERTY_PREFIX}.ccj.moduleName=${JAVA_FIPS_CCJ_MODULE}"
export CMF_JAVA_OPTS="\${CMF_JAVA_OPTS} -D${CM_FIPS_JDK_PROPERTY_PREFIX}.bctls.jar.path=${bctls_jar} -D${CM_FIPS_JDK_PROPERTY_PREFIX}.bctls.moduleName=${JAVA_FIPS_BCTLS_MODULE}"
# END MANAGED BY cfm_fips_install - CM Server FIPS options
EOFCMF
  cat "${tmp}" > "${defaults}"
  rm -f "${tmp}"
  normalize_legacy_java_home_files
  echo "[OK] Wrote CM Server FIPS options to ${defaults}"
}
