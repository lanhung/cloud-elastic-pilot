#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
E09_HELPER="${SCRIPT_DIR}/e09-gpu-dra-mig.py"
PILOT_HELPER="${SCRIPT_DIR}/e09-gpu-dra-mig-pilot.py"
CONFIG_FILE="${PROJECT_ROOT}/configs/gpu-dra-mig-pilot.env"
CHECK_ONLY=false

usage() {
  cat <<'USAGE'
Usage: ack-gpu-dra-mig-pilot.sh [--config PATH] [--check-only]

Runs the two-A100 E09 small-scale crossover pilot:
  period 1: node A static-balanced, node B dynamic-homogeneous
  period 2: node B static-balanced, node A dynamic-homogeneous

Each demand epoch creates a seven-Claim burst with a profile-specific DRA CEL
selector. CUDA probes hold their allocations through the admission window so
the first-wave success count is an observed capacity result.

--check-only is read-only. Execution requires:
  CONFIRM_E09_PILOT_EXECUTION=yes
  CONFIRM_MIG_RECONFIGURATION=yes
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
: "${CONFIRM_E09_PILOT_EXECUTION:=no}"
: "${CONFIRM_MIG_RECONFIGURATION:=no}"
: "${REQUIRE_CLEAN_GIT:=true}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${CLUSTER_ID:=}"
: "${E09_EXPECTED_BRANCH:=experiment/11-gpu-dra-mig-smoke}"
: "${E09_PILOT_NODE_A:=}"
: "${E09_PILOT_NODE_B:=}"
: "${E09_PILOT_GPU_PRODUCT_REGEX:=A100-SXM4-80GB}"
: "${E09_PILOT_SOURCE_PROFILE:=all-disabled}"
: "${E09_PILOT_REQUIRED_MIG_STRATEGY:=mixed}"
: "${E09_PILOT_STATIC_CONFIG:=all-balanced}"
: "${E09_PILOT_PROFILE_MAP:=1g.10gb=all-1g.10gb,3g.40gb=all-3g.40gb}"
: "${E09_PILOT_SEQUENCE:=1g.10gb,1g.10gb,3g.40gb,3g.40gb,1g.10gb,3g.40gb}"
: "${E09_PILOT_BATCH_SIZE:=7}"
: "${E09_PILOT_ADMISSION_WINDOW_SECONDS:=25}"
: "${E09_PILOT_HOLD_SECONDS:=45}"
: "${E09_DEVICE_CLASS:=mig.nvidia.com}"
: "${E09_DRA_DRIVER:=gpu.nvidia.com}"
: "${E09_IMAGE_METADATA_FILE:=dist/e09-images.env}"
: "${E09_STACK_IMAGE:=}"
: "${E09_PROBE_IMAGE:=}"
: "${E09_PILOT_WORKLOAD_NAMESPACE:=hooke-e09-pilot}"
: "${E09_PILOT_LOCK_NAMESPACE:=kube-system}"
: "${E09_PILOT_LOCK_NAME:=hooke-e09-gpu-dra-mig-pilot}"
: "${E09_CONTROL_NODE_SELECTOR_KEY:=hooke.io/pool}"
: "${E09_CONTROL_NODE_SELECTOR_VALUE:=fixed-cpu}"
: "${E09_GPU_TAINT_KEY:=nvidia.com/gpu}"
: "${E09_GPU_TAINT_VALUE:=}"
: "${E09_GPU_TAINT_EFFECT:=NoSchedule}"
: "${E09_GPU_OPERATOR_NAMESPACE:=gpu-operator}"
: "${E09_DRIVER_MODE:=preinstalled}"
: "${E09_DRIVER_POD_SELECTOR:=app=nvidia-driver-daemonset}"
: "${E09_DRIVER_CONTAINER:=nvidia-driver-ctr}"
: "${E09_MIG_MANAGER_NAMESPACE:=$E09_GPU_OPERATOR_NAMESPACE}"
: "${E09_MIG_MANAGER_POD_SELECTOR:=app=nvidia-mig-manager}"
: "${E09_MIG_MANAGER_CONTAINER:=nvidia-mig-manager}"
: "${E09_MIG_CONFIGMAP:=default-mig-parted-config}"
: "${E09_MIG_CONFIGMAP_KEY:=config.yaml}"
: "${E09_GPU_CLIENTS_CONFIGMAP:=ack-gpu-clients}"
: "${E09_GPU_CLIENTS_CONFIGMAP_KEY:=clients.yaml}"
: "${E09_DRA_NAMESPACE:=nvidia-dra-driver-gpu}"
: "${E09_DRA_POD_SELECTOR:=dra-driver-nvidia-gpu-component=kubelet-plugin}"
: "${E09_DRA_CONTAINER:=gpus}"
: "${E09_DRA_NODE_LABEL_KEY:=nvidia.com/dra-kubelet-plugin}"
: "${E09_DRA_NODE_LABEL_VALUE:=true}"
: "${E09_DEVICE_PLUGIN_NAMESPACE:=$E09_GPU_OPERATOR_NAMESPACE}"
: "${E09_DEVICE_PLUGIN_POD_SELECTOR:=app=nvidia-device-plugin-daemonset}"
: "${E09_PILOT_QUIESCE_DAEMONSETS:=arms-prom/ack-prometheus-gpu-exporter,kube-system/ack-accel-health-monitor}"
: "${E09_MIG_TIMEOUT_SECONDS:=1200}"
: "${E09_DRA_RESTART_TIMEOUT_SECONDS:=300}"
: "${E09_PILOT_WARMUP_TIMEOUT_SECONDS:=300}"
: "${E09_PILOT_BATCH_CLEANUP_TIMEOUT_SECONDS:=180}"
: "${E09_PILOT_RESTORE_SOURCE_PROFILE:=true}"
: "${ARTIFACT_ROOT:=artifacts}"

for command in kubectl jq python3 git date grep awk sed; do
  require_cmd "$command"
done
[[ -x "$E09_HELPER" ]] || die "helper must be executable: $E09_HELPER"
[[ -x "$PILOT_HELPER" ]] || die "helper must be executable: $PILOT_HELPER"
[[ "$CONFIRM_KUBE_CONTEXT" == yes ]] || \
  die "set CONFIRM_KUBE_CONTEXT=yes after verifying the ACK target"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
[[ -n "$KUBE_CONTEXT" && -n "$EXPECTED_API_SERVER_SUBSTRING" ]] || \
  die "KUBE_CONTEXT and EXPECTED_API_SERVER_SUBSTRING are required"
[[ -n "$CLUSTER_ID" ]] || die "CLUSTER_ID is required"
[[ -n "$E09_PILOT_NODE_A" && -n "$E09_PILOT_NODE_B" ]] || \
  die "both pilot GPU nodes are required"
[[ "$E09_PILOT_NODE_A" != "$E09_PILOT_NODE_B" ]] || \
  die "pilot GPU nodes must be distinct"
[[ "$E09_PILOT_REQUIRED_MIG_STRATEGY" == mixed ]] || \
  die "the balanced static control requires mig.strategy=mixed"
[[ "$E09_PILOT_RESTORE_SOURCE_PROFILE" == true ]] || \
  die "the small pilot requires source-profile restoration"
[[ "$E09_STACK_IMAGE" =~ ^[^[:space:]@]+@sha256:[0-9a-fA-F]{64}$ ]] || \
  die "E09_STACK_IMAGE must be an immutable repository digest"
[[ "$E09_PROBE_IMAGE" =~ ^[^[:space:]@]+@sha256:[0-9a-fA-F]{64}$ ]] || \
  die "E09_PROBE_IMAGE must be an immutable repository digest"
case "$E09_DRIVER_MODE" in
  operator|preinstalled) ;;
  *) die "E09_DRIVER_MODE must be operator or preinstalled" ;;
esac
for value in \
  "$E09_PILOT_BATCH_SIZE" \
  "$E09_PILOT_ADMISSION_WINDOW_SECONDS" \
  "$E09_PILOT_HOLD_SECONDS" \
  "$E09_MIG_TIMEOUT_SECONDS" \
  "$E09_DRA_RESTART_TIMEOUT_SECONDS" \
  "$E09_PILOT_WARMUP_TIMEOUT_SECONDS" \
  "$E09_PILOT_BATCH_CLEANUP_TIMEOUT_SECONDS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || \
    die "pilot counts and timeouts must be positive integers"
done
(( E09_PILOT_HOLD_SECONDS > E09_PILOT_ADMISSION_WINDOW_SECONDS + 5 )) || \
  die "hold time must exceed the admission window by more than five seconds"

kube() {
  kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" "$@"
}

CURRENT_CONTEXT="$(kube config current-context)"
[[ "$CURRENT_CONTEXT" == "$KUBE_CONTEXT" ]] || \
  die "current context ${CURRENT_CONTEXT} does not match ${KUBE_CONTEXT}"
API_SERVER="$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$API_SERVER" == *"$EXPECTED_API_SERVER_SUBSTRING"* ]] || \
  die "API server ${API_SERVER} does not contain the expected ACK identity"

PREFLIGHT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hooke-e09-pilot-preflight.XXXXXX")"
cleanup_preflight() {
  if [[ "$PREFLIGHT_DIR" == "${TMPDIR:-/tmp}"/hooke-e09-pilot-preflight.* ]]; then
    rm -rf -- "$PREFLIGHT_DIR"
  fi
}
trap cleanup_preflight EXIT

kube version -o json --request-timeout=15s >"$PREFLIGHT_DIR/kubernetes-version.json"
SERVER_MAJOR="$(jq -er '.serverVersion.major | sub("[^0-9].*$"; "") | tonumber' \
  "$PREFLIGHT_DIR/kubernetes-version.json")"
SERVER_MINOR="$(jq -er '.serverVersion.minor | sub("[^0-9].*$"; "") | tonumber' \
  "$PREFLIGHT_DIR/kubernetes-version.json")"
SERVER_PATCH="$(jq -er '
  .serverVersion.gitVersion
  | capture("^v[0-9]+\\.[0-9]+\\.(?<patch>[0-9]+)")
  | .patch | tonumber
' "$PREFLIGHT_DIR/kubernetes-version.json")"
SERVER_VERSION="v${SERVER_MAJOR}.${SERVER_MINOR}.${SERVER_PATCH}"
(( SERVER_MAJOR > 1 || (SERVER_MAJOR == 1 && (SERVER_MINOR > 34 || (SERVER_MINOR == 34 && SERVER_PATCH >= 2))) )) || \
  die "E09 pilot requires Kubernetes >=1.34.2"
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
  die "configured stack image does not match image metadata"
[[ "${E09_PROBE_IMAGE:-}" == "$CONFIGURED_PROBE_IMAGE" ]] || \
  die "configured probe image does not match image metadata"
[[ "${E09_IMAGE_PLATFORM:-}" =~ ^linux/(amd64|arm64)$ ]] || \
  die "E09 image metadata has an invalid target platform"
IMAGE_ARCH="${E09_IMAGE_PLATFORM#linux/}"

"$PILOT_HELPER" make-plan \
  --node-a "$E09_PILOT_NODE_A" \
  --node-b "$E09_PILOT_NODE_B" \
  --static-config "$E09_PILOT_STATIC_CONFIG" \
  --profile-map "$E09_PILOT_PROFILE_MAP" \
  --sequence "$E09_PILOT_SEQUENCE" \
  --batch-size "$E09_PILOT_BATCH_SIZE" \
  --hold-seconds "$E09_PILOT_HOLD_SECONDS" \
  --admission-window-seconds "$E09_PILOT_ADMISSION_WINDOW_SECONDS" \
  --output "$PREFLIGHT_DIR/plan.json"

kube get nodes -o json >"$PREFLIGHT_DIR/nodes.json"
kube get pods --all-namespaces -o json >"$PREFLIGHT_DIR/pods.json"
kube get deviceclasses.resource.k8s.io -o json \
  >"$PREFLIGHT_DIR/deviceclasses.json"
kube get resourceslices.resource.k8s.io -o json \
  >"$PREFLIGHT_DIR/resourceslices.json"
"$PILOT_HELPER" check-preflight \
  --nodes "$PREFLIGHT_DIR/nodes.json" \
  --pods "$PREFLIGHT_DIR/pods.json" \
  --device-classes "$PREFLIGHT_DIR/deviceclasses.json" \
  --resource-slices "$PREFLIGHT_DIR/resourceslices.json" \
  --node-a "$E09_PILOT_NODE_A" \
  --node-b "$E09_PILOT_NODE_B" \
  --source-profile "$E09_PILOT_SOURCE_PROFILE" \
  --mig-strategy "$E09_PILOT_REQUIRED_MIG_STRATEGY" \
  --device-class "$E09_DEVICE_CLASS" \
  --driver "$E09_DRA_DRIVER" \
  --dra-node-label-key "$E09_DRA_NODE_LABEL_KEY" \
  --dra-node-label-value "$E09_DRA_NODE_LABEL_VALUE" \
  --product-regex "$E09_PILOT_GPU_PRODUCT_REGEX" \
  --control-selector-key "$E09_CONTROL_NODE_SELECTOR_KEY" \
  --control-selector-value "$E09_CONTROL_NODE_SELECTOR_VALUE" \
  --output "$PREFLIGHT_DIR/preflight-summary.json"

for target_node in "$E09_PILOT_NODE_A" "$E09_PILOT_NODE_B"; do
  jq -e \
    --arg node "$target_node" \
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
    die "GPU node ${target_node} architecture or taint is incorrect"
done

component_pod_on_node() {
  local namespace="$1" selector="$2" container="$3" node="$4" output="$5"
  kube -n "$namespace" get pods -l "$selector" -o json >"$output"
  jq -e \
    --arg node "$node" \
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
kube -n "$E09_MIG_MANAGER_NAMESPACE" get pods \
  -l "$E09_MIG_MANAGER_POD_SELECTOR" -o json \
  >"$PREFLIGHT_DIR/mig-manager-pods.json"
kube -n "$E09_DRA_NAMESPACE" get pods \
  -l "$E09_DRA_POD_SELECTOR" -o json \
  >"$PREFLIGHT_DIR/dra-pods.json"

for target_node in "$E09_PILOT_NODE_A" "$E09_PILOT_NODE_B"; do
  if [[ "$E09_DRIVER_MODE" == operator ]]; then
    component_pod_on_node \
      "$E09_GPU_OPERATOR_NAMESPACE" "$E09_DRIVER_POD_SELECTOR" \
      "$E09_DRIVER_CONTAINER" "$target_node" \
      "$PREFLIGHT_DIR/driver-pods-${target_node}.json" || \
      die "one Ready NVIDIA driver Pod is required on ${target_node}"
  else
    jq -e \
      --arg node "$target_node" '
      [.items[] | select(
        .spec.nodeName == $node
        and (.status.phase // "") != "Succeeded"
        and (.status.phase // "") != "Failed"
      )] | length == 0
    ' "$PREFLIGHT_DIR/driver-pods.json" >/dev/null || \
      die "preinstalled driver mode forbids driver Pods on ${target_node}"
  fi
  component_pod_on_node \
    "$E09_MIG_MANAGER_NAMESPACE" "$E09_MIG_MANAGER_POD_SELECTOR" \
    "$E09_MIG_MANAGER_CONTAINER" "$target_node" \
    "$PREFLIGHT_DIR/mig-manager-pods-${target_node}.json" || \
    die "one Ready MIG Manager Pod is required on ${target_node}"
  component_pod_on_node \
    "$E09_DRA_NAMESPACE" "$E09_DRA_POD_SELECTOR" \
    "$E09_DRA_CONTAINER" "$target_node" \
    "$PREFLIGHT_DIR/dra-pods-${target_node}.json" || \
    die "one Ready NVIDIA DRA plugin Pod is required on ${target_node}"
  jq -e \
    --arg node "$target_node" \
    --arg key "$E09_DRA_NODE_LABEL_KEY" \
    --arg value "$E09_DRA_NODE_LABEL_VALUE" '
    any(.items[];
      .spec.nodeName == $node
      and .spec.nodeSelector[$key] == $value)
  ' "$PREFLIGHT_DIR/dra-pods.json" >/dev/null || \
    die "DRA plugin on ${target_node} does not use the frozen selector"
  jq -e \
    --arg node "$target_node" \
    --arg configmap "$E09_GPU_CLIENTS_CONFIGMAP" '
    any(.items[];
      .spec.nodeName == $node
      and any(.spec.volumes[]?;
        .configMap.name == $configmap))
  ' "$PREFLIGHT_DIR/mig-manager-pods.json" >/dev/null || \
    die "MIG Manager on ${target_node} does not mount GPU clients config"
done

if [[ "$E09_DRIVER_MODE" == operator ]]; then
  for target_node in "$E09_PILOT_NODE_A" "$E09_PILOT_NODE_B"; do
    jq -e \
      --arg node "$target_node" \
      --arg label "$E09_DRA_NODE_LABEL_KEY" '
      any(
        .items[]
        | select(.spec.nodeName == $node)
        | ((.spec.initContainers // []) + (.spec.containers // []))[]
        | (.env // [])[];
        .name == "NODE_LABEL_FOR_GPU_POD_EVICTION"
        and .value == $label
      )
    ' "$PREFLIGHT_DIR/driver-pods.json" >/dev/null || \
      die "driver manager on ${target_node} lacks DRA eviction label"
  done
fi

if [[ -n "$E09_DEVICE_PLUGIN_POD_SELECTOR" ]]; then
  kube -n "$E09_DEVICE_PLUGIN_NAMESPACE" get pods \
    -l "$E09_DEVICE_PLUGIN_POD_SELECTOR" -o json \
    >"$PREFLIGHT_DIR/device-plugin-pods.json"
  jq -e \
    --arg a "$E09_PILOT_NODE_A" \
    --arg b "$E09_PILOT_NODE_B" '
    [.items[] | select(
      (.spec.nodeName == $a or .spec.nodeName == $b)
      and (.status.phase // "") != "Succeeded"
      and (.status.phase // "") != "Failed"
    )] | length == 0
  ' "$PREFLIGHT_DIR/device-plugin-pods.json" >/dev/null || \
    die "legacy NVIDIA Device Plugin must be disabled on both pilot nodes"
fi

resolve_component_pod() {
  local namespace="$1" selector="$2" container="$3" node="$4"
  kube -n "$namespace" get pods -l "$selector" -o json |
    jq -r \
      --arg node "$node" \
      --arg container "$container" '
      [.items[] | select(
        .spec.nodeName == $node
        and .status.phase == "Running"
        and any(.status.containerStatuses[]?;
          .name == $container and .ready == true)
      )] | if length == 1 then .[0].metadata.name else "" end
    '
}

if [[ "$E09_DRIVER_MODE" == operator ]]; then
  SMI_NAMESPACE="$E09_GPU_OPERATOR_NAMESPACE"
  SMI_SELECTOR="$E09_DRIVER_POD_SELECTOR"
  SMI_CONTAINER="$E09_DRIVER_CONTAINER"
else
  SMI_NAMESPACE="$E09_MIG_MANAGER_NAMESPACE"
  SMI_SELECTOR="$E09_MIG_MANAGER_POD_SELECTOR"
  SMI_CONTAINER="$E09_MIG_MANAGER_CONTAINER"
fi
for target_node in "$E09_PILOT_NODE_A" "$E09_PILOT_NODE_B"; do
  smi_pod="$(resolve_component_pod \
    "$SMI_NAMESPACE" "$SMI_SELECTOR" "$SMI_CONTAINER" "$target_node")"
  [[ -n "$smi_pod" ]] || die "nvidia-smi provider missing on ${target_node}"
  kube -n "$SMI_NAMESPACE" exec "$smi_pod" -c "$SMI_CONTAINER" -- \
    nvidia-smi -L >"$PREFLIGHT_DIR/nvidia-smi-${target_node}.txt"
  [[ "$(grep -Ec '^GPU [0-9]+:' "$PREFLIGHT_DIR/nvidia-smi-${target_node}.txt")" -eq 1 ]] || \
    die "${target_node} must expose exactly one physical GPU"
  grep -Eiq "$E09_PILOT_GPU_PRODUCT_REGEX" \
    "$PREFLIGHT_DIR/nvidia-smi-${target_node}.txt" || \
    die "${target_node} is not the configured A100 product"
done

kube -n "$E09_MIG_MANAGER_NAMESPACE" get configmap "$E09_MIG_CONFIGMAP" \
  -o json |
  jq -er --arg key "$E09_MIG_CONFIGMAP_KEY" '.data[$key]' \
    >"$PREFLIGHT_DIR/mig-config.yaml"
kube -n "$E09_MIG_MANAGER_NAMESPACE" get configmap \
  "$E09_GPU_CLIENTS_CONFIGMAP" -o json |
  jq -er --arg key "$E09_GPU_CLIENTS_CONFIGMAP_KEY" '.data[$key]' \
    >"$PREFLIGHT_DIR/gpu-clients.yaml"
grep -Eq '^[[:space:]]*-[[:space:]]+nvidia-persistenced\.service[[:space:]]*$' \
  "$PREFLIGHT_DIR/gpu-clients.yaml" || \
  die "MIG Manager GPU clients config must stop nvidia-persistenced.service"
mapfile -t REQUIRED_MIG_CONFIGS < <(
  jq -r '
    [
      .strategies["static-balanced"].mig_config,
      (.strategies["dynamic-homogeneous"].profile_map | to_entries[].value)
    ] | unique[]
  ' "$PREFLIGHT_DIR/plan.json"
)
for config_name in "${REQUIRED_MIG_CONFIGS[@]}"; do
  grep -Fxq "  ${config_name}:" "$PREFLIGHT_DIR/mig-config.yaml" || \
    die "MIG Manager ConfigMap does not define ${config_name}"
done

if kube get namespace "$E09_PILOT_WORKLOAD_NAMESPACE" >/dev/null 2>&1; then
  die "pilot workload Namespace already exists"
fi
if kube -n "$E09_PILOT_LOCK_NAMESPACE" get lease "$E09_PILOT_LOCK_NAME" \
  >/dev/null 2>&1; then
  die "another E09 pilot holds the experiment Lease"
fi

QUIESCE_LABEL_KEY="hooke.io/e09-pilot-gpu-client"
IFS=',' read -r -a QUIESCE_DAEMONSETS <<<"$E09_PILOT_QUIESCE_DAEMONSETS"
[[ "${#QUIESCE_DAEMONSETS[@]}" -gt 0 ]] || \
  die "at least one GPU client DaemonSet must be configured"
for reference in "${QUIESCE_DAEMONSETS[@]}"; do
  namespace="${reference%%/*}"
  name="${reference#*/}"
  [[ -n "$namespace" && -n "$name" && "$namespace" != "$name" ]] || \
    die "invalid DaemonSet reference: ${reference}"
  kube -n "$namespace" get "daemonset/${name}" -o json \
    >"$PREFLIGHT_DIR/daemonset-${namespace}--${name}.json"
  jq -e --arg key "$QUIESCE_LABEL_KEY" '
    ((.spec.template.spec.nodeSelector // {}) | has($key)) | not
  ' "$PREFLIGHT_DIR/daemonset-${namespace}--${name}.json" >/dev/null || \
    die "${reference} already uses reserved selector ${QUIESCE_LABEL_KEY}"
done

can_i() {
  local verb="$1" resource="$2" namespace="${3:-}"
  local result
  if [[ -n "$namespace" ]]; then
    result="$(kube auth can-i "$verb" "$resource" -n "$namespace")"
  else
    result="$(kube auth can-i "$verb" "$resource" --all-namespaces)"
  fi
  [[ "$result" == yes ]] || \
    die "RBAC denied: ${verb} ${resource} ${namespace:+in ${namespace}}"
}

can_i patch nodes
can_i get nodes
can_i create namespaces
can_i delete namespaces
can_i create pods "$E09_PILOT_WORKLOAD_NAMESPACE"
can_i get pods "$E09_PILOT_WORKLOAD_NAMESPACE"
can_i get pods/log "$E09_PILOT_WORKLOAD_NAMESPACE"
can_i delete pods "$E09_PILOT_WORKLOAD_NAMESPACE"
can_i create resourceclaims.resource.k8s.io "$E09_PILOT_WORKLOAD_NAMESPACE"
can_i get resourceclaims.resource.k8s.io "$E09_PILOT_WORKLOAD_NAMESPACE"
can_i delete resourceclaims.resource.k8s.io "$E09_PILOT_WORKLOAD_NAMESPACE"
can_i delete pods "$E09_DRA_NAMESPACE"
can_i create leases.coordination.k8s.io "$E09_PILOT_LOCK_NAMESPACE"
can_i delete leases.coordination.k8s.io "$E09_PILOT_LOCK_NAMESPACE"
for reference in "${QUIESCE_DAEMONSETS[@]}"; do
  can_i patch daemonsets.apps "${reference%%/*}"
done

log "E09 pilot read-only preflight PASS: two equivalent A100 nodes, ${SERVER_VERSION}"
if [[ "$CHECK_ONLY" == true ]]; then
  log "E09 pilot check-only PASS; no cluster state was changed"
  exit 0
fi
[[ "$CONFIRM_E09_PILOT_EXECUTION" == yes ]] || \
  die "set CONFIRM_E09_PILOT_EXECUTION=yes to create pilot resources"
[[ "$CONFIRM_MIG_RECONFIGURATION" == yes ]] || \
  die "set CONFIRM_MIG_RECONFIGURATION=yes to authorize real MIG changes"

RUN_STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
RUN_ID="$("$PILOT_HELPER" new-run-id)"
ARTIFACT_DIR="${ARTIFACT_ROOT}/e09-gpu-dra-mig-pilot-${RUN_STAMP}"
mkdir -p "$ARTIFACT_DIR"
chmod 700 "$ARTIFACT_DIR"
cp "$PREFLIGHT_DIR"/* "$ARTIFACT_DIR/"
git status --short >"$ARTIFACT_DIR/git-status.txt"
git rev-parse HEAD >"$ARTIFACT_DIR/git-commit.txt"
cp "$E09_IMAGE_METADATA_FILE" "$ARTIFACT_DIR/image-metadata.env"
printf '%s\n' "$RUN_ID" >"$ARTIFACT_DIR/run-id.txt"
jq -n \
  --arg run_id "$RUN_ID" \
  --arg context "$KUBE_CONTEXT" \
  --arg api_server "$API_SERVER" \
  --arg cluster_id "$CLUSTER_ID" \
  --arg node_a "$E09_PILOT_NODE_A" \
  --arg node_b "$E09_PILOT_NODE_B" \
  --arg source_profile "$E09_PILOT_SOURCE_PROFILE" \
  --arg strategy "$E09_PILOT_REQUIRED_MIG_STRATEGY" \
  --arg stack_image "$CONFIGURED_STACK_IMAGE" \
  --arg probe_image "$CONFIGURED_PROBE_IMAGE" '{
    run_id: $run_id,
    kube_context: $context,
    api_server: $api_server,
    cluster_id: $cluster_id,
    nodes: [$node_a, $node_b],
    source_profile: $source_profile,
    mig_strategy: $strategy,
    stack_image: $stack_image,
    probe_image: $probe_image
  }' >"$ARTIFACT_DIR/frozen-config.json"

LOCK_CREATED=false
WORKLOAD_NAMESPACE_CREATED=false
SUCCESS=false
CLIENTS_QUIESCED=false
declare -A PROFILE_TOUCHED=()
BACKGROUND_PIDS=()

wait_mig_transition() {
  local node="$1" profile="$2" output="$3" require_transition="${4:-true}"
  local deadline=$((SECONDS + E09_MIG_TIMEOUT_SECONDS))
  local saw_transition=false
  : >"$output"
  while (( SECONDS < deadline )); do
    local observed object current_profile current_state
    observed="$(now_ns)"
    if ! object="$(kube get node "$node" -o json 2>/dev/null)"; then
      jq -cn --argjson observed "$observed" \
        '{observed_time_ns:$observed,api_reachable:false}' >>"$output"
      sleep 2
      continue
    fi
    current_profile="$(jq -r '.metadata.labels["nvidia.com/mig.config"] // ""' \
      <<<"$object")"
    current_state="$(jq -r '.metadata.labels["nvidia.com/mig.config.state"] // ""' \
      <<<"$object")"
    jq -cn \
      --argjson observed "$observed" \
      --arg profile "$current_profile" \
      --arg state "$current_state" \
      '{observed_time_ns:$observed,profile:$profile,state:$state}' >>"$output"
    [[ "$current_state" != failed ]] || return 1
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
  local node="$1" prefix="$2"
  local before old_uid old_name deadline
  before="$(kube -n "$E09_DRA_NAMESPACE" get pods \
    -l "$E09_DRA_POD_SELECTOR" -o json)"
  printf '%s\n' "$before" >"${prefix}-before.json"
  old_uid="$(jq -r \
    --arg node "$node" \
    --arg container "$E09_DRA_CONTAINER" '
    [.items[] | select(
      .spec.nodeName == $node
      and any(.status.containerStatuses[]?;
        .name == $container and .ready == true)
    )] | if length == 1 then .[0].metadata.uid else "" end
  ' <<<"$before")"
  old_name="$(jq -r \
    --arg uid "$old_uid" '
    [.items[] | select(.metadata.uid == $uid)]
    | if length == 1 then .[0].metadata.name else "" end
  ' <<<"$before")"
  [[ -n "$old_uid" && -n "$old_name" ]] || return 1
  kube -n "$E09_DRA_NAMESPACE" logs "$old_name" -c "$E09_DRA_CONTAINER" \
    >"${prefix}-before.log" 2>&1 || true
  kube -n "$E09_DRA_NAMESPACE" delete pod "$old_name" --wait=false \
    >/dev/null || return 1
  deadline=$((SECONDS + E09_DRA_RESTART_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local after new_uid new_name
    after="$(kube -n "$E09_DRA_NAMESPACE" get pods \
      -l "$E09_DRA_POD_SELECTOR" -o json)"
    new_uid="$(jq -r \
      --arg node "$node" \
      --arg old "$old_uid" \
      --arg container "$E09_DRA_CONTAINER" '
      [.items[] | select(
        .spec.nodeName == $node
        and .metadata.uid != $old
        and .status.phase == "Running"
        and any(.status.containerStatuses[]?;
          .name == $container and .ready == true)
      )] | if length == 1 then .[0].metadata.uid else "" end
    ' <<<"$after")"
    if [[ -n "$new_uid" ]]; then
      printf '%s\n' "$after" >"${prefix}-after.json"
      new_name="$(jq -r \
        --arg uid "$new_uid" '
        [.items[] | select(.metadata.uid == $uid)]
        | if length == 1 then .[0].metadata.name else "" end
      ' <<<"$after")"
      kube -n "$E09_DRA_NAMESPACE" logs "$new_name" -c "$E09_DRA_CONTAINER" \
        >"${prefix}-after.log" 2>&1 || true
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_resource_slice() {
  local node="$1" geometry="$2" expected_csv="$3" output="$4"
  local deadline=$((SECONDS + E09_DRA_RESTART_TIMEOUT_SECONDS))
  local expected_json
  expected_json="$(jq -cn --arg value "$expected_csv" \
    '$value | split(",") | map(select(length > 0))')"
  while (( SECONDS < deadline )); do
    kube get resourceslices.resource.k8s.io -o json >"$output"
    if jq -e \
      --arg node "$node" \
      --arg driver "$E09_DRA_DRIVER" \
      --arg geometry "$geometry" \
      --argjson expected "$expected_json" '
      def attr($device; $name):
        $device.attributes[$name].string
        // $device.attributes["gpu.nvidia.com/" + $name].string
        // $device.attributes["gpu.nvidia.com"][$name].string
        // $device.basic.attributes[$name].string
        // "";
      [.items[] | select(
        .spec.nodeName == $node and .spec.driver == $driver
      )] as $slices
      | [$slices[0].spec.devices[]? | {
          type: attr(.; "type"),
          profile: attr(.; "profile")
        }] as $devices
      | (($slices | length) == 1
        and ($slices[0].spec.pool.name // "") != ""
        and ($slices[0].spec.pool.resourceSliceCount // 0) == 1)
        and (
          if $geometry == "full" then
              ($devices | length) == 1 and $devices[0].type == "gpu"
            elif $geometry == "dynamic" then
              ($devices | length) > 0
              and all($devices[]; .type == "mig")
              and all($devices[]; .profile == $expected[0])
            else
              ($devices | length) > 0
              and all($devices[]; .type == "mig")
              and all(
                $expected[];
                . as $profile | any($devices[]; .profile == $profile)
              )
            end
        )
    ' "$output" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ensure_profile() {
  local node="$1" config_name="$2" geometry="$3" expected_csv="$4" prefix="$5"
  mkdir -p "$prefix"
  kube get node "$node" -o json >"$prefix/node-before.json"
  local current_profile current_state requested_ns requested_at request_id
  current_profile="$(jq -r '.metadata.labels["nvidia.com/mig.config"] // ""' \
    "$prefix/node-before.json")"
  current_state="$(jq -r '.metadata.labels["nvidia.com/mig.config.state"] // ""' \
    "$prefix/node-before.json")"
  if [[ "$current_profile" == "$config_name" && "$current_state" == success ]]; then
    wait_resource_slice "$node" "$geometry" "$expected_csv" \
      "$prefix/resourceslices.json" || return 1
    local ready_ns
    ready_ns="$(now_ns)"
    jq -n \
      --arg node "$node" \
      --arg config "$config_name" \
      --argjson ready "$ready_ns" '{
        node:$node,
        config:$config,
        changed:false,
        reshape_requested_time_ns:null,
        reshape_finished_time_ns:null,
        ready_time_ns:$ready
      }' >"$prefix/result.json"
    cp "$prefix/node-before.json" "$prefix/node-after.json"
    return 0
  fi

  requested_ns="$(now_ns)"
  requested_at="$(date -u +'%Y-%m-%dT%H:%M:%S.%NZ')"
  request_id="e09p-${RUN_ID,,}-$(basename "$prefix" | tr -c 'a-z0-9-' '-')"
  jq -n \
    --arg profile "$config_name" \
    --arg run_id "$RUN_ID" \
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
    }' >"$prefix/node-patch.json"
  PROFILE_TOUCHED["$node"]=true
  kube patch node "$node" --type=merge --patch-file "$prefix/node-patch.json" \
    >/dev/null
  wait_mig_transition "$node" "$config_name" \
    "$prefix/mig-observations.ndjson" true || return 1
  local finished_ns
  finished_ns="$(tail -n 1 "$prefix/mig-observations.ndjson" |
    jq -er '.observed_time_ns')"
  kube get node "$node" -o json >"$prefix/node-after.json"
  kube -n "$E09_MIG_MANAGER_NAMESPACE" logs \
    -l "$E09_MIG_MANAGER_POD_SELECTOR" \
    -c "$E09_MIG_MANAGER_CONTAINER" \
    --since-time="$requested_at" --prefix=true \
    >"$prefix/mig-manager.log" 2>&1 || true
  restart_dra_plugin "$node" "$prefix/dra-plugin" || return 1
  wait_resource_slice "$node" "$geometry" "$expected_csv" \
    "$prefix/resourceslices.json" || return 1
  local ready_ns
  ready_ns="$(now_ns)"
  jq -n \
    --arg node "$node" \
    --arg config "$config_name" \
    --argjson requested "$requested_ns" \
    --argjson finished "$finished_ns" \
    --argjson ready "$ready_ns" '{
      node:$node,
      config:$config,
      changed:true,
      reshape_requested_time_ns:$requested,
      reshape_finished_time_ns:$finished,
      ready_time_ns:$ready
    }' >"$prefix/result.json"
}

restore_node() {
  local node="$1" prefix="$2"
  local initial="$ARTIFACT_DIR/node-initial-${node}.json"
  mkdir -p "$prefix"
  kube get node "$node" -o json >"$prefix/node-before.json"
  local current_profile current_state changed=false
  current_profile="$(jq -r '.metadata.labels["nvidia.com/mig.config"] // ""' \
    "$prefix/node-before.json")"
  current_state="$(jq -r '.metadata.labels["nvidia.com/mig.config.state"] // ""' \
    "$prefix/node-before.json")"
  jq \
    --arg profile "$E09_PILOT_SOURCE_PROFILE" '{
      metadata: {
        labels: {"nvidia.com/mig.config": $profile},
        annotations: {
          "hooke.io/mig-run-id": (.metadata.annotations["hooke.io/mig-run-id"] // null),
          "hooke.io/mig-request-id": (.metadata.annotations["hooke.io/mig-request-id"] // null),
          "hooke.io/mig-request-profile": (.metadata.annotations["hooke.io/mig-request-profile"] // null),
          "hooke.io/mig-requested-at": (.metadata.annotations["hooke.io/mig-requested-at"] // null)
        }
      }
    }' "$initial" >"$prefix/node-patch.json"
  if [[ "$current_profile" != "$E09_PILOT_SOURCE_PROFILE" || "$current_state" != success ]]; then
    changed=true
  fi
  kube patch node "$node" --type=merge --patch-file "$prefix/node-patch.json" \
    >/dev/null || return 1
  if [[ "$changed" == true ]]; then
    wait_mig_transition "$node" "$E09_PILOT_SOURCE_PROFILE" \
      "$prefix/mig-observations.ndjson" false || return 1
  fi
  restart_dra_plugin "$node" "$prefix/dra-plugin" || return 1
  wait_resource_slice "$node" full "" "$prefix/resourceslices.json" || return 1
  kube get node "$node" -o json >"$prefix/node-after.json"
  jq -e \
    --arg profile "$E09_PILOT_SOURCE_PROFILE" '
    .metadata.labels["nvidia.com/mig.config"] == $profile
    and .metadata.labels["nvidia.com/mig.config.state"] == "success"
  ' "$prefix/node-after.json" >/dev/null
}

wait_daemonset_off_targets() {
  local namespace="$1" name="$2" uid="$3"
  local deadline=$((SECONDS + E09_DRA_RESTART_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local pods
    pods="$(kube -n "$namespace" get pods -o json)"
    if jq -e \
      --arg uid "$uid" \
      --arg a "$E09_PILOT_NODE_A" \
      --arg b "$E09_PILOT_NODE_B" '
      [.items[] | select(
        (.spec.nodeName == $a or .spec.nodeName == $b)
        and (.status.phase // "") != "Succeeded"
        and (.status.phase // "") != "Failed"
        and any(.metadata.ownerReferences[]?; .uid == $uid)
      )] | length == 0
    ' <<<"$pods" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

quiesce_gpu_clients() {
  local root="$ARTIFACT_DIR/gpu-client-daemonsets"
  mkdir -p "$root"
  CLIENTS_QUIESCED=true
  for reference in "${QUIESCE_DAEMONSETS[@]}"; do
    local namespace="${reference%%/*}" name="${reference#*/}"
    local prefix="$root/${namespace}--${name}" uid patch
    kube -n "$namespace" get "daemonset/${name}" -o json \
      >"${prefix}-before.json"
    uid="$(jq -er '.metadata.uid' "${prefix}-before.json")"
    jq '.spec.template.spec.nodeSelector // null' \
      "${prefix}-before.json" >"${prefix}-selector-original.json"
    jq --arg key "$QUIESCE_LABEL_KEY" '
      (.spec.template.spec.nodeSelector // {}) + {($key): "quiesced"}
    ' "${prefix}-before.json" >"${prefix}-selector-patched.json"
    patch="$(jq -cn \
      --slurpfile selector "${prefix}-selector-patched.json" \
      '{spec:{template:{spec:{nodeSelector:$selector[0]}}}}')"
    kube -n "$namespace" patch "daemonset/${name}" --type=merge \
      -p "$patch" >/dev/null
    : >"${prefix}-applied"
    kube -n "$namespace" get "daemonset/${name}" -o json \
      >"${prefix}-quiesced.json"
    wait_daemonset_off_targets "$namespace" "$name" "$uid" || return 1
  done
}

restore_gpu_clients() {
  local root="$ARTIFACT_DIR/gpu-client-daemonsets"
  local failed=false
  for reference in "${QUIESCE_DAEMONSETS[@]}"; do
    local namespace="${reference%%/*}" name="${reference#*/}"
    local prefix="$root/${namespace}--${name}" current patch
    [[ -f "${prefix}-applied" ]] || continue
    current="$(kube -n "$namespace" get "daemonset/${name}" -o json)" || {
      failed=true
      continue
    }
    if ! jq -e \
      --slurpfile expected "${prefix}-selector-patched.json" '
      (.spec.template.spec.nodeSelector // null) == $expected[0]
    ' <<<"$current" >/dev/null; then
      warn "${reference} changed while quiesced; refusing to overwrite it"
      failed=true
      continue
    fi
    patch="$(jq -cn \
      --slurpfile selector "${prefix}-selector-original.json" \
      '{spec:{template:{spec:{nodeSelector:$selector[0]}}}}')"
    if ! kube -n "$namespace" patch "daemonset/${name}" --type=merge \
      -p "$patch" >/dev/null; then
      failed=true
      continue
    fi
    if ! kube -n "$namespace" rollout status "daemonset/${name}" \
      --timeout=5m >/dev/null; then
      failed=true
    fi
    kube -n "$namespace" get "daemonset/${name}" -o json \
      >"${prefix}-restored.json" || failed=true
    kube -n "$namespace" get pods -o json \
      >"${prefix}-pods-restored.json" || failed=true
  done
  [[ "$failed" == false ]]
}

wait_pod_phase() {
  local namespace="$1" name="$2" desired="$3" timeout_seconds="$4"
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    local phase
    phase="$(kube -n "$namespace" get "pod/${name}" \
      -o jsonpath='{.status.phase}' 2>/dev/null)" || {
      sleep 1
      continue
    }
    [[ "$phase" != Failed ]] || return 1
    [[ "$phase" == "$desired" ]] && return 0
    sleep 1
  done
  return 1
}

warmup_node() {
  local node="$1" profile="$2" suffix="$3"
  local root="$ARTIFACT_DIR/warmup-${suffix}"
  local claim="e09-warm-${suffix}" pod="e09-warm-${suffix}" claim_uid
  mkdir -p "$root"
  "$E09_HELPER" render-claim \
    --namespace "$E09_PILOT_WORKLOAD_NAMESPACE" \
    --name "$claim" \
    --run-id "$RUN_ID" \
    --device-class "$E09_DEVICE_CLASS" \
    --profile "$profile" \
    --experiment e09-pilot \
    --output "$root/claim.json"
  kube apply -f "$root/claim.json" >/dev/null
  claim_uid="$(kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" get \
    "resourceclaim/${claim}" -o jsonpath='{.metadata.uid}')"
  "$E09_HELPER" render-probe \
    --namespace "$E09_PILOT_WORKLOAD_NAMESPACE" \
    --name "$pod" \
    --cluster-id "$CLUSTER_ID" \
    --run-id "$RUN_ID" \
    --image "$CONFIGURED_PROBE_IMAGE" \
    --target-node "$node" \
    --claim-name "$claim" \
    --claim-uid "$claim_uid" \
    --device-class "$E09_DEVICE_CLASS" \
    --hold-seconds 0 \
    --experiment e09-pilot \
    --role warmup \
    --taint-key "$E09_GPU_TAINT_KEY" \
    --taint-value "$E09_GPU_TAINT_VALUE" \
    --taint-effect "$E09_GPU_TAINT_EFFECT" \
    --output "$root/pod.json"
  kube apply -f "$root/pod.json" >/dev/null
  if ! wait_pod_phase \
    "$E09_PILOT_WORKLOAD_NAMESPACE" "$pod" Succeeded \
    "$E09_PILOT_WARMUP_TIMEOUT_SECONDS"; then
    kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" describe "pod/${pod}" \
      >"$root/pod-describe.txt" 2>&1 || true
    return 1
  fi
  kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" logs "$pod" -c cuda-probe \
    >"$root/cuda.log"
  grep -q '"hooke_event_type":"FIRST_CUDA_SUCCESS"' "$root/cuda.log" || \
    return 1
  grep -Fqi "MIG ${profile}" "$root/cuda.log" || return 1
  kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" delete pod "$pod" \
    --wait=true --timeout=2m >/dev/null
  kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" delete resourceclaim "$claim" \
    --wait=true --timeout=2m >/dev/null
}

run_batch() {
  local strategy="$1" node="$2" profile="$3" config_name="$4"
  local period="$5" trial="$6" request_ns="$7" profile_ready_ns="$8"
  local mismatch="$9" reshape_requested="${10}" reshape_finished="${11}"
  local root="${12}"
  local code batch_id label prefix
  [[ "$strategy" == static-balanced ]] && code=static || code=dynamic
  batch_id="p${period}-t$(printf '%02d' "$trial")-${code}"
  label="hooke.io/e09-pilot-batch=${batch_id}"
  prefix="e09-p${period}t$(printf '%02d' "$trial")-${code}"
  mkdir -p "$root/claims" "$root/pods" "$root/logs"
  kube get resourceslices.resource.k8s.io -o json \
    >"$root/resourceslices.json"

  local index claim claim_uid pod manifest temporary
  for ((index = 1; index <= E09_PILOT_BATCH_SIZE; index++)); do
    claim="${prefix}-$(printf '%02d' "$index")"
    manifest="$root/claims/${claim}.json"
    "$E09_HELPER" render-claim \
      --namespace "$E09_PILOT_WORKLOAD_NAMESPACE" \
      --name "$claim" \
      --run-id "$RUN_ID" \
      --device-class "$E09_DEVICE_CLASS" \
      --profile "$profile" \
      --experiment e09-pilot \
      --output "$manifest"
    temporary="${manifest}.labeled"
    jq --arg batch "$batch_id" --arg strategy "$strategy" '
      .metadata.labels["hooke.io/e09-pilot-batch"] = $batch
      | .metadata.labels["hooke.io/e09-pilot-strategy"] = $strategy
    ' "$manifest" >"$temporary"
    mv "$temporary" "$manifest"
    kube apply -f "$manifest" >/dev/null
    claim_uid="$(kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" get \
      "resourceclaim/${claim}" -o jsonpath='{.metadata.uid}')"
    printf '%s\n' "$claim_uid" >"$root/claims/${claim}.uid"
    pod="$claim"
    manifest="$root/pods/${pod}.json"
    "$E09_HELPER" render-probe \
      --namespace "$E09_PILOT_WORKLOAD_NAMESPACE" \
      --name "$pod" \
      --cluster-id "$CLUSTER_ID" \
      --run-id "$RUN_ID" \
      --image "$CONFIGURED_PROBE_IMAGE" \
      --target-node "$node" \
      --claim-name "$claim" \
      --claim-uid "$claim_uid" \
      --device-class "$E09_DEVICE_CLASS" \
      --hold-seconds "$E09_PILOT_HOLD_SECONDS" \
      --experiment e09-pilot \
      --role capacity-probe \
      --taint-key "$E09_GPU_TAINT_KEY" \
      --taint-value "$E09_GPU_TAINT_VALUE" \
      --taint-effect "$E09_GPU_TAINT_EFFECT" \
      --output "$manifest"
    temporary="${manifest}.labeled"
    jq --arg batch "$batch_id" --arg strategy "$strategy" '
      .metadata.labels["hooke.io/e09-pilot-batch"] = $batch
      | .metadata.labels["hooke.io/e09-pilot-strategy"] = $strategy
    ' "$manifest" >"$temporary"
    mv "$temporary" "$manifest"
  done

  local batch_start deadline
  batch_start="$(now_ns)"
  kube apply -f "$root/pods" >/dev/null
  deadline=$((batch_start + E09_PILOT_ADMISSION_WINDOW_SECONDS * 1000000000))
  jq -n \
    --arg run_id "$RUN_ID" \
    --argjson period "$period" \
    --argjson trial "$trial" \
    --arg strategy "$strategy" \
    --arg node "$node" \
    --arg profile "$profile" \
    --arg config "$config_name" \
    --argjson request_time "$request_ns" \
    --argjson ready_time "$profile_ready_ns" \
    --argjson batch_start "$batch_start" \
    --argjson deadline "$deadline" \
    --argjson batch_size "$E09_PILOT_BATCH_SIZE" \
    --argjson hold "$E09_PILOT_HOLD_SECONDS" \
    --argjson window "$E09_PILOT_ADMISSION_WINDOW_SECONDS" \
    --argjson mismatch "$mismatch" \
    --arg reshape_requested "$reshape_requested" \
    --arg reshape_finished "$reshape_finished" '{
      run_id:$run_id,
      period:$period,
      trial:$trial,
      strategy:$strategy,
      node:$node,
      requested_profile:$profile,
      configured_mig_profile:$config,
      request_time_ns:$request_time,
      profile_ready_time_ns:$ready_time,
      batch_apply_start_ns:$batch_start,
      admission_deadline_ns:$deadline,
      batch_size:$batch_size,
      hold_seconds:$hold,
      admission_window_seconds:$window,
      profile_mismatch:$mismatch,
      reshape_requested_time_ns:
        (if ($reshape_requested | length) > 0
         then ($reshape_requested | tonumber) else null end),
      reshape_finished_time_ns:
        (if ($reshape_finished | length) > 0
         then ($reshape_finished | tonumber) else null end)
    }' >"$root/metadata.json"

  : >"$root/observations.ndjson"
  while (( $(now_ns) < deadline )); do
    local observed pods_json claims_json
    observed="$(now_ns)"
    pods_json="$(kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" get pods \
      -l "$label" -o json)"
    claims_json="$(kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" get resourceclaims \
      -l "$label" -o json)"
    jq -cn \
      --argjson observed "$observed" \
      --argjson pods "$pods_json" \
      --argjson claims "$claims_json" '{
      observed_time_ns:$observed,
      pods:{
        total:($pods.items|length),
        pending:([$pods.items[]|select(.status.phase=="Pending")]|length),
        running:([$pods.items[]|select(.status.phase=="Running")]|length),
        succeeded:([$pods.items[]|select(.status.phase=="Succeeded")]|length),
        failed:([$pods.items[]|select(.status.phase=="Failed")]|length)
      },
      claims:{
        total:($claims.items|length),
        allocated:([
          $claims.items[]
          | select(
              ((.status.allocation.devices.results // []) | length) > 0
            )
        ]|length)
      }
    }' >>"$root/observations.ndjson"
    sleep 1
  done

  kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" get pods -l "$label" -o json \
    >"$root/pods-at-cutoff.json"
  kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" get resourceclaims -l "$label" -o json \
    >"$root/claims-at-cutoff.json"
  kube get resourceslices.resource.k8s.io -o json \
    >"$root/resourceslices-at-cutoff.json"
  while IFS= read -r pod; do
    : >"$root/logs/${pod}.log"
    kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" logs "$pod" -c cuda-probe \
      >>"$root/logs/${pod}.log" 2>/dev/null || true
  done < <(jq -r '.items[].metadata.name' "$root/pods-at-cutoff.json")

  "$PILOT_HELPER" summarize-batch \
    --metadata "$root/metadata.json" \
    --pods "$root/pods-at-cutoff.json" \
    --claims "$root/claims-at-cutoff.json" \
    --resource-slices "$root/resourceslices-at-cutoff.json" \
    --logs-dir "$root/logs" \
    --device-class "$E09_DEVICE_CLASS" \
    --driver "$E09_DRA_DRIVER" \
    --output "$root/batch-summary.json"

  kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" delete pods -l "$label" \
    --wait=false >/dev/null
  kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" delete resourceclaims -l "$label" \
    --wait=false >/dev/null
  local cleanup_deadline=$((SECONDS + E09_PILOT_BATCH_CLEANUP_TIMEOUT_SECONDS))
  while (( SECONDS < cleanup_deadline )); do
    local pod_count claim_count
    pod_count="$(kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" get pods \
      -l "$label" -o json | jq '.items | length')"
    claim_count="$(kube -n "$E09_PILOT_WORKLOAD_NAMESPACE" get resourceclaims \
      -l "$label" -o json | jq '.items | length')"
    if [[ "$pod_count" -eq 0 && "$claim_count" -eq 0 ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup_cluster() {
  local status=$?
  local cleanup_failed=false workload_cleared=true nodes_restored=true
  trap - EXIT

  for pid in "${BACKGROUND_PIDS[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  for pid in "${BACKGROUND_PIDS[@]:-}"; do
    wait "$pid" 2>/dev/null || true
  done

  if [[ "$WORKLOAD_NAMESPACE_CREATED" == true ]]; then
    if kube delete namespace "$E09_PILOT_WORKLOAD_NAMESPACE" \
      --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1; then
      WORKLOAD_NAMESPACE_CREATED=false
    else
      workload_cleared=false
      cleanup_failed=true
      warn "workload Namespace deletion was not confirmed"
    fi
  fi

  if [[ "$workload_cleared" == true ]]; then
    for node in "$E09_PILOT_NODE_A" "$E09_PILOT_NODE_B"; do
      log "Restoring ${node} to ${E09_PILOT_SOURCE_PROFILE}"
      if ! restore_node "$node" "$ARTIFACT_DIR/restore-${node}"; then
        nodes_restored=false
        cleanup_failed=true
        warn "source-profile restoration failed on ${node}"
      fi
    done
  else
    nodes_restored=false
    warn "refusing to reshape GPUs while workload deletion is uncertain"
  fi

  if [[ "$nodes_restored" == true && "$CLIENTS_QUIESCED" == true ]]; then
    if restore_gpu_clients; then
      CLIENTS_QUIESCED=false
    else
      cleanup_failed=true
      warn "one or more ACK GPU client DaemonSets were not restored"
    fi
  elif [[ "$CLIENTS_QUIESCED" == true ]]; then
    warn "GPU clients remain quiesced because GPU restoration is incomplete"
  fi

  if [[ "$LOCK_CREATED" == true ]]; then
    if [[ "$cleanup_failed" == false ]]; then
      kube -n "$E09_PILOT_LOCK_NAMESPACE" delete lease "$E09_PILOT_LOCK_NAME" \
        --ignore-not-found >/dev/null 2>&1 || cleanup_failed=true
      LOCK_CREATED=false
    else
      warn "pilot Lease preserved for manual recovery"
    fi
  fi

  if [[ -f "$ARTIFACT_DIR/summary.json" ]]; then
    local summary_temporary="$ARTIFACT_DIR/summary.json.cleanup"
    local clients_restored=true lease_released=true
    [[ "$CLIENTS_QUIESCED" == false ]] || clients_restored=false
    [[ "$LOCK_CREATED" == false ]] || lease_released=false
    if [[ "$cleanup_failed" == true ]]; then
      jq \
        --argjson workload "$workload_cleared" \
        --argjson nodes "$nodes_restored" \
        --argjson clients "$clients_restored" \
        --argjson lease "$lease_released" '
        .status = "FAIL"
        | .cleanup = {
            status:"FAIL",
            workload_namespace_deleted:$workload,
            source_profiles_restored:$nodes,
            gpu_client_daemonsets_restored:$clients,
            lease_released:$lease
          }
      ' "$ARTIFACT_DIR/summary.json" >"$summary_temporary" &&
        mv "$summary_temporary" "$ARTIFACT_DIR/summary.json"
      if [[ -f "$ARTIFACT_DIR/report.md" ]]; then
        sed 's/^Status: \\*\\*PASS\\*\\*/Status: **FAIL**/' \
          "$ARTIFACT_DIR/report.md" >"$ARTIFACT_DIR/report.md.cleanup" &&
          mv "$ARTIFACT_DIR/report.md.cleanup" "$ARTIFACT_DIR/report.md"
        printf '\nCleanup/restoration Gate: **FAIL**. The Lease was preserved for manual recovery.\n' \
          >>"$ARTIFACT_DIR/report.md"
      fi
    else
      jq '
        .cleanup = {
          status:"PASS",
          workload_namespace_deleted:true,
          source_profiles_restored:true,
          gpu_client_daemonsets_restored:true,
          lease_released:true
        }
      ' "$ARTIFACT_DIR/summary.json" >"$summary_temporary" &&
        mv "$summary_temporary" "$ARTIFACT_DIR/summary.json"
      if [[ -f "$ARTIFACT_DIR/report.md" ]]; then
        printf '\nCleanup/restoration Gate: **PASS**. Both A100s returned to the source profile and ACK GPU clients were restored.\n' \
          >>"$ARTIFACT_DIR/report.md"
      fi
    fi
  fi

  cleanup_preflight
  if [[ "$cleanup_failed" == true ]]; then
    warn "E09 pilot cleanup is incomplete; artifacts: ${ARTIFACT_DIR}"
    [[ "$status" -ne 0 ]] || status=1
  elif [[ "$SUCCESS" == true ]]; then
    log "E09 two-A100 pilot PASS; both GPUs restored; artifacts: ${ARTIFACT_DIR}"
  fi
  return "$status"
}
trap cleanup_cluster EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

jq -n \
  --arg namespace "$E09_PILOT_LOCK_NAMESPACE" \
  --arg name "$E09_PILOT_LOCK_NAME" \
  --arg holder "${USER:-hooke}@$(hostname)-${RUN_STAMP}" '{
    apiVersion:"coordination.k8s.io/v1",
    kind:"Lease",
    metadata:{namespace:$namespace,name:$name},
    spec:{holderIdentity:$holder}
  }' | kube create -f - >/dev/null
LOCK_CREATED=true

kube create namespace "$E09_PILOT_WORKLOAD_NAMESPACE" >/dev/null
WORKLOAD_NAMESPACE_CREATED=true
kube label namespace "$E09_PILOT_WORKLOAD_NAMESPACE" \
  hooke.io/experiment=e09-pilot --overwrite >/dev/null
kube annotate namespace "$E09_PILOT_WORKLOAD_NAMESPACE" \
  "hooke.io/run-id=${RUN_ID}" --overwrite >/dev/null

for node in "$E09_PILOT_NODE_A" "$E09_PILOT_NODE_B"; do
  kube get node "$node" -o json >"$ARTIFACT_DIR/node-initial-${node}.json"
done

log "Quiescing ACK GPU exporter and accelerator health clients"
quiesce_gpu_clients || die "GPU client DaemonSets did not leave both A100 nodes"

EXPECTED_PROFILES_CSV="$(jq -r '
  .strategies["dynamic-homogeneous"].profile_map | keys | join(",")
' "$ARTIFACT_DIR/plan.json")"

for period in 1 2; do
  static_node="$(jq -r --argjson period "$period" '
    .periods[] | select(.period == $period) | .static_node
  ' "$ARTIFACT_DIR/plan.json")"
  dynamic_node="$(jq -r --argjson period "$period" '
    .periods[] | select(.period == $period) | .dynamic_node
  ' "$ARTIFACT_DIR/plan.json")"
  initial_profile="$(jq -r --argjson period "$period" '
    .periods[] | select(.period == $period) | .dynamic_initial_profile
  ' "$ARTIFACT_DIR/plan.json")"
  initial_config="$(jq -r --argjson period "$period" '
    .periods[] | select(.period == $period) | .dynamic_initial_mig_config
  ' "$ARTIFACT_DIR/plan.json")"

  log "Period ${period} setup: static=${static_node}, dynamic=${dynamic_node}"
  ensure_profile \
    "$static_node" "$E09_PILOT_STATIC_CONFIG" static \
    "$EXPECTED_PROFILES_CSV" "$ARTIFACT_DIR/period-${period}/setup-static" || \
    die "static balanced profile setup failed in period ${period}"
  ensure_profile \
    "$dynamic_node" "$initial_config" dynamic "$initial_profile" \
    "$ARTIFACT_DIR/period-${period}/setup-dynamic" || \
    die "dynamic initial profile setup failed in period ${period}"

  if [[ "$period" -eq 1 ]]; then
    log "Warming the immutable CUDA probe image on both A100 nodes"
    warmup_node "$static_node" "$initial_profile" p1-static || \
      die "static-node CUDA warmup failed"
    warmup_node "$dynamic_node" "$initial_profile" p1-dynamic || \
      die "dynamic-node CUDA warmup failed"
  fi

  trial_count="$(jq -r --argjson period "$period" '
    .periods[] | select(.period == $period) | .trials | length
  ' "$ARTIFACT_DIR/plan.json")"
  for ((trial = 1; trial <= trial_count; trial++)); do
    profile="$(jq -r \
      --argjson period "$period" --argjson trial "$trial" '
      .periods[] | select(.period == $period)
      | .trials[] | select(.trial == $trial)
      | .requested_profile
    ' "$ARTIFACT_DIR/plan.json")"
    desired_config="$(jq -r \
      --argjson period "$period" --argjson trial "$trial" '
      .periods[] | select(.period == $period)
      | .trials[] | select(.trial == $trial)
      | .dynamic_mig_config
    ' "$ARTIFACT_DIR/plan.json")"
    planned_mismatch="$(jq -r \
      --argjson period "$period" --argjson trial "$trial" '
      .periods[] | select(.period == $period)
      | .trials[] | select(.trial == $trial)
      | .planned_dynamic_mismatch
    ' "$ARTIFACT_DIR/plan.json")"
    current_config="$(kube get node "$dynamic_node" \
      -o jsonpath='{.metadata.labels.nvidia\\.com/mig\\.config}')"
    actual_mismatch=false
    [[ "$current_config" == "$desired_config" ]] || actual_mismatch=true
    [[ "$actual_mismatch" == "$planned_mismatch" ]] || \
      die "dynamic profile state diverged from the frozen plan"

    request_ns="$(now_ns)"
    trial_root="$ARTIFACT_DIR/period-${period}/trial-$(printf '%02d' "$trial")"
    mkdir -p "$trial_root"
    log "Period ${period} trial ${trial}: profile=${profile}, mismatch=${actual_mismatch}"

    run_batch \
      static-balanced "$static_node" "$profile" "$E09_PILOT_STATIC_CONFIG" \
      "$period" "$trial" "$request_ns" "$request_ns" false "" "" \
      "$trial_root/static-balanced" &
    static_pid=$!
    BACKGROUND_PIDS+=("$static_pid")

    reshape_requested=""
    reshape_finished=""
    dynamic_ready="$request_ns"
    if [[ "$actual_mismatch" == true ]]; then
      reshape_root="$trial_root/dynamic-reshape"
      if ! ensure_profile \
        "$dynamic_node" "$desired_config" dynamic "$profile" "$reshape_root"; then
        wait "$static_pid" || true
        die "dynamic reshape failed in period ${period} trial ${trial}"
      fi
      reshape_requested="$(jq -r '.reshape_requested_time_ns' \
        "$reshape_root/result.json")"
      reshape_finished="$(jq -r '.reshape_finished_time_ns' \
        "$reshape_root/result.json")"
      dynamic_ready="$(jq -r '.ready_time_ns' "$reshape_root/result.json")"
    else
      wait_resource_slice "$dynamic_node" dynamic "$profile" \
        "$trial_root/dynamic-resourceslices-before.json" || {
        wait "$static_pid" || true
        die "dynamic matching profile inventory is not Ready"
      }
    fi

    dynamic_status=0
    run_batch \
      dynamic-homogeneous "$dynamic_node" "$profile" "$desired_config" \
      "$period" "$trial" "$request_ns" "$dynamic_ready" "$actual_mismatch" \
      "$reshape_requested" "$reshape_finished" \
      "$trial_root/dynamic-homogeneous" || dynamic_status=$?
    static_status=0
    wait "$static_pid" || static_status=$?
    [[ "$static_status" -eq 0 ]] || \
      die "static batch failed in period ${period} trial ${trial}"
    [[ "$dynamic_status" -eq 0 ]] || \
      die "dynamic batch failed in period ${period} trial ${trial}"
  done
done

"$PILOT_HELPER" aggregate \
  --plan "$ARTIFACT_DIR/plan.json" \
  --root "$ARTIFACT_DIR" \
  --output "$ARTIFACT_DIR/summary.json" \
  --report "$ARTIFACT_DIR/report.md"

SUCCESS=true
