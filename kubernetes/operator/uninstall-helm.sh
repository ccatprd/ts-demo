#!/usr/bin/env bash
set -euo pipefail

NS="tailscale"
RELEASE="tailscale-operator"

echo "[+] Uninstalling Helm release '${RELEASE}' from namespace '${NS}'"
helm -n "${NS}" uninstall "${RELEASE}" || true

echo "Note: CRDs may remain (normal for Helm)."
echo "If you rendered and applied CRDs manually, remove them with kubectl if needed."
