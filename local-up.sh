#!/usr/bin/env bash
# local-up.sh — Bootstrap the sandbox cluster locally using kind.
#
# What this script does (in order):
#   1.  Check required tools are installed
#   2.  Create the kind cluster (2 execution workers, 1 control-plane)
#   3.  Install Calico CNI (required for NetworkPolicy enforcement)
#   4.  Install gVisor (runsc) into each execution worker node
#   5.  Register the runsc runtime handler with containerd on each node
#   6.  Apply taint  sandbox.k8s.io/execution:NoSchedule  to execution nodes
#   7.  Apply all Kubernetes manifests (namespaces → CRD)
#   8.  Build the sandbox-operator Go binary and Docker image
#   9.  Load the image into kind (no registry needed)
#  10.  Deploy via Helm (operator + Redis)
#  11.  Wait for everything to become Ready
#  12.  Print a usage example
#
# Usage:
#   ./scripts/local-up.sh [--skip-build] [--skip-gvisor]
#
#   --skip-build    Skip Go build + docker build (reuses existing image)
#   --skip-gvisor   Skip gVisor installation (useful if nodes already configured)
#
# Requirements:
#   kind >= 0.22, kubectl >= 1.29, helm >= 3.14, docker, go >= 1.22

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }

# ── Script directory (all paths are relative to project root) ──────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Configuration ──────────────────────────────────────────────────────────────
CLUSTER_NAME="sandbox"
OPERATOR_IMAGE="sandbox-operator:local"
NAMESPACE_CONTROL="sandbox-system"
NAMESPACE_EXECUTION="sandbox-execution"
CALICO_VERSION="v3.27.2"
GVISOR_VERSION="20240212"                          # pinned for reproducibility
GVISOR_ARCH="$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/aarch64/')"

# ── Flags ──────────────────────────────────────────────────────────────────────
SKIP_BUILD=false
SKIP_GVISOR=false
for arg in "$@"; do
  case $arg in
    --skip-build)   SKIP_BUILD=true ;;
    --skip-gvisor)  SKIP_GVISOR=true ;;
    --help|-h)
      echo "Usage: $0 [--skip-build] [--skip-gvisor]"
      exit 0
      ;;
    *) warn "Unknown argument: $arg" ;;
  esac
done

# ── 1. Preflight checks ────────────────────────────────────────────────────────
step "Preflight checks"

check_tool() {
  local tool=$1 min_ver=${2:-""} install_hint=${3:-""}
  if ! command -v "$tool" &>/dev/null; then
    error "'$tool' not found. ${install_hint}"
  fi
  success "$tool found: $(command -v "$tool")"
}

check_tool kind   "" "Install: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
check_tool kubectl "" "Install: https://kubernetes.io/docs/tasks/tools/"
check_tool helm   "" "Install: https://helm.sh/docs/intro/install/"
check_tool docker "" "Install: https://docs.docker.com/engine/install/"

if [[ "$SKIP_BUILD" == false ]]; then
  check_tool go "" "Install: https://go.dev/dl/"
fi

# Verify Docker daemon is running.
if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start Docker and retry."
fi

# ── 2. Create kind cluster ─────────────────────────────────────────────────────
step "Creating kind cluster '${CLUSTER_NAME}'"

# Create the host mount dir for gVisor binaries (mapped into kind nodes).
mkdir -p /tmp/sandbox-gvisor-install

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
  warn "Run './scripts/local-down.sh' first if you want a clean slate."
else
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config "${SCRIPT_DIR}/kind-config.yaml" \
    --wait 120s
  success "Cluster '${CLUSTER_NAME}' created."
fi

# Point kubectl at the new cluster.
kubectl config use-context "kind-${CLUSTER_NAME}"
info "kubectl context: $(kubectl config current-context)"

# ── 3. Install Calico CNI ──────────────────────────────────────────────────────
step "Installing Calico CNI ${CALICO_VERSION}"

# Check if Calico is already installed.
if kubectl get daemonset -n kube-system calico-node &>/dev/null 2>&1; then
  warn "Calico already installed — skipping."
else
  kubectl apply -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

  info "Waiting for Calico to become ready (up to 3 min)..."
  kubectl rollout status daemonset/calico-node -n kube-system --timeout=180s
  success "Calico ready."
fi

# ── 4. Install gVisor on execution worker nodes ────────────────────────────────
step "Installing gVisor (runsc) on execution nodes"

EXECUTION_NODES=$(kubectl get nodes \
  -l "sandbox.k8s.io/role=execution" \
  -o jsonpath='{.items[*].metadata.name}')

if [[ -z "$EXECUTION_NODES" ]]; then
  error "No execution nodes found. Check kind-config.yaml node labels."
fi

info "Execution nodes: ${EXECUTION_NODES}"

install_gvisor_on_node() {
  local node=$1
  info "Installing gVisor on node: ${node}"

  # kind nodes are Docker containers — we exec directly into them.
  docker exec "${node}" bash -s <<NODEEOF
set -euo pipefail

# ── Download runsc ───────────────────────────────────────────────────────────
RUNSC_URL="https://storage.googleapis.com/gvisor/releases/release/${GVISOR_VERSION}/${GVISOR_ARCH}/runsc"
RUNSC_SIG_URL="\${RUNSC_URL}.sha512"

if command -v runsc &>/dev/null; then
  echo "  runsc already installed: \$(runsc --version | head -1)"
  SKIP_DOWNLOAD=true
else
  SKIP_DOWNLOAD=false
fi

if [[ "\$SKIP_DOWNLOAD" == false ]]; then
  echo "  Downloading runsc ${GVISOR_VERSION}/${GVISOR_ARCH}..."
  curl -fsSL "\${RUNSC_URL}" -o /usr/local/bin/runsc
  curl -fsSL "\${RUNSC_SIG_URL}" -o /tmp/runsc.sha512

  # Verify checksum.
  (cd /usr/local/bin && sha512sum -c /tmp/runsc.sha512) || {
    echo "  Checksum verification FAILED for runsc — aborting." >&2
    rm -f /usr/local/bin/runsc
    exit 1
  }
  chmod +x /usr/local/bin/runsc
  echo "  runsc installed: \$(runsc --version | head -1)"
fi

# ── Patch containerd config ──────────────────────────────────────────────────
CONTAINERD_CONFIG="/etc/containerd/config.toml"

# Check if the runsc handler is already registered.
if grep -q 'plugins.*runsc' "\${CONTAINERD_CONFIG}" 2>/dev/null; then
  echo "  containerd already configured for runsc — skipping patch."
else
  echo "  Patching containerd config..."
  cat >> "\${CONTAINERD_CONFIG}" <<'TOML'

# gVisor runsc runtime handler — added by sandbox local-up.sh
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
  TypeUrl = "io.containerd.runsc.v1.options"
TOML

  echo "  Restarting containerd..."
  systemctl restart containerd
  sleep 3
  systemctl is-active --quiet containerd && echo "  containerd restarted OK." || {
    echo "  containerd failed to restart" >&2; exit 1
  }
fi
NODEEOF
  success "gVisor installed on ${node}."
}

if [[ "$SKIP_GVISOR" == true ]]; then
  warn "--skip-gvisor set; skipping gVisor installation."
else
  for node in $EXECUTION_NODES; do
    install_gvisor_on_node "$node"
  done
fi

# ── 5. Taint execution nodes ───────────────────────────────────────────────────
step "Tainting execution nodes"

for node in $EXECUTION_NODES; do
  kubectl taint node "${node}" \
    "sandbox.k8s.io/execution=true:NoSchedule" \
    --overwrite 2>/dev/null || true
  success "Tainted ${node}: sandbox.k8s.io/execution=true:NoSchedule"
done

# ── 6. Apply manifests ─────────────────────────────────────────────────────────
step "Applying Kubernetes manifests"

MANIFESTS_DIR="${PROJECT_ROOT}/manifests"

# Apply in explicit order — the CRD must come last to avoid
# the namespace/RBAC depending on types that don't exist yet.
for manifest in \
  00-namespaces.yaml \
  01-rbac.yaml \
  02-runtime-class.yaml \
  03-redis.yaml \
  04-network-policy.yaml \
  05-crd-sandboxjob.yaml; do
  info "Applying ${manifest}..."
  kubectl apply -f "${MANIFESTS_DIR}/${manifest}"
done

success "All manifests applied."

# Wait for CRD to be established before Helm deploys.
info "Waiting for SandboxJob CRD to be established..."
kubectl wait --for=condition=Established \
  crd/sandboxjobs.sandbox.k8s.io \
  --timeout=60s
success "CRD ready."

# ── 7. Build operator image ────────────────────────────────────────────────────
step "Building sandbox-operator image"

if [[ "$SKIP_BUILD" == true ]]; then
  warn "--skip-build set; skipping Go build and docker build."
  # Verify the image exists at minimum.
  if ! docker image inspect "${OPERATOR_IMAGE}" &>/dev/null; then
    error "Image '${OPERATOR_IMAGE}' not found and --skip-build was set. Run without --skip-build first."
  fi
  warn "Reusing existing image: ${OPERATOR_IMAGE}"
else
  OPERATOR_DIR="${PROJECT_ROOT}/operator"

  info "Running go vet..."
  (cd "${OPERATOR_DIR}" && go vet ./...) || {
    warn "go vet reported issues — proceeding anyway (fix before production)."
  }

  info "Building Docker image: ${OPERATOR_IMAGE}"
  docker build \
    --file "${OPERATOR_DIR}/Dockerfile" \
    --tag "${OPERATOR_IMAGE}" \
    --build-arg TARGETOS=linux \
    --build-arg TARGETARCH=amd64 \
    "${OPERATOR_DIR}"

  success "Image built: ${OPERATOR_IMAGE}"
fi

# ── 8. Load image into kind ────────────────────────────────────────────────────
step "Loading image into kind cluster"

info "Loading ${OPERATOR_IMAGE} into cluster '${CLUSTER_NAME}'..."
kind load docker-image "${OPERATOR_IMAGE}" --name "${CLUSTER_NAME}"
success "Image loaded into kind."

# ── 9. Deploy via Helm ─────────────────────────────────────────────────────────
step "Deploying sandbox via Helm"

HELM_DIR="${PROJECT_ROOT}/helm/sandbox"

# Check if release already exists.
if helm status sandbox -n "${NAMESPACE_CONTROL}" &>/dev/null 2>&1; then
  info "Helm release 'sandbox' already exists — upgrading..."
  HELM_CMD="upgrade"
else
  info "Installing Helm release 'sandbox'..."
  HELM_CMD="install"
fi

helm "${HELM_CMD}" sandbox "${HELM_DIR}" \
  --namespace "${NAMESPACE_CONTROL}" \
  --create-namespace \
  --wait \
  --timeout 5m \
  --set "global.cloudProvider=local" \
  --set "operator.image.repository=sandbox-operator" \
  --set "operator.image.tag=local" \
  --set "operator.image.pullPolicy=Never" \
  --set "operator.replicaCount=1" \
  --set "operator.nodeSelector.sandbox\\.k8s\\.io/role=control" \
  --set "executionPlane.installer.enabled=false" \
  --set "redis.enabled=true"

success "Helm release deployed."

# ── 10. Wait for components ────────────────────────────────────────────────────
step "Waiting for components to become Ready"

wait_for_deployment() {
  local name=$1 ns=$2 timeout=${3:-120s}
  info "Waiting for deployment/${name} in namespace ${ns}..."
  kubectl rollout status deployment/"${name}" \
    -n "${ns}" \
    --timeout="${timeout}" \
  && success "deployment/${name} ready." \
  || warn "Timeout waiting for deployment/${name} — check: kubectl get pods -n ${ns}"
}

wait_for_deployment "sandbox-operator" "${NAMESPACE_CONTROL}"
wait_for_deployment "redis"            "${NAMESPACE_CONTROL}"

# ── 11. Summary ────────────────────────────────────────────────────────────────
step "Cluster Ready"

echo ""
echo -e "${BOLD}Cluster nodes:${RESET}"
kubectl get nodes -o wide

echo ""
echo -e "${BOLD}Pods in ${NAMESPACE_CONTROL}:${RESET}"
kubectl get pods -n "${NAMESPACE_CONTROL}"

echo ""
echo -e "${BOLD}━━━ Next steps ━━━${RESET}"
echo ""
echo -e "  ${CYAN}Submit a test job:${RESET}"
echo -e "    ./scripts/test-job.sh"
echo ""
echo -e "  ${CYAN}Submit manually:${RESET}"
echo -e "    kubectl apply -f - <<EOF"
echo -e "    apiVersion: sandbox.k8s.io/v1alpha1"
echo -e "    kind: SandboxJob"
echo -e "    metadata:"
echo -e "      name: hello"
echo -e "      namespace: ${NAMESPACE_CONTROL}"
echo -e "    spec:"
echo -e "      runtime: python"
echo -e "      timeoutSeconds: 30"
echo -e "      code:"
echo -e "        inline: |"
echo -e "          print('Hello from gVisor sandbox!')"
echo -e "    EOF"
echo ""
echo -e "  ${CYAN}Watch jobs:${RESET}"
echo -e "    kubectl get sbj -n ${NAMESPACE_CONTROL} -w"
echo ""
echo -e "  ${CYAN}Tear down:${RESET}"
echo -e "    ./scripts/local-down.sh"
echo ""
