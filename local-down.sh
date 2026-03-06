#!/usr/bin/env bash
# local-down.sh — Tear down the local sandbox cluster.
#
# Usage:
#   ./scripts/local-down.sh [--purge]
#
#   --purge   Also delete the locally built Docker image and /tmp/sandbox-gvisor-install

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }

CLUSTER_NAME="sandbox"
OPERATOR_IMAGE="sandbox-operator:local"
PURGE=false

for arg in "$@"; do
  case $arg in
    --purge) PURGE=true ;;
    --help|-h)
      echo "Usage: $0 [--purge]"
      exit 0
      ;;
  esac
done

echo -e "${BOLD}━━━ Tearing down sandbox cluster ━━━${RESET}"
echo ""

# ── Helm uninstall ─────────────────────────────────────────────────────────────
if helm status sandbox -n sandbox-system &>/dev/null 2>&1; then
  info "Uninstalling Helm release 'sandbox'..."
  helm uninstall sandbox -n sandbox-system --wait --timeout 60s
  success "Helm release removed."
else
  warn "Helm release 'sandbox' not found — skipping."
fi

# ── kind cluster delete ────────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "Deleting kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
  success "Cluster '${CLUSTER_NAME}' deleted."
else
  warn "Cluster '${CLUSTER_NAME}' not found — skipping."
fi

# ── Optional purge ─────────────────────────────────────────────────────────────
if [[ "$PURGE" == true ]]; then
  info "Removing Docker image '${OPERATOR_IMAGE}'..."
  docker rmi "${OPERATOR_IMAGE}" 2>/dev/null && success "Image removed." \
    || warn "Image not found — skipping."

  info "Removing /tmp/sandbox-gvisor-install..."
  rm -rf /tmp/sandbox-gvisor-install
  success "Temp files removed."
fi

# ── Clean up kubectl context ────────────────────────────────────────────────────
if kubectl config get-contexts "kind-${CLUSTER_NAME}" &>/dev/null 2>&1; then
  info "Removing kubectl context 'kind-${CLUSTER_NAME}'..."
  kubectl config delete-context "kind-${CLUSTER_NAME}" 2>/dev/null || true
  kubectl config delete-cluster "kind-${CLUSTER_NAME}" 2>/dev/null || true
  kubectl config unset "users.kind-${CLUSTER_NAME}" 2>/dev/null || true
  success "kubectl context cleaned up."
fi

echo ""
success "Teardown complete."
