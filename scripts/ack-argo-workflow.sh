#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${SCRIPT_DIR}/e06-argo-workflow.py"
APPLICATION_EXPORTER="${SCRIPT_DIR}/export-application-events.py"
CONFIG_FILE="${PROJECT_ROOT}/configs/argo-workflow.env"
CHECK_ONLY=false

usage() {
  cat <<'USAGE'
Usage: ack-argo-workflow.sh [--config PATH] [--check-only]

Runs the paired E06 Argo Workflow critical-path smoke: a serial A→B→C→D→E→F
baseline and a tuned A→[B,C]→D→E→F DAG.

--check-only validates local configuration, image provenance, Kubernetes
identity/RBAC, ACK Argo release/CRDs, controller health, fixed-node conditions,
and scheduler headroom. It creates nothing.
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
: "${CONFIRM_E06_EXECUTION:=no}"
: "${REQUIRE_CLEAN_GIT:=true}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${CLUSTER_ID:=}"
: "${ARTIFACT_ROOT:=artifacts}"
: "${ARGO_NAMESPACE:=argo}"
: "${ARGO_RELEASE:=ack-workflow}"
: "${ARGO_CHART_VERSION:=3.5.15}"
: "${ARGO_CONTROLLER_DEPLOYMENT:=ack-workflow-controller}"
: "${ARGO_CONTROLLER_VERSION_PREFIX:=v3.5.13}"
: "${E06_WORKFLOW_SERVICE_ACCOUNT:=e06-workflow}"
: "${E06_REPETITIONS:=1}"
: "${E06_RANDOM_SEED:=20260727}"
: "${E06_STAGE_DURATIONS:=a=2s,b=6s,c=4s,d=2s,e=1s,f=1s}"
: "${E06_SAMPLE_INTERVAL_SECONDS:=0.5}"
: "${E06_STAGE_TIMEOUT_SECONDS:=120}"
: "${E06_WORKFLOW_TIMEOUT_SECONDS:=600}"
: "${E06_SLO_SECONDS:=30}"
: "${E06_CLOCK_TOLERANCE_SECONDS:=2}"
: "${E06_IMAGE_METADATA_FILE:=dist/e06-image.env}"
: "${E06_APP_IMAGE:=}"
: "${E06_NODE_SELECTOR_KEY:=}"
: "${E06_NODE_SELECTOR_VALUE:=}"
: "${E06_TAINT_KEY:=}"
: "${E06_TAINT_VALUE:=}"
: "${E06_TAINT_EFFECT:=NoSchedule}"
: "${E06_MIN_FREE_CPU_MILLICORES:=300}"
: "${E06_MIN_FREE_MEMORY_MIB:=256}"
: "${E06_WORKER_CPU_REQUEST:=50m}"
: "${E06_WORKER_CPU_LIMIT:=100m}"
: "${E06_WORKER_MEMORY_REQUEST:=32Mi}"
: "${E06_WORKER_MEMORY_LIMIT:=64Mi}"
: "${CLEANUP_K8S_ON_SUCCESS:=true}"
: "${CLEANUP_K8S_ON_ERROR:=true}"

for command in kubectl helm jq python3 git date mktemp; do
  require_cmd "$command"
done
[[ -x "$HELPER" ]] || die "E06 helper must be executable: $HELPER"
[[ -x "$APPLICATION_EXPORTER" ]] || die "application exporter must be executable: $APPLICATION_EXPORTER"

[[ "$CONFIRM_KUBE_CONTEXT" == yes ]] || die "set CONFIRM_KUBE_CONTEXT=yes after verifying the target cluster"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
[[ -n "$EXPECTED_API_SERVER_SUBSTRING" ]] || die "EXPECTED_API_SERVER_SUBSTRING is required"
[[ -n "$CLUSTER_ID" ]] || die "CLUSTER_ID is required"
[[ -n "$ARGO_NAMESPACE" && -n "$ARGO_RELEASE" ]] || die "Argo release identity is required"
[[ -n "$ARGO_CHART_VERSION" && -n "$ARGO_CONTROLLER_VERSION_PREFIX" ]] || die "Argo version lock is required"
[[ "$E06_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die "E06_REPETITIONS must be positive"
[[ "$E06_RANDOM_SEED" =~ ^[0-9]+$ ]] || die "E06_RANDOM_SEED must be non-negative"
[[ "$E06_STAGE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E06_STAGE_TIMEOUT_SECONDS must be positive"
[[ "$E06_WORKFLOW_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E06_WORKFLOW_TIMEOUT_SECONDS must be positive"
[[ "$E06_MIN_FREE_CPU_MILLICORES" =~ ^[1-9][0-9]*$ ]] || die "E06_MIN_FREE_CPU_MILLICORES must be positive"
[[ "$E06_MIN_FREE_MEMORY_MIB" =~ ^[1-9][0-9]*$ ]] || die "E06_MIN_FREE_MEMORY_MIB must be positive"
[[ "$E06_APP_IMAGE" =~ @sha256:[0-9a-fA-F]{64}$ ]] || die "E06_APP_IMAGE must use an immutable digest"
[[ -n "$E06_NODE_SELECTOR_KEY" && -n "$E06_NODE_SELECTOR_VALUE" ]] || die "E06 fixed node selector is required"
if [[ -n "$E06_TAINT_KEY" || -n "$E06_TAINT_VALUE" ]]; then
  [[ -n "$E06_TAINT_KEY" && -n "$E06_TAINT_VALUE" ]] || die "E06 taint key/value must be set together"
  case "$E06_TAINT_EFFECT" in NoSchedule|PreferNoSchedule|NoExecute) ;; *) die "invalid E06_TAINT_EFFECT" ;; esac
fi

python3 - "$E06_SAMPLE_INTERVAL_SECONDS" "$E06_SLO_SECONDS" "$E06_CLOCK_TOLERANCE_SECONDS" <<'PY' >/dev/null || die "E06 numeric interval/SLO configuration is invalid"
import math, sys
values = [float(value) for value in sys.argv[1:]]
if any(not math.isfinite(value) or value <= 0 for value in values):
    raise SystemExit(1)
PY

# The helper validates the frozen stage set, durations, deterministic B>C path,
# and Kubernetes quantities without contacting the cluster.
python3 "$HELPER" workflow \
  --namespace validation \
  --name validation \
  --run-id validation \
  --cluster-id validation \
  --variant tuned \
  --image "$E06_APP_IMAGE" \
  --service-account "$E06_WORKFLOW_SERVICE_ACCOUNT" \
  --stage-durations "$E06_STAGE_DURATIONS" \
  --stage-timeout-seconds "$E06_STAGE_TIMEOUT_SECONDS" \
  --workflow-timeout-seconds "$E06_WORKFLOW_TIMEOUT_SECONDS" \
  --cpu-request "$E06_WORKER_CPU_REQUEST" \
  --cpu-limit "$E06_WORKER_CPU_LIMIT" \
  --memory-request "$E06_WORKER_MEMORY_REQUEST" \
  --memory-limit "$E06_WORKER_MEMORY_LIMIT" \
  --node-selector-key "$E06_NODE_SELECTOR_KEY" \
  --node-selector-value "$E06_NODE_SELECTOR_VALUE" \
  --taint-key "$E06_TAINT_KEY" \
  --taint-value "$E06_TAINT_VALUE" \
  --taint-effect "$E06_TAINT_EFFECT" >/dev/null || die "E06 manifest configuration is invalid"

is_true "$REQUIRE_CLEAN_GIT" || die "E06 requires REQUIRE_CLEAN_GIT=true"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die "E06 requires a clean Git worktree"

if [[ "$E06_IMAGE_METADATA_FILE" = /* ]]; then
  IMAGE_METADATA_PATH="$E06_IMAGE_METADATA_FILE"
else
  IMAGE_METADATA_PATH="${PROJECT_ROOT}/${E06_IMAGE_METADATA_FILE}"
fi
[[ -f "$IMAGE_METADATA_PATH" ]] || die "E06 image metadata not found: $IMAGE_METADATA_PATH"

metadata_value() {
  local key="$1" count value
  count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$IMAGE_METADATA_PATH")"
  [[ "$count" == 1 ]] || die "image metadata must contain exactly one ${key}"
  value="$(awk -v prefix="${key}=" 'index($0,prefix)==1 {sub(prefix,""); print; exit}' "$IMAGE_METADATA_PATH")"
  [[ -n "$value" ]] || die "image metadata value is empty: ${key}"
  printf '%s' "$value"
}

IMAGE_BUILD_COMMIT="$(metadata_value E06_APP_IMAGE_BUILD_COMMIT)"
IMAGE_SOURCE_STATE="$(metadata_value E06_APP_IMAGE_SOURCE_STATE)"
METADATA_APP_IMAGE="$(metadata_value E06_APP_IMAGE)"
[[ "$IMAGE_BUILD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "E06 image build commit is invalid"
[[ "$IMAGE_SOURCE_STATE" == clean ]] || die "E06 image must be built from a clean worktree"
[[ "$METADATA_APP_IMAGE" == "$E06_APP_IMAGE" ]] || die "E06_APP_IMAGE does not match image metadata"
git cat-file -e "${IMAGE_BUILD_COMMIT}^{commit}" 2>/dev/null || die "E06 image build commit is unavailable"
git merge-base --is-ancestor "$IMAGE_BUILD_COMMIT" HEAD || die "E06 image build commit is not an ancestor of HEAD"
IMAGE_BUILD_INPUTS=(
  examples/e06-argo-workflow/Dockerfile
  examples/e06-argo-workflow/Dockerfile.dockerignore
  cmd/e06-stage-worker
  internal/buildinfo
  internal/event
  internal/transport
  sdk/go
  go.mod
  go.sum
)
git diff --quiet "$IMAGE_BUILD_COMMIT"..HEAD -- "${IMAGE_BUILD_INPUTS[@]}" || \
  die "E06 image inputs changed since its build; rebuild and push the image"

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
kube get --raw='/readyz' | grep -qx ok || die "Kubernetes API server is not ready"

RELEASE_JSON="$(helm_cmd list -n "$ARGO_NAMESPACE" -o json | jq -c --arg release "$ARGO_RELEASE" '.[] | select(.name == $release)')"
[[ -n "$RELEASE_JSON" ]] || die "Helm release ${ARGO_NAMESPACE}/${ARGO_RELEASE} not found"
[[ "$(jq -r '.status' <<<"$RELEASE_JSON")" == deployed ]] || die "Argo release is not deployed"
EXPECTED_CHART="ack-workflow-${ARGO_CHART_VERSION}"
[[ "$(jq -r '.chart' <<<"$RELEASE_JSON")" == "$EXPECTED_CHART" ]] || \
  die "expected chart ${EXPECTED_CHART}, got $(jq -r '.chart' <<<"$RELEASE_JSON")"

for resource in workflows.argoproj.io workflowtaskresults.argoproj.io; do
  kube get crd "$resource" >/dev/null 2>&1 || die "required CRD is missing: ${resource}"
  [[ "$(kube get crd "$resource" -o json | jq -r '[.status.conditions[] | select(.type=="Established" and .status=="True")] | length')" == 1 ]] || \
    die "CRD is not Established: ${resource}"
done
kube -n "$ARGO_NAMESPACE" get deployment "$ARGO_CONTROLLER_DEPLOYMENT" >/dev/null 2>&1 || \
  die "Argo controller deployment is missing"
CONTROLLER_JSON="$(kube -n "$ARGO_NAMESPACE" get deployment "$ARGO_CONTROLLER_DEPLOYMENT" -o json)"
CONTROLLER_DESIRED="$(jq -r '.spec.replicas' <<<"$CONTROLLER_JSON")"
CONTROLLER_AVAILABLE="$(jq -r '.status.availableReplicas // 0' <<<"$CONTROLLER_JSON")"
[[ "$CONTROLLER_AVAILABLE" == "$CONTROLLER_DESIRED" ]] || die "Argo controller is not fully available"
CONTROLLER_IMAGE="$(jq -r '.spec.template.spec.containers[] | select(.name=="workflow-controller") | .image' <<<"$CONTROLLER_JSON")"
[[ "$CONTROLLER_IMAGE" == *":${ARGO_CONTROLLER_VERSION_PREFIX}"* || "$CONTROLLER_IMAGE" == *":${ARGO_CONTROLLER_VERSION_PREFIX}-"* ]] || \
  die "Argo controller image ${CONTROLLER_IMAGE} does not match ${ARGO_CONTROLLER_VERSION_PREFIX}"
CONTROLLER_SA="$(jq -r '.spec.template.spec.serviceAccountName' <<<"$CONTROLLER_JSON")"
[[ -n "$CONTROLLER_SA" && "$CONTROLLER_SA" != null ]] || die "Argo controller has no ServiceAccount"

for check in \
  "list workflows.argoproj.io --all-namespaces" \
  "list pods --all-namespaces" \
  "get nodes"; do
  # shellcheck disable=SC2086
  [[ "$(kube auth can-i $check)" == yes ]] || die "kubectl identity cannot ${check}"
done
[[ "$(kube auth can-i create pods --as="system:serviceaccount:${ARGO_NAMESPACE}:${CONTROLLER_SA}" -n default)" == yes ]] || \
  die "Argo controller ServiceAccount cannot create Pods outside its install namespace"

NODES_JSON="$(kube get nodes -l "${E06_NODE_SELECTOR_KEY}=${E06_NODE_SELECTOR_VALUE}" -o json)"
[[ "$(jq '.items | length' <<<"$NODES_JSON")" == 1 ]] || die "E06 node selector must match exactly one node"
NODE_JSON="$(jq -c '.items[0]' <<<"$NODES_JSON")"
TARGET_NODE="$(jq -r '.metadata.name' <<<"$NODE_JSON")"
[[ "$(jq -r '[.status.conditions[] | select(.type=="Ready" and .status=="True")] | length' <<<"$NODE_JSON")" == 1 ]] || \
  die "target node is not Ready"
for condition in MemoryPressure DiskPressure PIDPressure; do
  [[ "$(jq -r --arg condition "$condition" '[.status.conditions[] | select(.type==$condition and .status=="True")] | length' <<<"$NODE_JSON")" == 0 ]] || \
    die "target node reports ${condition}"
done
[[ "$(jq -r '[.status.conditions[] | select(.type=="NTPProblem" and .status=="True")] | length' <<<"$NODE_JSON")" == 0 ]] || \
  die "target node reports NTPProblem"
[[ "$(jq -r '.metadata.labels.type // ""' <<<"$NODE_JSON")" != virtual-kubelet ]] || die "E06 cannot run on virtual-kubelet"
BLOCKING_TAINTS="$(jq -c \
  --arg key "$E06_TAINT_KEY" --arg value "$E06_TAINT_VALUE" --arg effect "$E06_TAINT_EFFECT" \
  '[.spec.taints[]? | select(.effect=="NoSchedule" or .effect=="NoExecute") | select(.key != $key or (.value // "") != $value or .effect != $effect)]' \
  <<<"$NODE_JSON")"
[[ "$(jq 'length' <<<"$BLOCKING_TAINTS")" == 0 ]] || die "target node has an untolerated blocking taint: ${BLOCKING_TAINTS}"

PODS_JSON="$(kube get pods -A -o json)"
PREFLIGHT_DIR="$(mktemp -d)"
printf '%s\n' "$NODE_JSON" >"${PREFLIGHT_DIR}/node.json"
printf '%s\n' "$PODS_JSON" >"${PREFLIGHT_DIR}/pods.json"
python3 "$HELPER" node-headroom \
  --node "${PREFLIGHT_DIR}/node.json" \
  --pods "${PREFLIGHT_DIR}/pods.json" \
  --output "${PREFLIGHT_DIR}/headroom.json"
AVAILABLE_CPU="$(jq -r '.available_cpu_millicores' "${PREFLIGHT_DIR}/headroom.json")"
AVAILABLE_MEMORY_BYTES="$(jq -r '.available_memory_bytes' "${PREFLIGHT_DIR}/headroom.json")"
MIN_MEMORY_BYTES=$((E06_MIN_FREE_MEMORY_MIB * 1024 * 1024))
(( AVAILABLE_CPU >= E06_MIN_FREE_CPU_MILLICORES )) || die "target node has only ${AVAILABLE_CPU}m free requested CPU"
(( AVAILABLE_MEMORY_BYTES >= MIN_MEMORY_BYTES )) || die "target node has less than ${E06_MIN_FREE_MEMORY_MIB}Mi free requested memory"
rm -rf "$PREFLIGHT_DIR"

[[ "$(kube get lease.coordination.k8s.io hooke-e06-argo-lock -n kube-system --ignore-not-found -o name)" == "" ]] || \
  die "the E06 cluster lock already exists"
log "preflight passed: context=${EFFECTIVE_CONTEXT}, server=${API_SERVER}, chart=${EXPECTED_CHART}, controller=${ARGO_CONTROLLER_VERSION_PREFIX}"
log "fixed node ${TARGET_NODE}: available requested headroom cpu=${AVAILABLE_CPU}m memory=$((AVAILABLE_MEMORY_BYTES / 1024 / 1024))Mi"
if [[ "$(jq -r '.metadata.labels[\"goatscaler.io/managed\"] // \"\"' <<<"$NODE_JSON")" == true ]]; then
  warn "target node is GOATScaler-managed; the exact node is rechecked before every cell"
fi
if [[ "$CHECK_ONLY" == true ]]; then
  exit 0
fi

[[ "$CONFIRM_E06_EXECUTION" == yes ]] || die "set CONFIRM_E06_EXECUTION=yes to create E06 resources"
for check in \
  "create namespaces" \
  "delete namespaces" \
  "create leases.coordination.k8s.io -n kube-system" \
  "delete leases.coordination.k8s.io -n kube-system" \
  "create roles.rbac.authorization.k8s.io -n default" \
  "create rolebindings.rbac.authorization.k8s.io -n default" \
  "create workflows.argoproj.io -n default" \
  "delete workflows.argoproj.io -n default" \
  "create pods -n default" \
  "delete pods -n default"; do
  # shellcheck disable=SC2086
  [[ "$(kube auth can-i $check)" == yes ]] || die "kubectl identity cannot ${check}"
done

RUN_SUFFIX="$(date -u +'%Y%m%d%H%M%S')-$(printf '%04x' "$RANDOM")"
RUN_ID="e06-${RUN_SUFFIX}"
NAMESPACE="hooke-${RUN_ID}"
LOCK_NAME="hooke-e06-argo-lock"
ARTIFACT_DIR="${ARTIFACT_ROOT}/e06-argo-workflow-smoke-${RUN_SUFFIX}"
mkdir -p "$ARTIFACT_DIR"
chmod 700 "$ARTIFACT_DIR"

LOCK_CREATED=false
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
    if [[ "$NAMESPACE_CREATED" == true ]]; then
      kube delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null || true
    fi
    if [[ "$LOCK_CREATED" == true ]]; then
      kube -n kube-system delete lease.coordination.k8s.io "$LOCK_NAME" --ignore-not-found --wait=true >/dev/null || true
    fi
  else
    warn "retaining E06 Kubernetes resources for run ${RUN_ID}"
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
  --arg image "$E06_APP_IMAGE" \
  --arg chart "$EXPECTED_CHART" \
  --arg controller_image "$CONTROLLER_IMAGE" \
  --arg node "$TARGET_NODE" \
  '{context:$context,api_server:$api_server,cluster_id:$cluster_id,run_id:$run_id,namespace:$namespace,image:$image,chart:$chart,controller_image:$controller_image,fixed_node:$node,scope:"one-paired-block-smoke"}' \
  >"${ARTIFACT_DIR}/run-metadata.json"
cp "$CONFIG_FILE" "${ARTIFACT_DIR}/config.env"
cp "$IMAGE_METADATA_PATH" "${ARTIFACT_DIR}/image-metadata.env"
printf '%s\n' "$RELEASE_JSON" >"${ARTIFACT_DIR}/argo-helm-release.json"
printf '%s\n' "$NODE_JSON" >"${ARTIFACT_DIR}/target-node-before.json"
printf '%s\n' "$PODS_JSON" >"${ARTIFACT_DIR}/pods-before.json"
chmod 600 "${ARTIFACT_DIR}/config.env" "${ARTIFACT_DIR}/image-metadata.env"

jq -n \
  --arg name "$LOCK_NAME" \
  --arg holder "$RUN_ID" \
  '{apiVersion:"coordination.k8s.io/v1",kind:"Lease",metadata:{name:$name,namespace:"kube-system"},spec:{holderIdentity:$holder,leaseDurationSeconds:7200}}' \
  | kube create -f - >/dev/null
LOCK_CREATED=true

kube create namespace "$NAMESPACE" >/dev/null
NAMESPACE_CREATED=true
kube annotate namespace "$NAMESPACE" "hooke.io/run-id=${RUN_ID}" --overwrite >/dev/null
kube label namespace "$NAMESPACE" "app.kubernetes.io/managed-by=hooke-e06-runner" --overwrite >/dev/null
python3 "$HELPER" rbac \
  --namespace "$NAMESPACE" \
  --service-account "$E06_WORKFLOW_SERVICE_ACCOUNT" \
  >"${ARTIFACT_DIR}/executor-rbac.json"
kube create -f "${ARTIFACT_DIR}/executor-rbac.json" >/dev/null
[[ "$(kube auth can-i create workflowtaskresults.argoproj.io --as="system:serviceaccount:${NAMESPACE}:${E06_WORKFLOW_SERVICE_ACCOUNT}" -n "$NAMESPACE")" == yes ]] || \
  die "E06 executor ServiceAccount cannot create WorkflowTaskResults"
[[ "$(kube auth can-i patch workflowtaskresults.argoproj.io --as="system:serviceaccount:${NAMESPACE}:${E06_WORKFLOW_SERVICE_ACCOUNT}" -n "$NAMESPACE")" == yes ]] || \
  die "E06 executor ServiceAccount cannot patch WorkflowTaskResults"

WARMUP_NAME="e06-image-warmup"
python3 "$HELPER" warmup \
  --namespace "$NAMESPACE" \
  --name "$WARMUP_NAME" \
  --run-id "$RUN_ID" \
  --cluster-id "$CLUSTER_ID" \
  --image "$E06_APP_IMAGE" \
  --cpu-request "$E06_WORKER_CPU_REQUEST" \
  --cpu-limit "$E06_WORKER_CPU_LIMIT" \
  --memory-request "$E06_WORKER_MEMORY_REQUEST" \
  --memory-limit "$E06_WORKER_MEMORY_LIMIT" \
  --node-selector-key "$E06_NODE_SELECTOR_KEY" \
  --node-selector-value "$E06_NODE_SELECTOR_VALUE" \
  --taint-key "$E06_TAINT_KEY" \
  --taint-value "$E06_TAINT_VALUE" \
  --taint-effect "$E06_TAINT_EFFECT" \
  >"${ARTIFACT_DIR}/warmup-manifest.json"
kube create -f "${ARTIFACT_DIR}/warmup-manifest.json" >/dev/null
warmup_deadline=$((SECONDS + 300))
while (( SECONDS < warmup_deadline )); do
  warmup_phase="$(kube -n "$NAMESPACE" get pod "$WARMUP_NAME" -o jsonpath='{.status.phase}')"
  case "$warmup_phase" in
    Succeeded) break ;;
    Failed) die "E06 image warmup Pod failed" ;;
  esac
  sleep 1
done
[[ "$warmup_phase" == Succeeded ]] || die "E06 image warmup Pod timed out"
kube -n "$NAMESPACE" get pod "$WARMUP_NAME" -o json >"${ARTIFACT_DIR}/warmup-pod.json"
kube -n "$NAMESPACE" logs "$WARMUP_NAME" -c main >"${ARTIFACT_DIR}/warmup.log"
WARMUP_IMAGE_ID="$(jq -r '.status.containerStatuses[] | select(.name=="main") | .imageID' "${ARTIFACT_DIR}/warmup-pod.json")"
EXPECTED_IMAGE_DIGEST="${E06_APP_IMAGE##*@}"
[[ "${WARMUP_IMAGE_ID,,}" == *"${EXPECTED_IMAGE_DIGEST,,}"* ]] || die "warmup Pod did not run the configured immutable image"
kube -n "$NAMESPACE" delete pod "$WARMUP_NAME" --wait=true >/dev/null

python3 "$HELPER" schedule \
  --repetitions "$E06_REPETITIONS" \
  --seed "$E06_RANDOM_SEED" \
  --output "${ARTIFACT_DIR}/schedule.tsv"

sample_cell() {
  local namespace="$1" workflow="$2" stop_file="$3" workflow_output="$4" pod_output="$5"
  while [[ ! -f "$stop_file" ]]; do
    local observed
    observed="$(date +%s%N)"
    kube -n "$namespace" get workflow.argoproj.io "$workflow" -o json \
      | jq -c --argjson observed_time_ns "$observed" '. + {observed_time_ns:$observed_time_ns}' \
      >>"$workflow_output" || true
    kube -n "$namespace" get pods -l "workflows.argoproj.io/workflow=${workflow}" -o json \
      | jq -c --argjson observed_time_ns "$observed" '. + {observed_time_ns:$observed_time_ns}' \
      >>"$pod_output" || true
    sleep "$E06_SAMPLE_INTERVAL_SECONDS"
  done
}

SUMMARY_FILES=()
while IFS=$'\t' read -r sequence block cell_id variant; do
  [[ "$cell_id" == "$variant" ]] || die "E06 schedule semantics drifted"
  printf -v ordinal '%03d' "$sequence"
  WORKFLOW_NAME="e06-${ordinal}-${variant}"
  CELL_DIR="${ARTIFACT_DIR}/cells/${ordinal}-${variant}"
  LOGS_DIR="${CELL_DIR}/logs"
  mkdir -p "$LOGS_DIR"
  chmod 700 "$CELL_DIR" "$LOGS_DIR"
  log "cell ${sequence}: block=${block}, variant=${variant}"

  CURRENT_NODE_JSON="$(kube get node "$TARGET_NODE" -o json 2>/dev/null || true)"
  [[ -n "$CURRENT_NODE_JSON" ]] || die "fixed node ${TARGET_NODE} disappeared before cell ${sequence}"
  [[ "$(jq -r '[.status.conditions[] | select(.type=="Ready" and .status=="True")] | length' <<<"$CURRENT_NODE_JSON")" == 1 ]] || \
    die "fixed node ${TARGET_NODE} is not Ready before cell ${sequence}"

  python3 "$HELPER" workflow \
    --namespace "$NAMESPACE" \
    --name "$WORKFLOW_NAME" \
    --run-id "$RUN_ID" \
    --cluster-id "$CLUSTER_ID" \
    --variant "$variant" \
    --image "$E06_APP_IMAGE" \
    --service-account "$E06_WORKFLOW_SERVICE_ACCOUNT" \
    --stage-durations "$E06_STAGE_DURATIONS" \
    --stage-timeout-seconds "$E06_STAGE_TIMEOUT_SECONDS" \
    --workflow-timeout-seconds "$E06_WORKFLOW_TIMEOUT_SECONDS" \
    --cpu-request "$E06_WORKER_CPU_REQUEST" \
    --cpu-limit "$E06_WORKER_CPU_LIMIT" \
    --memory-request "$E06_WORKER_MEMORY_REQUEST" \
    --memory-limit "$E06_WORKER_MEMORY_LIMIT" \
    --node-selector-key "$E06_NODE_SELECTOR_KEY" \
    --node-selector-value "$E06_NODE_SELECTOR_VALUE" \
    --taint-key "$E06_TAINT_KEY" \
    --taint-value "$E06_TAINT_VALUE" \
    --taint-effect "$E06_TAINT_EFFECT" \
    >"${CELL_DIR}/manifest.json"
  START_NS="$(date +%s%N)"
  kube create -f "${CELL_DIR}/manifest.json" >/dev/null

  CURRENT_STOP_FILE="${CELL_DIR}/sampler.stop"
  sample_cell \
    "$NAMESPACE" "$WORKFLOW_NAME" "$CURRENT_STOP_FILE" \
    "${CELL_DIR}/workflow-snapshots.ndjson" \
    "${CELL_DIR}/pod-snapshots.ndjson" &
  SAMPLER_PID=$!

  workflow_deadline=$((SECONDS + E06_WORKFLOW_TIMEOUT_SECONDS))
  workflow_phase=""
  while (( SECONDS < workflow_deadline )); do
    workflow_phase="$(kube -n "$NAMESPACE" get workflow.argoproj.io "$WORKFLOW_NAME" -o jsonpath='{.status.phase}')"
    case "$workflow_phase" in
      Succeeded) break ;;
      Failed|Error)
        : >"$CURRENT_STOP_FILE"
        wait "$SAMPLER_PID" || true
        kube -n "$NAMESPACE" get workflow.argoproj.io "$WORKFLOW_NAME" -o yaml >"${CELL_DIR}/workflow-failed.yaml" || true
        kube -n "$NAMESPACE" get pods -l "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" -o wide >"${CELL_DIR}/pods-failed.txt" || true
        die "E06 Workflow ${WORKFLOW_NAME} ended in ${workflow_phase}"
        ;;
    esac
    sleep 1
  done
  : >"$CURRENT_STOP_FILE"
  wait "$SAMPLER_PID"
  CURRENT_STOP_FILE=""
  [[ "$workflow_phase" == Succeeded ]] || die "E06 Workflow ${WORKFLOW_NAME} timed out"

  kube -n "$NAMESPACE" get workflow.argoproj.io "$WORKFLOW_NAME" -o json >"${CELL_DIR}/workflow.json"
  kube -n "$NAMESPACE" get pods -l "workflows.argoproj.io/workflow=${WORKFLOW_NAME}" -o json >"${CELL_DIR}/pods.json"
  while IFS= read -r pod_name; do
    kube -n "$NAMESPACE" logs "$pod_name" -c main >"${LOGS_DIR}/${pod_name}-main.log"
  done < <(jq -r '.items[].metadata.name' "${CELL_DIR}/pods.json")
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
    --workflow "${CELL_DIR}/workflow.json" \
    --pods "${CELL_DIR}/pods.json" \
    --application-events "${CELL_DIR}/application-events.ndjson" \
    --variant "$variant" \
    --sequence "$sequence" \
    --block "$block" \
    --slo-seconds "$E06_SLO_SECONDS" \
    --clock-tolerance-seconds "$E06_CLOCK_TOLERANCE_SECONDS" \
    --expected-image "$E06_APP_IMAGE" \
    --expected-node "$TARGET_NODE" \
    --output "${CELL_DIR}/summary.json"
  SUMMARY_FILES+=("${CELL_DIR}/summary.json")

  kube -n "$NAMESPACE" delete workflow.argoproj.io "$WORKFLOW_NAME" --wait=true >/dev/null
done < <(tail -n +2 "${ARTIFACT_DIR}/schedule.tsv")

AGGREGATE_ARGS=()
for summary_file in "${SUMMARY_FILES[@]}"; do
  AGGREGATE_ARGS+=(--summary "$summary_file")
done
python3 "$HELPER" aggregate \
  "${AGGREGATE_ARGS[@]}" \
  --output "${ARTIFACT_DIR}/summary.json" \
  --tsv "${ARTIFACT_DIR}/summary.tsv" \
  --report "${ARTIFACT_DIR}/report.md"

kube get node "$TARGET_NODE" -o json >"${ARTIFACT_DIR}/target-node-after.json"
kube get nodes -o wide >"${ARTIFACT_DIR}/nodes-after.txt"
log "E06 smoke completed: ${ARTIFACT_DIR}"
log "report: ${ARTIFACT_DIR}/report.md"
