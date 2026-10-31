#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Executable implementation files only. Documentation, EXPORTS, and examples are
# intentionally excluded because EXPORTS is the approved home for these values.
RG_COMMON=(
  --glob '*.sh'
  --glob 'RUN_MANAGER'
  --glob 'RUN_AGENT'
  --glob '!EXPORTS'
  --glob '!README.md'
  --glob '!utilities/tls/README.md'
  --glob '!*.example'
  --glob '!tools/audit_configurability.sh'
)

failures=0

check_pattern() {
  local label="$1"
  local pattern="$2"
  local matches

  matches="$(rg -n "${RG_COMMON[@]}" -- "$pattern" . || true)"
  if [[ -n "$matches" ]]; then
    echo "[ERROR] ${label} found outside EXPORTS:" >&2
    printf '%s\n' "$matches" >&2
    failures=$((failures + 1))
  else
    echo "[OK] ${label}"
  fi
}

check_pattern 'embedded HTTP/HTTPS URL' 'https?://'
check_pattern 'embedded semantic release literal' '(^|[^0-9])[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?([^0-9]|$)'
check_pattern 'embedded repository platform literal' '(redhat[0-9]+|EL-[0-9]+)'
check_pattern 'embedded standard service port' '(^|[^0-9])(7180|7182|7183|5432|2181)([^0-9]|$)'
check_pattern 'embedded absolute operational path' "(['\"])/(etc|opt|var|usr|data|tmp|home|root)/"
check_pattern 'embedded CFM or CSD artifact filename' '(NIFI-[0-9]|NIFIREGISTRY-[0-9]|CFM-[0-9].*\.jar)'

if (( failures > 0 )); then
  echo "[ERROR] Configurability audit failed with ${failures} category failure(s)." >&2
  exit 1
fi

echo '[OK] Configurability audit passed. Runtime URLs, release values, ports, and operational paths are sourced from EXPORTS.'
