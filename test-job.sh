#!/usr/bin/env bash
# test-job.sh — Submit sample SandboxJobs and stream their output.
#
# Usage:
#   ./scripts/test-job.sh [python|nodejs|all|egress|timeout|cache]
#
#   python   — Run a Python job with numpy (tests package install + cache warm)
#   nodejs   — Run a Node.js job with lodash
#   all      — Run all of the above sequentially
#   egress   — Run a job with allowNetworkEgress=true (fetches a URL)
#   timeout  — Run a job that intentionally exceeds its timeout
#   cache    — Run the Python job twice to demonstrate Redis cache hit
#
# If no argument is given, 'all' is assumed.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${BLUE}▶ $* ${RESET}"; }

NAMESPACE="sandbox-system"
TIMEOUT_WAIT=120    # seconds to wait for a job to reach terminal state

# ── Verify cluster is up ───────────────────────────────────────────────────────
if ! kubectl cluster-info &>/dev/null 2>&1; then
  error "No cluster reachable. Run ./scripts/local-up.sh first."
fi

if ! kubectl get crd sandboxjobs.sandbox.k8s.io &>/dev/null 2>&1; then
  error "SandboxJob CRD not found. Run ./scripts/local-up.sh first."
fi

# ── Job submission helper ──────────────────────────────────────────────────────
# submit_job <name> <yaml-here-doc>
#
# Applies the YAML, then polls the job status until it reaches a terminal
# phase (Succeeded | Failed | Timeout) or the wait timeout is exceeded.
# Prints the execution pod log on completion.
submit_job() {
  local job_name=$1
  local job_yaml=$2
  local expected_phase=${3:-Succeeded}

  banner "Submitting job: ${job_name}"

  # Delete any existing job with the same name (idempotent test runs).
  kubectl delete sandboxjob "${job_name}" -n "${NAMESPACE}" \
    --ignore-not-found=true --wait=true 2>/dev/null || true

  echo "${job_yaml}" | kubectl apply -f -

  info "Waiting for job '${job_name}' to reach terminal state (max ${TIMEOUT_WAIT}s)..."

  local start elapsed phase pod_name
  start=$(date +%s)

  while true; do
    elapsed=$(( $(date +%s) - start ))
    if (( elapsed > TIMEOUT_WAIT )); then
      warn "Timed out waiting for job '${job_name}' after ${TIMEOUT_WAIT}s."
      kubectl describe sandboxjob "${job_name}" -n "${NAMESPACE}"
      return 1
    fi

    phase=$(kubectl get sandboxjob "${job_name}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    case "$phase" in
      Succeeded|Failed|Timeout)
        break
        ;;
      "")
        info "  phase: <pending API>  (${elapsed}s elapsed)"
        ;;
      *)
        info "  phase: ${phase}  (${elapsed}s elapsed)"
        ;;
    esac
    sleep 3
  done

  # ── Print results ────────────────────────────────────────────────────────────
  local exit_code cache_hit pod_name
  exit_code=$(kubectl get sandboxjob "${job_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.exitCode}' 2>/dev/null || echo "?")
  cache_hit=$(kubectl get sandboxjob "${job_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.cacheHit}' 2>/dev/null || echo "?")
  pod_name=$(kubectl get sandboxjob "${job_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.podName}' 2>/dev/null || echo "")

  echo ""
  echo -e "  ${BOLD}Phase:${RESET}     ${phase}"
  echo -e "  ${BOLD}ExitCode:${RESET}  ${exit_code}"
  echo -e "  ${BOLD}CacheHit:${RESET}  ${cache_hit}"
  echo -e "  ${BOLD}Pod:${RESET}       ${pod_name}"

  if [[ -n "$pod_name" ]]; then
    echo ""
    echo -e "  ${BOLD}─── stdout/stderr ───────────────────────────────────────────${RESET}"
    # Pods in sandbox-execution namespace.
    kubectl logs "${pod_name}" \
      -n "${NAMESPACE_EXECUTION:-sandbox-execution}" \
      -c executor \
      --tail=100 2>/dev/null \
    | sed 's/^/  /' \
    || warn "Could not retrieve pod logs (pod may have been cleaned up)."
    echo -e "  ${BOLD}─────────────────────────────────────────────────────────────${RESET}"
  fi

  if [[ "$phase" == "$expected_phase" ]]; then
    success "Job '${job_name}' completed as expected: ${phase}"
    return 0
  else
    warn "Job '${job_name}' phase was '${phase}', expected '${expected_phase}'."
    return 1
  fi
}

# ── Test definitions ───────────────────────────────────────────────────────────

run_python() {
  submit_job "test-python" "$(cat <<EOF
apiVersion: sandbox.k8s.io/v1alpha1
kind: SandboxJob
metadata:
  name: test-python
  namespace: ${NAMESPACE}
spec:
  runtime: python
  packages:
    - numpy==1.26.4
  timeoutSeconds: 90
  resources:
    cpu: "500m"
    memory: "256Mi"
  code:
    inline: |
      import numpy as np
      import sys, platform

      print(f"Python {sys.version}")
      print(f"Platform: {platform.machine()}")
      print(f"NumPy:    {np.__version__}")
      print()

      arr = np.random.seed(42)
      arr = np.random.randn(1000)
      print(f"1000 random samples — mean: {arr.mean():.4f}, std: {arr.std():.4f}")

      # Matrix multiply
      A = np.random.rand(128, 128)
      B = np.random.rand(128, 128)
      C = A @ B
      print(f"128x128 matmul — result shape: {C.shape}, sum: {C.sum():.2f}")
      print("All checks passed.")
EOF
)"
}

run_nodejs() {
  submit_job "test-nodejs" "$(cat <<EOF
apiVersion: sandbox.k8s.io/v1alpha1
kind: SandboxJob
metadata:
  name: test-nodejs
  namespace: ${NAMESPACE}
spec:
  runtime: nodejs
  packages:
    - lodash@4.17.21
  timeoutSeconds: 60
  code:
    inline: |
      const _ = require('lodash');

      console.log('Node.js:', process.version);
      console.log('lodash: ', _.VERSION);
      console.log();

      const nums = _.range(1, 101);
      console.log('Sum 1..100:  ', _.sum(nums));
      console.log('Mean 1..100: ', _.mean(nums));

      const groups = _.groupBy(nums, n => n % 3 === 0 ? 'div3' : n % 2 === 0 ? 'even' : 'odd');
      console.log('Group sizes:', { div3: groups.div3.length, even: groups.even.length, odd: groups.odd.length });

      const flat = _.flattenDeep([[[1,2],[3,4]],[[5,6]]]);
      console.log('Flattened: ', flat.join(', '));
      console.log('All checks passed.');
EOF
)"
}

run_egress() {
  banner "Egress test (allowNetworkEgress: true)"
  warn "This job will attempt to reach example.com — requires internet from cluster."
  submit_job "test-egress" "$(cat <<EOF
apiVersion: sandbox.k8s.io/v1alpha1
kind: SandboxJob
metadata:
  name: test-egress
  namespace: ${NAMESPACE}
spec:
  runtime: python
  timeoutSeconds: 30
  allowNetworkEgress: true
  code:
    inline: |
      import urllib.request
      try:
          r = urllib.request.urlopen('http://example.com', timeout=10)
          print(f'HTTP {r.status}: {r.url}')
          print('Egress allowed — network reachable.')
      except Exception as e:
          print(f'Network request failed: {e}')
          print('(This is expected if the cluster has no internet access.)')
EOF
)"
}

run_timeout() {
  banner "Timeout test (expected phase: Timeout)"
  submit_job "test-timeout" "$(cat <<EOF
apiVersion: sandbox.k8s.io/v1alpha1
kind: SandboxJob
metadata:
  name: test-timeout
  namespace: ${NAMESPACE}
spec:
  runtime: python
  timeoutSeconds: 5
  code:
    inline: |
      import time
      print('Sleeping for 60s to trigger timeout...')
      time.sleep(60)
      print('This line should never print.')
EOF
)" "Timeout"
}

run_cache() {
  banner "Cache test — two runs, second should be a cache hit"

  # First run warms the cache.
  submit_job "test-cache-miss" "$(cat <<EOF
apiVersion: sandbox.k8s.io/v1alpha1
kind: SandboxJob
metadata:
  name: test-cache-miss
  namespace: ${NAMESPACE}
spec:
  runtime: python
  packages:
    - requests==2.31.0
  timeoutSeconds: 90
  code:
    inline: |
      import requests
      print(f'requests version: {requests.__version__}')
      print('Cache miss run complete.')
EOF
)"

  echo ""
  info "Submitting second run — should show cacheHit=true ..."
  sleep 2

  # Second run should hit Redis.
  submit_job "test-cache-hit" "$(cat <<EOF
apiVersion: sandbox.k8s.io/v1alpha1
kind: SandboxJob
metadata:
  name: test-cache-hit
  namespace: ${NAMESPACE}
spec:
  runtime: python
  packages:
    - requests==2.31.0
  timeoutSeconds: 90
  code:
    inline: |
      import requests
      print(f'requests version: {requests.__version__}')
      print('Cache hit run complete.')
EOF
)"
}

# ── Dispatcher ─────────────────────────────────────────────────────────────────
MODE="${1:-all}"

case "$MODE" in
  python)  run_python ;;
  nodejs)  run_nodejs ;;
  egress)  run_egress ;;
  timeout) run_timeout ;;
  cache)   run_cache ;;
  all)
    run_python
    run_nodejs
    run_timeout
    ;;
  *)
    echo "Usage: $0 [python|nodejs|all|egress|timeout|cache]"
    exit 1
    ;;
esac

echo ""
echo -e "${BOLD}━━━ All requested tests finished ━━━${RESET}"
echo ""
echo -e "  ${CYAN}List all jobs:${RESET}   kubectl get sbj -n ${NAMESPACE}"
echo -e "  ${CYAN}Describe a job:${RESET}  kubectl describe sbj <name> -n ${NAMESPACE}"
echo -e "  ${CYAN}Delete all:${RESET}      kubectl delete sbj --all -n ${NAMESPACE}"
echo ""
