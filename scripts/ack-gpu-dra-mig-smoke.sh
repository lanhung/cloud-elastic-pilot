#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${SCRIPT_DIR}/e09-gpu-dra-mig.py"
APPLICATION_EXPORTER="${SCRIPT_DIR}/export-application-events.py"
CHART="${PROJECT_ROOT}/deploy/helm/hooke"
CONFIG_FILE="${PROJECT_ROOT}/configs/gpu-dra-mig.env"
CHECK_ONLY=false

usage() {
  cat <<'USAGE'
Usage: ack-gpu-dra-mig-smoke.sh [--config PATH] [--check-only]

Runs the single-A100 E09 functional smoke:
  dedicated A100 -> real MIG Manager reshape -> A100 DRA plugin restart
  -> resource.k8s.io/v1 ResourceClaim -> exact Pod UID -> real CUDA success

--check-only is strictly read-only. Execution requires both
CONFIRM_E09_EXECUTION=yes and CONFIRM_MIG_RECONFIGURATION=yes. The runner
restores the original MIG profile on every exit by default.
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

[[ -f "$CONFIG_FILE" ]] || die "config not found: $CONFIG_FILE"
# shellcheck disable=SC1090
set -a
source "$CONFIG_FILE"
set +a

: "${CONFIRM_KUBE_CONTEXT:=no}"
: "${CONFIRM_E09_EXECUTION:=no}"
: "${CONFIRM_MIG_RECONFIGURATION:=no}"
: "${REQUIRE_CLEAN_GIT:=true}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${CLUSTER_ID:=}"
: "${E09_EXPECTED_BRANCH:=experiment/11-gpu-dra-mig-smoke}"
: "${E09_TARGET_NODE:=}"
: "${E09_GPU_PRODUCT_REGEX:=\\bA100\\b}"
: "${E09_MIG_SOURCE_PROFILE:=all-disabled}"
: "${E09_MIG_TARGET_PROFILE:=}"
: "${E09_DEVICE_CLASS:=mig.nvidia.com}"
: "${E09_DRA_DRIVER:=gpu.nvidia.com}"
: "${E09_IMAGE_METADATA_FILE:=dist/e09-images.env}"
: "${E09_STACK_IMAGE:=}"
: "${E09_PROBE_IMAGE:=}"
: "${HOOKE_MYSQL_DSN:=}"
: "${E09_SYSTEM_NAMESPACE:=hooke-e09-system}"
: "${E09_WORKLOAD_NAMESPACE:=hooke-e09-smoke}"
: "${E09_HELM_RELEASE:=hooke-e09}"
: "${E09_MYSQL_SECRET:=hooke-e09-mysql}"
: "${E09_LOCK_NAMESPACE:=kube-system}"
: "${E09_LOCK_NAME:=hooke-e09-gpu-dra-mig}"
: "${E09_CONTROL_NODE_SELECTOR_KEY:=hooke.io/pool}"
: "${E09_CONTROL_NODE_SELECTOR_VALUE:=fixed-cpu}"
: "${E09_GPU_TAINT_KEY:=nvidia.com/gpu}"
: "${E09_GPU_TAINT_VALUE:=}"
: "${E09_GPU_TAINT_EFFECT:=NoSchedule}"
: "${E09_GPU_OPERATOR_NAMESPACE:=gpu-operator}"
: "${E09_DRIVER_MODE:=operator}"
: "${E09_DRIVER_POD_SELECTOR:=app=nvidia-driver-daemonset}"
: "${E09_DRIVER_CONTAINER:=nvidia-driver-ctr}"
: "${E09_MIG_MANAGER_NAMESPACE:=$E09_GPU_OPERATOR_NAMESPACE}"
: "${E09_MIG_MANAGER_POD_SELECTOR:=app=nvidia-mig-manager}"
: "${E09_MIG_MANAGER_CONTAINER:=nvidia-mig-manager}"
: "${E09_DRA_NAMESPACE:=nvidia-dra-driver-gpu}"
: "${E09_DRA_POD_SELECTOR:=dra-driver-nvidia-gpu-component=kubelet-plugin}"
: "${E09_DRA_CONTAINER:=gpus}"
: "${E09_DRA_NODE_LABEL_KEY:=nvidia.com/dra-kubelet-plugin}"
: "${E09_DRA_NODE_LABEL_VALUE:=true}"
: "${E09_DEVICE_PLUGIN_NAMESPACE:=$E09_GPU_OPERATOR_NAMESPACE}"
: "${E09_DEVICE_PLUGIN_POD_SELECTOR:=app=nvidia-device-plugin-daemonset}"
: "${E09_DCGM_METRICS_API_PATH:=}"
: "${E09_CONTROLLER_SETTLE_SECONDS:=5}"
: "${E09_MIG_TIMEOUT_SECONDS:=1200}"
: "${E09_DRA_RESTART_TIMEOUT_SECONDS:=300}"
: "${E09_POD_TIMEOUT_SECONDS:=600}"
: "${E09_CLAIM_SETTLE_SECONDS:=5}"
: "${E09_RESTORE_MIG_PROFILE:=true}"
: "${ARTIFACT_ROOT:=artifacts}"
: "${CLEANUP_K8S_ON_SUCCESS:=true}"
: "${CLEANUP_K8S_ON_ERROR:=true}"
export -n HOOKE_MYSQL_DSN 2>/dev/null || true

for command in kubectl helm jq python3 git date mktemp grep; do
  require_cmd "$command"
done
HELM_UPGRADE_HELP="$(helm upgrade --help)"
[[ "$HELM_UPGRADE_HELP" == *"--rollback-on-failure"* ]] || \
  die "E09 requires Helm with --rollback-on-failure support (Helm 4)"
unset HELM_UPGRADE_HELP
[[ -x "$HELPER" ]] || die "helper must be executable: $HELPER"
[[ -x "$APPLICATION_EXPORTER" ]] || \
  die "application exporter must be executable: $APPLICATION_EXPORTER"
[[ -d "$CHART" ]] || die "Hooke Helm chart not found: $CHART"
[[ "$CONFIRM_KUBE_CONTEXT" == yes ]] || \
  die "set CONFIRM_KUBE_CONTEXT=yes after verifying the ACK target"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
[[ -n "$KUBE_CONTEXT" && -n "$EXPECTED_API_SERVER_SUBSTRING" ]] || \
  die "KUBE_CONTEXT and EXPECTED_API_SERVER_SUBSTRING are required"
[[ -n "$CLUSTER_ID" && -n "$E09_TARGET_NODE" ]] || \
  die "CLUSTER_ID and E09_TARGET_NODE are required"
[[ -n "$E09_MIG_SOURCE_PROFILE" && -n "$E09_MIG_TARGET_PROFILE" ]] || \
  die "both source and target MIG profiles are required"
[[ "$E09_MIG_SOURCE_PROFILE" != "$E09_MIG_TARGET_PROFILE" ]] || \
  die "source and target MIG profiles must differ to exercise a real reshape"
[[ -n "$E09_CONTROL_NODE_SELECTOR_KEY" && -n "$E09_CONTROL_NODE_SELECTOR_VALUE" ]] || \
  die "a fixed CPU node selector is required for the Hooke control plane"
[[ -n "$E09_DRA_NODE_LABEL_KEY" && -n "$E09_DRA_NODE_LABEL_VALUE" ]] || \
  die "the NVIDIA DRA node label key and value are required"
case "$E09_DRIVER_MODE" in
  operator|preinstalled) ;;
  *) die "E09_DRIVER_MODE must be operator or preinstalled" ;;
esac
[[ "$E09_STACK_IMAGE" =~ ^[^[:space:]@]+@sha256:[0-9a-fA-F]{64}$ ]] || \
  die "E09_STACK_IMAGE must be an immutable repository digest"
[[ "$E09_PROBE_IMAGE" =~ ^[^[:space:]@]+@sha256:[0-9a-fA-F]{64}$ ]] || \
  die "E09_PROBE_IMAGE must be an immutable repository digest"
[[ "$HOOKE_MYSQL_DSN" == *"@tcp("*":3306)/"* ]] || \
  die "HOOKE_MYSQL_DSN must be an ACK-reachable Go MySQL TCP DSN on port 3306"
for value in \
  "$E09_CONTROLLER_SETTLE_SECONDS" \
  "$E09_MIG_TIMEOUT_SECONDS" \
  "$E09_DRA_RESTART_TIMEOUT_SECONDS" \
  "$E09_POD_TIMEOUT_SECONDS" \
  "$E09_CLAIM_SETTLE_SECONDS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "E09 timeouts must be positive integers"
done

kube() {
  kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" "$@"
}

helm_ack() {
  helm --kubeconfig "$KUBECONFIG_PATH" --kube-context "$KUBE_CONTEXT" "$@"
}

CURRENT_CONTEXT="$(kube config current-context)"
[[ "$CURRENT_CONTEXT" == "$KUBE_CONTEXT" ]] || \
  die "current context ${CURRENT_CONTEXT} does not match ${KUBE_CONTEXT}"
API_SERVER="$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$API_SERVER" == *"$EXPECTED_API_SERVER_SUBSTRING"* ]] || \
  die "API server ${API_SERVER} does not contain the expected ACK identity"

PREFLIGHT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hooke-e09-preflight.XXXXXX")"
cleanup_preflight() {
  if [[ "$PREFLIGHT_DIR" == "${TMPDIR:-/tmp}"/hooke-e09-preflight.* ]]; then
    rm -rf -- "$PREFLIGHT_DIR"
  fi
}
trap cleanup_preflight EXIT

helm version --short >"$PREFLIGHT_DIR/helm-version.txt"
kube version -o json --request-timeout=15s >"$PREFLIGHT_DIR/kubernetes-version.json"
SERVER_MAJOR="$(jq -er '.serverVersion.major | sub("[^0-9].*$"; "") | tonumber' "$PREFLIGHT_DIR/kubernetes-version.json")" || \
  die "could not parse the Kubernetes server major version"
SERVER_MINOR="$(jq -er '.serverVersion.minor | sub("[^0-9].*$"; "") | tonumber' "$PREFLIGHT_DIR/kubernetes-version.json")" || \
  die "could not parse the Kubernetes server minor version"
SERVER_PATCH="$(jq -er '
  .serverVersion.gitVersion
  | capture("^v[0-9]+\\.[0-9]+\\.(?<patch>[0-9]+)")
  | .patch
  | tonumber
' "$PREFLIGHT_DIR/kubernetes-version.json")" || \
  die "could not parse the Kubernetes server patch version"
SERVER_VERSION="v${SERVER_MAJOR}.${SERVER_MINOR}.${SERVER_PATCH}"
(( SERVER_MAJOR > 1 || (SERVER_MAJOR == 1 && (SERVER_MINOR > 34 || (SERVER_MINOR == 34 && SERVER_PATCH >= 2))) )) || \
  die "E09 requires Kubernetes >=1.34.2 for the NVIDIA DRA v0.4.1 contract"
kube get --raw /apis/resource.k8s.io/v1 >"$PREFLIGHT_DIR/resource-api.json"
jq -e '
  [.resources[].name] as $names
  | all(["resourceclaims","resourceslices","deviceclasses"][];
      . as $name | $names | index($name) != null)
' "$PREFLIGHT_DIR/resource-api.json" >/dev/null || \
  die "resource.k8s.io/v1 does not expose all required DRA resources"

CURRENT_BRANCH="$(git branch --show-current)"
[[ "$CURRENT_BRANCH" == "$E09_EXPECTED_BRANCH" ]] || \
  die "current branch ${CURRENT_BRANCH} does not match ${E09_EXPECTED_BRANCH}"
if [[ "$REQUIRE_CLEAN_GIT" == true && -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  die "Git worktree must be clean so images, runner, and evidence share one commit"
fi
GIT_COMMIT="$(git rev-parse HEAD)"
[[ -f "$E09_IMAGE_METADATA_FILE" ]] || \
  die "E09 image metadata not found: $E09_IMAGE_METADATA_FILE"
CONFIGURED_STACK_IMAGE="$E09_STACK_IMAGE"
CONFIGURED_PROBE_IMAGE="$E09_PROBE_IMAGE"
# shellcheck disable=SC1090
source "$E09_IMAGE_METADATA_FILE"
[[ "${E09_IMAGE_SOURCE_STATE:-}" == clean ]] || \
  die "E09 image metadata was not produced from a clean worktree"
[[ "${E09_IMAGE_BUILD_COMMIT:-}" == "$GIT_COMMIT" ]] || \
  die "E09 image commit does not match current HEAD"
[[ "${E09_STACK_IMAGE:-}" == "$CONFIGURED_STACK_IMAGE" ]] || \
  die "configured E09_STACK_IMAGE does not match image metadata"
[[ "${E09_PROBE_IMAGE:-}" == "$CONFIGURED_PROBE_IMAGE" ]] || \
  die "configured E09_PROBE_IMAGE does not match image metadata"
[[ "${E09_IMAGE_PLATFORM:-}" =~ ^linux/(amd64|arm64)$ ]] || \
  die "E09 image metadata has an invalid target platform"
IMAGE_ARCH="${E09_IMAGE_PLATFORM#linux/}"

kube get nodes -o json >"$PREFLIGHT_DIR/nodes.json"
kube get pods --all-namespaces -o json >"$PREFLIGHT_DIR/pods.json"
kube get deviceclasses.resource.k8s.io -o json >"$PREFLIGHT_DIR/deviceclasses.json"
kube get resourceslices.resource.k8s.io -o json >"$PREFLIGHT_DIR/resourceslices.json"
"$HELPER" check-preflight \
  --nodes "$PREFLIGHT_DIR/nodes.json" \
  --pods "$PREFLIGHT_DIR/pods.json" \
  --device-classes "$PREFLIGHT_DIR/deviceclasses.json" \
  --resource-slices "$PREFLIGHT_DIR/resourceslices.json" \
  --target-node "$E09_TARGET_NODE" \
  --source-profile "$E09_MIG_SOURCE_PROFILE" \
  --device-class "$E09_DEVICE_CLASS" \
  --driver "$E09_DRA_DRIVER" \
  --dra-node-label-key "$E09_DRA_NODE_LABEL_KEY" \
  --dra-node-label-value "$E09_DRA_NODE_LABEL_VALUE" \
  --product-regex "$E09_GPU_PRODUCT_REGEX" \
  --output "$PREFLIGHT_DIR/preflight-summary.json"
jq -e \
  --arg node "$E09_TARGET_NODE" \
  --arg arch "$IMAGE_ARCH" \
  --arg taint_key "$E09_GPU_TAINT_KEY" \
  --arg taint_value "$E09_GPU_TAINT_VALUE" \
  --arg taint_effect "$E09_GPU_TAINT_EFFECT" '
  [.items[] | select(.metadata.name == $node)] | first
  | .metadata.labels["kubernetes.io/arch"] == $arch
    and (
      ($taint_key | length) == 0
      or any(.spec.taints[]?;
        .key == $taint_key
        and (($taint_value | length) == 0 or .value == $taint_value)
        and .effect == $taint_effect)
    )
' "$PREFLIGHT_DIR/nodes.json" >/dev/null || \
  die "GPU node architecture or protective taint does not match E09 configuration"
jq -e \
  --arg target "$E09_TARGET_NODE" \
  --arg arch "$IMAGE_ARCH" \
  --arg selector_key "$E09_CONTROL_NODE_SELECTOR_KEY" \
  --arg selector_value "$E09_CONTROL_NODE_SELECTOR_VALUE" '
  any(.items[];
    .metadata.name != $target
    and .metadata.labels[$selector_key] == $selector_value
    and .metadata.labels["kubernetes.io/arch"] == $arch
    and (.spec.unschedulable // false) == false
    and any(.status.conditions[]?;
      .type == "Ready" and .status == "True")
    and all(.spec.taints[]?;
      .effect != "NoSchedule" and .effect != "NoExecute")
  )
' "$PREFLIGHT_DIR/nodes.json" >/dev/null || \
  die "no untainted Ready CPU node matches the Hooke control-plane selector and image architecture"

component_pod_on_target() {
  local namespace="$1" selector="$2" container="$3" output="$4"
  kube -n "$namespace" get pods -l "$selector" -o json >"$output"
  jq -e \
    --arg node "$E09_TARGET_NODE" \
    --arg container "$container" '
    [.items[] | select(
      .spec.nodeName == $node
      and .status.phase == "Running"
      and any(.status.containerStatuses[]?;
        .name == $container and .ready == true)
    )] | length == 1
  ' "$output" >/dev/null
}

kube -n "$E09_GPU_OPERATOR_NAMESPACE" get pods \
  -l "$E09_DRIVER_POD_SELECTOR" -o json \
  >"$PREFLIGHT_DIR/driver-pods.json"
if [[ "$E09_DRIVER_MODE" == operator ]]; then
  component_pod_on_target \
    "$E09_GPU_OPERATOR_NAMESPACE" "$E09_DRIVER_POD_SELECTOR" \
    "$E09_DRIVER_CONTAINER" "$PREFLIGHT_DIR/driver-pods.json" || \
    die "exactly one Ready NVIDIA driver Pod is required on the target"
else
  jq -e \
    --arg node "$E09_TARGET_NODE" '
    [.items[] | select(
      .spec.nodeName == $node
      and (.status.phase // "") != "Succeeded"
      and (.status.phase // "") != "Failed"
    )] | length == 0
  ' "$PREFLIGHT_DIR/driver-pods.json" >/dev/null || \
    die "preinstalled driver mode forbids an active NVIDIA driver Pod on the target"
  jq -e \
    --arg node "$E09_TARGET_NODE" '
    any(.items[];
      .metadata.name == $node
      and (.metadata.labels["nvidia.com/cuda.driver-version.full"] // "") != ""
    )
  ' "$PREFLIGHT_DIR/nodes.json" >/dev/null || \
    die "preinstalled driver mode requires the NVIDIA driver version node label"
fi
component_pod_on_target \
  "$E09_MIG_MANAGER_NAMESPACE" "$E09_MIG_MANAGER_POD_SELECTOR" \
  "$E09_MIG_MANAGER_CONTAINER" "$PREFLIGHT_DIR/mig-manager-pods.json" || \
  die "exactly one Ready MIG Manager Pod is required on the target"
component_pod_on_target \
  "$E09_DRA_NAMESPACE" "$E09_DRA_POD_SELECTOR" \
  "$E09_DRA_CONTAINER" "$PREFLIGHT_DIR/dra-pods.json" || \
  die "exactly one Ready NVIDIA DRA kubelet plugin is required on the target"
jq -e \
  --arg node "$E09_TARGET_NODE" \
  --arg key "$E09_DRA_NODE_LABEL_KEY" \
  --arg value "$E09_DRA_NODE_LABEL_VALUE" '
  any(.items[];
    .spec.nodeName == $node and .spec.nodeSelector[$key] == $value)
' "$PREFLIGHT_DIR/dra-pods.json" >/dev/null || \
  die "NVIDIA DRA kubelet plugin does not use the frozen node selector"

if [[ -n "$E09_DEVICE_PLUGIN_POD_SELECTOR" ]]; then
  kube -n "$E09_DEVICE_PLUGIN_NAMESPACE" get pods \
    -l "$E09_DEVICE_PLUGIN_POD_SELECTOR" -o json \
    >"$PREFLIGHT_DIR/device-plugin-pods.json"
  jq -e \
    --arg node "$E09_TARGET_NODE" '
    [.items[] | select(
      .spec.nodeName == $node
      and (.status.phase // "") != "Succeeded"
      and (.status.phase // "") != "Failed"
    )] | length == 0
  ' "$PREFLIGHT_DIR/device-plugin-pods.json" >/dev/null || \
    die "the legacy NVIDIA Device Plugin must be disabled on the E09 target"
fi

if [[ "$E09_DRIVER_MODE" == operator ]]; then
  jq -e \
    --arg node "$E09_TARGET_NODE" \
    --arg label "$E09_DRA_NODE_LABEL_KEY" '
    any(
      .items[]
      | select(.spec.nodeName == $node)
      | ((.spec.initContainers // []) + (.spec.containers // []))[]
      | (.env // [])[];
      .name == "NODE_LABEL_FOR_GPU_POD_EVICTION" and .value == $label
    )
  ' "$PREFLIGHT_DIR/driver-pods.json" >/dev/null || \
    die "GPU Operator driver manager does not carry the required DRA eviction label"
  NVIDIA_SMI_NAMESPACE="$E09_GPU_OPERATOR_NAMESPACE"
  NVIDIA_SMI_POD_SELECTOR="$E09_DRIVER_POD_SELECTOR"
  NVIDIA_SMI_CONTAINER="$E09_DRIVER_CONTAINER"
else
  NVIDIA_SMI_NAMESPACE="$E09_MIG_MANAGER_NAMESPACE"
  NVIDIA_SMI_POD_SELECTOR="$E09_MIG_MANAGER_POD_SELECTOR"
  NVIDIA_SMI_CONTAINER="$E09_MIG_MANAGER_CONTAINER"
fi

resolve_nvidia_smi_pod() {
  kube -n "$NVIDIA_SMI_NAMESPACE" get pods \
    -l "$NVIDIA_SMI_POD_SELECTOR" -o json |
    jq -r \
      --arg node "$E09_TARGET_NODE" \
      --arg container "$NVIDIA_SMI_CONTAINER" '
      [.items[] | select(
        .spec.nodeName == $node
        and .status.phase == "Running"
        and any(.status.containerStatuses[]?;
          .name == $container and .ready == true)
      )] | if length == 1 then .[0].metadata.name else "" end
    '
}

NVIDIA_SMI_POD="$(resolve_nvidia_smi_pod)"
[[ -n "$NVIDIA_SMI_POD" ]] || \
  die "exactly one Ready nvidia-smi provider Pod is required on the target"
kube -n "$NVIDIA_SMI_NAMESPACE" exec "$NVIDIA_SMI_POD" \
  -c "$NVIDIA_SMI_CONTAINER" -- nvidia-smi -L \
  >"$PREFLIGHT_DIR/nvidia-smi-before.txt"
[[ "$(grep -Ec '^GPU [0-9]+:' "$PREFLIGHT_DIR/nvidia-smi-before.txt")" -eq 1 ]] || \
  die "E09 requires exactly one physical NVIDIA GPU"
grep -Eiq "$E09_GPU_PRODUCT_REGEX" "$PREFLIGHT_DIR/nvidia-smi-before.txt" || \
  die "nvidia-smi output does not identify the configured A100"

for namespace in "$E09_SYSTEM_NAMESPACE" "$E09_WORKLOAD_NAMESPACE"; do
  if kube get namespace "$namespace" >/dev/null 2>&1; then
    die "isolated E09 namespace already exists: $namespace"
  fi
done
if helm_ack status "$E09_HELM_RELEASE" -n "$E09_SYSTEM_NAMESPACE" >/dev/null 2>&1; then
  die "isolated E09 Helm release already exists: $E09_HELM_RELEASE"
fi
if kube -n "$E09_LOCK_NAMESPACE" get lease "$E09_LOCK_NAME" >/dev/null 2>&1; then
  die "another E09 runner holds lease ${E09_LOCK_NAMESPACE}/${E09_LOCK_NAME}"
fi

can_i() {
  local verb="$1" resource="$2" namespace="${3:-}"
  local result
  if [[ -n "$namespace" ]]; then
    result="$(kube auth can-i "$verb" "$resource" -n "$namespace")"
  else
    result="$(kube auth can-i "$verb" "$resource" --all-namespaces)"
  fi
  [[ "$result" == yes ]] || die "RBAC denied: ${verb} ${resource} ${namespace:+in ${namespace}}"
}

can_i patch nodes
can_i get nodes
can_i create namespaces
can_i delete namespaces
can_i create secrets "$E09_SYSTEM_NAMESPACE"
can_i create configmaps "$E09_SYSTEM_NAMESPACE"
can_i create jobs.batch "$E09_SYSTEM_NAMESPACE"
can_i get pods "$E09_SYSTEM_NAMESPACE"
can_i get pods/log "$E09_SYSTEM_NAMESPACE"
can_i create resourceclaims.resource.k8s.io "$E09_WORKLOAD_NAMESPACE"
can_i get resourceclaims.resource.k8s.io "$E09_WORKLOAD_NAMESPACE"
can_i delete resourceclaims.resource.k8s.io "$E09_WORKLOAD_NAMESPACE"
can_i create pods "$E09_WORKLOAD_NAMESPACE"
can_i get pods "$E09_WORKLOAD_NAMESPACE"
can_i get pods/log "$E09_WORKLOAD_NAMESPACE"
can_i delete pods "$E09_WORKLOAD_NAMESPACE"
can_i delete pods "$E09_DRA_NAMESPACE"
can_i create leases.coordination.k8s.io "$E09_LOCK_NAMESPACE"
can_i delete leases.coordination.k8s.io "$E09_LOCK_NAMESPACE"
can_i create clusterroles.rbac.authorization.k8s.io
can_i delete clusterroles.rbac.authorization.k8s.io
can_i create clusterrolebindings.rbac.authorization.k8s.io
can_i delete clusterrolebindings.rbac.authorization.k8s.io

STACK_REPOSITORY="${CONFIGURED_STACK_IMAGE%@*}"
STACK_DIGEST="${CONFIGURED_STACK_IMAGE#*@}"
helm lint "$CHART" --set global.clusterID="$CLUSTER_ID" >/dev/null
helm template hooke-e09-check "$CHART" \
  --set global.clusterID="$CLUSTER_ID" \
  --set image.repository="$STACK_REPOSITORY" \
  --set image.digest="$STACK_DIGEST" >/dev/null

log "E09 read-only preflight PASS: node=${E09_TARGET_NODE}, Kubernetes=${SERVER_VERSION}, GPU=one A100"
if [[ "$CHECK_ONLY" == true ]]; then
  log "E09 check-only PASS; no cluster state was changed"
  exit 0
fi
[[ "$CONFIRM_E09_EXECUTION" == yes ]] || \
  die "set CONFIRM_E09_EXECUTION=yes to create isolated smoke resources"
[[ "$CONFIRM_MIG_RECONFIGURATION" == yes ]] || \
  die "set CONFIRM_MIG_RECONFIGURATION=yes to authorize the real MIG reshape"

RUN_STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
ARTIFACT_DIR="${ARTIFACT_ROOT}/e09-gpu-dra-mig-smoke-${RUN_STAMP}"
mkdir -p "$ARTIFACT_DIR"
chmod 700 "$ARTIFACT_DIR"
cp "$PREFLIGHT_DIR"/* "$ARTIFACT_DIR/"
git status --short >"$ARTIFACT_DIR/git-status.txt"
git rev-parse HEAD >"$ARTIFACT_DIR/git-commit.txt"
cp "$E09_IMAGE_METADATA_FILE" "$ARTIFACT_DIR/image-metadata.env"
if [[ -n "$E09_DCGM_METRICS_API_PATH" ]]; then
  kube get --raw "$E09_DCGM_METRICS_API_PATH" >"$ARTIFACT_DIR/dcgm-before.prom"
fi
jq -n \
  --arg context "$KUBE_CONTEXT" \
  --arg api_server "$API_SERVER" \
  --arg cluster_id "$CLUSTER_ID" \
  --arg node "$E09_TARGET_NODE" \
  --arg source_profile "$E09_MIG_SOURCE_PROFILE" \
  --arg target_profile "$E09_MIG_TARGET_PROFILE" \
  --arg driver_mode "$E09_DRIVER_MODE" \
  --arg device_class "$E09_DEVICE_CLASS" \
  --arg driver "$E09_DRA_DRIVER" \
  --arg stack_image "$CONFIGURED_STACK_IMAGE" \
  --arg probe_image "$CONFIGURED_PROBE_IMAGE" '{
    kube_context: $context,
    api_server: $api_server,
    cluster_id: $cluster_id,
    target_node: $node,
    source_profile: $source_profile,
    target_profile: $target_profile,
    driver_mode: $driver_mode,
    device_class: $device_class,
    dra_driver: $driver,
    stack_image: $stack_image,
    probe_image: $probe_image,
    mysql_dsn_redacted: true
  }' >"$ARTIFACT_DIR/frozen-config.json"

LOCK_CREATED=false
SYSTEM_NAMESPACE_CREATED=false
WORKLOAD_NAMESPACE_CREATED=false
PROFILE_MUTATED=false
SUCCESS=false
RESTORE_CONFIRMED=false
RUN_ID=""
RUN_STOPPED=false
EVENTS_EXPORTED=false
REQUESTED_AT=""

wait_mig_transition() {
  local profile="$1" output="$2" require_transition="${3:-true}"
  local deadline=$((SECONDS + E09_MIG_TIMEOUT_SECONDS))
  local saw_transition=false
  : >"$output"
  while (( SECONDS < deadline )); do
    local observed labels current_profile current_state
    observed="$(now_ns)"
    if ! labels="$(kube get node "$E09_TARGET_NODE" -o json 2>/dev/null)"; then
      jq -cn \
        --argjson observed "$observed" \
        '{observed_time_ns:$observed,api_reachable:false}' >>"$output"
      sleep 2
      continue
    fi
    current_profile="$(jq -r '.metadata.labels["nvidia.com/mig.config"] // ""' <<<"$labels")"
    current_state="$(jq -r '.metadata.labels["nvidia.com/mig.config.state"] // ""' <<<"$labels")"
    jq -cn \
      --argjson observed "$observed" \
      --arg profile "$current_profile" \
      --arg state "$current_state" \
      '{observed_time_ns:$observed,profile:$profile,state:$state}' >>"$output"
    if [[ "$current_state" == failed ]]; then
      return 1
    fi
    if [[ "$current_profile" == "$profile" && "$current_state" != success ]]; then
      saw_transition=true
    fi
    if [[ "$current_profile" == "$profile" && "$current_state" == success ]]; then
      if [[ "$require_transition" == false || "$saw_transition" == true ]]; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

restart_dra_plugin() {
  local prefix="$1"
  local before old_uid old_name deadline
  before="$(kube -n "$E09_DRA_NAMESPACE" get pods -l "$E09_DRA_POD_SELECTOR" -o json)"
  printf '%s\n' "$before" >"${prefix}-before.json"
  old_uid="$(jq -r \
    --arg node "$E09_TARGET_NODE" \
    --arg container "$E09_DRA_CONTAINER" '
    [.items[] | select(
      .spec.nodeName == $node
      and any(.status.containerStatuses[]?;
        .name == $container and .ready == true)
    )] | first | .metadata.uid // ""
  ' <<<"$before")"
  old_name="$(jq -r \
    --arg uid "$old_uid" '
    [.items[] | select(.metadata.uid == $uid)] | first | .metadata.name // ""
  ' <<<"$before")"
  [[ -n "$old_uid" && -n "$old_name" ]] || return 1
  kube -n "$E09_DRA_NAMESPACE" logs "$old_name" \
    -c "$E09_DRA_CONTAINER" >"${prefix}-before.log" 2>&1 || true
  kube -n "$E09_DRA_NAMESPACE" delete pod "$old_name" --wait=false >/dev/null || return 1
  deadline=$((SECONDS + E09_DRA_RESTART_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local after new_uid
    after="$(kube -n "$E09_DRA_NAMESPACE" get pods -l "$E09_DRA_POD_SELECTOR" -o json)"
    new_uid="$(jq -r \
      --arg node "$E09_TARGET_NODE" \
      --arg old "$old_uid" \
      --arg container "$E09_DRA_CONTAINER" '
      [.items[] | select(
        .spec.nodeName == $node
        and .metadata.uid != $old
        and any(.status.containerStatuses[]?;
          .name == $container and .ready == true)
      )] | first
      | .metadata.uid // ""
    ' <<<"$after")"
    if [[ -n "$new_uid" ]]; then
      printf '%s\n' "$after" >"${prefix}-after.json"
      local new_name
      new_name="$(jq -r \
        --arg uid "$new_uid" '
        [.items[] | select(.metadata.uid == $uid)] | first | .metadata.name // ""
      ' <<<"$after")"
      if [[ -n "$new_name" ]]; then
        kube -n "$E09_DRA_NAMESPACE" logs "$new_name" \
          -c "$E09_DRA_CONTAINER" >"${prefix}-after.log" 2>&1 || true
      fi
      return 0
    fi
    sleep 2
  done
  return 1
}

patch_target_profile() {
  local profile="$1" run_id="$2" request_id="$3" requested_at="$4" output="$5"
  jq -n \
    --arg profile "$profile" \
    --arg run_id "$run_id" \
    --arg request_id "$request_id" \
    --arg requested_at "$requested_at" '{
      metadata: {
        labels: {"nvidia.com/mig.config": $profile},
        annotations: {
          "hooke.io/mig-run-id": $run_id,
          "hooke.io/mig-request-id": $request_id,
          "hooke.io/mig-request-profile": $profile,
          "hooke.io/mig-requested-at": $requested_at
        }
      }
    }' >"$output"
  kube patch node "$E09_TARGET_NODE" --type=merge --patch-file "$output" >/dev/null
}

restore_original_profile() {
  local patch="$ARTIFACT_DIR/restore-node-patch.json"
  local current current_profile current_state
  jq \
    --arg profile "$E09_MIG_SOURCE_PROFILE" '{
      metadata: {
        labels: {"nvidia.com/mig.config": $profile},
        annotations: {
          "hooke.io/mig-run-id": (.metadata.annotations["hooke.io/mig-run-id"] // null),
          "hooke.io/mig-request-id": (.metadata.annotations["hooke.io/mig-request-id"] // null),
          "hooke.io/mig-request-profile": (.metadata.annotations["hooke.io/mig-request-profile"] // null),
          "hooke.io/mig-requested-at": (.metadata.annotations["hooke.io/mig-requested-at"] // null)
        }
      }
    }' "$ARTIFACT_DIR/node-before.json" >"$patch"
  if current="$(kube get node "$E09_TARGET_NODE" -o json 2>/dev/null)"; then
    current_profile="$(jq -r '.metadata.labels["nvidia.com/mig.config"] // ""' <<<"$current")"
    current_state="$(jq -r '.metadata.labels["nvidia.com/mig.config.state"] // ""' <<<"$current")"
    if [[ "$current_profile" == "$E09_MIG_SOURCE_PROFILE" && "$current_state" == success ]]; then
      kube patch node "$E09_TARGET_NODE" --type=merge --patch-file "$patch" >/dev/null
      return 0
    fi
  fi
  kube patch node "$E09_TARGET_NODE" --type=merge --patch-file "$patch" >/dev/null &&
    wait_mig_transition \
      "$E09_MIG_SOURCE_PROFILE" \
      "$ARTIFACT_DIR/mig-restore-observations.ndjson" false &&
    restart_dra_plugin "$ARTIFACT_DIR/dra-plugin-restore"
}

cleanup_cluster() {
  local status=$?
  local cleanup_failed=false
  local should_cleanup=false
  local workload_cleared=true
  trap - EXIT
  if [[ "$SUCCESS" == true && "$CLEANUP_K8S_ON_SUCCESS" == true ]]; then
    should_cleanup=true
  elif [[ "$SUCCESS" != true && "$CLEANUP_K8S_ON_ERROR" == true ]]; then
    should_cleanup=true
  fi

  kube get node "$E09_TARGET_NODE" -o json \
    >"$ARTIFACT_DIR/node-at-exit.json" 2>/dev/null || true
  kube -n "$E09_DRA_NAMESPACE" get pods -l "$E09_DRA_POD_SELECTOR" -o json \
    >"$ARTIFACT_DIR/dra-pods-at-exit.json" 2>/dev/null || true
  if [[ -n "$REQUESTED_AT" ]]; then
    kube -n "$E09_MIG_MANAGER_NAMESPACE" logs \
      -l "$E09_MIG_MANAGER_POD_SELECTOR" \
      -c "$E09_MIG_MANAGER_CONTAINER" \
      --since-time="$REQUESTED_AT" --prefix=true \
      >"$ARTIFACT_DIR/mig-manager-at-exit.log" 2>&1 || true
  fi

  if [[ "$SUCCESS" != true && -n "$RUN_ID" && "$SYSTEM_NAMESPACE_CREATED" == true ]]; then
    if [[ "$RUN_STOPPED" != true ]] && declare -F run_hookectl_job >/dev/null; then
      if run_hookectl_job "e09-cleanup-stop-run" \
        "$ARTIFACT_DIR/run-stop-at-exit.json" \
        run stop \
        --api "http://${E09_HELM_RELEASE}-ingester:8080" \
        --run-id "$RUN_ID"; then
        RUN_STOPPED=true
      else
        warn "best-effort E09 run stop failed during cleanup"
        cleanup_failed=true
      fi
    fi
    if [[ "$EVENTS_EXPORTED" != true ]] && declare -F run_event_export_job >/dev/null; then
      if run_event_export_job "e09-cleanup-export-events" \
        "$ARTIFACT_DIR/events-at-exit.ndjson" "$RUN_ID"; then
        EVENTS_EXPORTED=true
      else
        warn "best-effort E09 event export failed during cleanup"
        cleanup_failed=true
      fi
    fi
  fi

  if [[ "$PROFILE_MUTATED" == true && "$E09_RESTORE_MIG_PROFILE" == true ]]; then
    if [[ "$SYSTEM_NAMESPACE_CREATED" == true ]]; then
      kube -n "$E09_SYSTEM_NAMESPACE" scale \
        "deployment/${E09_HELM_RELEASE}-controller" --replicas=0 \
        >/dev/null 2>&1 || true
    fi
    if [[ "$WORKLOAD_NAMESPACE_CREATED" == true ]]; then
      if kube delete namespace "$E09_WORKLOAD_NAMESPACE" \
        --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1; then
        WORKLOAD_NAMESPACE_CREATED=false
      else
        workload_cleared=false
        cleanup_failed=true
      fi
    fi
    if [[ "$workload_cleared" == true ]]; then
      log "Restoring MIG profile ${E09_MIG_SOURCE_PROFILE}"
      if restore_original_profile; then
        RESTORE_CONFIRMED=true
        kube get node "$E09_TARGET_NODE" -o json >"$ARTIFACT_DIR/node-restored.json" || \
          cleanup_failed=true
      else
        warn "MIG profile or DRA plugin restoration could not be confirmed"
        cleanup_failed=true
      fi
    else
      warn "Workload deletion was not confirmed; refusing to reshape an in-use GPU"
      warn "Target MIG profile and E09 Lease are preserved for manual recovery"
      should_cleanup=false
    fi
  fi

  if [[ "$should_cleanup" == true ]]; then
    if [[ "$WORKLOAD_NAMESPACE_CREATED" == true ]]; then
      kube delete namespace "$E09_WORKLOAD_NAMESPACE" \
        --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || \
        cleanup_failed=true
    fi
    if [[ "$SYSTEM_NAMESPACE_CREATED" == true ]]; then
      if helm_ack status "$E09_HELM_RELEASE" -n "$E09_SYSTEM_NAMESPACE" \
        >/dev/null 2>&1; then
        helm_ack uninstall "$E09_HELM_RELEASE" -n "$E09_SYSTEM_NAMESPACE" \
          --wait --timeout 5m >/dev/null 2>&1 || cleanup_failed=true
      fi
      kube delete clusterrole "${E09_HELM_RELEASE}-reader" \
        --ignore-not-found >/dev/null 2>&1 || cleanup_failed=true
      kube delete clusterrolebinding "${E09_HELM_RELEASE}-reader" \
        --ignore-not-found >/dev/null 2>&1 || cleanup_failed=true
      kube delete namespace "$E09_SYSTEM_NAMESPACE" \
        --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || \
        cleanup_failed=true
    fi
  else
    warn "E09 Kubernetes resources preserved for diagnosis"
  fi

  if [[ "$LOCK_CREATED" == true ]]; then
    if [[ "$cleanup_failed" == false && ( "$PROFILE_MUTATED" == false || "$E09_RESTORE_MIG_PROFILE" != true || "$RESTORE_CONFIRMED" == true ) ]]; then
      kube -n "$E09_LOCK_NAMESPACE" delete lease "$E09_LOCK_NAME" \
        --ignore-not-found >/dev/null 2>&1 || cleanup_failed=true
    else
      warn "E09 Lease preserved because restoration/cleanup needs manual review"
    fi
  fi
  cleanup_preflight
  if [[ "$cleanup_failed" == true ]]; then
    warn "E09 cleanup/restoration is incomplete; artifacts: ${ARTIFACT_DIR}"
    [[ "$status" -ne 0 ]] || status=1
  elif [[ "$SUCCESS" == true ]]; then
    if [[ "$PROFILE_MUTATED" == true && "$E09_RESTORE_MIG_PROFILE" == true ]]; then
      log "E09 smoke PASS; original MIG profile restored; artifacts: ${ARTIFACT_DIR}"
    else
      log "E09 smoke PASS; target MIG profile retained by configuration; artifacts: ${ARTIFACT_DIR}"
    fi
  fi
  return "$status"
}
trap cleanup_cluster EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

jq -n \
  --arg namespace "$E09_LOCK_NAMESPACE" \
  --arg name "$E09_LOCK_NAME" \
  --arg holder "${USER:-hooke}@$(hostname)-${RUN_STAMP}" '{
    apiVersion: "coordination.k8s.io/v1",
    kind: "Lease",
    metadata: {namespace: $namespace, name: $name},
    spec: {holderIdentity: $holder}
  }' | kube create -f - >/dev/null
LOCK_CREATED=true

kube create namespace "$E09_SYSTEM_NAMESPACE" >/dev/null
SYSTEM_NAMESPACE_CREATED=true
kube label namespace "$E09_SYSTEM_NAMESPACE" hooke.io/experiment=e09 --overwrite >/dev/null
printf '%s' "$HOOKE_MYSQL_DSN" | \
  kube -n "$E09_SYSTEM_NAMESPACE" create secret generic "$E09_MYSQL_SECRET" \
  --from-file=dsn=/dev/stdin >/dev/null

render_values() {
  local run_id="$1" controller_enabled="$2" output="$3"
  jq -n \
    --arg cluster_id "$CLUSTER_ID" \
    --arg hooke_namespace "$E09_SYSTEM_NAMESPACE" \
    --arg run_id "$run_id" \
    --arg repository "$STACK_REPOSITORY" \
    --arg digest "$STACK_DIGEST" \
    --arg mysql_secret "$E09_MYSQL_SECRET" \
    --arg selector_key "$E09_CONTROL_NODE_SELECTOR_KEY" \
    --arg selector_value "$E09_CONTROL_NODE_SELECTOR_VALUE" \
    --argjson controller_enabled "$controller_enabled" '{
      global: {
        clusterID: $cluster_id,
        hookeNamespace: $hooke_namespace,
        activeRunID: $run_id
      },
      image: {
        repository: $repository,
        digest: $digest,
        pullPolicy: "IfNotPresent"
      },
      mysql: {dsnSecret: {name: $mysql_secret, key: "dsn"}},
      migration: {enabled: true},
      ingester: {enabled: true, replicas: 1},
      controller: {
        enabled: $controller_enabled,
        replicas: 1,
        captureUnlabeled: false,
        eventSamplePercent: 100,
        nodeSelector: {($selector_key): $selector_value}
      },
      nodeAgent: {enabled: false},
      ackAdapter: {enabled: false},
      correlator: {enabled: false},
      networkPolicy: {enabled: true},
      nodeSelector: {($selector_key): $selector_value}
    }' >"$output"
}

BASE_VALUES="$ARTIFACT_DIR/helm-values-base.json"
render_values "" false "$BASE_VALUES"
helm_ack upgrade --install "$E09_HELM_RELEASE" "$CHART" \
  --namespace "$E09_SYSTEM_NAMESPACE" \
  --values "$BASE_VALUES" \
  --rollback-on-failure --wait --timeout 10m >/dev/null
kube -n "$E09_SYSTEM_NAMESPACE" rollout status \
  "deployment/${E09_HELM_RELEASE}-ingester" --timeout=5m >/dev/null

wait_job_complete() {
  local name="$1" timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    local job
    if ! job="$(kube -n "$E09_SYSTEM_NAMESPACE" get "job/$name" -o json 2>/dev/null)"; then
      sleep 2
      continue
    fi
    if jq -e 'any(.status.conditions[]?; .type == "Complete" and .status == "True")' \
      <<<"$job" >/dev/null; then
      return 0
    fi
    if jq -e 'any(.status.conditions[]?; .type == "Failed" and .status == "True")' \
      <<<"$job" >/dev/null; then
      return 1
    fi
    sleep 2
  done
  return 1
}

wait_pod_succeeded() {
  local namespace="$1" name="$2" timeout_seconds="$3"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    local phase
    phase="$(kube -n "$namespace" get "pod/$name" \
      -o jsonpath='{.status.phase}' 2>/dev/null)" || {
      sleep 2
      continue
    }
    case "$phase" in
      Succeeded) return 0 ;;
      Failed) return 1 ;;
    esac
    sleep 2
  done
  return 1
}

run_hookectl_job() {
  local name="$1" output="$2"
  shift 2
  jq -n \
    --arg namespace "$E09_SYSTEM_NAMESPACE" \
    --arg name "$name" \
    --arg image "$CONFIGURED_STACK_IMAGE" \
    --arg selector_key "$E09_CONTROL_NODE_SELECTOR_KEY" \
    --arg selector_value "$E09_CONTROL_NODE_SELECTOR_VALUE" \
    --args '{
      apiVersion: "batch/v1",
      kind: "Job",
      metadata: {namespace: $namespace, name: $name},
      spec: {
        backoffLimit: 0,
        template: {
          spec: {
            restartPolicy: "Never",
            nodeSelector: {($selector_key): $selector_value},
            containers: [{
              name: "hookectl",
              image: $image,
              imagePullPolicy: "IfNotPresent",
              command: ["/hookectl"],
              args: $ARGS.positional,
              securityContext: {
                allowPrivilegeEscalation: false,
                capabilities: {drop: ["ALL"]}
              }
            }]
          }
        }
      }
  }' -- "$@" >"$ARTIFACT_DIR/${name}.json"
  kube apply -f "$ARTIFACT_DIR/${name}.json" >/dev/null
  if ! wait_job_complete "$name" 180; then
    kube -n "$E09_SYSTEM_NAMESPACE" get "job/$name" -o json \
      >"$ARTIFACT_DIR/${name}-failed.json" 2>/dev/null || true
    kube -n "$E09_SYSTEM_NAMESPACE" logs "job/$name" >&2 || true
    return 1
  fi
  kube -n "$E09_SYSTEM_NAMESPACE" logs "job/$name" >"$output"
}

run_event_export_job() {
  local name="$1" output="$2" run_id="$3"
  jq -n \
    --arg namespace "$E09_SYSTEM_NAMESPACE" \
    --arg name "$name" \
    --arg image "$CONFIGURED_STACK_IMAGE" \
    --arg secret "$E09_MYSQL_SECRET" \
    --arg run "$run_id" \
    --arg selector_key "$E09_CONTROL_NODE_SELECTOR_KEY" \
    --arg selector_value "$E09_CONTROL_NODE_SELECTOR_VALUE" '{
      apiVersion: "batch/v1",
      kind: "Job",
      metadata: {namespace: $namespace, name: $name},
      spec: {
        backoffLimit: 0,
        template: {
          spec: {
            restartPolicy: "Never",
            nodeSelector: {($selector_key): $selector_value},
            containers: [{
              name: "export",
              image: $image,
              imagePullPolicy: "IfNotPresent",
              command: ["/hookectl"],
              args: ["events","export","--run-id",$run,"--file","-"],
              env: [{
                name:"HOOKE_MYSQL_DSN",
                valueFrom:{secretKeyRef:{name:$secret,key:"dsn"}}
              }],
              securityContext: {
                allowPrivilegeEscalation: false,
                capabilities: {drop: ["ALL"]}
              }
            }]
          }
        }
      }
    }' >"$ARTIFACT_DIR/${name}.json"
  kube apply -f "$ARTIFACT_DIR/${name}.json" >/dev/null
  if ! wait_job_complete "$name" 180; then
    kube -n "$E09_SYSTEM_NAMESPACE" get "job/$name" -o json \
      >"$ARTIFACT_DIR/${name}-failed.json" 2>/dev/null || true
    kube -n "$E09_SYSTEM_NAMESPACE" logs "job/$name" >&2 || true
    return 1
  fi
  kube -n "$E09_SYSTEM_NAMESPACE" logs "job/$name" >"$output"
}

CREATE_JOB="e09-create-run"
run_hookectl_job "$CREATE_JOB" "$ARTIFACT_DIR/run-create.json" \
  run create \
  --api "http://${E09_HELM_RELEASE}-ingester:8080" \
  --cluster "$CLUSTER_ID" \
  --name "E09 GPU DRA MIG smoke ${RUN_STAMP}" \
  --slo-seconds 120 \
  --labels-json '{"experiment":"E09","scope":"single-A100-smoke"}' || \
  die "failed to create E09 run"
RUN_ID="$(jq -er '.run_id' "$ARTIFACT_DIR/run-create.json")" || \
  die "run create returned no run_id"
[[ "$RUN_ID" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || die "invalid run ULID"
printf '%s\n' "$RUN_ID" >"$ARTIFACT_DIR/run-id.txt"

kube create namespace "$E09_WORKLOAD_NAMESPACE" >/dev/null
WORKLOAD_NAMESPACE_CREATED=true
kube annotate namespace "$E09_WORKLOAD_NAMESPACE" \
  "hooke.io/run-id=$RUN_ID" --overwrite >/dev/null
kube label namespace "$E09_WORKLOAD_NAMESPACE" \
  hooke.io/experiment=e09 --overwrite >/dev/null

ACTIVE_VALUES="$ARTIFACT_DIR/helm-values-active.json"
render_values "$RUN_ID" true "$ACTIVE_VALUES"
helm_ack upgrade "$E09_HELM_RELEASE" "$CHART" \
  --namespace "$E09_SYSTEM_NAMESPACE" \
  --values "$ACTIVE_VALUES" \
  --rollback-on-failure --wait --timeout 10m >/dev/null
kube -n "$E09_SYSTEM_NAMESPACE" rollout status \
  "deployment/${E09_HELM_RELEASE}-controller" --timeout=5m >/dev/null
sleep "$E09_CONTROLLER_SETTLE_SECONDS"

kube get node "$E09_TARGET_NODE" -o json >"$ARTIFACT_DIR/node-before.json"
REQUEST_ID="e09-${RUN_ID,,}"
REQUESTED_AT="$(date -u +'%Y-%m-%dT%H:%M:%S.%NZ')"
PROFILE_MUTATED=true
patch_target_profile \
  "$E09_MIG_TARGET_PROFILE" "$RUN_ID" "$REQUEST_ID" "$REQUESTED_AT" \
  "$ARTIFACT_DIR/target-node-patch.json"
if ! wait_mig_transition \
  "$E09_MIG_TARGET_PROFILE" \
  "$ARTIFACT_DIR/mig-target-observations.ndjson" true; then
  die "MIG Manager did not reach target profile success"
fi
kube get node "$E09_TARGET_NODE" -o json >"$ARTIFACT_DIR/node-after.json"
kube -n "$E09_MIG_MANAGER_NAMESPACE" logs \
  -l "$E09_MIG_MANAGER_POD_SELECTOR" \
  -c "$E09_MIG_MANAGER_CONTAINER" \
  --since-time="$REQUESTED_AT" --prefix=true \
  >"$ARTIFACT_DIR/mig-manager.log" || true

log "A100 MIG reshape succeeded; restarting NVIDIA DRA kubelet plugin"
restart_dra_plugin "$ARTIFACT_DIR/dra-plugin-target" || \
  die "NVIDIA DRA kubelet plugin did not restart Ready on the A100"
SLICE_DEADLINE=$((SECONDS + E09_DRA_RESTART_TIMEOUT_SECONDS))
SLICE_READY=false
while (( SECONDS < SLICE_DEADLINE )); do
  kube get resourceslices.resource.k8s.io -o json \
    >"$ARTIFACT_DIR/resourceslices-after.json"
  if jq -e \
    --arg node "$E09_TARGET_NODE" \
    --arg driver "$E09_DRA_DRIVER" '
    [.items[] | select(
      .spec.nodeName == $node and .spec.driver == $driver
    )] as $slices
    | ($slices | length) == 1
      and ($slices[0].spec.pool.name // "") != ""
      and ($slices[0].spec.pool.resourceSliceCount // 0) == 1
      and any($slices[0].spec.devices[]?;
          (
            .attributes.type.string
            // .attributes["gpu.nvidia.com/type"].string
            // .attributes["gpu.nvidia.com"].type.string
            // .basic.attributes.type.string
            // ""
          ) == "mig")
  ' "$ARTIFACT_DIR/resourceslices-after.json" >/dev/null; then
    SLICE_READY=true
    break
  fi
  sleep 2
done
[[ "$SLICE_READY" == true ]] || \
  die "post-reshape NVIDIA ResourceSlice did not publish a MIG device"

NVIDIA_SMI_POD="$(resolve_nvidia_smi_pod)"
[[ -n "$NVIDIA_SMI_POD" ]] || \
  die "Ready nvidia-smi provider Pod disappeared after reshape"
kube -n "$NVIDIA_SMI_NAMESPACE" exec "$NVIDIA_SMI_POD" \
  -c "$NVIDIA_SMI_CONTAINER" -- nvidia-smi -L \
  >"$ARTIFACT_DIR/nvidia-smi-after.txt"
grep -q 'MIG ' "$ARTIFACT_DIR/nvidia-smi-after.txt" || \
  die "nvidia-smi did not report a MIG device after reshape"
if [[ -n "$E09_DCGM_METRICS_API_PATH" ]]; then
  kube get --raw "$E09_DCGM_METRICS_API_PATH" >"$ARTIFACT_DIR/dcgm-after.prom"
fi

CLAIM_NAME="e09-mig"
PROBE_NAME="e09-cuda-probe"
"$HELPER" render-claim \
  --namespace "$E09_WORKLOAD_NAMESPACE" \
  --name "$CLAIM_NAME" \
  --run-id "$RUN_ID" \
  --device-class "$E09_DEVICE_CLASS" \
  --output "$ARTIFACT_DIR/resourceclaim.json"
kube apply -f "$ARTIFACT_DIR/resourceclaim.json" >/dev/null
CLAIM_UID="$(kube -n "$E09_WORKLOAD_NAMESPACE" get resourceclaim "$CLAIM_NAME" -o jsonpath='{.metadata.uid}')"
[[ -n "$CLAIM_UID" ]] || die "ResourceClaim UID was not assigned"
printf '%s\n' "$CLAIM_UID" >"$ARTIFACT_DIR/claim-uid.txt"

"$HELPER" render-probe \
  --namespace "$E09_WORKLOAD_NAMESPACE" \
  --name "$PROBE_NAME" \
  --cluster-id "$CLUSTER_ID" \
  --run-id "$RUN_ID" \
  --image "$CONFIGURED_PROBE_IMAGE" \
  --target-node "$E09_TARGET_NODE" \
  --claim-name "$CLAIM_NAME" \
  --claim-uid "$CLAIM_UID" \
  --device-class "$E09_DEVICE_CLASS" \
  --taint-key "$E09_GPU_TAINT_KEY" \
  --taint-value "$E09_GPU_TAINT_VALUE" \
  --taint-effect "$E09_GPU_TAINT_EFFECT" \
  --output "$ARTIFACT_DIR/probe-pod.json"
START_NS="$(now_ns)"
kube apply -f "$ARTIFACT_DIR/probe-pod.json" >/dev/null
if ! wait_pod_succeeded \
  "$E09_WORKLOAD_NAMESPACE" "$PROBE_NAME" "$E09_POD_TIMEOUT_SECONDS"; then
  kube -n "$E09_WORKLOAD_NAMESPACE" get pod "$PROBE_NAME" -o yaml \
    >"$ARTIFACT_DIR/probe-pod-failed.yaml" || true
  kube -n "$E09_WORKLOAD_NAMESPACE" describe pod "$PROBE_NAME" \
    >"$ARTIFACT_DIR/probe-pod-describe.txt" || true
  kube -n "$E09_WORKLOAD_NAMESPACE" logs "$PROBE_NAME" --all-containers=true \
    >"$ARTIFACT_DIR/probe-failed.log" || true
  die "CUDA probe Pod did not succeed"
fi
sleep "$E09_CLAIM_SETTLE_SECONDS"
END_NS="$(now_ns)"
kube -n "$E09_WORKLOAD_NAMESPACE" get pod "$PROBE_NAME" -o json \
  >"$ARTIFACT_DIR/probe-pod-final.json"
jq '{apiVersion:"v1",kind:"PodList",items:[.]}' \
  "$ARTIFACT_DIR/probe-pod-final.json" \
  >"$ARTIFACT_DIR/probe-pods-final.json"
kube -n "$E09_WORKLOAD_NAMESPACE" get resourceclaim "$CLAIM_NAME" -o json \
  >"$ARTIFACT_DIR/resourceclaim-final.json"
POD_UID="$(jq -r '.metadata.uid' "$ARTIFACT_DIR/probe-pod-final.json")"
printf '%s\n' "$POD_UID" >"$ARTIFACT_DIR/pod-uid.txt"
mkdir -p "$ARTIFACT_DIR/probe-logs"
kube -n "$E09_WORKLOAD_NAMESPACE" logs "$PROBE_NAME" -c cuda-probe \
  >"$ARTIFACT_DIR/probe-logs/${PROBE_NAME}-cuda-probe.log"
"$APPLICATION_EXPORTER" \
  --cluster-id "$CLUSTER_ID" \
  --run-id "$RUN_ID" \
  --pods "$ARTIFACT_DIR/probe-pods-final.json" \
  --logs-dir "$ARTIFACT_DIR/probe-logs" \
  --start-ns "$START_NS" \
  --end-ns "$END_NS" \
  --output "$ARTIFACT_DIR/application-events.ndjson"

APP_EVENTS_CONFIGMAP="e09-application-events"
kube -n "$E09_SYSTEM_NAMESPACE" create configmap "$APP_EVENTS_CONFIGMAP" \
  --from-file=events.ndjson="$ARTIFACT_DIR/application-events.ndjson" >/dev/null
IMPORT_JOB="e09-import-events"
jq -n \
  --arg namespace "$E09_SYSTEM_NAMESPACE" \
  --arg name "$IMPORT_JOB" \
  --arg image "$CONFIGURED_STACK_IMAGE" \
  --arg configmap "$APP_EVENTS_CONFIGMAP" \
  --arg cluster "$CLUSTER_ID" \
  --arg run "$RUN_ID" \
  --arg api "http://${E09_HELM_RELEASE}-ingester:8080" \
  --arg selector_key "$E09_CONTROL_NODE_SELECTOR_KEY" \
  --arg selector_value "$E09_CONTROL_NODE_SELECTOR_VALUE" '{
    apiVersion: "batch/v1",
    kind: "Job",
    metadata: {namespace: $namespace, name: $name},
    spec: {
      backoffLimit: 0,
      template: {
        spec: {
          restartPolicy: "Never",
          nodeSelector: {($selector_key): $selector_value},
          containers: [{
            name: "import",
            image: $image,
            command: ["/hookectl"],
            args: ["events","import","--api",$api,"--cluster",$cluster,"--run-id",$run,"--file","/events/events.ndjson"],
            volumeMounts: [{name:"events",mountPath:"/events",readOnly:true}],
            securityContext: {
              allowPrivilegeEscalation: false,
              capabilities: {drop: ["ALL"]}
            }
          }],
          volumes: [{name:"events",configMap:{name:$configmap}}]
        }
      }
    }
  }' >"$ARTIFACT_DIR/import-job.json"
kube apply -f "$ARTIFACT_DIR/import-job.json" >/dev/null
if ! wait_job_complete "$IMPORT_JOB" 180; then
  kube -n "$E09_SYSTEM_NAMESPACE" get "job/$IMPORT_JOB" -o json \
    >"$ARTIFACT_DIR/import-job-failed.json" 2>/dev/null || true
  kube -n "$E09_SYSTEM_NAMESPACE" logs "job/$IMPORT_JOB" >&2 || true
  die "application event import failed"
fi

STOP_JOB="e09-stop-run"
run_hookectl_job "$STOP_JOB" "$ARTIFACT_DIR/run-stop.json" \
  run stop \
  --api "http://${E09_HELM_RELEASE}-ingester:8080" \
  --run-id "$RUN_ID" || die "failed to stop E09 run"
RUN_STOPPED=true

EXPORT_JOB="e09-export-events"
run_event_export_job "$EXPORT_JOB" "$ARTIFACT_DIR/events.ndjson" "$RUN_ID" || \
  die "event export failed"
EVENTS_EXPORTED=true

"$HELPER" summarize \
  --events "$ARTIFACT_DIR/events.ndjson" \
  --claim "$ARTIFACT_DIR/resourceclaim-final.json" \
  --pod "$ARTIFACT_DIR/probe-pod-final.json" \
  --node-before "$ARTIFACT_DIR/node-before.json" \
  --node-after "$ARTIFACT_DIR/node-after.json" \
  --resource-slices "$ARTIFACT_DIR/resourceslices-after.json" \
  --run-id "$RUN_ID" \
  --claim-uid "$CLAIM_UID" \
  --pod-uid "$POD_UID" \
  --target-node "$E09_TARGET_NODE" \
  --source-profile "$E09_MIG_SOURCE_PROFILE" \
  --target-profile "$E09_MIG_TARGET_PROFILE" \
  --device-class "$E09_DEVICE_CLASS" \
  --driver "$E09_DRA_DRIVER" \
  --output "$ARTIFACT_DIR/summary.json" \
  --report "$ARTIFACT_DIR/report.md"

SUCCESS=true
