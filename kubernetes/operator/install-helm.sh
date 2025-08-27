#!/usr/bin/env bash
set -euo pipefail

NS="tailscale"
RELEASE="tailscale-operator"
CHART="${CHART:-tailscale/tailscale-operator}"

# Optionally pin a chart version by exporting VERSION=1.86.5 (or similar).
# If VERSION is unset, Helm will install the latest available chart version.
VERSION="${VERSION:-}"

echo "[+] Ensuring namespace '${NS}' exists"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

echo "[+] Adding/updating Tailscale Helm repo"
helm repo add tailscale https://pkgs.tailscale.com/helmcharts >/dev/null 2>&1 || true
helm repo update

echo "[+] Verifying OAuth secret exists (operator-oauth)"
if ! kubectl -n "${NS}" get secret operator-oauth >/dev/null 2>&1; then
  echo "ERROR: Secret 'operator-oauth' not found in namespace '${NS}'."
  echo "Create it first (do NOT commit credentials):"
  echo '  kubectl -n tailscale create secret generic operator-oauth \'
  echo '    --from-literal=client_id="tsc_xxx" \'
  echo '    --from-literal=client_secret="tskey-client-xxx"'
  exit 1
fi

echo "[+] Installing/Upgrading Tailscale Operator release '${RELEASE}'"
if [[ -n "${VERSION}" ]]; then
  helm upgrade --install "${RELEASE}" "${CHART}" \
    --namespace "${NS}" \
    --version "${VERSION}" \
    --values kubernetes/operator/values.yaml \
    --wait
else
  helm upgrade --install "${RELEASE}" "${CHART}" \
    --namespace "${NS}" \
    --values kubernetes/operator/values.yaml \
    --wait
fi

echo ""
echo "Tailscale Operator installed."
echo "    Check status with:"
echo "      kubectl -n ${NS} get deploy,po"
