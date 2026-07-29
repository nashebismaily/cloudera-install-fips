#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'USAGE'
Usage: sudo -E bash run_autotls.sh <command> [--yes]

Commands:
  inventory       Create hosts.csv automatically when it does not exist.
  setup-ssh       Create the dedicated Auto-TLS SSH user/key and distribute it.
  prepare-csrs    Prepare directories, generate/reuse keys+CSRs, package CSRs.
  test            Run the complete test-CA workflow through dry/live submission.
  customer        Run the customer-certificate workflow. Stops if issued certs are absent.
  validate        Validate returned certs, build stores, and run all validations.
  enable          Setup SSH, validate everything, and run the Auto-TLS submission step.
  post-restart    Restart CM server/agents/management service/clusters after enablement.
  reset           Remove AUTO_TLS_LOCATION only. Requires --yes.
  all             Select test or customer workflow from AUTO_TLS_CERT_MODE.

AUTO_TLS_DRY_RUN=true builds and validates the payload without contacting CM.
AUTO_TLS_DRY_RUN=false performs the live generateCmca API call.
USAGE
}

run_step() {
  local script="$1"
  echo
  echo "========================================================================"
  echo "[STEP] ${script}"
  echo "========================================================================"
  bash "${SCRIPT_DIR}/${script}"
}

prepare_inventory() {
  run_step 00_prepare_inventory.sh
}

setup_ssh() {
  prepare_inventory
  if [[ "${AUTO_TLS_SSH_AUTO_SETUP}" == "true" ]]; then
    run_step 00_setup_autotls_ssh.sh
  else
    echo "[INFO] AUTO_TLS_SSH_AUTO_SETUP=false; SSH setup was not changed"
  fi
}

prepare_csrs() {
  prepare_inventory
  run_step 00_prepare_dirs.sh
  run_step 01_generate_keys_csrs.sh
  run_step 02_package_customer_csrs.sh
}

validate_and_build() {
  run_step 05_validate_issued_certificates.sh
  run_step 06_build_pkcs12_stores.sh
  run_step 07_validate_artifacts.sh
  run_step 08_validate_autotls_prereqs.sh
}

issued_artifacts_present() {
  [[ -f "${AUTO_TLS_ISSUED_CA_CHAIN_FILE}" ]] || return 1
  local host
  while read -r host; do
    [[ -f "${AUTO_TLS_CERT_DIR}/${host}-cert.pem" ]] || return 1
  done < <(read_host_ids)
}

run_test_workflow() {
  [[ "${AUTO_TLS_CERT_MODE}" == "test" ]] || fail "Set AUTO_TLS_CERT_MODE=test for the test workflow"
  setup_ssh
  prepare_csrs
  run_step 03_create_test_ca.sh
  run_step 04_sign_csrs_with_test_ca.sh
  validate_and_build
  run_step 09_enable_autotls.sh
}

run_customer_workflow() {
  [[ "${AUTO_TLS_CERT_MODE}" == "customer" ]] || fail "Set AUTO_TLS_CERT_MODE=customer for the customer workflow"
  setup_ssh
  prepare_csrs
  if ! issued_artifacts_present; then
    echo
    echo "[STOP] Customer-issued certificates are not present yet."
    echo "[INFO] Send this package to the customer CA team:"
    echo "       ${AUTO_TLS_CSR_PACKAGE_FILE}"
    echo "[INFO] Place returned files here using the exact names in the manifest:"
    echo "       ${AUTO_TLS_CERT_DIR}"
    echo "[INFO] Required CA chain: ${AUTO_TLS_ISSUED_CA_CHAIN_FILE}"
    echo "[INFO] After the files are returned, run: sudo -E bash run_autotls.sh customer"
    exit 2
  fi
  validate_and_build
  run_step 09_enable_autotls.sh
}

command="${1:-}"
case "${command}" in
  inventory)
    prepare_inventory
    ;;
  setup-ssh)
    setup_ssh
    ;;
  prepare-csrs)
    prepare_csrs
    ;;
  test)
    run_test_workflow
    ;;
  customer)
    run_customer_workflow
    ;;
  validate)
    validate_and_build
    ;;
  enable)
    setup_ssh
    validate_and_build
    run_step 09_enable_autotls.sh
    ;;
  post-restart)
    run_step 10_post_enable_restart.sh
    ;;
  reset)
    [[ "${2:-}" == "--yes" ]] || fail "Reset requires: run_autotls.sh reset --yes"
    [[ -n "${AUTO_TLS_LOCATION}" && "${AUTO_TLS_LOCATION}" != "/" ]] || fail "Unsafe AUTO_TLS_LOCATION"
    rm -rf -- "${AUTO_TLS_LOCATION}"
    echo "[OK] Removed Auto-TLS staging location: ${AUTO_TLS_LOCATION}"
    ;;
  all)
    if [[ "${AUTO_TLS_CERT_MODE}" == "test" ]]; then
      run_test_workflow
    else
      run_customer_workflow
    fi
    ;;
  -h|--help|help|'')
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
