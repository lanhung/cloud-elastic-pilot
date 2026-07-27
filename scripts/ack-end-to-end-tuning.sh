#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
E04_HELPER="${SCRIPT_DIR}/e04-keda-scale-to-zero.py"
E05_HELPER="${SCRIPT_DIR}/e05-kube-queue-gang.py"
E06_HELPER="${SCRIPT_DIR}/e06-argo-workflow.py"
E07_HELPER="${SCRIPT_DIR}/e07-end-to-end-tuning.py"
APPLICATION_EXPORTER="${SCRIPT_DIR}/export-application-events.py"
CONFIG_FILE="${PROJECT_ROOT}/configs/end-to-end-tuning.env"
CHECK_ONLY=false

usage() {
  cat <<'USAGE'
Usage: ack-end-to-end-tuning.sh [--config PATH] [--check-only]

Runs the E07 cumulative 1x5 smoke on ACK:
  B0 cold node + baseline KEDA + direct Job + serial Argo
  B1 warm node
  B2 shorter KEDA cooldown
  B3 ACK Queue whole-Job admission + application k-of-n barrier
  B4 parallel Argo DAG

The smoke creates one memory-reservation anchor Pod that forces one new Node
from the configured ACK auto-scaling node pool. All five cells run on that
exact Node. --check-only performs only local and read-only cluster checks.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "--config requires a path" >&2; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --check-only) CHECK_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

cd "$PROJECT_ROOT"

log()  { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }
now_ns() { date +%s%N; }

is_true() {
  case "${1,,}" in 1|true|yes|y|on) return 0 ;; *) return 1 ;; esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

[[ -f "$CONFIG_FILE" ]] || die "config not found: $CONFIG_FILE"
# shellcheck disable=SC1090
set -a
source "$CONFIG_FILE"
set +a

: "${CONFIRM_KUBE_CONTEXT:=no}"
: "${CONFIRM_E07_EXECUTION:=no}"
: "${REQUIRE_CLEAN_GIT:=true}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${CLUSTER_ID:=}"
: "${ACK_CLUSTER_ID:=}"
: "${ACK_NODE_POOL_ID:=}"
: "${ACK_NODE_POOL_LABEL:=alibabacloud.com/nodepool-id}"
: "${ACK_NODE_POOL_MAX_NODES:=5}"
: "${ARTIFACT_ROOT:=artifacts}"
: "${LOCK_NAMESPACE:=kube-system}"
: "${KEDA_NAMESPACE:=keda}"
: "${KEDA_RELEASE:=keda}"
: "${KEDA_CHART_VERSION:=2.20.1}"
: "${KUBE_QUEUE_NAMESPACE:=kube-queue}"
: "${KUBE_QUEUE_RELEASE:=ack-kube-queue}"
: "${KUBE_QUEUE_CHART_VERSION:=1.26.3}"
: "${ARGO_NAMESPACE:=argo}"
: "${ARGO_RELEASE:=ack-workflow}"
: "${ARGO_CHART_VERSION:=3.5.15}"
: "${ARGO_CONTROLLER_DEPLOYMENT:=ack-workflow-controller}"
: "${ARGO_CONTROLLER_VERSION_PREFIX:=v3.5.13}"
: "${E07_WORKFLOW_SERVICE_ACCOUNT:=e07-workflow}"
: "${E07_BASELINE_COOLDOWN_SECONDS:=30}"
: "${E07_CANDIDATE_COOLDOWN_SECONDS:=5}"
: "${E07_POLLING_INTERVAL_SECONDS:=2}"
: "${E07_MIN_REPLICAS:=0}"
: "${E07_MAX_REPLICAS:=2}"
: "${E07_LAMBDA_PER_SECOND:=2}"
: "${E07_MESSAGE_COUNT:=4}"
: "${E07_PROCESSING_DURATION:=5s}"
: "${E07_QUEUE_SAMPLE_INTERVAL:=250ms}"
: "${E07_METRIC_SAMPLE_INTERVAL_SECONDS:=0.5}"
: "${E07_METRIC_REQUEST_TIMEOUT_SECONDS:=15}"
: "${E07_METRIC_MAX_CONSECUTIVE_ERRORS:=10}"
: "${E07_METRIC_SAMPLE_MAX_GAP_SECONDS:=3}"
: "${E07_INITIAL_TIMEOUT_SECONDS:=180}"
: "${E07_PRODUCER_TIMEOUT_SECONDS:=180}"
: "${E07_SCALE_ZERO_TIMEOUT_SECONDS:=120}"
: "${E07_N:=2}"
: "${E07_BASELINE_K:=2}"
: "${E07_CANDIDATE_K:=1}"
: "${E07_BARRIER_TIMEOUT:=3m}"
: "${E07_GANG_WORK_DURATION:=1s}"
: "${E07_GANG_LEADER_GRACE_DURATION:=5s}"
: "${E07_JOB_TIMEOUT_SECONDS:=180}"
: "${E07_QUOTA_CPU:=1}"
: "${E07_QUOTA_MEMORY:=512Mi}"
: "${E07_QUOTA_MAX_JOBS:=1}"
: "${E07_STAGE_DURATIONS:=a=1s,b=3s,c=2s,d=1s,e=1s,f=1s}"
: "${E07_STAGE_TIMEOUT_SECONDS:=120}"
: "${E07_WORKFLOW_TIMEOUT_SECONDS:=300}"
: "${E07_SLO_SECONDS:=30}"
: "${E07_CLOCK_TOLERANCE_SECONDS:=2}"
: "${E07_ANCHOR_MEMORY_REQUEST:=1024Mi}"
: "${E07_PHASE_PEAK_MEMORY:=240Mi}"
: "${E07_HEADROOM_SAFETY_MEMORY:=64Mi}"
: "${E07_ANCHOR_TIMEOUT_SECONDS:=900}"
: "${E07_SCALE_DOWN_TIMEOUT_SECONDS:=900}"
: "${E07_ANCHOR_IMAGE:=}"
: "${E04_IMAGE_METADATA_FILE:=dist/e04-image.env}"
: "${E04_APP_IMAGE:=}"
: "${E04_REDIS_IMAGE:=}"
: "${E05_IMAGE_METADATA_FILE:=dist/e05-image.env}"
: "${E05_APP_IMAGE:=}"
: "${E06_IMAGE_METADATA_FILE:=dist/e06-image.env}"
: "${E06_APP_IMAGE:=}"
: "${E07_REDIS_CPU_REQUEST:=25m}"
: "${E07_REDIS_CPU_LIMIT:=100m}"
: "${E07_REDIS_MEMORY_REQUEST:=64Mi}"
: "${E07_REDIS_MEMORY_LIMIT:=128Mi}"
: "${E07_KEDA_WORKER_CPU_REQUEST:=25m}"
: "${E07_KEDA_WORKER_CPU_LIMIT:=100m}"
: "${E07_KEDA_WORKER_MEMORY_REQUEST:=32Mi}"
: "${E07_KEDA_WORKER_MEMORY_LIMIT:=64Mi}"
: "${E07_PRODUCER_CPU_REQUEST:=10m}"
: "${E07_PRODUCER_CPU_LIMIT:=50m}"
: "${E07_PRODUCER_MEMORY_REQUEST:=16Mi}"
: "${E07_PRODUCER_MEMORY_LIMIT:=32Mi}"
: "${E07_GANG_CPU_REQUEST:=25m}"
: "${E07_GANG_CPU_LIMIT:=100m}"
: "${E07_GANG_MEMORY_REQUEST:=32Mi}"
: "${E07_GANG_MEMORY_LIMIT:=64Mi}"
: "${E07_ARGO_CPU_REQUEST:=25m}"
: "${E07_ARGO_CPU_LIMIT:=100m}"
: "${E07_ARGO_MEMORY_REQUEST:=16Mi}"
: "${E07_ARGO_MEMORY_LIMIT:=32Mi}"
: "${CLEANUP_K8S_ON_SUCCESS:=true}"
: "${CLEANUP_K8S_ON_ERROR:=true}"

for command in kubectl helm jq python3 git date mktemp aliyun; do
  require_cmd "$command"
done
for helper in \
  "$E04_HELPER" "$E05_HELPER" "$E06_HELPER" "$E07_HELPER" \
  "$APPLICATION_EXPORTER"; do
  [[ -x "$helper" ]] || die "helper must be executable: $helper"
done

[[ "$CONFIRM_KUBE_CONTEXT" == yes ]] || \
  die "set CONFIRM_KUBE_CONTEXT=yes after verifying the ACK target"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
[[ -n "$EXPECTED_API_SERVER_SUBSTRING" ]] || \
  die "EXPECTED_API_SERVER_SUBSTRING is required"
[[ -n "$CLUSTER_ID" && -n "$ACK_CLUSTER_ID" && -n "$ACK_NODE_POOL_ID" ]] || \
  die "cluster and node-pool identities are required"
[[ "$E07_BASELINE_COOLDOWN_SECONDS" == 30 ]] || \
  die "E07 smoke baseline cooldown is frozen at 30s"
[[ "$E07_CANDIDATE_COOLDOWN_SECONDS" == 5 ]] || \
  die "E07 smoke candidate cooldown is frozen at 5s"
[[ "$E07_POLLING_INTERVAL_SECONDS" == 2 ]] || \
  die "E07 smoke polling interval is frozen at 2s"
[[ "$E07_MIN_REPLICAS" == 0 && "$E07_MAX_REPLICAS" == 2 ]] || \
  die "E07 smoke KEDA replica bounds are frozen at 0..2"
[[ "$E07_MESSAGE_COUNT" == 4 && "$E07_N" == 2 ]] || \
  die "E07 smoke message/member counts are frozen at 4 and 2"
[[ "$E07_PROCESSING_DURATION" == 5s ]] || \
  die "E07 smoke processing duration is frozen at 5s"
[[ "$E07_BASELINE_K" == 2 && "$E07_CANDIDATE_K" == 1 ]] || \
  die "E07 smoke barrier levels are frozen at k=2 and k=1"
[[ "$E07_STAGE_DURATIONS" == "a=1s,b=3s,c=2s,d=1s,e=1s,f=1s" ]] || \
  die "E07 smoke Argo durations differ from the frozen protocol"
[[ "$E07_ANCHOR_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
  die "invalid anchor timeout"
[[ "$E07_SCALE_DOWN_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
  die "invalid scale-down timeout"
for image in "$E07_ANCHOR_IMAGE" "$E04_APP_IMAGE" "$E04_REDIS_IMAGE" \
  "$E05_APP_IMAGE" "$E06_APP_IMAGE"; do
  [[ "$image" =~ @sha256:[0-9a-fA-F]{64}$ ]] || \
    die "every E07 image must be digest pinned: ${image}"
done
[[ "$E07_ANCHOR_IMAGE" == "$E04_REDIS_IMAGE" ]] || \
  die "the anchor and E07 Redis image must be identical"

LOCAL_SCHEDULE_CHECK="$(mktemp)"
python3 "$E07_HELPER" schedule \
  --baseline-cooldown "$E07_BASELINE_COOLDOWN_SECONDS" \
  --candidate-cooldown "$E07_CANDIDATE_COOLDOWN_SECONDS" \
  --n "$E07_N" --baseline-k "$E07_BASELINE_K" \
  --candidate-k "$E07_CANDIDATE_K" --output "$LOCAL_SCHEDULE_CHECK"
rm -f -- "$LOCAL_SCHEDULE_CHECK"

if is_true "$REQUIRE_CLEAN_GIT"; then
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] || \
    die "E07 requires a clean Git worktree"
fi

metadata_value() {
  local path="$1" key="$2" count value
  count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$path")"
  [[ "$count" == 1 ]] || die "${path} must contain exactly one ${key}"
  value="$(awk -v prefix="${key}=" 'index($0,prefix)==1 {sub(prefix,""); print; exit}' "$path")"
  [[ -n "$value" ]] || die "${path} has an empty ${key}"
  printf '%s' "$value"
}

resolve_path() {
  if [[ "$1" = /* ]]; then printf '%s' "$1"; else printf '%s/%s' "$PROJECT_ROOT" "$1"; fi
}

verify_image_metadata() {
  local prefix="$1" configured="$2" metadata_file="$3"
  shift 3
  local path build_commit source_state metadata_image
  path="$(resolve_path "$metadata_file")"
  [[ -f "$path" ]] || die "image metadata not found: $path"
  build_commit="$(metadata_value "$path" "${prefix}_APP_IMAGE_BUILD_COMMIT")"
  source_state="$(metadata_value "$path" "${prefix}_APP_IMAGE_SOURCE_STATE")"
  metadata_image="$(metadata_value "$path" "${prefix}_APP_IMAGE")"
  [[ "$build_commit" =~ ^[0-9a-f]{40}$ ]] || die "${prefix} build commit is invalid"
  [[ "$source_state" == clean ]] || die "${prefix} image source was not clean"
  [[ "$metadata_image" == "$configured" ]] || die "${prefix} image differs from metadata"
  git cat-file -e "${build_commit}^{commit}" 2>/dev/null || \
    die "${prefix} image build commit is unavailable"
  git merge-base --is-ancestor "$build_commit" HEAD || \
    die "${prefix} image build commit is not an ancestor of HEAD"
  git diff --quiet "${build_commit}"..HEAD -- "$@" || \
    die "${prefix} image inputs changed since the immutable image was built"
}

verify_image_metadata E04 "$E04_APP_IMAGE" "$E04_IMAGE_METADATA_FILE" \
  examples/keda-redis-app/Dockerfile \
  examples/keda-redis-app/Dockerfile.dockerignore \
  cmd/keda-redis-app internal/buildinfo internal/redisresp \
  internal/transport sdk/go go.mod go.sum
verify_image_metadata E05 "$E05_APP_IMAGE" "$E05_IMAGE_METADATA_FILE" \
  examples/e05-ack-gang/Dockerfile \
  examples/e05-ack-gang/Dockerfile.dockerignore \
  cmd/e05-gang-worker internal/buildinfo internal/transport \
  sdk/go go.mod go.sum
verify_image_metadata E06 "$E06_APP_IMAGE" "$E06_IMAGE_METADATA_FILE" \
  examples/e06-argo-workflow/Dockerfile \
  examples/e06-argo-workflow/Dockerfile.dockerignore \
  cmd/e06-stage-worker internal/buildinfo internal/event internal/transport \
  sdk/go go.mod go.sum

KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_PATH")
HELM=(helm --kubeconfig "$KUBECONFIG_PATH")
SAMPLER_CONTEXT_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL+=(--context "$KUBE_CONTEXT")
  HELM+=(--kube-context "$KUBE_CONTEXT")
  SAMPLER_CONTEXT_ARGS=(--context "$KUBE_CONTEXT")
  "${KUBECTL[@]}" config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1 || \
    die "kube context not found: $KUBE_CONTEXT"
  EFFECTIVE_CONTEXT="$KUBE_CONTEXT"
else
  EFFECTIVE_CONTEXT="$(kubectl --kubeconfig "$KUBECONFIG_PATH" config current-context)"
fi
[[ -n "$EFFECTIVE_CONTEXT" ]] || die "no effective kube context"
kube() { "${KUBECTL[@]}" "$@"; }
helm_cmd() { "${HELM[@]}" "$@"; }

API_SERVER="$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$API_SERVER" == *"$EXPECTED_API_SERVER_SUBSTRING"* ]] || \
  die "API server ${API_SERVER} does not match the configured target"
kube get --raw=/readyz | grep -qx ok || die "Kubernetes API is not ready"

NODEPOOL_JSON="$(aliyun cs GET \
  "/clusters/${ACK_CLUSTER_ID}/nodepools/${ACK_NODE_POOL_ID}")"
[[ "$(jq -r '.nodepool_info.nodepool_id // ""' <<<"$NODEPOOL_JSON")" == "$ACK_NODE_POOL_ID" ]] || \
  die "ACK node-pool API returned a different pool"
[[ "$(jq -r '.auto_scaling.enable // false' <<<"$NODEPOOL_JSON")" == true ]] || \
  die "ACK node pool auto scaling is disabled"
[[ "$(jq -r '.auto_scaling.min_instances' <<<"$NODEPOOL_JSON")" == 0 ]] || \
  die "E07 requires node-pool min_instances=0"
POOL_MAX="$(jq -r '.auto_scaling.max_instances' <<<"$NODEPOOL_JSON")"
[[ "$POOL_MAX" == "$ACK_NODE_POOL_MAX_NODES" ]] || \
  die "node-pool maximum is ${POOL_MAX}, expected ${ACK_NODE_POOL_MAX_NODES}"

helm_release() {
  local namespace="$1" release="$2" expected_chart="$3" output="$4"
  helm_cmd list -n "$namespace" -o json \
    | jq -ce --arg release "$release" --arg chart "$expected_chart" \
      '.[] | select(.name==$release and .status=="deployed" and .chart==$chart)' \
      >"$output" || die "Helm release ${namespace}/${release} is not ${expected_chart} deployed"
}

PREFLIGHT_DIR="$(mktemp -d)"
trap 'rm -rf -- "$PREFLIGHT_DIR"' EXIT
helm_release "$KEDA_NAMESPACE" "$KEDA_RELEASE" \
  "keda-${KEDA_CHART_VERSION}" "$PREFLIGHT_DIR/keda-release.json"
helm_release "$KUBE_QUEUE_NAMESPACE" "$KUBE_QUEUE_RELEASE" \
  "ack-kube-queue-${KUBE_QUEUE_CHART_VERSION}" "$PREFLIGHT_DIR/queue-release.json"
helm_release "$ARGO_NAMESPACE" "$ARGO_RELEASE" \
  "ack-workflow-${ARGO_CHART_VERSION}" "$PREFLIGHT_DIR/argo-release.json"

for crd in \
  scaledobjects.keda.sh \
  queueunits.scheduling.x-k8s.io \
  queues.scheduling.x-k8s.io \
  elasticquotatrees.scheduling.sigs.k8s.io \
  workflows.argoproj.io \
  workflowtaskresults.argoproj.io; do
  kube get crd "$crd" -o json \
    | jq -e 'any(.status.conditions[]; .type=="Established" and .status=="True")' \
      >/dev/null || die "required CRD is missing or not Established: ${crd}"
done
kube get apiservice v1beta1.external.metrics.k8s.io -o json \
  | jq -e 'any(.status.conditions[]; .type=="Available" and .status=="True")' \
    >/dev/null || die "KEDA external metrics APIService is unavailable"

kube -n "$KEDA_NAMESPACE" get deployments -o json \
  | jq -e '
      any(.items[]; (.metadata.name | contains("operator")) and
        (.metadata.name | contains("metrics") | not) and
        (.status.availableReplicas // 0) >= 1) and
      any(.items[]; (.metadata.name | contains("metrics")) and
        (.status.availableReplicas // 0) >= 1)
    ' >/dev/null || die "KEDA operator or metrics server is not Ready"

QUEUE_DEPLOYMENTS="$(kube -n "$KUBE_QUEUE_NAMESPACE" get deployments -o json)"
jq -e '
  any(.items[]; .metadata.name=="kube-queue-controller" and
    (.status.availableReplicas // 0) >= 1) and
  any(.items[]; .metadata.name=="job-extensions" and
    (.status.availableReplicas // 0) >= 1)
' <<<"$QUEUE_DEPLOYMENTS" >/dev/null || die "ACK Kube Queue deployments are not Ready"
JOB_EXTENSION_COMMAND="$(jq -r '
  .items[] | select(.metadata.name=="job-extensions") |
  .spec.template.spec.containers[0].command[0] // ""
' <<<"$QUEUE_DEPLOYMENTS")"
[[ "$JOB_EXTENSION_COMMAND" == /usr/bin/kube-queue-controllers ]] || \
  die "ACK Queue job-extensions entrypoint is not the 1.26.3 compatibility fix"

ARGO_CONTROLLER_JSON="$(kube -n "$ARGO_NAMESPACE" get deployment \
  "$ARGO_CONTROLLER_DEPLOYMENT" -o json)"
[[ "$(jq -r '.status.availableReplicas // 0' <<<"$ARGO_CONTROLLER_JSON")" == \
    "$(jq -r '.spec.replicas' <<<"$ARGO_CONTROLLER_JSON")" ]] || \
  die "Argo controller is not fully available"
ARGO_CONTROLLER_IMAGE="$(jq -r '
  .spec.template.spec.containers[] |
  select(.name=="workflow-controller") | .image
' <<<"$ARGO_CONTROLLER_JSON")"
[[ "$ARGO_CONTROLLER_IMAGE" == *":${ARGO_CONTROLLER_VERSION_PREFIX}"* || \
   "$ARGO_CONTROLLER_IMAGE" == *":${ARGO_CONTROLLER_VERSION_PREFIX}-"* ]] || \
  die "Argo controller image does not match ${ARGO_CONTROLLER_VERSION_PREFIX}"

for permission in \
  "get nodes" \
  "list pods --all-namespaces" \
  "create namespaces" \
  "delete namespaces" \
  "create leases.coordination.k8s.io -n ${LOCK_NAMESPACE}" \
  "delete leases.coordination.k8s.io -n ${LOCK_NAMESPACE}" \
  "create elasticquotatrees.scheduling.sigs.k8s.io -n kube-system" \
  "delete elasticquotatrees.scheduling.sigs.k8s.io -n kube-system"; do
  # shellcheck disable=SC2086
  [[ "$(kube auth can-i $permission)" == yes ]] || \
    die "kubectl identity cannot ${permission}"
done

LOCK_NAME="hooke-e07-end-to-end-lock"
[[ -z "$(kube -n "$LOCK_NAMESPACE" get lease "$LOCK_NAME" \
  --ignore-not-found -o name)" ]] || die "E07 cluster lock already exists"
[[ -z "$(kube -n kube-system get elasticquotatree \
  -l hooke.io/experiment=E07 --ignore-not-found -o name)" ]] || \
  die "an E07 ElasticQuotaTree already exists"

kube get nodes -o json >"$PREFLIGHT_DIR/nodes.json"
kube get pods -A -o json >"$PREFLIGHT_DIR/pods.json"
python3 "$E07_HELPER" headroom \
  --nodes "$PREFLIGHT_DIR/nodes.json" \
  --pods "$PREFLIGHT_DIR/pods.json" \
  --pool-label "$ACK_NODE_POOL_LABEL" \
  --pool-id "$ACK_NODE_POOL_ID" \
  --pool-max-nodes "$ACK_NODE_POOL_MAX_NODES" \
  --anchor-memory "$E07_ANCHOR_MEMORY_REQUEST" \
  --phase-peak-memory "$E07_PHASE_PEAK_MEMORY" \
  --safety-memory "$E07_HEADROOM_SAFETY_MEMORY" \
  --output "$PREFLIGHT_DIR/headroom.json"
BASELINE_NODE_COUNT="$(jq -r '.baseline_node_count' "$PREFLIGHT_DIR/headroom.json")"
log "E07 preflight passed: context=${EFFECTIVE_CONTEXT}, pool=${ACK_NODE_POOL_ID}, baseline_nodes=${BASELINE_NODE_COUNT}/${ACK_NODE_POOL_MAX_NODES}"
log "memory proof: current_max=$(jq -r '.max_current_available_memory_mib' "$PREFLIGHT_DIR/headroom.json")Mi, anchor=$(jq -r '.anchor_memory_mib' "$PREFLIGHT_DIR/headroom.json")Mi, fresh_required=$(jq -r '.required_fresh_memory_mib' "$PREFLIGHT_DIR/headroom.json")Mi"

if [[ "$CHECK_ONLY" == true ]]; then
  log "E07 check-only complete; no Kubernetes resource was created"
  exit 0
fi
[[ "$CONFIRM_E07_EXECUTION" == yes ]] || \
  die "set CONFIRM_E07_EXECUTION=yes before creating E07 resources"

RUN_SUFFIX="$(date -u +'%Y%m%d%H%M%S')-$(printf '%04x' "$RANDOM")"
RUN_ID="e07-${RUN_SUFFIX}"
NAMESPACE="hooke-${RUN_ID}"
ANCHOR_NAME="e07-capacity-anchor"
TREE_NAME="hooke-${RUN_ID}"
TREE_CHILD="e07-${RUN_SUFFIX}"
ARTIFACT_DIR="${ARTIFACT_ROOT}/e07-end-to-end-tuning-smoke-${RUN_SUFFIX}"
mkdir -p "$ARTIFACT_DIR/cells"
chmod 700 "$ARTIFACT_DIR" "$ARTIFACT_DIR/cells"
cp "$PREFLIGHT_DIR/headroom.json" "$ARTIFACT_DIR/provisioning-evidence.json"
cp "$PREFLIGHT_DIR/nodes.json" "$ARTIFACT_DIR/nodes-before.json"
cp "$PREFLIGHT_DIR/pods.json" "$ARTIFACT_DIR/pods-before.json"
cp "$PREFLIGHT_DIR"/*-release.json "$ARTIFACT_DIR/"
printf '%s\n' "$NODEPOOL_JSON" >"$ARTIFACT_DIR/nodepool.json"
sed -E \
  -e 's/^([A-Za-z0-9_]*(PASSWORD|TOKEN|DSN|SECRET|ACCESS_KEY|CREDENTIAL)[A-Za-z0-9_]*)=.*/\1="<redacted>"/' \
  "$CONFIG_FILE" >"$ARTIFACT_DIR/config.env.redacted"
chmod 600 "$ARTIFACT_DIR/config.env.redacted"
rm -rf -- "$PREFLIGHT_DIR"
trap - EXIT

python3 "$E07_HELPER" schedule \
  --baseline-cooldown "$E07_BASELINE_COOLDOWN_SECONDS" \
  --candidate-cooldown "$E07_CANDIDATE_COOLDOWN_SECONDS" \
  --n "$E07_N" --baseline-k "$E07_BASELINE_K" \
  --candidate-k "$E07_CANDIDATE_K" \
  --output "$ARTIFACT_DIR/schedule.tsv"

LOCK_CREATED=false
NAMESPACE_CREATED=false
TREE_CREATED=false
SUCCESS=false
CURRENT_STATE_PID=""
CURRENT_STATE_STOP=""
CURRENT_METRIC_PID=""
CURRENT_METRIC_STOP=""
CURRENT_GANG_PID=""
CURRENT_GANG_STOP=""

stop_process() {
  local pid="${1:-}" stop_file="${2:-}" deadline rc=0
  [[ -n "$pid" ]] || return 0
  [[ -z "$stop_file" ]] || : >"$stop_file"
  deadline=$((SECONDS + 30))
  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      kill -TERM "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -KILL "$pid" >/dev/null 2>&1 || true
      rc=1
      break
    fi
    sleep 0.1
  done
  wait "$pid" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

stop_all_samplers() {
  stop_process "$CURRENT_STATE_PID" "$CURRENT_STATE_STOP" || true
  stop_process "$CURRENT_METRIC_PID" "$CURRENT_METRIC_STOP" || true
  stop_process "$CURRENT_GANG_PID" "$CURRENT_GANG_STOP" || true
  CURRENT_STATE_PID=""
  CURRENT_STATE_STOP=""
  CURRENT_METRIC_PID=""
  CURRENT_METRIC_STOP=""
  CURRENT_GANG_PID=""
  CURRENT_GANG_STOP=""
}

wait_namespace_deleted() {
  local deadline=$((SECONDS + 240))
  while kube get namespace "$NAMESPACE" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
}

cleanup_resources() {
  local rc=0
  stop_all_samplers
  if [[ "$TREE_CREATED" == true ]]; then
    kube -n kube-system delete elasticquotatree "$TREE_NAME" \
      --ignore-not-found --wait=true >/dev/null || rc=1
    TREE_CREATED=false
  fi
  if [[ "$NAMESPACE_CREATED" == true ]]; then
    kube delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null || rc=1
    wait_namespace_deleted || rc=1
    NAMESPACE_CREATED=false
  fi
  if [[ "$LOCK_CREATED" == true ]]; then
    kube -n "$LOCK_NAMESPACE" delete lease "$LOCK_NAME" \
      --ignore-not-found --wait=true >/dev/null || rc=1
    LOCK_CREATED=false
  fi
  return "$rc"
}

on_exit() {
  local status=$?
  trap - EXIT INT TERM
  trap '' INT TERM
  if (( status == 0 )); then
    if is_true "$CLEANUP_K8S_ON_SUCCESS"; then
      cleanup_resources || status=1
    fi
  elif is_true "$CLEANUP_K8S_ON_ERROR"; then
    cleanup_resources || true
  else
    warn "retaining E07 resources for failed run ${RUN_ID}"
  fi
  if (( status != 0 )); then
    warn "E07 failed; artifacts retained at ${ARTIFACT_DIR}"
  fi
  exit "$status"
}
trap on_exit EXIT INT TERM

jq -n \
  --arg context "$EFFECTIVE_CONTEXT" \
  --arg api_server "$API_SERVER" \
  --arg cluster_id "$CLUSTER_ID" \
  --arg ack_cluster_id "$ACK_CLUSTER_ID" \
  --arg node_pool_id "$ACK_NODE_POOL_ID" \
  --arg run_id "$RUN_ID" \
  --arg namespace "$NAMESPACE" \
  --arg e04_image "$E04_APP_IMAGE" \
  --arg e05_image "$E05_APP_IMAGE" \
  --arg e06_image "$E06_APP_IMAGE" \
  --arg redis_image "$E04_REDIS_IMAGE" \
  '{
    context:$context,
    api_server:$api_server,
    cluster_id:$cluster_id,
    ack_cluster_id:$ack_cluster_id,
    node_pool_id:$node_pool_id,
    run_id:$run_id,
    namespace:$namespace,
    images:{keda_worker:$e04_image,gang_worker:$e05_image,argo_worker:$e06_image,redis:$redis_image},
    design:"cumulative-1x5",
    scope:"smoke",
    statistical_conclusion:false
  }' >"$ARTIFACT_DIR/run-metadata.json"

jq -n \
  --arg name "$LOCK_NAME" \
  --arg namespace "$LOCK_NAMESPACE" \
  --arg holder "$RUN_ID" \
  '{
    apiVersion:"coordination.k8s.io/v1",
    kind:"Lease",
    metadata:{name:$name,namespace:$namespace,labels:{"hooke.io/experiment":"E07"}},
    spec:{holderIdentity:$holder,leaseDurationSeconds:7200}
  }' | kube create -f - >/dev/null
LOCK_CREATED=true

kube create namespace "$NAMESPACE" >/dev/null
NAMESPACE_CREATED=true
kube annotate namespace "$NAMESPACE" "hooke.io/run-id=${RUN_ID}" --overwrite >/dev/null
kube label namespace "$NAMESPACE" \
  "app.kubernetes.io/managed-by=hooke-e07-runner" \
  "hooke.io/experiment=E07" --overwrite >/dev/null

python3 "$E06_HELPER" rbac \
  --namespace "$NAMESPACE" \
  --service-account "$E07_WORKFLOW_SERVICE_ACCOUNT" \
  >"$ARTIFACT_DIR/argo-executor-rbac.json"
kube create -f "$ARTIFACT_DIR/argo-executor-rbac.json" >/dev/null

ANCHOR_CREATED_NS="$(now_ns)"
jq -n \
  --arg name "$ANCHOR_NAME" \
  --arg namespace "$NAMESPACE" \
  --arg run_id "$RUN_ID" \
  --arg image "$E07_ANCHOR_IMAGE" \
  --arg pool_key "$ACK_NODE_POOL_LABEL" \
  --arg pool_id "$ACK_NODE_POOL_ID" \
  --arg memory "$E07_ANCHOR_MEMORY_REQUEST" \
  '{
    apiVersion:"v1",
    kind:"Pod",
    metadata:{
      name:$name,
      namespace:$namespace,
      labels:{"hooke.io/experiment":"E07","hooke.io/e07-role":"capacity-anchor"},
      annotations:{"hooke.io/run-id":$run_id}
    },
    spec:{
      restartPolicy:"Never",
      terminationGracePeriodSeconds:5,
      automountServiceAccountToken:false,
      enableServiceLinks:false,
      nodeSelector:{($pool_key):$pool_id},
      securityContext:{
        runAsNonRoot:true,
        runAsUser:999,
        runAsGroup:999,
        seccompProfile:{type:"RuntimeDefault"}
      },
      containers:[{
        name:"anchor",
        image:$image,
        imagePullPolicy:"IfNotPresent",
        command:["sh","-c","trap \"exit 0\" TERM INT; while true; do sleep 3600 & wait $!; done"],
        resources:{
          requests:{cpu:"10m",memory:$memory},
          limits:{cpu:"50m",memory:$memory}
        },
        securityContext:{
          allowPrivilegeEscalation:false,
          capabilities:{drop:["ALL"]},
          runAsNonRoot:true,
          runAsUser:999,
          runAsGroup:999
        }
      }]
    }
  }' >"$ARTIFACT_DIR/anchor-manifest.json"
kube create -f "$ARTIFACT_DIR/anchor-manifest.json" >/dev/null
log "B0: capacity anchor created; waiting for a fifth physical Node"

anchor_deadline=$((SECONDS + E07_ANCHOR_TIMEOUT_SECONDS))
TARGET_NODE=""
while (( SECONDS < anchor_deadline )); do
  TARGET_NODE="$(kube -n "$NAMESPACE" get pod "$ANCHOR_NAME" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  [[ -n "$TARGET_NODE" ]] && break
  sleep 2
done
[[ -n "$TARGET_NODE" ]] || die "capacity anchor was not scheduled before timeout"
if jq -e --arg target "$TARGET_NODE" \
  'any(.baseline_nodes[]; .name==$target)' \
  "$ARTIFACT_DIR/provisioning-evidence.json" >/dev/null; then
  die "capacity anchor reused baseline Node ${TARGET_NODE}"
fi
TARGET_NODE_JSON="$(kube get node "$TARGET_NODE" -o json)"
[[ "$(jq -r --arg key "$ACK_NODE_POOL_LABEL" \
  '.metadata.labels[$key] // ""' <<<"$TARGET_NODE_JSON")" == "$ACK_NODE_POOL_ID" ]] || \
  die "new target Node is outside the configured node pool"
[[ "$(jq -r '.metadata.labels.type // ""' <<<"$TARGET_NODE_JSON")" != virtual-kubelet ]] || \
  die "E07 target is a virtual-kubelet Node"
[[ "$(jq -r '
  any(.status.conditions[]; .type=="Ready" and .status=="True")
' <<<"$TARGET_NODE_JSON")" == true ]] || die "new target Node is not Ready"
kube -n "$NAMESPACE" wait --for=condition=Ready "pod/${ANCHOR_NAME}" \
  --timeout="${E07_ANCHOR_TIMEOUT_SECONDS}s" >/dev/null
NODE_READY_NS="$(now_ns)"
kube -n "$NAMESPACE" get pod "$ANCHOR_NAME" -o json >"$ARTIFACT_DIR/anchor-pod.json"
printf '%s\n' "$TARGET_NODE_JSON" >"$ARTIFACT_DIR/target-node-created.json"
TARGET_NODE_UID="$(jq -r '.metadata.uid' <<<"$TARGET_NODE_JSON")"
ANCHOR_NODE="$(jq -r '.spec.nodeName' "$ARTIFACT_DIR/anchor-pod.json")"
[[ "$ANCHOR_NODE" == "$TARGET_NODE" ]] || die "anchor placement changed"
jq \
  --arg target_node "$TARGET_NODE" \
  --arg target_node_uid "$TARGET_NODE_UID" \
  --arg anchor_node "$ANCHOR_NODE" \
  --argjson anchor_created_ns "$ANCHOR_CREATED_NS" \
  --argjson node_ready_ns "$NODE_READY_NS" \
  '. + {
    target_node:$target_node,
    target_node_uid:$target_node_uid,
    anchor_node:$anchor_node,
    anchor_created_ns:$anchor_created_ns,
    node_ready_ns:$node_ready_ns
  }' "$ARTIFACT_DIR/provisioning-evidence.json" \
  >"$ARTIFACT_DIR/provisioning-evidence.tmp"
mv "$ARTIFACT_DIR/provisioning-evidence.tmp" \
  "$ARTIFACT_DIR/provisioning-evidence.json"
log "B0 target ready: ${TARGET_NODE} (provisioning=$(((NODE_READY_NS - ANCHOR_CREATED_NS) / 1000000000))s)"

ensure_target_ready() {
  local node
  node="$(kube get node "$TARGET_NODE" -o json 2>/dev/null || true)"
  [[ -n "$node" ]] || die "target Node ${TARGET_NODE} disappeared"
  [[ "$(jq -r '
    any(.status.conditions[]; .type=="Ready" and .status=="True")
  ' <<<"$node")" == true ]] || die "target Node ${TARGET_NODE} is not Ready"
  [[ "$(jq -r '.spec.unschedulable // false' <<<"$node")" == false ]] || \
    die "target Node ${TARGET_NODE} is unschedulable"
}

ensure_queue_tree() {
  [[ "$TREE_CREATED" == false ]] || return 0
  python3 "$E05_HELPER" quota-tree \
    --name "$TREE_NAME" \
    --child-name "$TREE_CHILD" \
    --namespace "$NAMESPACE" \
    --cpu "$E07_QUOTA_CPU" \
    --memory "$E07_QUOTA_MEMORY" \
    --max-jobs "$E07_QUOTA_MAX_JOBS" \
    | jq --arg run_id "$RUN_ID" \
      '.metadata.labels={"hooke.io/experiment":"E07","hooke.io/run-id":$run_id}' \
    >"$ARTIFACT_DIR/elasticquotatree-manifest.json"
  kube create -f "$ARTIFACT_DIR/elasticquotatree-manifest.json" >/dev/null
  TREE_CREATED=true
  local deadline=$((SECONDS + 120)) count=0
  while (( SECONDS < deadline )); do
    count="$(kube -n "$KUBE_QUEUE_NAMESPACE" get queues -o json \
      | jq --arg child "$TREE_CHILD" \
        '[.items[] | select(.metadata.name | startswith("root-" + $child + "-"))] | length')"
    (( count > 0 )) && break
    sleep 1
  done
  (( count > 0 )) || die "ACK Queue leaf was not created for E07"
  kube -n "$KUBE_QUEUE_NAMESPACE" get queues -o json \
    >"$ARTIFACT_DIR/queues.json"
}

write_keda_config() {
  local output="$1" sequence="$2" cell_id="$3" cooldown="$4" prefix="$5"
  jq -n \
    --argjson sequence "$sequence" \
    --arg cell_id "$cell_id" \
    --argjson cooldown "$cooldown" \
    --argjson polling "$E07_POLLING_INTERVAL_SECONDS" \
    --argjson min_replicas "$E07_MIN_REPLICAS" \
    --argjson max_replicas "$E07_MAX_REPLICAS" \
    --argjson lambda "$E07_LAMBDA_PER_SECOND" \
    --argjson messages "$E07_MESSAGE_COUNT" \
    --arg processing "$E07_PROCESSING_DURATION" \
    --arg queue_sample "$E07_QUEUE_SAMPLE_INTERVAL" \
    --argjson metric_gap "$E07_METRIC_SAMPLE_MAX_GAP_SECONDS" \
    --arg app_image "$E04_APP_IMAGE" \
    --arg redis_image "$E04_REDIS_IMAGE" \
    --arg node "$TARGET_NODE" \
    --argjson producer_timeout "$E07_PRODUCER_TIMEOUT_SECONDS" \
    --arg queue_key "hooke:e07:${cell_id}:queue" \
    --arg completion_key "hooke:e07:${cell_id}:completed" \
    --arg redis_name "${prefix}-redis" \
    --arg worker_name "${prefix}-worker" \
    --arg producer_name "${prefix}-producer" \
    --arg scaler_name "${prefix}-scaler" \
    --arg redis_cpu_request "$E07_REDIS_CPU_REQUEST" \
    --arg redis_cpu_limit "$E07_REDIS_CPU_LIMIT" \
    --arg redis_memory_request "$E07_REDIS_MEMORY_REQUEST" \
    --arg redis_memory_limit "$E07_REDIS_MEMORY_LIMIT" \
    --arg worker_cpu_request "$E07_KEDA_WORKER_CPU_REQUEST" \
    --arg worker_cpu_limit "$E07_KEDA_WORKER_CPU_LIMIT" \
    --arg worker_memory_request "$E07_KEDA_WORKER_MEMORY_REQUEST" \
    --arg worker_memory_limit "$E07_KEDA_WORKER_MEMORY_LIMIT" \
    --arg producer_cpu_request "$E07_PRODUCER_CPU_REQUEST" \
    --arg producer_cpu_limit "$E07_PRODUCER_CPU_LIMIT" \
    --arg producer_memory_request "$E07_PRODUCER_MEMORY_REQUEST" \
    --arg producer_memory_limit "$E07_PRODUCER_MEMORY_LIMIT" \
    '{
      sequence:$sequence,
      block:1,
      cell_id:$cell_id,
      cooldown_seconds:$cooldown,
      cluster_id:env.CLUSTER_ID,
      polling_interval_seconds:$polling,
      min_replicas:$min_replicas,
      max_replicas:$max_replicas,
      lambda_per_second:$lambda,
      message_count:$messages,
      processing_duration:$processing,
      queue_sample_interval:$queue_sample,
      metric_sample_max_gap_seconds:$metric_gap,
      list_length:"1",
      activation_list_length:"0",
      arrival_rate_relative_tolerance:0.35,
      app_image:$app_image,
      redis_image:$redis_image,
      node_selector_key:"kubernetes.io/hostname",
      node_selector_value:$node,
      taint_key:"",
      taint_value:"",
      taint_effect:"NoSchedule",
      producer_timeout_seconds:$producer_timeout,
      queue_key:$queue_key,
      completion_key:$completion_key,
      redis_name:$redis_name,
      worker_name:$worker_name,
      producer_name:$producer_name,
      scaled_object_name:$scaler_name,
      redis_cpu_request:$redis_cpu_request,
      redis_cpu_limit:$redis_cpu_limit,
      redis_memory_request:$redis_memory_request,
      redis_memory_limit:$redis_memory_limit,
      worker_cpu_request:$worker_cpu_request,
      worker_cpu_limit:$worker_cpu_limit,
      worker_memory_request:$worker_memory_request,
      worker_memory_limit:$worker_memory_limit,
      producer_cpu_request:$producer_cpu_request,
      producer_cpu_limit:$producer_cpu_limit,
      producer_memory_request:$producer_memory_request,
      producer_memory_limit:$producer_memory_limit
    }' >"$output"
}

create_redis_secret() {
  local name="$1" password
  password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  E07_REDIS_PASSWORD="$password" jq -n \
    --arg name "$name" \
    --arg namespace "$NAMESPACE" \
    --arg run_id "$RUN_ID" \
    --arg password "$password" \
    '{
      apiVersion:"v1",
      kind:"Secret",
      metadata:{
        name:$name,
        namespace:$namespace,
        labels:{"hooke.io/experiment":"E07"},
        annotations:{"hooke.io/run-id":$run_id}
      },
      type:"Opaque",
      stringData:{password:$password}
    }' | kube create -f - >/dev/null
  unset password
}

wait_keda_baseline() {
  local cell_dir="$1" worker="$2" scaler="$3"
  local deadline=$((SECONDS + E07_INITIAL_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if kube -n "$NAMESPACE" get scaledobject "$scaler" -o json \
        >"$cell_dir/scaledobject-initial-candidate.json" 2>/dev/null &&
      kube -n "$NAMESPACE" get deployment "$worker" -o json \
        >"$cell_dir/worker-initial-candidate.json" 2>/dev/null &&
      python3 - \
        "$cell_dir/scaledobject-initial-candidate.json" \
        "$cell_dir/worker-initial-candidate.json" <<'PY' >/dev/null 2>&1
import json, sys
scaled_object = json.load(open(sys.argv[1], encoding="utf-8"))
deployment = json.load(open(sys.argv[2], encoding="utf-8"))
conditions = scaled_object.get("status", {}).get("conditions", [])
ready = any(item.get("type") == "Ready" and item.get("status") == "True" for item in conditions)
active = next((item.get("status") for item in conditions if item.get("type") == "Active"), "")
status = deployment.get("status", {})
zero = deployment.get("spec", {}).get("replicas") == 0 and all(
    int(status.get(field) or 0) == 0
    for field in ("replicas", "readyReplicas", "availableReplicas")
)
raise SystemExit(0 if ready and active in ("", "False") and zero else 1)
PY
    then
      jq -n \
        --slurpfile deployment "$cell_dir/worker-initial-candidate.json" \
        --slurpfile scaled_object "$cell_dir/scaledobject-initial-candidate.json" \
        '{deployment:$deployment[0],scaled_object:$scaled_object[0]}' \
        >"$cell_dir/keda-initial-state.json"
      return 0
    fi
    sleep 1
  done
  die "KEDA baseline did not become Ready+Inactive at zero replicas"
}

sample_keda_state() {
  local cell_dir="$1" worker="$2" scaler="$3" stop_file="$4" output="$5"
  local sample_dir="${cell_dir}/state-sampler"
  mkdir -p "$sample_dir"
  while [[ ! -f "$stop_file" ]]; do
    local observed
    observed="$(now_ns)"
    kube -n "$NAMESPACE" get scaledobject "$scaler" -o json >"$sample_dir/so.json"
    kube -n "$NAMESPACE" get deployment "$worker" -o json >"$sample_dir/deployment.json"
    kube -n "$NAMESPACE" get hpa -o json >"$sample_dir/hpas.json"
    kube -n "$NAMESPACE" get pods \
      -l "hooke.io/e04-role=worker" \
      -o json >"$sample_dir/pods.json"
    jq -cn \
      --argjson observed "$observed" \
      --arg scaler "$scaler" \
      --slurpfile so "$sample_dir/so.json" \
      --slurpfile deployment "$sample_dir/deployment.json" \
      --slurpfile hpas "$sample_dir/hpas.json" \
      --slurpfile pods "$sample_dir/pods.json" \
      '{
        observed_time_ns:$observed,
        scaled_object:$so[0],
        deployment:$deployment[0],
        hpa:([
          $hpas[0].items[] |
          select(any(.metadata.ownerReferences[]?;
            .kind=="ScaledObject" and .name==$scaler))
        ][0] // {}),
        pods:$pods[0]
      }' >>"$output"
    sleep "$E07_METRIC_SAMPLE_INTERVAL_SECONDS"
  done
}

wait_initial_zero_metric() {
  local capture="$1"
  local deadline=$((SECONDS + E07_INITIAL_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if [[ -s "$capture" ]] && python3 - "$capture" <<'PY' >/dev/null 2>&1
import json, re, sys
for line in open(sys.argv[1], encoding="utf-8"):
    row = json.loads(line)
    if row.get("error"):
        continue
    for item in (row.get("payload") or {}).get("items", []):
        match = re.fullmatch(r"([+-]?(?:\d+(?:\.\d*)?|\.\d+))(m)?", str(item.get("value") or ""))
        if match:
            value = float(match.group(1)) / (1000 if match.group(2) else 1)
            if value == 0:
                raise SystemExit(0)
raise SystemExit(1)
PY
    then
      return 0
    fi
    [[ -n "$CURRENT_METRIC_PID" ]] &&
      kill -0 "$CURRENT_METRIC_PID" >/dev/null 2>&1 ||
      die "KEDA metric sampler exited before initial zero"
    sleep 1
  done
  die "KEDA external metric did not expose initial zero"
}

capture_keda_application() {
  local cell_dir="$1"
  mkdir -p "$cell_dir/keda-logs"
  kube -n "$NAMESPACE" get pods \
    -l "hooke.io/experiment=E04" -o json \
    | jq '{
        apiVersion,
        kind,
        metadata,
        items:[
          .items[] |
          select(
            .metadata.labels["hooke.io/e04-role"]=="producer" or
            .metadata.labels["hooke.io/e04-role"]=="worker"
          )
        ]
      }' >"$cell_dir/keda-application-pods.json"
  [[ "$(jq '[.items[] | select(.metadata.labels["hooke.io/e04-role"]=="producer")] | length' \
    "$cell_dir/keda-application-pods.json")" == 1 ]] || \
    die "KEDA producer Pod snapshot is incomplete"
  (( $(jq '[.items[] | select(.metadata.labels["hooke.io/e04-role"]=="worker")] | length' \
    "$cell_dir/keda-application-pods.json") >= 1 )) || \
    die "KEDA worker Pod snapshot is incomplete"
  while IFS=$'\t' read -r pod container role; do
    kube -n "$NAMESPACE" logs "$pod" -c "$container" \
      >"$cell_dir/keda-logs/${role}-${pod}-${container}.log"
  done < <(jq -r '
    .items[] |
    .metadata.name as $pod |
    .metadata.labels["hooke.io/e04-role"] as $role |
    .spec.containers[] |
    [$pod,.name,$role] | @tsv
  ' "$cell_dir/keda-application-pods.json")
}

wait_keda_zero() {
  local worker="$1" scaler="$2"
  local deadline=$((SECONDS + E07_SCALE_ZERO_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if python3 - \
      <(kube -n "$NAMESPACE" get deployment "$worker" -o json) \
      <(kube -n "$NAMESPACE" get scaledobject "$scaler" -o json) \
      <<'PY' >/dev/null 2>&1
import json, sys
deployment = json.load(open(sys.argv[1], encoding="utf-8"))
scaled_object = json.load(open(sys.argv[2], encoding="utf-8"))
status = deployment.get("status", {})
zero = deployment.get("spec", {}).get("replicas") == 0 and all(
    int(status.get(field) or 0) == 0
    for field in ("replicas", "readyReplicas", "availableReplicas")
)
inactive = any(
    item.get("type") == "Active" and item.get("status") == "False"
    for item in scaled_object.get("status", {}).get("conditions", [])
)
raise SystemExit(0 if zero and inactive else 1)
PY
    then
      return 0
    fi
    sleep 1
  done
  die "KEDA worker did not scale to zero"
}

run_keda_phase() {
  local sequence="$1" cell_id="$2" cooldown="$3" cell_dir="$4"
  local prefix="e07-$(tr '[:upper:]' '[:lower:]' <<<"$cell_id")"
  local worker="${prefix}-worker"
  local producer="${prefix}-producer"
  local scaler="${prefix}-scaler"
  local secret="${prefix}-redis-auth"
  local start_ns end_ns
  KEDA_STARTED_NS="$(now_ns)"
  start_ns="$KEDA_STARTED_NS"
  write_keda_config "$cell_dir/keda-config.json" \
    "$sequence" "$cell_id" "$cooldown" "$prefix"
  create_redis_secret "$secret"
  python3 "$E04_HELPER" render \
    --config "$cell_dir/keda-config.json" \
    --namespace "$NAMESPACE" \
    --run-id "$RUN_ID" \
    --redis-secret "$secret" \
    --base-output "$cell_dir/keda-base-manifest.json" \
    --producer-output "$cell_dir/keda-producer-manifest.json"
  kube apply -f "$cell_dir/keda-base-manifest.json" >/dev/null
  kube -n "$NAMESPACE" rollout status \
    "deployment/${prefix}-redis" \
    --timeout="${E07_INITIAL_TIMEOUT_SECONDS}s" >/dev/null
  wait_keda_baseline "$cell_dir" "$worker" "$scaler"

  CURRENT_STATE_STOP="$cell_dir/keda-state.stop"
  CURRENT_METRIC_STOP="$cell_dir/keda-metric.stop"
  rm -f -- "$CURRENT_STATE_STOP" "$CURRENT_METRIC_STOP"
  sample_keda_state "$cell_dir" "$worker" "$scaler" \
    "$CURRENT_STATE_STOP" "$cell_dir/keda-state-captures.ndjson" &
  CURRENT_STATE_PID=$!
  python3 "$E04_HELPER" sample-keda \
    --kubeconfig "$KUBECONFIG_PATH" \
    "${SAMPLER_CONTEXT_ARGS[@]}" \
    --namespace "$NAMESPACE" \
    --scaled-object "$scaler" \
    --output "$cell_dir/keda-metric-captures.ndjson" \
    --stop-file "$CURRENT_METRIC_STOP" \
    --interval-seconds "$E07_METRIC_SAMPLE_INTERVAL_SECONDS" \
    --request-timeout-seconds "$E07_METRIC_REQUEST_TIMEOUT_SECONDS" \
    --max-consecutive-errors "$E07_METRIC_MAX_CONSECUTIVE_ERRORS" \
    >"$cell_dir/keda-metric-sampler.log" 2>&1 &
  CURRENT_METRIC_PID=$!
  wait_initial_zero_metric "$cell_dir/keda-metric-captures.ndjson"

  kube apply -f "$cell_dir/keda-producer-manifest.json" >/dev/null
  if ! kube -n "$NAMESPACE" wait --for=condition=Complete \
      "job/${producer}" --timeout="${E07_PRODUCER_TIMEOUT_SECONDS}s" >/dev/null; then
    kube -n "$NAMESPACE" get pods -o wide >"$cell_dir/keda-failed-pods.txt" || true
    kube -n "$NAMESPACE" logs "job/${producer}" >"$cell_dir/keda-producer-failed.log" || true
    die "KEDA producer failed in ${cell_id}"
  fi
  capture_keda_application "$cell_dir"
  wait_keda_zero "$worker" "$scaler"
  sleep 1
  stop_process "$CURRENT_STATE_PID" "$CURRENT_STATE_STOP" || \
    die "KEDA state sampler failed in ${cell_id}"
  CURRENT_STATE_PID=""
  CURRENT_STATE_STOP=""
  stop_process "$CURRENT_METRIC_PID" "$CURRENT_METRIC_STOP" || \
    die "KEDA metric sampler failed in ${cell_id}"
  CURRENT_METRIC_PID=""
  CURRENT_METRIC_STOP=""

  end_ns="$(now_ns)"
  kube -n "$NAMESPACE" get deployment "$worker" -o json \
    >"$cell_dir/keda-worker-final.json"
  kube -n "$NAMESPACE" get scaledobject "$scaler" -o json \
    >"$cell_dir/keda-scaledobject-final.json"
  python3 "$APPLICATION_EXPORTER" \
    --cluster-id "$CLUSTER_ID" \
    --run-id "$RUN_ID" \
    --pods "$cell_dir/keda-application-pods.json" \
    --logs-dir "$cell_dir/keda-logs" \
    --start-ns "$start_ns" \
    --end-ns "$end_ns" \
    --output "$cell_dir/keda-application-events.ndjson"
  python3 "$E07_HELPER" summarize-keda \
    --config "$cell_dir/keda-config.json" \
    --initial-state "$cell_dir/keda-initial-state.json" \
    --final-scaled-object "$cell_dir/keda-scaledobject-final.json" \
    --final-deployment "$cell_dir/keda-worker-final.json" \
    --state-captures "$cell_dir/keda-state-captures.ndjson" \
    --metric-captures "$cell_dir/keda-metric-captures.ndjson" \
    --application-events "$cell_dir/keda-application-events.ndjson" \
    --expected-node "$TARGET_NODE" \
    --expected-image "$E04_APP_IMAGE" \
    --output "$cell_dir/keda-summary.json"

  kube delete -f "$cell_dir/keda-producer-manifest.json" \
    --ignore-not-found --wait=true >/dev/null
  kube delete -f "$cell_dir/keda-base-manifest.json" \
    --ignore-not-found --wait=true >/dev/null
  kube -n "$NAMESPACE" delete secret "$secret" \
    --ignore-not-found --wait=true >/dev/null
  KEDA_FINISHED_NS="$(now_ns)"
}

sample_gang_state() {
  local job_name="$1" stop_file="$2" queue_output="$3" pod_output="$4"
  while [[ ! -f "$stop_file" ]]; do
    local observed
    observed="$(now_ns)"
    kube -n "$NAMESPACE" get queueunits -o json \
      | jq -c --argjson observed_time_ns "$observed" \
        '. + {observed_time_ns:$observed_time_ns}' >>"$queue_output"
    kube -n "$NAMESPACE" get pods \
      -l "hooke.io/e05-job=${job_name}" -o json \
      | jq -c --argjson observed_time_ns "$observed" \
        '. + {observed_time_ns:$observed_time_ns}' >>"$pod_output"
    sleep 0.5
  done
}

run_gang_phase() {
  local cell_id="$1" queue_mode="$2" n="$3" k="$4" cell_dir="$5"
  local lower job_name service_name start_ns end_ns remaining
  lower="$(tr '[:upper:]' '[:lower:]' <<<"$cell_id")"
  job_name="e07-${lower}-gang"
  service_name="$job_name"
  [[ "$queue_mode" != ack ]] || ensure_queue_tree
  GANG_STARTED_NS="$(now_ns)"
  start_ns="$GANG_STARTED_NS"
  python3 "$E05_HELPER" manifest \
    --namespace "$NAMESPACE" \
    --job-name "$job_name" \
    --service-name "$service_name" \
    --run-id "$RUN_ID" \
    --cluster-id "$CLUSTER_ID" \
    --image "$E05_APP_IMAGE" \
    --n "$n" --k "$k" \
    --barrier-timeout "$E07_BARRIER_TIMEOUT" \
    --work-duration "$E07_GANG_WORK_DURATION" \
    --leader-grace "$E07_GANG_LEADER_GRACE_DURATION" \
    --cpu-request "$E07_GANG_CPU_REQUEST" \
    --cpu-limit "$E07_GANG_CPU_LIMIT" \
    --memory-request "$E07_GANG_MEMORY_REQUEST" \
    --memory-limit "$E07_GANG_MEMORY_LIMIT" \
    --node-selector-key kubernetes.io/hostname \
    --node-selector-value "$TARGET_NODE" \
    >"$cell_dir/gang-manifest.json"
  if [[ "$queue_mode" == direct ]]; then
    jq '(.items[] | select(.kind=="Job").spec.suspend)=false' \
      "$cell_dir/gang-manifest.json" >"$cell_dir/gang-manifest.tmp"
    mv "$cell_dir/gang-manifest.tmp" "$cell_dir/gang-manifest.json"
  fi

  CURRENT_GANG_STOP="$cell_dir/gang-sampler.stop"
  rm -f -- "$CURRENT_GANG_STOP"
  sample_gang_state "$job_name" "$CURRENT_GANG_STOP" \
    "$cell_dir/gang-queueunits.ndjson" "$cell_dir/gang-pods.ndjson" &
  CURRENT_GANG_PID=$!
  kube apply -f "$cell_dir/gang-manifest.json" >/dev/null
  if ! kube -n "$NAMESPACE" wait --for=condition=Complete \
      "job/${job_name}" --timeout="${E07_JOB_TIMEOUT_SECONDS}s" >/dev/null; then
    kube -n "$NAMESPACE" get job "$job_name" -o yaml \
      >"$cell_dir/gang-job-failed.yaml" || true
    kube -n "$NAMESPACE" get pods -l "hooke.io/e05-job=${job_name}" -o wide \
      >"$cell_dir/gang-pods-failed.txt" || true
    die "gang Job failed in ${cell_id}"
  fi
  stop_process "$CURRENT_GANG_PID" "$CURRENT_GANG_STOP" || \
    die "gang sampler failed in ${cell_id}"
  CURRENT_GANG_PID=""
  CURRENT_GANG_STOP=""

  kube -n "$NAMESPACE" get job "$job_name" -o json >"$cell_dir/gang-job.json"
  kube -n "$NAMESPACE" get pods -l "hooke.io/e05-job=${job_name}" -o json \
    >"$cell_dir/gang-pods.json"
  mkdir -p "$cell_dir/gang-logs"
  while IFS=$'\t' read -r pod container; do
    kube -n "$NAMESPACE" logs "$pod" -c "$container" \
      >"$cell_dir/gang-logs/${pod}-${container}.log"
  done < <(jq -r '
    .items[] | .metadata.name as $pod |
    .spec.containers[] | [$pod,.name] | @tsv
  ' "$cell_dir/gang-pods.json")
  end_ns="$(now_ns)"
  python3 "$APPLICATION_EXPORTER" \
    --cluster-id "$CLUSTER_ID" \
    --run-id "$RUN_ID" \
    --pods "$cell_dir/gang-pods.json" \
    --logs-dir "$cell_dir/gang-logs" \
    --start-ns "$start_ns" \
    --end-ns "$end_ns" \
    --output "$cell_dir/gang-application-events.ndjson"
  if [[ "$queue_mode" == ack ]]; then
    python3 "$E05_HELPER" summarize-cell \
      --job-name "$job_name" \
      --n "$n" --k "$k" \
      --queueunit-captures "$cell_dir/gang-queueunits.ndjson" \
      --pod-captures "$cell_dir/gang-pods.ndjson" \
      --pods "$cell_dir/gang-pods.json" \
      --application-events "$cell_dir/gang-application-events.ndjson" \
      --output "$cell_dir/gang-summary.json"
  else
    python3 "$E07_HELPER" summarize-direct-gang \
      --job "$cell_dir/gang-job.json" \
      --pods "$cell_dir/gang-pods.json" \
      --application-events "$cell_dir/gang-application-events.ndjson" \
      --queueunit-captures "$cell_dir/gang-queueunits.ndjson" \
      --n "$n" --k "$k" \
      --expected-node "$TARGET_NODE" \
      --expected-image "$E05_APP_IMAGE" \
      --output "$cell_dir/gang-summary.json"
  fi

  kube -n "$NAMESPACE" delete job "$job_name" \
    --ignore-not-found --wait=true >/dev/null
  kube -n "$NAMESPACE" delete service "$service_name" \
    --ignore-not-found --wait=true >/dev/null
  local deletion_deadline=$((SECONDS + 120))
  remaining=0
  while (( SECONDS < deletion_deadline )); do
    remaining="$(kube -n "$NAMESPACE" get queueunits -o json \
      | jq --arg job "$job_name" \
        '[.items[] | select(.spec.consumerRef.name==$job)] | length')"
    (( remaining == 0 )) && break
    sleep 1
  done
  (( remaining == 0 )) || die "QueueUnit for ${job_name} was not garbage-collected"
  GANG_FINISHED_NS="$(now_ns)"
}

run_argo_phase() {
  local cell_id="$1" variant="$2" sequence="$3" cell_dir="$4"
  local lower workflow start_ns end_ns phase deadline
  lower="$(tr '[:upper:]' '[:lower:]' <<<"$cell_id")"
  workflow="e07-${lower}-argo"
  ARGO_STARTED_NS="$(now_ns)"
  start_ns="$ARGO_STARTED_NS"
  python3 "$E06_HELPER" workflow \
    --namespace "$NAMESPACE" \
    --name "$workflow" \
    --run-id "$RUN_ID" \
    --cluster-id "$CLUSTER_ID" \
    --variant "$variant" \
    --image "$E06_APP_IMAGE" \
    --service-account "$E07_WORKFLOW_SERVICE_ACCOUNT" \
    --stage-durations "$E07_STAGE_DURATIONS" \
    --stage-timeout-seconds "$E07_STAGE_TIMEOUT_SECONDS" \
    --workflow-timeout-seconds "$E07_WORKFLOW_TIMEOUT_SECONDS" \
    --cpu-request "$E07_ARGO_CPU_REQUEST" \
    --cpu-limit "$E07_ARGO_CPU_LIMIT" \
    --memory-request "$E07_ARGO_MEMORY_REQUEST" \
    --memory-limit "$E07_ARGO_MEMORY_LIMIT" \
    --node-selector-key kubernetes.io/hostname \
    --node-selector-value "$TARGET_NODE" \
    >"$cell_dir/argo-manifest.json"
  kube create -f "$cell_dir/argo-manifest.json" >/dev/null
  deadline=$((SECONDS + E07_WORKFLOW_TIMEOUT_SECONDS))
  phase=""
  while (( SECONDS < deadline )); do
    phase="$(kube -n "$NAMESPACE" get workflow "$workflow" \
      -o jsonpath='{.status.phase}')"
    case "$phase" in
      Succeeded) break ;;
      Failed|Error)
        kube -n "$NAMESPACE" get workflow "$workflow" -o yaml \
          >"$cell_dir/argo-workflow-failed.yaml" || true
        kube -n "$NAMESPACE" get pods \
          -l "workflows.argoproj.io/workflow=${workflow}" -o wide \
          >"$cell_dir/argo-pods-failed.txt" || true
        die "Argo Workflow ${workflow} ended in ${phase}"
        ;;
    esac
    sleep 1
  done
  [[ "$phase" == Succeeded ]] || die "Argo Workflow timed out in ${cell_id}"
  kube -n "$NAMESPACE" get workflow "$workflow" -o json \
    >"$cell_dir/argo-workflow.json"
  kube -n "$NAMESPACE" get pods \
    -l "workflows.argoproj.io/workflow=${workflow}" -o json \
    >"$cell_dir/argo-pods.json"
  mkdir -p "$cell_dir/argo-logs"
  while IFS= read -r pod; do
    kube -n "$NAMESPACE" logs "$pod" -c main \
      >"$cell_dir/argo-logs/${pod}-main.log"
  done < <(jq -r '.items[].metadata.name' "$cell_dir/argo-pods.json")
  end_ns="$(now_ns)"
  python3 "$APPLICATION_EXPORTER" \
    --cluster-id "$CLUSTER_ID" \
    --run-id "$RUN_ID" \
    --pods "$cell_dir/argo-pods.json" \
    --logs-dir "$cell_dir/argo-logs" \
    --start-ns "$start_ns" \
    --end-ns "$end_ns" \
    --output "$cell_dir/argo-application-events.ndjson"
  python3 "$E06_HELPER" summarize-cell \
    --workflow "$cell_dir/argo-workflow.json" \
    --pods "$cell_dir/argo-pods.json" \
    --application-events "$cell_dir/argo-application-events.ndjson" \
    --variant "$variant" \
    --sequence "$sequence" \
    --block 1 \
    --slo-seconds "$E07_SLO_SECONDS" \
    --clock-tolerance-seconds "$E07_CLOCK_TOLERANCE_SECONDS" \
    --expected-image "$E06_APP_IMAGE" \
    --expected-node "$TARGET_NODE" \
    --output "$cell_dir/argo-summary.json"
  kube -n "$NAMESPACE" delete workflow "$workflow" \
    --ignore-not-found --wait=true >/dev/null
  ARGO_FINISHED_NS="$(now_ns)"
}

CELL_SUMMARIES=()
while IFS=$'\t' read -r \
  sequence cell_id node_mode cooldown queue_mode n k argo_variant; do
  [[ "$sequence" != sequence ]] || continue
  ensure_target_ready
  lower="$(tr '[:upper:]' '[:lower:]' <<<"$cell_id")"
  CELL_DIR="$ARTIFACT_DIR/cells/$(printf '%02d' "$sequence")-${lower}"
  mkdir -p "$CELL_DIR"
  chmod 700 "$CELL_DIR"
  jq -n \
    --argjson sequence "$sequence" \
    --arg cell_id "$cell_id" \
    --arg node_mode "$node_mode" \
    --argjson cooldown "$cooldown" \
    --arg queue_mode "$queue_mode" \
    --argjson n "$n" \
    --argjson k "$k" \
    --arg argo_variant "$argo_variant" \
    '{
      sequence:$sequence,
      cell_id:$cell_id,
      node_mode:$node_mode,
      cooldown_seconds:$cooldown,
      queue_mode:$queue_mode,
      n:$n,
      k:$k,
      argo_variant:$argo_variant
    }' >"$CELL_DIR/cell-config.json"

  if [[ "$cell_id" == B0 ]]; then
    CELL_STARTED_NS="$ANCHOR_CREATED_NS"
    CELL_NODE_READY_NS="$NODE_READY_NS"
  else
    CELL_STARTED_NS="$(now_ns)"
    CELL_NODE_READY_NS="$CELL_STARTED_NS"
  fi
  log "${cell_id}: KEDA cooldown=${cooldown}s, queue=${queue_mode}, n/k=${n}/${k}, Argo=${argo_variant}"
  run_keda_phase "$sequence" "$cell_id" "$cooldown" "$CELL_DIR"
  ensure_target_ready
  run_gang_phase "$cell_id" "$queue_mode" "$n" "$k" "$CELL_DIR"
  ensure_target_ready
  run_argo_phase "$cell_id" "$argo_variant" "$sequence" "$CELL_DIR"
  CELL_FINISHED_NS="$(now_ns)"

  jq -n \
    --argjson cell_started_ns "$CELL_STARTED_NS" \
    --argjson node_ready_ns "$CELL_NODE_READY_NS" \
    --argjson keda_started_ns "$KEDA_STARTED_NS" \
    --argjson keda_finished_ns "$KEDA_FINISHED_NS" \
    --argjson gang_started_ns "$GANG_STARTED_NS" \
    --argjson gang_finished_ns "$GANG_FINISHED_NS" \
    --argjson argo_started_ns "$ARGO_STARTED_NS" \
    --argjson argo_finished_ns "$ARGO_FINISHED_NS" \
    --argjson cell_finished_ns "$CELL_FINISHED_NS" \
    '{
      cell_started_ns:$cell_started_ns,
      node_ready_ns:$node_ready_ns,
      keda_started_ns:$keda_started_ns,
      keda_finished_ns:$keda_finished_ns,
      gang_started_ns:$gang_started_ns,
      gang_finished_ns:$gang_finished_ns,
      argo_started_ns:$argo_started_ns,
      argo_finished_ns:$argo_finished_ns,
      cell_finished_ns:$cell_finished_ns
    }' >"$CELL_DIR/timing.json"
  python3 "$E07_HELPER" summarize-cell \
    --cell-config "$CELL_DIR/cell-config.json" \
    --timing "$CELL_DIR/timing.json" \
    --keda-summary "$CELL_DIR/keda-summary.json" \
    --gang-summary "$CELL_DIR/gang-summary.json" \
    --gang-pods "$CELL_DIR/gang-pods.json" \
    --argo-summary "$CELL_DIR/argo-summary.json" \
    --expected-node "$TARGET_NODE" \
    --message-count "$E07_MESSAGE_COUNT" \
    --gang-image "$E05_APP_IMAGE" \
    --argo-image "$E06_APP_IMAGE" \
    --output "$CELL_DIR/summary.json"
  CELL_SUMMARIES+=("$CELL_DIR/summary.json")
  log "${cell_id}: PASS ($(jq -r '.e2e_seconds' "$CELL_DIR/summary.json")s E2E)"
done <"$ARTIFACT_DIR/schedule.tsv"

kube get node "$TARGET_NODE" -o json >"$ARTIFACT_DIR/target-node-before-cleanup.json"
CLEANUP_STARTED_NS="$(now_ns)"
cleanup_resources || die "E07 Kubernetes cleanup failed"
log "workloads removed; waiting for the anchor-created Node to scale down"

scale_down_deadline=$((SECONDS + E07_SCALE_DOWN_TIMEOUT_SECONDS))
last_scale_log=$SECONDS
while kube get node "$TARGET_NODE" >/dev/null 2>&1; do
  (( SECONDS < scale_down_deadline )) || \
    die "target Node ${TARGET_NODE} did not scale down before timeout"
  if (( SECONDS - last_scale_log >= 60 )); then
    log "still waiting for Node scale-down: ${TARGET_NODE}"
    last_scale_log=$SECONDS
  fi
  sleep 10
done
TARGET_REMOVED_NS="$(now_ns)"
kube get nodes -o json >"$ARTIFACT_DIR/nodes-after-cleanup.json"
jq \
  --argjson cleanup_started_ns "$CLEANUP_STARTED_NS" \
  --argjson target_removed_ns "$TARGET_REMOVED_NS" \
  --argjson scale_down_seconds \
    "$((TARGET_REMOVED_NS - CLEANUP_STARTED_NS))e-9" \
  '. + {
    cleanup_started_ns:$cleanup_started_ns,
    target_removed_ns:$target_removed_ns,
    target_removed:true,
    scale_down_seconds:$scale_down_seconds
  }' "$ARTIFACT_DIR/provisioning-evidence.json" \
  >"$ARTIFACT_DIR/provisioning-evidence.tmp"
mv "$ARTIFACT_DIR/provisioning-evidence.tmp" \
  "$ARTIFACT_DIR/provisioning-evidence.json"

AGGREGATE_ARGS=()
for summary in "${CELL_SUMMARIES[@]}"; do
  AGGREGATE_ARGS+=(--cell "$summary")
done
python3 "$E07_HELPER" aggregate \
  --schedule "$ARTIFACT_DIR/schedule.tsv" \
  "${AGGREGATE_ARGS[@]}" \
  --provisioning-evidence "$ARTIFACT_DIR/provisioning-evidence.json" \
  --output "$ARTIFACT_DIR/summary.json" \
  --tsv "$ARTIFACT_DIR/summary.tsv" \
  --report "$ARTIFACT_DIR/report.md"

SUCCESS=true
log "E07 smoke completed: ${ARTIFACT_DIR}"
log "report: ${ARTIFACT_DIR}/report.md"
