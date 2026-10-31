#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for test_script in \
  run_inventory_generation_test.sh \
  run_ssh_setup_sandbox_test.sh \
  run_offline_workflow_test.sh \
  run_negative_validation_tests.sh \
  run_customer_chain_test.sh \
  run_unencrypted_external_key_test.sh \
  run_key_mode_mismatch_tests.sh; do
  echo "===== ${test_script} ====="
  bash "${SCRIPT_DIR}/${test_script}"
done

echo '[OK] All Auto-TLS offline tests passed.'
