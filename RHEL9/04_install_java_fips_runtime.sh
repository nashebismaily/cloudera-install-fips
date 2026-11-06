#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
need_root
log_init 04_install_java_fips_runtime
validate_platform
require_artifact_lock

# Use the RHEL repository packages requested for this deployment. Do not invoke
# the upstream downloader or require JAVA_DOWNLOAD_* / archive settings.
# Package scripts and the initial version probes must not inherit provider
# options that refer to a Java installation which has not been configured yet.
unset JDK_JAVA_OPTIONS JAVA_TOOL_OPTIONS _JAVA_OPTIONS
dnf install -y \
  "java-${JAVA_MAJOR}-openjdk" "java-${JAVA_MAJOR}-openjdk-devel" \
  "java-${CFM_JAVA_MAJOR}-openjdk" "java-${CFM_JAVA_MAJOR}-openjdk-devel"

find_rhel_jdk_home() {
  local major="$1" package suffix vendor arch files path home stable
  for suffix in '' '-headless' '-devel'; do
    package="java-${major}-openjdk${suffix}"
    vendor="$(rpm -q --qf '%{VENDOR}' "${package}")" || return 1
    arch="$(rpm -q --qf '%{ARCH}' "${package}")" || return 1
    [[ "${vendor}" == 'Red Hat, Inc.' && "${arch}" == "${REQUIRED_ARCH}" ]] || {
      echo "[ERROR] Expected the RHEL ${REQUIRED_ARCH} package ${package}; got vendor=${vendor}, arch=${arch}" >&2
      return 1
    }
  done
  # Ask the installed development RPM, rather than choosing an old JDK from
  # a directory glob or whichever major currently owns the java alternative.
  files="$(rpm -ql "java-${major}-openjdk-devel")" || return 1
  while IFS= read -r path; do
    [[ "${path}" == */bin/javac && -x "${path}" ]] || continue
    path="$(readlink -f -- "${path}")" || return 1
    home="$(dirname "$(dirname "${path}")")"
    [[ -x "${home}/bin/java" && -x "${home}/bin/jar" && -x "${home}/bin/keytool" ]] || continue
    stable="${JAVA_SEARCH_ROOT}/java-${major}-openjdk"
    if [[ "${stable}" -ef "${home}" ]]; then
      printf '%s\n' "${stable}"
    else
      printf '%s\n' "${home}"
    fi
    return 0
  done <<< "${files}"
  echo "[ERROR] The installed RHEL JDK ${major} development RPM has no complete Java home" >&2
  return 1
}

link_configured_java_home() {
  local target="$1" native_home="$2" backup
  [[ "${target}" == /* && "${target}" != / ]] || {
    echo '[ERROR] Configured Java homes must be absolute JDK directory paths' >&2
    return 1
  }
  if [[ "${target}" -ef "${native_home}" ]]; then
    echo "[OK] Configured Java home already resolves to the RHEL JDK: ${target}"
    return 0
  fi
  # Retain a previous downloaded JDK or old alias instead of deleting it.
  if [[ -e "${target}" || -L "${target}" ]]; then
    backup="${target}.before-rhel.$(date +%Y%m%d_%H%M%S_%N)"
    mv -T -- "${target}" "${backup}"
    echo "[INFO] Previous Java home preserved at ${backup}"
  fi
  install -d -m 0755 "$(dirname "${target}")"
  ln -s -- "${native_home}" "${target}"
  echo "[OK] ${target} -> ${native_home}"
}

cm_native_home="$(find_rhel_jdk_home "${JAVA_MAJOR}")"
cfm_native_home="$(find_rhel_jdk_home "${CFM_JAVA_MAJOR}")"
validate_java_home "${cm_native_home}" "${JAVA_MAJOR}"
validate_java_home "${cfm_native_home}" "${CFM_JAVA_MAJOR}"
[[ "${JAVA_HOME_TARGET}" != "${CFM_JAVA_HOME}" ]] || {
  echo '[ERROR] CM and CFM must have separate Java homes'; exit 1;
}
link_configured_java_home "${JAVA_HOME_TARGET}" "${cm_native_home}"
link_configured_java_home "${CFM_JAVA_HOME}" "${cfm_native_home}"

# RPMs register the real, versioned executables with alternatives. Select those
# registrations rather than attempting to register the configured alias paths.
"${JAVA_ALTERNATIVES_COMMAND}" --set java "$(readlink -f -- "${cm_native_home}/bin/java")"
"${JAVA_ALTERNATIVES_COMMAND}" --set javac "$(readlink -f -- "${cm_native_home}/bin/javac")"

# Retain CCJ4 / BCJSSE / Cloudera SASL, approved-only checks and the existing
# security.useSystemPropertiesFile=false setting for these Java installations.
# The latter prevents RHEL's automatic NSS provider selection from replacing
# the explicit SafeLogic provider list. OS FIPS remains enabled and validated.
configure_java_fips_safelogic
prepare_java_public_roots
echo '[OK] RHEL OpenJDKs installed; CM/CDP and CFM SafeLogic FIPS checks passed.'

