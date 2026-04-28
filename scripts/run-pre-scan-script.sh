#!/bin/bash

set -euo pipefail

PRE_SCAN_SCRIPT="${1:-}"

# Treat an empty pre-scan value as a no-op so PR baseline and head scans can share one runner path.
if [ -z "${PRE_SCAN_SCRIPT}" ]; then
  exit 0
fi

if [ -f "${PRE_SCAN_SCRIPT}" ] && [ ! -d "${PRE_SCAN_SCRIPT}" ]; then
  # Repository-owned setup scripts are executed directly so projects can keep complex preparation logic versioned.
  chmod +x "${PRE_SCAN_SCRIPT}"
  "${PRE_SCAN_SCRIPT}"
else
  # Inline scripts preserve the existing action contract while avoiding YAML duplication between base and head scans.
  printf '%s\n' "${PRE_SCAN_SCRIPT}" > pre-scan-script.sh
  chmod +x pre-scan-script.sh
  ./pre-scan-script.sh
fi
