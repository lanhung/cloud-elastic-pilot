#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${SCRIPT_DIR}/e05-kube-queue-gang.py"
APPLICATION_EXPORTER="${SCRIPT_DIR}/export-application-events.py"
CONFIG_FILE="${PROJECT_ROOT}/configs/kube-queue-gang.env"
CHECK_ONLY=false

usage() {
  cat <<USAGE
Usage: $0 [--config PATH] [--check-only]

Runs the randomized E05 ACK Kube Queue gang pilot. ACK Kube Queue admits the
entire Indexed Job (n members); the E05 worker independently releases its
application barrier after k members join.

--check-only validates local configuration, image provenance, Kubernetes
identity/RBAC, the ack-kube-queue 1.26.3 release, QueueUnit APIs, absence of an
existing ElasticQuotaTree, and fixed-node availability. It creates nothing.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) [[ $# -ge 2 ]] || { echo "--config requires a path" >&2; exit 2; }; CONFIG_FILE="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

cd "$PROJECT_ROOT"

log()  { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

is_true() {
  case "${1,,}" in 1|true|yes|y|on) return 0 ;; *) return 1 ;; esac
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

[[ -f "$CONFIG_FILE" ]] || die "config not found: $CONFIG_FILE"
# shellcheck disable=SC1090
set -a
source "$CONFIG_FILE"
set +a

: "${CONFIRM_KUBE_CONTEXT:=no}"
: "${CONFIRM_E05_EXECUTION:=no}"
: "${REQUIRE_CLEAN_GIT:=true}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${CLUSTER_ID:=}"
: "${ARTIFACT_ROOT:=artifacts}"
: "${KUBE_QUEUE_NAMESPACE:=kube-queue}"
: "${KUBE_QUEUE_RELEASE:=ack-kube-queue}"
: "${KUBE_QUEUE_CHART_VERSION:=1.26.3}"
: "${E05_PILOT_REPETITIONS:=5}"
: "${E05_RANDOM_SEED:=20260724}"
: "${E05_MEMBER_COUNTS:=2,4}"
: "${E05_SAMPLE_INTERVAL_SECONDS:=0.5}"
: "${E05_JOB_TIMEOUT_SECONDS:=900}"
: "${E05_BARRIER_TIMEOUT:=10m}"
: "${E05_WORK_DURATION:=10s}"
: "${E05_LEADER_GRACE_DURATION:=60s}"
: "${E05_IMAGE_METADATA_FILE:=dist/e05-image.env}"
: "${E05_APP_IMAGE:=}"
: "${E05_NODE_SELECTOR_KEY:=}"
: "${E05_NODE_SELECTOR_VALUE:=}"
: "${E05_TAINT_KEY:=}"
: "${E05_TAINT_VALUE:=}"
: "${E05_TAINT_EFFECT:=NoSchedule}"
: "${E05_WORKER_CPU_REQUEST:=250m}"
: "${E05_WORKER_CPU_LIMIT:=250m}"
: "${E05_WORKER_MEMORY_REQUEST:=64Mi}"
: "${E05_WORKER_MEMORY_LIMIT:=64Mi}"
: "${E05_QUOTA_CPU:=2}"
: "${E05_QUOTA_MEMORY:=1Gi}"
: "${E05_QUOTA_MAX_JOBS:=1}"
: "${CLEANUP_K8S_ON_SUCCESS:=true}"
: "${CLEANUP_K8S_ON_ERROR:=true}"

for command in kubectl helm jq python3 git date mktemp; do
  require_cmd "$command"
done
[[ -x "$HELPER" ]] || die "E05 helper must be executable: $HELPER"
[[ -x "$APPLICATION_EXPORTER" ]] || die "application exporter must be executable: $APPLICATION_EXPORTER"

[[ "$CONFIRM_KUBE_CONTEXT" == yes ]] || die "set CONFIRM_KUBE_CONTEXT=yes after verifying the target cluster"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
[[ -n "$EXPECTED_API_SERVER_SUBSTRING" ]] || die "EXPECTED_API_SERVER_SUBSTRING is required"
[[ -n "$CLUSTER_ID" ]] || die "CLUSTER_ID is required"
[[ -n "$KUBE_QUEUE_NAMESPACE" && -n "$KUBE_QUEUE_RELEASE" ]] || die "Kube Queue release identity is required"
[[ "$KUBE_QUEUE_CHART_VERSION" == 1.26.3 ]] || die "this E05 adapter is locked to ack-kube-queue chart 1.26.3"
[[ "$E05_PILOT_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die "E05_PILOT_REPETITIONS must be positive"
[[ "$E05_RANDOM_SEED" =~ ^[0-9]+$ ]] || die "E05_RANDOM_SEED must be non-negative"
[[ "$E05_MEMBER_COUNTS" == 2,4 ]] || die "E05 pilot member counts are frozen at 2,4"
[[ "$E05_JOB_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E05_JOB_TIMEOUT_SECONDS must be positive"
[[ "$E05_QUOTA_MAX_JOBS" == 1 ]] || die "E05 pilot requires E05_QUOTA_MAX_JOBS=1"
[[ "$E05_APP_IMAGE" =~ @sha256:[0-9a-fA-F]{64}$ ]] || die "E05_APP_IMAGE must use an immutable digest"
[[ -n "$E05_NODE_SELECTOR_KEY" && -n "$E05_NODE_SELECTOR_VALUE" ]] || die "E05 fixed node selector is required"
if [[ -n "$E05_TAINT_KEY" || -n "$E05_TAINT_VALUE" ]]; then
  [[ -n "$E05_TAINT_KEY" && -n "$E05_TAINT_VALUE" ]] || die "E05 taint key/value must be set together"
  case "$E05_TAINT_EFFECT" in NoSchedule|PreferNoSchedule|NoExecute) ;; *) die "invalid E05_TAINT_EFFECT" ;; esac
fi

python3 - \
  "$E05_SAMPLE_INTERVAL_SECONDS" "$E05_BARRIER_TIMEOUT" \
  "$E05_WORK_DURATION" "$E05_LEADER_GRACE_DURATION" <<'PY' >/dev/null || die "invalid E05 interval/duration configuration"
import re, sys
if float(sys.argv[1]) <= 0:
    raise SystemExit(1)
duration = re.compile(r"^[1-9][0-9]*(?:ms|s|m|h)$")
if any(not duration.fullmatch(value) for value in sys.argv[2:]):
    raise SystemExit(1)
PY

python3 - \
  "$E05_WORKER_CPU_REQUEST" "$E05_WORKER_CPU_LIMIT" \
  "$E05_WORKER_MEMORY_REQUEST" "$E05_WORKER_MEMORY_LIMIT" \
  "$E05_QUOTA_CPU" "$E05_QUOTA_MEMORY" <<'PY' >/dev/null || die "E05 Kubernetes quantities are invalid"
from decimal import Decimal, InvalidOperation
import re, sys
pattern = re.compile(
    r"^(?P<number>[+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"
    r"(?P<suffix>n|u|m|k|K|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?$"
)
multipliers = {
    "": Decimal(1), "n": Decimal("1e-9"), "u": Decimal("1e-6"),
    "m": Decimal("1e-3"), "k": Decimal("1e3"), "K": Decimal("1e3"),
    "M": Decimal("1e6"), "G": Decimal("1e9"), "T": Decimal("1e12"),
    "P": Decimal("1e15"), "E": Decimal("1e18"),
    "Ki": Decimal(1024), "Mi": Decimal(1024) ** 2,
    "Gi": Decimal(1024) ** 3, "Ti": Decimal(1024) ** 4,
    "Pi": Decimal(1024) ** 5, "Ei": Decimal(1024) ** 6,
}
values = []
for raw in sys.argv[1:]:
    match = pattern.fullmatch(raw)
    if not match:
        raise SystemExit(1)
    try:
        value = Decimal(match.group("number")) * multipliers[match.group("suffix") or ""]
    except InvalidOperation:
        raise SystemExit(1)
    if value <= 0:
        raise SystemExit(1)
    values.append(value)
if values[0] > values[1] or values[2] > values[3]:
    raise SystemExit(1)
if values[4] < values[0] * 4 or values[5] < values[2] * 4:
    raise SystemExit(1)
PY

is_true "$REQUIRE_CLEAN_GIT" || die "E05 requires REQUIRE_CLEAN_GIT=true"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die "E05 requires a clean Git worktree"

if [[ "$E05_IMAGE_METADATA_FILE" = /* ]]; then
  IMAGE_METADATA_PATH="$E05_IMAGE_METADATA_FILE"
else
  IMAGE_METADATA_PATH="${PROJECT_ROOT}/${E05_IMAGE_METADATA_FILE}"
fi
[[ -f "$IMAGE_METADATA_PATH" ]] || die "E05 image metadata not found: $IMAGE_METADATA_PATH"

metadata_value() {
  local key="$1" count value
  count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$IMAGE_METADATA_PATH")"
  [[ "$count" == 1 ]] || die "image metadata must contain exactly one ${key}"
  value="$(awk -v prefix="${key}=" 'index($0,prefix)==1 {sub(prefix,""); print; exit}' "$IMAGE_METADATA_PATH")"
  [[ -n "$value" ]] || die "image metadata value is empty: ${key}"
  printf '%s' "$value"
}

IMAGE_BUILD_COMMIT="$(metadata_value E05_APP_IMAGE_BUILD_COMMIT)"
IMAGE_SOURCE_STATE="$(metadata_value E05_APP_IMAGE_SOURCE_STATE)"
METADATA_APP_IMAGE="$(metadata_value E05_APP_IMAGE)"
[[ "$IMAGE_BUILD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "E05 image build commit is invalid"
[[ "$IMAGE_SOURCE_STATE" == clean ]] || die "E05 image must be built from a clean worktree"
[[ "$METADATA_APP_IMAGE" == "$E05_APP_IMAGE" ]] || die "E05_APP_IMAGE does not match image metadata"
git cat-file -e "${IMAGE_BUILD_COMMIT}^{commit}" 2>/dev/null || die "E05 image build commit is unavailable"
git merge-base --is-ancestor "$IMAGE_BUILD_COMMIT" HEAD || die "E05 image build commit is not an ancestor of HEAD"
IMAGE_BUILD_INPUTS=(
  examples/e05-ack-gang/Dockerfile
  examples/e05-ack-gang/Dockerfile.dockerignore
  cmd/e05-gang-worker
  internal/buildinfo
  internal/event
  internal/transport
  sdk/go
  go.mod
  go.sum
)
git diff --quiet "$IMAGE_BUILD_COMMIT"..HEAD -- "${IMAGE_BUILD_INPUTS[@]}" || \
  die "E05 image inputs changed since its build; rebuild and push the image"

KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_PATH")
HELM=(helm --kubeconfig "$KUBECONFIG_PATH")
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL+=(--context "$KUBE_CONTEXT")
  HELM+=(--kube-context "$KUBE_CONTEXT")
  "${KUBECTL[@]}" config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1 || die "kube context not found: $KUBE_CONTEXT"
  EFFECTIVE_CONTEXT="$KUBE_CONTEXT"
else
  EFFECTIVE_CONTEXT="$(kubectl --kubeconfig "$KUBECONFIG_PATH" config current-context)"
fi
[[ -n "$EFFECTIVE_CONTEXT" ]] || die "no effective kube context"
kube() { "${KUBECTL[@]}" "$@"; }
helm_cmd() { "${HELM[@]}" "$@"; }

CURRENT_CONTEXT="$(kube config current-context)"
[[ -n "$KUBE_CONTEXT" || "$CURRENT_CONTEXT" == "$EFFECTIVE_CONTEXT" ]] || die "effective context drifted"
API_SERVER="$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$API_SERVER" == *"$EXPECTED_API_SERVER_SUBSTRING"* ]] || \
  die "API server ${API_SERVER} does not contain EXPECTED_API_SERVER_SUBSTRING"
SERVER_MINOR="$(kube version -o json | jq -r '.serverVersion.minor | sub("[^0-9].*$"; "")')"
[[ "$SERVER_MINOR" =~ ^[0-9]+$ ]] || die "cannot determine Kubernetes server minor"
(( SERVER_MINOR >= 22 )) || die "native Job queueing requires Kubernetes >= 1.22"

RELEASE_JSON="$(helm_cmd list -n "$KUBE_QUEUE_NAMESPACE" -o json | jq -c --arg release "$KUBE_QUEUE_RELEASE" '.[] | select(.name == $release)')"
[[ -n "$RELEASE_JSON" ]] || die "Helm release ${KUBE_QUEUE_NAMESPACE}/${KUBE_QUEUE_RELEASE} not found"
[[ "$(jq -r '.status' <<<"$RELEASE_JSON")" == deployed ]] || die "ack-kube-queue release is not deployed"
EXPECTED_CHART="ack-kube-queue-${KUBE_QUEUE_CHART_VERSION}"
[[ "$(jq -r '.chart' <<<"$RELEASE_JSON")" == "$EXPECTED_CHART" ]] || \
  die "expected chart ${EXPECTED_CHART}, got $(jq -r '.chart' <<<"$RELEASE_JSON")"

for resource in \
  queueunits.scheduling.x-k8s.io \
  queues.scheduling.x-k8s.io \
  elasticquotatrees.scheduling.sigs.k8s.io; do
  kube get crd "$resource" >/dev/null 2>&1 || die "required CRD is missing: ${resource}"
done
for deployment in kube-queue-controller job-extensions; do
  kube -n "$KUBE_QUEUE_NAMESPACE" get deployment "$deployment" >/dev/null 2>&1 || \
    die "required deployment is missing: ${KUBE_QUEUE_NAMESPACE}/${deployment}"
  available="$(kube -n "$KUBE_QUEUE_NAMESPACE" get deployment "$deployment" -o jsonpath='{.status.availableReplicas}')"
  desired="$(kube -n "$KUBE_QUEUE_NAMESPACE" get deployment "$deployment" -o jsonpath='{.spec.replicas}')"
  [[ -n "$available" && "$available" == "$desired" ]] || die "deployment ${deployment} is not fully available"
done

for check in \
  "list queueunits.scheduling.x-k8s.io --all-namespaces" \
  "list jobs.batch --all-namespaces" \
  "list pods --all-namespaces"; do
  # shellcheck disable=SC2086
  [[ "$(kube auth can-i $check)" == yes ]] || die "kubectl identity cannot ${check}"
done

EXISTING_TREES="$(kube get elasticquotatrees.scheduling.sigs.k8s.io -A -o json)"
[[ "$(jq '.items | length' <<<"$EXISTING_TREES")" == 0 ]] || \
  die "an ElasticQuotaTree already exists; E05 refuses to replace or share the cluster-wide singleton"
[[ "$(kube get lease.coordination.k8s.io hooke-e05-kube-queue-lock -n kube-system --ignore-not-found -o name)" == "" ]] || \
  die "the E05 cluster lock already exists"

NODES_JSON="$(kube get nodes -l "${E05_NODE_SELECTOR_KEY}=${E05_NODE_SELECTOR_VALUE}" -o json)"
READY_NODES="$(jq '[.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$NODES_JSON")"
(( READY_NODES >= 1 )) || die "fixed node selector matches no schedulable Ready node"

log "preflight passed: context=${EFFECTIVE_CONTEXT}, server=${API_SERVER}, chart=${EXPECTED_CHART}, ready_nodes=${READY_NODES}"
log "semantics locked: QueueUnit admission=n (whole Job); application barrier=k"
if [[ "$CHECK_ONLY" == true ]]; then
  exit 0
fi

[[ "$CONFIRM_E05_EXECUTION" == yes ]] || die "set CONFIRM_E05_EXECUTION=yes to create E05 resources"
for check in \
  "create namespaces" \
  "delete namespaces" \
  "create elasticquotatrees.scheduling.sigs.k8s.io -n kube-system" \
  "delete elasticquotatrees.scheduling.sigs.k8s.io -n kube-system" \
  "create leases.coordination.k8s.io -n kube-system" \
  "delete leases.coordination.k8s.io -n kube-system"; do
  # shellcheck disable=SC2086
  [[ "$(kube auth can-i $check)" == yes ]] || die "kubectl identity cannot ${check}"
done

RUN_SUFFIX="$(date -u +'%Y%m%d%H%M%S')-$(printf '%04x' "$RANDOM")"
RUN_ID="e05-${RUN_SUFFIX}"
NAMESPACE="hooke-${RUN_ID}"
TREE_NAME="hooke-${RUN_ID}"
TREE_CHILD="e05-${RUN_SUFFIX}"
LOCK_NAME="hooke-e05-kube-queue-lock"
ARTIFACT_DIR="${ARTIFACT_ROOT}/e05-kube-queue-gang-pilot-${RUN_SUFFIX}"
mkdir -p "$ARTIFACT_DIR"
chmod 700 "$ARTIFACT_DIR"

LOCK_CREATED=false
TREE_CREATED=false
NAMESPACE_CREATED=false
CURRENT_STOP_FILE=""
cleanup() {
  local status=$?
  if [[ -n "$CURRENT_STOP_FILE" ]]; then
    : >"$CURRENT_STOP_FILE"
  fi
  local should_cleanup=false
  if (( status == 0 )) && is_true "$CLEANUP_K8S_ON_SUCCESS"; then
    should_cleanup=true
  elif (( status != 0 )) && is_true "$CLEANUP_K8S_ON_ERROR"; then
    should_cleanup=true
  fi
  if [[ "$should_cleanup" == true ]]; then
    if [[ "$TREE_CREATED" == true ]]; then
      kube -n kube-system delete elasticquotatree.scheduling.sigs.k8s.io "$TREE_NAME" --ignore-not-found --wait=true >/dev/null || true
    fi
    if [[ "$NAMESPACE_CREATED" == true ]]; then
      kube delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null || true
    fi
    if [[ "$LOCK_CREATED" == true ]]; then
      kube -n kube-system delete lease.coordination.k8s.io "$LOCK_NAME" --ignore-not-found --wait=true >/dev/null || true
    fi
  else
    warn "retaining E05 Kubernetes resources for run ${RUN_ID}"
  fi
  exit "$status"
}
trap cleanup EXIT

jq -n \
  --arg context "$EFFECTIVE_CONTEXT" \
  --arg api_server "$API_SERVER" \
  --arg cluster_id "$CLUSTER_ID" \
  --arg run_id "$RUN_ID" \
  --arg namespace "$NAMESPACE" \
  --arg image "$E05_APP_IMAGE" \
  --arg chart "$EXPECTED_CHART" \
  '{context:$context,api_server:$api_server,cluster_id:$cluster_id,run_id:$run_id,namespace:$namespace,image:$image,chart:$chart,queue_admission_policy:"whole-job",barrier_policy:"application-k-of-n"}' \
  >"${ARTIFACT_DIR}/run-metadata.json"
cp "$CONFIG_FILE" "${ARTIFACT_DIR}/config.env"
cp "$IMAGE_METADATA_PATH" "${ARTIFACT_DIR}/image-metadata.env"
chmod 600 "${ARTIFACT_DIR}/config.env" "${ARTIFACT_DIR}/image-metadata.env"

jq -n \
  --arg name "$LOCK_NAME" \
  --arg holder "$RUN_ID" \
  '{apiVersion:"coordination.k8s.io/v1",kind:"Lease",metadata:{name:$name,namespace:"kube-system"},spec:{holderIdentity:$holder,leaseDurationSeconds:86400}}' \
  | kube create -f - >/dev/null
LOCK_CREATED=true

kube create namespace "$NAMESPACE" >/dev/null
NAMESPACE_CREATED=true
kube annotate namespace "$NAMESPACE" "hooke.io/run-id=${RUN_ID}" --overwrite >/dev/null
kube label namespace "$NAMESPACE" "app.kubernetes.io/managed-by=hooke-e05-runner" --overwrite >/dev/null

python3 "$HELPER" quota-tree \
  --name "$TREE_NAME" \
  --child-name "$TREE_CHILD" \
  --namespace "$NAMESPACE" \
  --cpu "$E05_QUOTA_CPU" \
  --memory "$E05_QUOTA_MEMORY" \
  --max-jobs "$E05_QUOTA_MAX_JOBS" \
  | kube create -f - >/dev/null
TREE_CREATED=true
kube -n kube-system get elasticquotatree.scheduling.sigs.k8s.io "$TREE_NAME" -o json \
  >"${ARTIFACT_DIR}/elasticquotatree.json"

queue_deadline=$((SECONDS + 120))
while (( SECONDS < queue_deadline )); do
  if (( $(kube -n "$KUBE_QUEUE_NAMESPACE" get queues.scheduling.x-k8s.io -o json | jq --arg child "$TREE_CHILD" '[.items[] | select(.metadata.name | startswith("root-" + $child + "-"))] | length') > 0 )); then
    break
  fi
  sleep 1
done
QUEUES_JSON="$(kube -n "$KUBE_QUEUE_NAMESPACE" get queues.scheduling.x-k8s.io -o json)"
(( $(jq --arg child "$TREE_CHILD" '[.items[] | select(.metadata.name | startswith("root-" + $child + "-"))] | length' <<<"$QUEUES_JSON") > 0 )) || \
  die "ElasticQuotaTree did not create a leaf Queue for ${NAMESPACE} in ${KUBE_QUEUE_NAMESPACE}"
printf '%s\n' "$QUEUES_JSON" >"${ARTIFACT_DIR}/queues.json"

python3 "$HELPER" schedule \
  --repetitions "$E05_PILOT_REPETITIONS" \
  --seed "$E05_RANDOM_SEED" \
  --members "$E05_MEMBER_COUNTS" \
  --output "${ARTIFACT_DIR}/schedule.tsv"

sample_cell() {
  local namespace="$1" stop_file="$2" queue_output="$3" job_output="$4" pod_output="$5"
  while [[ ! -f "$stop_file" ]]; do
    local observed
    observed="$(date +%s%N)"
    kube -n "$namespace" get queueunits.scheduling.x-k8s.io -o json \
      | jq -c --argjson observed_time_ns "$observed" '. + {observed_time_ns:$observed_time_ns}' \
      >>"$queue_output"
    kube -n "$namespace" get jobs.batch -o json \
      | jq -c --argjson observed_time_ns "$observed" '. + {observed_time_ns:$observed_time_ns}' \
      >>"$job_output"
    kube -n "$namespace" get pods -o json \
      | jq -c --argjson observed_time_ns "$observed" '. + {observed_time_ns:$observed_time_ns}' \
      >>"$pod_output"
    sleep "$E05_SAMPLE_INTERVAL_SECONDS"
  done
}

while IFS=$'\t' read -r sequence block cell_id n k admission_members barrier_minimum; do
  [[ "$admission_members" == "$n" && "$barrier_minimum" == "$k" ]] || die "schedule semantics drifted"
  printf -v ordinal '%03d' "$sequence"
  JOB_NAME="e05-${ordinal}-n${n}-k${k}"
  SERVICE_NAME="$JOB_NAME"
  CELL_DIR="${ARTIFACT_DIR}/cells/${ordinal}-${cell_id}"
  LOGS_DIR="${CELL_DIR}/logs"
  mkdir -p "$LOGS_DIR"
  chmod 700 "$CELL_DIR" "$LOGS_DIR"
  log "cell ${sequence}: block=${block} n=${n}, app-k=${k}, queue-admission=${n}"

  START_NS="$(date +%s%N)"
  python3 "$HELPER" manifest \
    --namespace "$NAMESPACE" \
    --job-name "$JOB_NAME" \
    --service-name "$SERVICE_NAME" \
    --run-id "$RUN_ID" \
    --cluster-id "$CLUSTER_ID" \
    --image "$E05_APP_IMAGE" \
    --n "$n" \
    --k "$k" \
    --barrier-timeout "$E05_BARRIER_TIMEOUT" \
    --work-duration "$E05_WORK_DURATION" \
    --leader-grace "$E05_LEADER_GRACE_DURATION" \
    --cpu-request "$E05_WORKER_CPU_REQUEST" \
    --cpu-limit "$E05_WORKER_CPU_LIMIT" \
    --memory-request "$E05_WORKER_MEMORY_REQUEST" \
    --memory-limit "$E05_WORKER_MEMORY_LIMIT" \
    --node-selector-key "$E05_NODE_SELECTOR_KEY" \
    --node-selector-value "$E05_NODE_SELECTOR_VALUE" \
    --taint-key "$E05_TAINT_KEY" \
    --taint-value "$E05_TAINT_VALUE" \
    --taint-effect "$E05_TAINT_EFFECT" \
    >"${CELL_DIR}/manifest.json"
  kube apply -f "${CELL_DIR}/manifest.json" >/dev/null

  CURRENT_STOP_FILE="${CELL_DIR}/sampler.stop"
  QUEUE_CAPTURES="${CELL_DIR}/queueunits.ndjson"
  JOB_CAPTURES="${CELL_DIR}/jobs.ndjson"
  POD_CAPTURES="${CELL_DIR}/pods.ndjson"
  sample_cell "$NAMESPACE" "$CURRENT_STOP_FILE" "$QUEUE_CAPTURES" "$JOB_CAPTURES" "$POD_CAPTURES" &
  SAMPLER_PID=$!

  if ! kube -n "$NAMESPACE" wait --for=condition=complete "job/${JOB_NAME}" --timeout="${E05_JOB_TIMEOUT_SECONDS}s"; then
    kube -n "$NAMESPACE" get job "$JOB_NAME" -o yaml >"${CELL_DIR}/job-failed.yaml" || true
    kube -n "$NAMESPACE" get pods -l "hooke.io/e05-job=${JOB_NAME}" -o wide >"${CELL_DIR}/pods-failed.txt" || true
    : >"$CURRENT_STOP_FILE"
    wait "$SAMPLER_PID" || true
    die "E05 Job ${JOB_NAME} did not complete"
  fi
  : >"$CURRENT_STOP_FILE"
  wait "$SAMPLER_PID"
  CURRENT_STOP_FILE=""

  kube -n "$NAMESPACE" get job "$JOB_NAME" -o json >"${CELL_DIR}/job.json"
  kube -n "$NAMESPACE" get pods -l "hooke.io/e05-job=${JOB_NAME}" -o json >"${CELL_DIR}/pods.json"
  kube -n "$NAMESPACE" get queueunits.scheduling.x-k8s.io -o json >"${CELL_DIR}/queueunits-final.json"
  while IFS=$'\t' read -r pod_name container_name; do
    kube -n "$NAMESPACE" logs "$pod_name" -c "$container_name" >"${LOGS_DIR}/${pod_name}-${container_name}.log"
  done < <(jq -r '.items[] | .metadata.name as $pod | .spec.containers[] | [$pod,.name] | @tsv' "${CELL_DIR}/pods.json")
  END_NS="$(date +%s%N)"

  python3 "$APPLICATION_EXPORTER" \
    --cluster-id "$CLUSTER_ID" \
    --run-id "$RUN_ID" \
    --pods "${CELL_DIR}/pods.json" \
    --logs-dir "$LOGS_DIR" \
    --start-ns "$START_NS" \
    --end-ns "$END_NS" \
    --output "${CELL_DIR}/application-events.ndjson"
  python3 "$HELPER" summarize-cell \
    --job-name "$JOB_NAME" \
    --n "$n" \
    --k "$k" \
    --queueunit-captures "$QUEUE_CAPTURES" \
    --pod-captures "$POD_CAPTURES" \
    --pods "${CELL_DIR}/pods.json" \
    --application-events "${CELL_DIR}/application-events.ndjson" \
    --output "${CELL_DIR}/summary.json"

  kube -n "$NAMESPACE" delete job "$JOB_NAME" --wait=true >/dev/null
  kube -n "$NAMESPACE" delete service "$SERVICE_NAME" --wait=true >/dev/null
  deletion_deadline=$((SECONDS + 120))
  while (( SECONDS < deletion_deadline )); do
    remaining="$(kube -n "$NAMESPACE" get queueunits.scheduling.x-k8s.io -o json | jq --arg job "$JOB_NAME" '[.items[] | select(.spec.consumerRef.name == $job)] | length')"
    (( remaining == 0 )) && break
    sleep 1
  done
  (( remaining == 0 )) || die "QueueUnit for ${JOB_NAME} was not garbage-collected"
done < <(tail -n +2 "${ARTIFACT_DIR}/schedule.tsv")

jq -s 'sort_by(.job_name)' "${ARTIFACT_DIR}"/cells/*/summary.json >"${ARTIFACT_DIR}/cell-summaries.json"
jq -r '
  ["job_name","n","k","queue_admission_members","kth_ready_delay_seconds","nth_ready_delay_seconds","barrier_after_kth_ready_seconds"],
  (.[] | [.job_name,.n,.k,.queue_admission_members,.kth_ready_delay_seconds,.nth_ready_delay_seconds,.barrier_after_kth_ready_seconds])
  | @tsv
' "${ARTIFACT_DIR}/cell-summaries.json" >"${ARTIFACT_DIR}/cell-summaries.tsv"

log "E05 pilot completed: ${ARTIFACT_DIR}"
