#!/usr/bin/env bash
# run-samples.sh — Run sandbox code-execution samples and print a results table.
#
# Usage:
#   ./scripts/run-samples.sh [category] [--parallel] [--keep]
#
#   category    Run only one category: python | nodejs | security | configmap | all
#               Default: all
#
#   --parallel  Submit all jobs simultaneously then poll (faster, less readable output)
#   --keep      Don't delete SandboxJob objects after the run
#   --timeout N Per-job wait timeout in seconds (default: 180)
#
# Exit code: 0 if all jobs matched their expected phase; 1 otherwise.

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m';   GREEN='\033[0;32m';  YELLOW='\033[1;33m'
CYAN='\033[0;36m';  BLUE='\033[0;34m';   MAGENTA='\033[0;35m'
BOLD='\033[1m';     DIM='\033[2m';        RESET='\033[0m'

pass()  { echo -e "${GREEN}PASS${RESET}"; }
fail()  { echo -e "${RED}FAIL${RESET}"; }
skip()  { echo -e "${YELLOW}SKIP${RESET}"; }
info()  { echo -e "${CYAN}[info]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[warn]${RESET} $*"; }
error() { echo -e "${RED}[error]${RESET} $*" >&2; }
hr()    { printf '%0.s─' $(seq 1 72); echo; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SAMPLES_DIR="${PROJECT_ROOT}/samples"
NAMESPACE="sandbox-system"
NAMESPACE_EXEC="sandbox-execution"

# ── Flags ──────────────────────────────────────────────────────────────────────
CATEGORY="${1:-all}"
PARALLEL=false
KEEP=false
JOB_TIMEOUT=180

shift || true
while [[ $# -gt 0 ]]; do
  case $1 in
    --parallel) PARALLEL=true ;;
    --keep)     KEEP=true ;;
    --timeout)  JOB_TIMEOUT="$2"; shift ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) warn "Unknown argument: $1" ;;
  esac
  shift
done

# ── Result tracking ────────────────────────────────────────────────────────────
declare -a RESULTS_NAME=()
declare -a RESULTS_CATEGORY=()
declare -a RESULTS_EXPECT=()
declare -a RESULTS_GOT=()
declare -a RESULTS_EXIT_EXPECTED=()
declare -a RESULTS_EXIT_GOT=()
declare -a RESULTS_CACHE_HIT=()
declare -a RESULTS_DURATION=()
declare -a RESULTS_STATUS=()   # PASS | FAIL | ERROR

record_result() {
  RESULTS_NAME+=("$1")
  RESULTS_CATEGORY+=("$2")
  RESULTS_EXPECT+=("$3")
  RESULTS_GOT+=("$4")
  RESULTS_EXIT_EXPECTED+=("$5")
  RESULTS_EXIT_GOT+=("$6")
  RESULTS_CACHE_HIT+=("$7")
  RESULTS_DURATION+=("$8")
  RESULTS_STATUS+=("$9")
}

# ── Preflight ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${BLUE}║         Sandbox Code Execution — Sample Test Suite           ║${RESET}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

if ! kubectl cluster-info &>/dev/null 2>&1; then
  error "No cluster reachable. Run ./scripts/local-up.sh first."
  exit 1
fi

if ! kubectl get crd sandboxjobs.sandbox.k8s.io &>/dev/null 2>&1; then
  error "SandboxJob CRD not found. Run ./scripts/local-up.sh first."
  exit 1
fi

info "Cluster  : $(kubectl config current-context)"
info "Namespace: ${NAMESPACE}"
info "Category : ${CATEGORY}"
info "Parallel : ${PARALLEL}"
info "Timeout  : ${JOB_TIMEOUT}s per job"
echo ""

# ── Discover sample files ──────────────────────────────────────────────────────
declare -a SAMPLE_FILES=()

add_category() {
  local cat=$1
  local dir="${SAMPLES_DIR}/${cat}"
  if [[ ! -d "$dir" ]]; then
    warn "Category directory not found: ${dir}"
    return
  fi
  while IFS= read -r -d '' f; do
    SAMPLE_FILES+=("$f")
  done < <(find "$dir" -name "*.yaml" -print0 | sort -z)
}

case "${CATEGORY}" in
  all)       add_category python; add_category nodejs; add_category security; add_category configmap ;;
  python)    add_category python ;;
  nodejs)    add_category nodejs ;;
  security)  add_category security ;;
  configmap) add_category configmap ;;
  *)
    error "Unknown category '${CATEGORY}'. Use: all | python | nodejs | security | configmap"
    exit 1 ;;
esac

if [[ ${#SAMPLE_FILES[@]} -eq 0 ]]; then
  error "No sample YAML files found in ${SAMPLES_DIR}/${CATEGORY}/"
  exit 1
fi

info "Found ${#SAMPLE_FILES[@]} sample file(s)."
echo ""

# ── Helper: get a label from a YAML file using grep ───────────────────────────
yaml_label() {
  local file=$1 label=$2 default=${3:-""}
  grep -oP "(?<=sample\.sandbox/${label}: )[\w-]+" "$file" 2>/dev/null | head -1 || echo "$default"
}

# ── Helper: wait for a SandboxJob to reach a terminal phase ───────────────────
# Prints a progress spinner while waiting.
wait_for_job() {
  local job_name=$1
  local timeout=$2
  local start elapsed phase
  start=$(date +%s)
  local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0

  while true; do
    elapsed=$(( $(date +%s) - start ))
    if (( elapsed > timeout )); then
      echo ""
      echo "WAIT_TIMEOUT"
      return
    fi

    phase=$(kubectl get sandboxjob "${job_name}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    case "$phase" in
      Succeeded|Failed|Timeout)
        echo ""
        echo "$phase"
        return ;;
    esac

    printf "\r  %s  Waiting... %ds  (phase: %-12s)" \
      "${spinner[$i]}" "$elapsed" "${phase:-<pending>}"
    i=$(( (i + 1) % ${#spinner[@]} ))
    sleep 2
  done
}

# ── Helper: get pod log for a job ─────────────────────────────────────────────
get_job_output() {
  local job_name=$1
  local pod_name
  pod_name=$(kubectl get sandboxjob "${job_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.podName}' 2>/dev/null || echo "")

  if [[ -z "$pod_name" ]]; then
    echo "(no pod name recorded)"
    return
  fi

  # Try both namespaces — operator may schedule in either.
  kubectl logs "${pod_name}" -n "${NAMESPACE_EXEC}" -c executor --tail=40 2>/dev/null \
  || kubectl logs "${pod_name}" -n "${NAMESPACE}"     -c executor --tail=40 2>/dev/null \
  || echo "(logs unavailable — pod may have been cleaned up)"
}

# ── Run a single sample file ───────────────────────────────────────────────────
run_sample() {
  local file=$1
  local category expect expect_exit job_name duration phase exit_code cache_hit status
  local t_start t_end

  category=$(basename "$(dirname "$file")")
  expect=$(yaml_label "$file" "expect" "Succeeded")
  expect_exit=$(yaml_label "$file" "expect-exitcode" "*")

  # Extract all job names from the YAML (may contain multiple documents).
  # We care about SandboxJob resources only.
  local job_names
  job_names=$(grep -A2 'kind: SandboxJob' "$file" \
    | grep 'name:' | grep -oP '(?<=name: )\S+' || true)

  if [[ -z "$job_names" ]]; then
    warn "No SandboxJob found in ${file} — skipping."
    return
  fi

  # For files with multiple documents (e.g. ConfigMap + SandboxJob),
  # apply the whole file but only track the SandboxJob.
  job_name=$(echo "$job_names" | tail -1)

  echo ""
  echo -e "${BOLD}$(hr)${RESET}"
  echo -e "${BOLD}  $(basename "$file")${RESET}  ${DIM}(${category})${RESET}"
  echo -e "  Expect: ${CYAN}${expect}${RESET}  ExitCode: ${CYAN}${expect_exit}${RESET}"
  echo ""

  # Delete any prior run.
  kubectl delete sandboxjob "${job_name}" -n "${NAMESPACE}" \
    --ignore-not-found=true --wait=false 2>/dev/null || true

  # For ConfigMap samples, also delete the ConfigMap.
  local cm_names
  cm_names=$(grep -A2 'kind: ConfigMap' "$file" \
    | grep 'name:' | grep -oP '(?<=name: )\S+' || true)
  for cm in $cm_names; do
    kubectl delete configmap "$cm" -n "${NAMESPACE}" \
      --ignore-not-found=true --wait=false 2>/dev/null || true
  done

  # Wait for old pod to clean up.
  sleep 1

  # Apply the manifest.
  if ! kubectl apply -f "$file" &>/dev/null; then
    error "kubectl apply failed for ${file}"
    record_result "$job_name" "$category" "$expect" "ERROR" \
      "$expect_exit" "?" "?" "0s" "ERROR"
    return
  fi

  t_start=$(date +%s)

  # Wait for terminal phase.
  phase=$(wait_for_job "$job_name" "$JOB_TIMEOUT")
  t_end=$(date +%s)
  duration=$(( t_end - t_start ))

  # Fetch status fields.
  exit_code=$(kubectl get sandboxjob "${job_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.exitCode}' 2>/dev/null || echo "?")
  cache_hit=$(kubectl get sandboxjob "${job_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.cacheHit}' 2>/dev/null || echo "false")

  # Evaluate result.
  if [[ "$phase" == "WAIT_TIMEOUT" ]]; then
    status="ERROR"
    echo -e "  ${RED}WAIT TIMEOUT${RESET} — job did not reach terminal state in ${JOB_TIMEOUT}s"
  elif [[ "$phase" == "$expect" ]]; then
    if [[ "$expect_exit" == "*" || "$exit_code" == "$expect_exit" ]]; then
      status="PASS"
      echo -e "  ${GREEN}✓ PASS${RESET}  phase=${phase}  exitCode=${exit_code}  cacheHit=${cache_hit}  duration=${duration}s"
    else
      status="FAIL"
      echo -e "  ${RED}✗ FAIL${RESET}  phase=${phase} (ok)  exitCode=${exit_code} (want ${expect_exit})  duration=${duration}s"
    fi
  else
    status="FAIL"
    echo -e "  ${RED}✗ FAIL${RESET}  phase=${phase} (want ${expect})  exitCode=${exit_code}  duration=${duration}s"
  fi

  # Print job output (truncated).
  echo ""
  echo -e "  ${DIM}── output ──────────────────────────────────────────────────${RESET}"
  get_job_output "$job_name" | head -30 | sed 's/^/  │ /'
  echo -e "  ${DIM}───────────────────────────────────────────────────────────${RESET}"

  record_result "$job_name" "$category" "$expect" "$phase" \
    "$expect_exit" "$exit_code" "$cache_hit" "${duration}s" "$status"

  # Clean up unless --keep.
  if [[ "$KEEP" == false ]]; then
    kubectl delete sandboxjob "${job_name}" -n "${NAMESPACE}" \
      --ignore-not-found=true --wait=false 2>/dev/null || true
  fi
}

# ── Sequential mode ────────────────────────────────────────────────────────────
run_sequential() {
  for f in "${SAMPLE_FILES[@]}"; do
    run_sample "$f"
  done
}

# ── Parallel mode ──────────────────────────────────────────────────────────────
run_parallel() {
  info "Submitting all jobs in parallel..."
  local pids=()
  for f in "${SAMPLE_FILES[@]}"; do
    run_sample "$f" &
    pids+=($!)
  done
  info "Waiting for ${#pids[@]} parallel jobs..."
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
}

# ── Execute ────────────────────────────────────────────────────────────────────
if [[ "$PARALLEL" == true ]]; then
  run_parallel
else
  run_sequential
fi

# ── Results table ──────────────────────────────────────────────────────────────
echo ""
echo ""
echo -e "${BOLD}$(hr)${RESET}"
echo -e "${BOLD}  RESULTS SUMMARY${RESET}"
echo -e "${BOLD}$(hr)${RESET}"

# Header
printf "${BOLD}  %-28s %-12s %-12s %-8s %-8s %-8s %-6s  %s${RESET}\n" \
  "Job" "Category" "Phase" "Expect" "Exit" "Cache" "Time" "Result"
hr

PASS_COUNT=0
FAIL_COUNT=0
ERROR_COUNT=0

for i in "${!RESULTS_NAME[@]}"; do
  name="${RESULTS_NAME[$i]}"
  cat="${RESULTS_CATEGORY[$i]}"
  expect="${RESULTS_EXPECT[$i]}"
  got="${RESULTS_GOT[$i]}"
  ex_exit="${RESULTS_EXIT_EXPECTED[$i]}"
  got_exit="${RESULTS_EXIT_GOT[$i]}"
  cache="${RESULTS_CACHE_HIT[$i]}"
  dur="${RESULTS_DURATION[$i]}"
  status="${RESULTS_STATUS[$i]}"

  case "$status" in
    PASS)
      colour="${GREEN}"
      label="✓ PASS"
      PASS_COUNT=$(( PASS_COUNT + 1 ))
      ;;
    FAIL)
      colour="${RED}"
      label="✗ FAIL"
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      ;;
    ERROR)
      colour="${YELLOW}"
      label="⚠ ERROR"
      ERROR_COUNT=$(( ERROR_COUNT + 1 ))
      ;;
  esac

  # Highlight phase mismatch.
  if [[ "$got" != "$expect" ]]; then
    phase_str="${RED}${got}${RESET}"
  else
    phase_str="${got}"
  fi

  # Highlight exit code mismatch.
  if [[ "$ex_exit" != "*" && "$got_exit" != "$ex_exit" ]]; then
    exit_str="${RED}${got_exit}${RESET} (want ${ex_exit})"
  else
    exit_str="${got_exit}"
  fi

  printf "  %-28s %-12s %-12b %-8s %-16b %-6s %-6s  ${colour}%s${RESET}\n" \
    "${name:0:27}" "${cat:0:11}" "${phase_str}" \
    "${expect}" "${exit_str}" "${cache}" "${dur}" "${label}"
done

hr
echo ""

TOTAL=$(( PASS_COUNT + FAIL_COUNT + ERROR_COUNT ))
echo -e "  Total: ${TOTAL}  |  ${GREEN}Pass: ${PASS_COUNT}${RESET}  |  ${RED}Fail: ${FAIL_COUNT}${RESET}  |  ${YELLOW}Error: ${ERROR_COUNT}${RESET}"
echo ""

# ── Final exit code ────────────────────────────────────────────────────────────
if (( FAIL_COUNT > 0 || ERROR_COUNT > 0 )); then
  echo -e "${RED}${BOLD}  ✗ Test suite FAILED — ${FAIL_COUNT} failure(s), ${ERROR_COUNT} error(s).${RESET}"
  echo ""
  echo -e "  Diagnose with:"
  echo -e "    ${CYAN}kubectl describe sbj <job-name> -n ${NAMESPACE}${RESET}"
  echo -e "    ${CYAN}kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp${RESET}"
  echo ""
  exit 1
else
  echo -e "${GREEN}${BOLD}  ✓ All ${PASS_COUNT} sample(s) PASSED.${RESET}"
  echo ""
  exit 0
fi
