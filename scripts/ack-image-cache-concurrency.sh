#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${SCRIPT_DIR}/e03-image-cache-concurrency.py"
CONFIG_FILE="${PROJECT_ROOT}/configs/image-cache-concurrency.env"
CHECK_ONLY=false

usage() {
  cat <<USAGE
Usage: $0 [--config PATH] [--check-only]

Runs the randomized E03 image size/cache/concurrency pilot. The default matrix
has 27 cells per repetition: existing-node cold/warm and new-node cold across
100/500/1024 MiB and requested concurrency 1/2/4.

--check-only performs local validation, Kubernetes reads, an ACK node-pool
shape read, and child preflights. It does not create Pods, change caches,
create a Lease, mutate the node pool, or trigger node scale.
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

require_cmd kubectl
require_cmd python3
require_cmd git
require_cmd timeout
require_cmd setsid

: "${CONFIRM_KUBE_CONTEXT:=no}"
: "${CONFIRM_E03_EXECUTION:=no}"
: "${REQUIRE_CLEAN_GIT:=true}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${CLUSTER_ID:=}"
: "${HOOKE_SYSTEM_NAMESPACE:=hooke-system}"
: "${ARTIFACT_ROOT:=artifacts}"
: "${E03_PILOT_REPETITIONS:=1}"
: "${E03_RANDOM_SEED:=20260723}"
: "${E03_IMAGE_METADATA_FILE:=dist/e03-images.env}"
: "${E03_IMAGE_REGISTRY_HOST:=}"
: "${E03_EXISTING_NODE_NAME:=}"
: "${E03_EXPECTED_INSTANCE_TYPE:=}"
: "${E03_EXPECTED_ZONE:=}"
: "${E03_DISK_TYPE:=}"
: "${E03_NODE_POOL_CHECK_HOOK:=}"
: "${E03_NODE_POOL_NAME:=}"
: "${E03_NODE_POOL_RESOURCE_GROUP_ID:=}"
: "${E03_NODE_POOL_HOOK_TIMEOUT_SECONDS:=180}"
: "${ALIYUN_CLI_PROFILE:=}"
: "${ALIYUN_CLI_REGION:=}"
: "${E03_MAX_TRIGGER_SPREAD_MS:=1000}"
: "${E03_REQUIRE_UNPACK_SUBSTAGE:=false}"
: "${E03_SMOKE_COMMAND_JSON:=[\"/smoke-app\"]}"
: "${E03_STARTUP_WORK_MIB:=0}"
: "${E03_CPU_REQUEST:=100m}"
: "${E03_CPU_LIMIT:=500m}"
: "${E03_MEMORY_REQUEST:=128Mi}"
: "${E03_MEMORY_LIMIT:=256Mi}"
: "${E03_APP_EVENT_MODE:=log}"
: "${E03_INGESTER_REACHABLE_URL:=}"
: "${INGESTER_BIND_ADDRESS:=127.0.0.1}"
: "${INGESTER_PORT:=18080}"
: "${CONTROLLER_METRICS_PORT:=18081}"
: "${HOOKE_AUTH_TOKEN:=}"
: "${FIXED_TAINT_KEY:=}"
: "${FIXED_TAINT_VALUE:=}"
: "${FIXED_TAINT_EFFECT:=NoSchedule}"
: "${ELASTIC_NODE_SELECTOR_KEY:=}"
: "${ELASTIC_NODE_SELECTOR_VALUE:=}"
: "${ELASTIC_TAINT_KEY:=}"
: "${ELASTIC_TAINT_VALUE:=}"
: "${ELASTIC_TAINT_EFFECT:=NoSchedule}"
: "${CONFIRM_NEW_NODE_COLD_SOURCE:=no}"
: "${CACHE_RESET_HOOK:=}"
: "${CACHE_VERIFY_HOOK:=}"
: "${ACK_EVENTS_EXPORT_HOOK:=}"
: "${RUNTIME_EVENTS_EXPORT_HOOK:=}"
: "${E01_HOST_HELPER_IMAGE:=}"
: "${ACK_SLS_REGION:=}"
: "${ACK_SLS_PROJECT:=}"
: "${ACK_SLS_LOGSTORE:=}"
: "${E03_CACHE_HOOK_TIMEOUT_SECONDS:=600}"
: "${E03_CHILD_RUN_TIMEOUT_SECONDS:=7200}"
: "${E03_ELASTIC_ZERO_TIMEOUT_SECONDS:=2400}"
: "${E03_ELASTIC_POLL_SECONDS:=15}"
: "${E03_PREWARM_TIMEOUT_SECONDS:=1800}"
: "${NODE_SCALE_TIMEOUT:=30m}"
: "${ROLLOUT_TIMEOUT:=20m}"
: "${CONTROLLER_WARMUP_SECONDS:=5}"
: "${EVENT_SETTLE_SECONDS:=5}"
: "${MYSQL_MODE:=docker}"
: "${MYSQL_CONTAINER_NAME:=hooke-e03-mysql}"
: "${MYSQL_VOLUME_NAME:=hooke-e03-mysql-data}"
: "${MYSQL_HOST_PORT:=13306}"
: "${RESET_MYSQL:=false}"
: "${STOP_MYSQL_ON_EXIT:=false}"

[[ "$CONFIRM_KUBE_CONTEXT" == yes ]] || die "set CONFIRM_KUBE_CONTEXT=yes after verifying the target cluster"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
[[ -n "$CLUSTER_ID" ]] || die "CLUSTER_ID is required"
[[ -n "$EXPECTED_API_SERVER_SUBSTRING" ]] || die "EXPECTED_API_SERVER_SUBSTRING is required"
[[ "$E03_PILOT_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die "E03_PILOT_REPETITIONS must be positive"
[[ "$E03_RANDOM_SEED" =~ ^[0-9]+$ ]] || die "E03_RANDOM_SEED must be non-negative"
[[ -n "$E03_IMAGE_REGISTRY_HOST" && "$E03_IMAGE_REGISTRY_HOST" != */* ]] || die "E03_IMAGE_REGISTRY_HOST is required"
[[ -n "$E03_EXISTING_NODE_NAME" ]] || die "E03_EXISTING_NODE_NAME is required"
[[ "$E03_EXISTING_NODE_NAME" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "invalid E03_EXISTING_NODE_NAME"
[[ -n "$E03_EXPECTED_INSTANCE_TYPE" ]] || die "E03_EXPECTED_INSTANCE_TYPE is required"
[[ -n "$E03_EXPECTED_ZONE" ]] || die "E03_EXPECTED_ZONE is required"
[[ -n "$E03_DISK_TYPE" ]] || die "E03_DISK_TYPE is required"
[[ -x "$E03_NODE_POOL_CHECK_HOOK" ]] || die "E03_NODE_POOL_CHECK_HOOK must be executable"
[[ -n "$E03_NODE_POOL_NAME" ]] || die "E03_NODE_POOL_NAME is required"
[[ -n "$E03_NODE_POOL_RESOURCE_GROUP_ID" ]] || die "E03_NODE_POOL_RESOURCE_GROUP_ID is required"
[[ -n "$ALIYUN_CLI_REGION" ]] || die "ALIYUN_CLI_REGION is required"
[[ "$E03_NODE_POOL_HOOK_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid E03_NODE_POOL_HOOK_TIMEOUT_SECONDS"
(( E03_NODE_POOL_HOOK_TIMEOUT_SECONDS <= 600 )) || die "node-pool hook timeout cannot exceed 600 seconds"
[[ "$E03_MAX_TRIGGER_SPREAD_MS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "E03_MAX_TRIGGER_SPREAD_MS must be numeric"
python3 - "$E03_MAX_TRIGGER_SPREAD_MS" <<'PY' >/dev/null || die "E03_MAX_TRIGGER_SPREAD_MS must be positive"
import sys
raise SystemExit(0 if float(sys.argv[1]) > 0 else 1)
PY
[[ "$E03_STARTUP_WORK_MIB" =~ ^[0-9]+$ ]] || die "E03_STARTUP_WORK_MIB must be non-negative"
[[ -n "$ELASTIC_NODE_SELECTOR_KEY" && -n "$ELASTIC_NODE_SELECTOR_VALUE" ]] || die "elastic selector is required"
[[ "$ELASTIC_NODE_SELECTOR_KEY" == node.alibabacloud.com/nodepool-id ]] || \
  die "E03 requires the ACK node-pool identity selector"
[[ -n "$ELASTIC_TAINT_KEY" && -n "$ELASTIC_TAINT_VALUE" ]] || die "elastic taint is required"
[[ "$ELASTIC_TAINT_EFFECT" == NoSchedule ]] || die "E03 requires ELASTIC_TAINT_EFFECT=NoSchedule"
if [[ -n "$FIXED_TAINT_KEY" || -n "$FIXED_TAINT_VALUE" ]]; then
  [[ -n "$FIXED_TAINT_KEY" && -n "$FIXED_TAINT_VALUE" ]] || die "fixed taint key/value must be set together"
fi
[[ "$CONFIRM_NEW_NODE_COLD_SOURCE" == yes ]] || die "set CONFIRM_NEW_NODE_COLD_SOURCE=yes only for fresh elastic instances"
[[ "$E03_CACHE_HOOK_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid E03_CACHE_HOOK_TIMEOUT_SECONDS"
[[ "$E03_CHILD_RUN_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid E03_CHILD_RUN_TIMEOUT_SECONDS"
[[ "$E03_ELASTIC_ZERO_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid E03_ELASTIC_ZERO_TIMEOUT_SECONDS"
[[ "$E03_ELASTIC_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid E03_ELASTIC_POLL_SECONDS"
[[ "$E03_PREWARM_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid E03_PREWARM_TIMEOUT_SECONDS"
(( E03_CACHE_HOOK_TIMEOUT_SECONDS <= 1800 )) || die "cache hook timeout cannot exceed 1800 seconds"
(( E03_CHILD_RUN_TIMEOUT_SECONDS <= 14400 )) || die "child timeout cannot exceed 14400 seconds"
(( E03_ELASTIC_POLL_SECONDS <= 60 )) || die "elastic poll interval cannot exceed 60 seconds"
(( E03_PREWARM_TIMEOUT_SECONDS <= 3600 )) || die "prewarm timeout cannot exceed 3600 seconds"

case "$E03_APP_EVENT_MODE" in
  log) APP_SDK_DISABLED=true ;;
  sdk)
    APP_SDK_DISABLED=false
    [[ -n "$E03_INGESTER_REACHABLE_URL" ]] || die "E03_INGESTER_REACHABLE_URL is required in sdk mode"
    [[ "$E03_INGESTER_REACHABLE_URL" != *localhost* && "$E03_INGESTER_REACHABLE_URL" != *127.0.0.1* ]] || die "E03 ingester URL must be Pod-routable"
    [[ "$INGESTER_BIND_ADDRESS" != localhost && "$INGESTER_BIND_ADDRESS" != 127.0.0.1 ]] || die "INGESTER_BIND_ADDRESS must accept Pod traffic"
    [[ -n "$HOOKE_AUTH_TOKEN" ]] || die "HOOKE_AUTH_TOKEN is required in sdk mode"
    ;;
  *) die "E03_APP_EVENT_MODE must be log or sdk" ;;
esac

[[ -x "$HELPER" ]] || die "E03 helper must be executable: $HELPER"
[[ -x "$CACHE_RESET_HOOK" ]] || die "CACHE_RESET_HOOK must be executable"
[[ -x "$CACHE_VERIFY_HOOK" ]] || die "CACHE_VERIFY_HOOK must be executable"
[[ -x "$ACK_EVENTS_EXPORT_HOOK" ]] || die "ACK_EVENTS_EXPORT_HOOK must be executable"
[[ -x "$RUNTIME_EVENTS_EXPORT_HOOK" ]] || die "RUNTIME_EVENTS_EXPORT_HOOK must be executable"
[[ -n "$E01_HOST_HELPER_IMAGE" ]] || die "E01_HOST_HELPER_IMAGE is required"
[[ -n "$ACK_SLS_REGION" && -n "$ACK_SLS_PROJECT" && -n "$ACK_SLS_LOGSTORE" ]] || \
  die "ACK_SLS_REGION, ACK_SLS_PROJECT, and ACK_SLS_LOGSTORE are required"

is_true "$REQUIRE_CLEAN_GIT" || die "E03 requires REQUIRE_CLEAN_GIT=true"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die "E03 requires a clean Git worktree"

if [[ "$E03_IMAGE_METADATA_FILE" = /* ]]; then
  IMAGE_METADATA_PATH="$E03_IMAGE_METADATA_FILE"
else
  IMAGE_METADATA_PATH="${PROJECT_ROOT}/${E03_IMAGE_METADATA_FILE}"
fi
[[ -f "$IMAGE_METADATA_PATH" ]] || die "E03 image metadata not found: $IMAGE_METADATA_PATH"

metadata_value() {
  local key="$1" count value
  count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$IMAGE_METADATA_PATH")"
  [[ "$count" == 1 ]] || die "image metadata must contain exactly one ${key}"
  value="$(awk -v prefix="${key}=" 'index($0,prefix)==1 {sub(prefix,""); print; exit}' "$IMAGE_METADATA_PATH")"
  [[ -n "$value" ]] || die "image metadata value is empty: ${key}"
  printf '%s' "$value"
}

IMAGE_BUILD_COMMIT="$(metadata_value E03_IMAGE_BUILD_COMMIT)"
IMAGE_SOURCE_STATE="$(metadata_value E03_IMAGE_SOURCE_STATE)"
IMAGE_SIZE_LEVELS="$(metadata_value E03_IMAGE_SIZE_LEVELS_MIB)"
IMAGES_PER_SIZE="$(metadata_value E03_IMAGES_PER_SIZE)"
# build-e03-images.sh emits shell-compatible values with printf %q, which
# escapes commas even though this reader deliberately avoids evaluating shell
# text. Accept that one frozen CSV in either encoded or plain form.
if [[ "$IMAGE_SIZE_LEVELS" == '100\,500\,1024' ]]; then
  IMAGE_SIZE_LEVELS='100,500,1024'
fi
[[ "$IMAGE_BUILD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "E03 image build commit is invalid"
[[ "$IMAGE_SOURCE_STATE" == clean ]] || die "E03 images must be built from a clean worktree"
[[ "$IMAGE_SIZE_LEVELS" == 100,500,1024 ]] || die "E03 image metadata has the wrong size levels"
[[ "$IMAGES_PER_SIZE" == 4 ]] || die "E03 image metadata must contain four images per size"
git cat-file -e "${IMAGE_BUILD_COMMIT}^{commit}" 2>/dev/null || die "image build commit is unavailable"
git merge-base --is-ancestor "$IMAGE_BUILD_COMMIT" HEAD || die "image build commit is not an ancestor of HEAD"
IMAGE_BUILD_INPUTS=(
  examples/smoke-app/Dockerfile
  examples/smoke-app/Dockerfile.dockerignore
  cmd/smoke-app
  sdk/go
  internal/buildinfo
  internal/event
  internal/transport
  scripts/build-e03-images.sh
  tools/e01-image-padding
  go.mod
  go.sum
)
git diff --quiet "$IMAGE_BUILD_COMMIT"..HEAD -- "${IMAGE_BUILD_INPUTS[@]}" || \
  die "smoke-app image inputs changed since E03 image build; rebuild all E03 images"

declare -A E03_IMAGES=()
declare -A E03_PADDING_BYTES=()
declare -A OBSERVED_DIGESTS=()
for size in 100 500 1024; do
  for slot in 1 2 3 4; do
    key="${size}_${slot}"
    image="$(metadata_value "E03_IMAGE_${size}_P${slot}")"
    target_size="$(metadata_value "E03_IMAGE_${size}_P${slot}_TARGET_SIZE_MIB")"
    padding_bytes="$(metadata_value "E03_IMAGE_${size}_P${slot}_PADDING_BYTES")"
    actual_size_bytes="$(metadata_value "E03_IMAGE_${size}_P${slot}_SIZE_BYTES")"
    [[ "$image" =~ @sha256:[0-9a-fA-F]{64}$ ]] || die "metadata image is not immutable: ${key}"
    [[ "$target_size" == "$size" ]] || die "metadata target size mismatch: ${key}"
    [[ "$padding_bytes" =~ ^[1-9][0-9]*$ ]] || die "metadata padding bytes are invalid: ${key}"
    [[ "$actual_size_bytes" =~ ^[1-9][0-9]*$ ]] || die "metadata image size is invalid: ${key}"
    target_bytes=$((size * 1024 * 1024))
    size_delta=$((actual_size_bytes - target_bytes))
    (( size_delta < 0 )) && size_delta=$((-size_delta))
    (( size_delta <= 4096 )) || die "metadata image size is outside the E03 target tolerance: ${key}"
    registry="$(python3 - "$image" <<'PY'
import sys
from urllib.parse import urlsplit
print(urlsplit("//" + sys.argv[1].split("@", 1)[0]).hostname or "")
PY
)"
    [[ "$registry" == "$E03_IMAGE_REGISTRY_HOST" ]] || die "image ${key} is not in E03_IMAGE_REGISTRY_HOST"
    digest="${image##*@}"
    [[ -z "${OBSERVED_DIGESTS[$digest]:-}" ]] || die "duplicate E03 digest: ${digest}"
    OBSERVED_DIGESTS["$digest"]="$key"
    E03_IMAGES["$key"]="$image"
    E03_PADDING_BYTES["$key"]="$padding_bytes"
  done
  for slot in 2 3 4; do
    [[ "${E03_PADDING_BYTES[${size}_${slot}]}" == "${E03_PADDING_BYTES[${size}_1]}" ]] || \
      die "same-size E03 images use different padding byte counts: ${size} MiB"
  done
done

KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_PATH")
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL+=(--context "$KUBE_CONTEXT")
  "${KUBECTL[@]}" config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1 || die "kube context not found: $KUBE_CONTEXT"
  EFFECTIVE_CONTEXT="$KUBE_CONTEXT"
else
  EFFECTIVE_CONTEXT="$(kubectl --kubeconfig "$KUBECONFIG_PATH" config current-context)"
fi
[[ -n "$EFFECTIVE_CONTEXT" ]] || die "no effective kube context"
kube() { "${KUBECTL[@]}" "$@"; }

EFFECTIVE_API_SERVER="$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$EFFECTIVE_API_SERVER" == *"$EXPECTED_API_SERVER_SUBSTRING"* ]] || die "API server does not match EXPECTED_API_SERVER_SUBSTRING"

SESSION_STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
SESSION_NAME="e03-image-cache-concurrency-pilot-${SESSION_STAMP}"
if [[ "$CHECK_ONLY" == true ]]; then
  SESSION_DIR="$(mktemp -d)"
else
  if [[ "$ARTIFACT_ROOT" = /* ]]; then
    SESSION_DIR="${ARTIFACT_ROOT}/${SESSION_NAME}"
  else
    SESSION_DIR="${PROJECT_ROOT}/${ARTIFACT_ROOT}/${SESSION_NAME}"
  fi
  mkdir -p "$SESSION_DIR/runs"
  chmod 700 "$SESSION_DIR"
fi

SCHEDULE_FILE="$SESSION_DIR/schedule.tsv"
"$HELPER" schedule --repetitions "$E03_PILOT_REPETITIONS" --seed "$E03_RANDOM_SEED" --output "$SCHEDULE_FILE"

TEMP_CONFIG=""
ACTIVE_CHILD_PID=""
LOCK_ACQUIRED=false
LOCK_NAME=""
LOCK_UID=""
LOCK_HOLDER="$SESSION_NAME"
PREWARM_NAMESPACE=""
PREWARM_NAMESPACE_UID=""
FIRST_RUN=true

terminate_active_child() {
  local pid="${ACTIVE_CHILD_PID:-}"
  [[ -n "$pid" ]] || return 0
  kill -TERM -- "-${pid}" >/dev/null 2>&1 || true
  for _ in {1..50}; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" >/dev/null 2>&1 || true
      ACTIVE_CHILD_PID=""
      return 0
    fi
    sleep 0.1
  done
  kill -KILL -- "-${pid}" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  ACTIVE_CHILD_PID=""
}

run_managed() {
  local timeout_seconds="$1" label="$2" rc
  shift 2
  [[ -z "$ACTIVE_CHILD_PID" ]] || die "cannot start ${label}; another child is active"
  setsid timeout --signal=TERM --kill-after=10s "${timeout_seconds}s" "$@" &
  ACTIVE_CHILD_PID=$!
  if wait "$ACTIVE_CHILD_PID"; then rc=0; else rc=$?; fi
  ACTIVE_CHILD_PID=""
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then warn "${label} exceeded ${timeout_seconds}s"; fi
  return "$rc"
}

validate_pool_evidence() {
  local evidence="$1"
  python3 - "$evidence" "$CLUSTER_ID" "$ELASTIC_NODE_SELECTOR_VALUE" \
    "$E03_NODE_POOL_NAME" "$E03_NODE_POOL_RESOURCE_GROUP_ID" "$ALIYUN_CLI_REGION" \
    "$EFFECTIVE_API_SERVER" "$ELASTIC_NODE_SELECTOR_KEY" "$ELASTIC_TAINT_KEY" \
    "$ELASTIC_TAINT_VALUE" "$ELASTIC_TAINT_EFFECT" "$E03_EXPECTED_INSTANCE_TYPE" \
    "$E03_EXPECTED_ZONE" "$E03_DISK_TYPE" <<'PY'
import json
import sys

(
    evidence,
    cluster_id,
    node_pool_id,
    node_pool_name,
    resource_group_id,
    region_id,
    api_server,
    selector_key,
    taint_key,
    taint_value,
    taint_effect,
    instance_type,
    zone,
    disk_type,
) = sys.argv[1:]
with open(evidence, encoding="utf-8") as stream:
    value = json.load(stream)

shape = value.get("pool_shape")
vswitches = shape.get("vswitches") if isinstance(shape, dict) else None
valid_vswitches = (
    isinstance(vswitches, list)
    and bool(vswitches)
    and len({item.get("vswitch_id") for item in vswitches if isinstance(item, dict)}) == len(vswitches)
    and all(
        isinstance(item, dict)
        and isinstance(item.get("vswitch_id"), str)
        and bool(item["vswitch_id"])
        and item.get("zone_id") == zone
        and item.get("status") == "Available"
        for item in vswitches
    )
)
if not (
    value.get("action") == "check"
    and value.get("cluster_id") == cluster_id
    and value.get("node_pool_id") == node_pool_id
    and value.get("node_pool_name") == node_pool_name
    and value.get("resource_group_id") == resource_group_id
    and value.get("region_id") == region_id
    and value.get("api_server") == api_server
    and value.get("min_size") == 0
    and value.get("max_size") == 1
    and value.get("auto_scaling_enabled") is True
    and value.get("nodepool_type") == "ess"
    and value.get("is_default") is False
    and value.get("status_state") == "active"
    and value.get("selector") == {"key": selector_key, "value": node_pool_id}
    and value.get("taint")
    == {"key": taint_key, "value": taint_value, "effect": taint_effect}
    and isinstance(shape, dict)
    and shape.get("instance_types") == [instance_type]
    and shape.get("system_disk_category") == disk_type
    and isinstance(shape.get("system_disk_size_gib"), int)
    and shape["system_disk_size_gib"] > 0
    and valid_vswitches
):
    raise SystemExit("invalid E03 node-pool shape evidence")
PY
}

run_pool_check() {
  local evidence="$1"
  if ! run_managed "$E03_NODE_POOL_HOOK_TIMEOUT_SECONDS" "E03 node-pool check" \
      "$E03_NODE_POOL_CHECK_HOOK" \
      --action check \
      --cluster-id "$CLUSTER_ID" \
      --node-pool-id "$ELASTIC_NODE_SELECTOR_VALUE" \
      --node-pool-name "$E03_NODE_POOL_NAME" \
      --resource-group-id "$E03_NODE_POOL_RESOURCE_GROUP_ID" \
      --expected-api-server "$EFFECTIVE_API_SERVER" \
      --selector-key "$ELASTIC_NODE_SELECTOR_KEY" \
      --selector-value "$ELASTIC_NODE_SELECTOR_VALUE" \
      --taint-key "$ELASTIC_TAINT_KEY" \
      --taint-value "$ELASTIC_TAINT_VALUE" \
      --taint-effect "$ELASTIC_TAINT_EFFECT" \
      --evidence "$evidence" \
      --expected-instance-type "$E03_EXPECTED_INSTANCE_TYPE" \
      --expected-zone "$E03_EXPECTED_ZONE" \
      --expected-disk-type "$E03_DISK_TYPE" \
      --expected-min-size 0 \
      --expected-max-size 1; then
    die "E03 node-pool read-only check failed"
  fi
  [[ -s "$evidence" ]] || die "E03 node-pool check produced no evidence"
  chmod 600 "$evidence"
  validate_pool_evidence "$evidence" || die "E03 node-pool evidence validation failed"
}

delete_prewarm_namespace() {
  [[ -n "$PREWARM_NAMESPACE" ]] || return 0
  local identity uid owner remaining deadline namespace
  namespace="$PREWARM_NAMESPACE"
  identity="$(kube --request-timeout=30s get namespace "$PREWARM_NAMESPACE" --ignore-not-found \
    -o jsonpath='{.metadata.uid}{"\t"}{.metadata.annotations.hooke\.io/session}' 2>/dev/null)" || return 1
  if [[ -z "$identity" ]]; then
    PREWARM_NAMESPACE=""
    PREWARM_NAMESPACE_UID=""
    return 0
  fi
  IFS=$'\t' read -r uid owner <<<"$identity"
  [[ "$uid" == "$PREWARM_NAMESPACE_UID" && "$owner" == "$SESSION_NAME" ]] || return 1
  python3 - "$uid" <<'PY' | kube --request-timeout=30s delete \
    --raw "/api/v1/namespaces/${PREWARM_NAMESPACE}" -f - >/dev/null
import json, sys
print(json.dumps({"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":sys.argv[1]},"propagationPolicy":"Foreground"}, separators=(",",":")))
PY
  deadline=$((SECONDS + 300))
  while true; do
    remaining="$(kube --request-timeout=10s get namespace "$namespace" --ignore-not-found -o name 2>/dev/null)" || return 1
    [[ -z "$remaining" ]] && break
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
  PREWARM_NAMESPACE=""
  PREWARM_NAMESPACE_UID=""
}

release_lock() {
  [[ "$LOCK_ACQUIRED" == true ]] || return 0
  local identity uid holder remaining deadline
  identity="$(kube --request-timeout=30s -n "$HOOKE_SYSTEM_NAMESPACE" get lease "$LOCK_NAME" \
    -o jsonpath='{.metadata.uid}{"\t"}{.spec.holderIdentity}' 2>/dev/null)" || return 1
  IFS=$'\t' read -r uid holder <<<"$identity"
  [[ "$uid" == "$LOCK_UID" && "$holder" == "$LOCK_HOLDER" ]] || return 1
  python3 - "$uid" <<'PY' | kube --request-timeout=30s delete \
    --raw "/apis/coordination.k8s.io/v1/namespaces/${HOOKE_SYSTEM_NAMESPACE}/leases/${LOCK_NAME}" \
    -f - >/dev/null
import json, sys
print(json.dumps({"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":sys.argv[1]},"propagationPolicy":"Background"}, separators=(",",":")))
PY
  deadline=$((SECONDS + 30))
  while true; do
    remaining="$(kube --request-timeout=10s -n "$HOOKE_SYSTEM_NAMESPACE" get lease "$LOCK_NAME" \
      --ignore-not-found -o name 2>/dev/null)" || return 1
    [[ -z "$remaining" ]] && break
    (( SECONDS < deadline )) || return 1
    sleep 1
  done
  LOCK_ACQUIRED=false
  LOCK_UID=""
}

session_child_namespaces_gone() {
  [[ -d "$SESSION_DIR/runs" ]] || return 0
  local evidence values namespace uid run_id actual actual_uid actual_run
  while IFS= read -r evidence; do
    [[ -n "$evidence" ]] || continue
    values="$(python3 - "$evidence" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
name, uid, run_id = value.get("name"), value.get("uid"), value.get("run_id")
if value.get("created_by_run") is not True or not all(isinstance(item, str) and item for item in (name, uid, run_id)):
    raise SystemExit(1)
print(name, uid, run_id, sep="\t")
PY
)" || return 1
    IFS=$'\t' read -r namespace uid run_id <<<"$values"
    actual="$(kube --request-timeout=20s get namespace "$namespace" --ignore-not-found \
      -o jsonpath='{.metadata.uid}{"\t"}{.metadata.annotations.hooke\.io/run-id}' 2>/dev/null)" || return 1
    [[ -z "$actual" ]] && continue
    IFS=$'\t' read -r actual_uid actual_run <<<"$actual"
    if [[ "$actual_uid" == "$uid" && "$actual_run" == "$run_id" ]]; then
      return 1
    fi
    return 1
  done < <(find "$SESSION_DIR/runs" -mindepth 2 -maxdepth 2 -name experiment-namespace.json -type f -print 2>/dev/null | sort)
}

privileged_helpers_gone_now() {
  local listing count
  listing="$(kube --request-timeout=20s get pods -A \
    -l 'hooke.io/component in (e01-cache-helper,runtime-journal-exporter)' \
    --no-headers 2>/dev/null)" || return 1
  count="$(awk 'NF {count++} END {print count+0}' <<<"$listing")"
  [[ "$count" == 0 ]]
}

elastic_pool_zero_now() {
  local listing count
  listing="$(kube --request-timeout=20s get nodes \
    -l "${ELASTIC_NODE_SELECTOR_KEY}=${ELASTIC_NODE_SELECTOR_VALUE}" \
    --no-headers 2>/dev/null)" || return 1
  count="$(awk 'NF {count++} END {print count+0}' <<<"$listing")"
  [[ "$count" == 0 ]]
}

cleanup() {
  local rc=$?
  local safe_to_unlock=true
  trap - EXIT INT TERM
  trap '' INT TERM
  terminate_active_child
  [[ -z "$TEMP_CONFIG" ]] || rm -f -- "$TEMP_CONFIG"
  if ! delete_prewarm_namespace; then
    warn "failed to delete owned prewarm namespace"
    rc=1
    safe_to_unlock=false
  fi
  if [[ "$LOCK_ACQUIRED" == true ]] && ! privileged_helpers_gone_now; then
    warn "privileged helper Pods remain or could not be verified"
    rc=1
    safe_to_unlock=false
  fi
  if [[ "$LOCK_ACQUIRED" == true ]] && ! session_child_namespaces_gone; then
    warn "child namespace cleanup is incomplete or could not be verified"
    rc=1
    safe_to_unlock=false
  fi
  if [[ "$LOCK_ACQUIRED" == true ]] && ! elastic_pool_zero_now; then
    warn "elastic pool is non-empty or could not be verified"
    rc=1
    safe_to_unlock=false
  fi
  if [[ "$safe_to_unlock" == true ]]; then
    if ! release_lock; then warn "failed to release E03 Lease"; rc=1; fi
  elif [[ "$LOCK_ACQUIRED" == true ]]; then
    warn "preserving E03 Lease ${HOOKE_SYSTEM_NAMESPACE}/${LOCK_NAME} for manual recovery"
  fi
  if [[ "$CHECK_ONLY" == true ]]; then rm -rf -- "$SESSION_DIR"; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

acquire_lock() {
  local stamp created identity holder
  LOCK_NAME="$(python3 - "$CLUSTER_ID" "$E03_EXISTING_NODE_NAME" <<'PY'
import hashlib, re, sys
raw = "-".join(sys.argv[1:])
safe = re.sub(r"[^a-z0-9-]+", "-", raw.lower()).strip("-")
print(("hooke-e03-" + safe[:35] + "-" + hashlib.sha256(raw.encode()).hexdigest()[:10])[:63].rstrip("-"))
PY
)"
  stamp="$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
PY
)"
  created="$(python3 - "$LOCK_NAME" "$HOOKE_SYSTEM_NAMESPACE" "$LOCK_HOLDER" "$stamp" <<'PY' | \
    kube --request-timeout=30s create -f - -o json
import json, sys
print(json.dumps({
  "apiVersion":"coordination.k8s.io/v1","kind":"Lease",
  "metadata":{"name":sys.argv[1],"namespace":sys.argv[2],"labels":{"hooke.io/experiment":"E03-image-cache-concurrency"}},
  "spec":{"holderIdentity":sys.argv[3],"acquireTime":sys.argv[4],"leaseDurationSeconds":86400}
}, separators=(",",":")))
PY
)" || die "E03 Lease already exists or could not be created"
  identity="$(printf '%s' "$created" | python3 /dev/fd/3 "$LOCK_NAME" "$LOCK_HOLDER" 3<<'PY'
import json, sys
payload = json.load(sys.stdin)
metadata = payload.get("metadata", {})
holder = (payload.get("spec") or {}).get("holderIdentity")
if metadata.get("name") != sys.argv[1] or holder != sys.argv[2] or not metadata.get("uid"):
    raise SystemExit(1)
print(metadata["uid"], holder, sep="\t")
PY
)" || die "created E03 Lease has invalid ownership evidence"
  IFS=$'\t' read -r LOCK_UID holder <<<"$identity"
  LOCK_ACQUIRED=true
}

validate_existing_node() {
  local output="$1"
  kube --request-timeout=30s get node "$E03_EXISTING_NODE_NAME" -o json >"$output"
  python3 - "$output" "$E03_EXISTING_NODE_NAME" "$E03_EXPECTED_INSTANCE_TYPE" "$E03_EXPECTED_ZONE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    node = json.load(stream)
metadata = node.get("metadata", {})
labels = metadata.get("labels") or {}
conditions = (node.get("status") or {}).get("conditions") or []
instance = labels.get("node.kubernetes.io/instance-type") or labels.get("beta.kubernetes.io/instance-type")
zone = labels.get("topology.kubernetes.io/zone") or labels.get("failure-domain.beta.kubernetes.io/zone")
if (
    metadata.get("name") != sys.argv[2]
    or labels.get("kubernetes.io/hostname") != sys.argv[2]
    or instance != sys.argv[3]
    or zone != sys.argv[4]
    or (node.get("spec") or {}).get("unschedulable") is True
    or not any(item.get("type") == "Ready" and item.get("status") == "True" for item in conditions)
):
    raise SystemExit(1)
PY
}

wait_elastic_zero() {
  local deadline=$((SECONDS + E03_ELASTIC_ZERO_TIMEOUT_SECONDS)) count
  while true; do
    count="$(kube --request-timeout=30s get nodes \
      -l "${ELASTIC_NODE_SELECTOR_KEY}=${ELASTIC_NODE_SELECTOR_VALUE}" \
      --no-headers 2>/dev/null | awk 'NF {count++} END {print count+0}')"
    [[ "$count" == 0 ]] && return 0
    (( SECONDS < deadline )) || die "elastic pool did not return to zero before timeout"
    sleep "$E03_ELASTIC_POLL_SECONDS"
  done
}

wait_privileged_helpers_gone() {
  local deadline=$((SECONDS + E03_CACHE_HOOK_TIMEOUT_SECONDS)) listing count
  while true; do
    listing="$(kube --request-timeout=30s get pods -A \
      -l 'hooke.io/component in (e01-cache-helper,runtime-journal-exporter)' \
      --no-headers 2>/dev/null)" || die "failed to query privileged helper Pods"
    count="$(awk 'NF {count++} END {print count+0}' <<<"$listing")"
    [[ "$count" == 0 ]] && return 0
    (( SECONDS < deadline )) || die "privileged helper Pods did not terminate before timeout"
    sleep 2
  done
}

images_json() {
  local size="$1" concurrency="$2" values=() slot
  for ((slot=1; slot<=concurrency; slot++)); do values+=("${E03_IMAGES[${size}_${slot}]}"); done
  python3 - "${values[@]}" <<'PY'
import json, sys
print(json.dumps(sys.argv[1:], separators=(",",":")))
PY
}

minimum_download_bytes() {
  local size="$1" padding
  padding="${E03_PADDING_BYTES[${size}_1]}"
  printf '%s' "$((padding * 98 / 100))"
}

prepare_cold_cache() {
  local size="$1" concurrency="$2" sequence="$3" slot image
  for ((slot=1; slot<=concurrency; slot++)); do
    image="${E03_IMAGES[${size}_${slot}]}"
    run_managed "$E03_CACHE_HOOK_TIMEOUT_SECONDS" "cache reset ${size}/p${slot}" \
      "$CACHE_RESET_HOOK" --image "$image" \
      --selector-key kubernetes.io/hostname --selector-value "$E03_EXISTING_NODE_NAME" \
      --reason e03-existing-cold --evidence "$SESSION_DIR/cache-reset-${sequence}-p${slot}.json"
    run_managed "$E03_CACHE_HOOK_TIMEOUT_SECONDS" "cache verify cold ${size}/p${slot}" \
      "$CACHE_VERIFY_HOOK" --state cold --image "$image" \
      --selector-key kubernetes.io/hostname --selector-value "$E03_EXISTING_NODE_NAME" \
      --evidence "$SESSION_DIR/cache-cold-${sequence}-p${slot}.json"
  done
}

prewarm_images() {
  local size="$1" concurrency="$2" sequence="$3" slot image pod created
  PREWARM_NAMESPACE="e03-prewarm-${SESSION_STAMP,,}-${sequence}"
  PREWARM_NAMESPACE="${PREWARM_NAMESPACE:0:63}"
  while [[ "$PREWARM_NAMESPACE" == *- ]]; do PREWARM_NAMESPACE="${PREWARM_NAMESPACE%-}"; done
  created="$(python3 - "$PREWARM_NAMESPACE" "$SESSION_NAME" <<'PY' | kube create -f - -o json
import json, sys
print(json.dumps({"apiVersion":"v1","kind":"Namespace","metadata":{"name":sys.argv[1],"annotations":{"hooke.io/session":sys.argv[2]}}}, separators=(",",":")))
PY
)" || die "failed to create E03 prewarm namespace"
  PREWARM_NAMESPACE_UID="$(printf '%s' "$created" | python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["uid"])')"
  for ((slot=1; slot<=concurrency; slot++)); do
    image="${E03_IMAGES[${size}_${slot}]}"
    pod="prewarm-p${slot}"
    python3 - "$PREWARM_NAMESPACE" "$pod" "$SESSION_NAME" "$E03_EXISTING_NODE_NAME" "$image" "$E03_SMOKE_COMMAND_JSON" <<'PY' | kube apply -f - >/dev/null
import json, sys
namespace, name, session, node, image, command = sys.argv[1:]
print(json.dumps({
  "apiVersion":"v1","kind":"Pod",
  "metadata":{"name":name,"namespace":namespace,"labels":{"hooke.io/experiment":"true"},"annotations":{"hooke.io/session":session}},
  "spec":{"nodeName":node,"restartPolicy":"Never","terminationGracePeriodSeconds":1,
    "tolerations":[{"operator":"Exists"}],
    "containers":[{"name":"prewarm","image":image,"imagePullPolicy":"IfNotPresent",
      "command":json.loads(command),
      "env":[{"name":"HOOKE_SDK_DISABLED","value":"true"},{"name":"HOOKE_STARTUP_WORK_MIB","value":"0"}],
      "resources":{"requests":{"cpu":"1m","memory":"8Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}
}, separators=(",",":")))
PY
  done
  for ((slot=1; slot<=concurrency; slot++)); do
    kube -n "$PREWARM_NAMESPACE" wait --for=condition=Ready "pod/prewarm-p${slot}" \
      "--timeout=${E03_PREWARM_TIMEOUT_SECONDS}s" >/dev/null
  done
  kube -n "$PREWARM_NAMESPACE" get pods -o json >"$SESSION_DIR/prewarm-${sequence}.json"
  delete_prewarm_namespace || die "failed to delete E03 prewarm namespace"
  for ((slot=1; slot<=concurrency; slot++)); do
    image="${E03_IMAGES[${size}_${slot}]}"
    run_managed "$E03_CACHE_HOOK_TIMEOUT_SECONDS" "cache verify warm ${size}/p${slot}" \
      "$CACHE_VERIFY_HOOK" --state warm --image "$image" \
      --selector-key kubernetes.io/hostname --selector-value "$E03_EXISTING_NODE_NAME" \
      --evidence "$SESSION_DIR/cache-warm-${sequence}-p${slot}.json"
  done
}

append_config() {
  local key="$1" value="$2"
  printf '%s=%q\n' "$key" "$value" >>"$TEMP_CONFIG"
}

make_labels() {
  local sequence="$1" block="$2" repetition="$3" cell="$4" node_state="$5"
  local cache_state="$6" size="$7" concurrency="$8" selected_images="$9"
  python3 - "$sequence" "$block" "$repetition" "$cell" "$node_state" "$cache_state" \
    "$size" "$concurrency" "$E03_RANDOM_SEED" "$selected_images" "$IMAGE_BUILD_COMMIT" "$(git rev-parse HEAD)" <<'PY'
import json, sys
images = json.loads(sys.argv[10])
print(json.dumps({
  "experiment":"E03-image-cache-concurrency","phase":"pilot",
  "sequence":int(sys.argv[1]),"block":int(sys.argv[2]),"repetition":int(sys.argv[3]),
  "cell":sys.argv[4],"node_state":sys.argv[5],"cache_state":sys.argv[6],
  "size_mib":int(sys.argv[7]),"requested_concurrency":int(sys.argv[8]),
  "random_seed":int(sys.argv[9]),"image_digests_csv":",".join(item.rsplit("@",1)[1] for item in images),
  "image_build_commit":sys.argv[11],"orchestrator_commit":sys.argv[12]
}, separators=(",",":"), sort_keys=True))
PY
}

make_child_config() {
  local sequence="$1" block="$2" repetition="$3" cell="$4" node_state="$5"
  local cache_state="$6" size="$7" concurrency="$8" selected_images="$9" check_mode="${10}"
  local labels first_image
  labels="$(make_labels "$sequence" "$block" "$repetition" "$cell" "$node_state" "$cache_state" "$size" "$concurrency" "$selected_images")"
  first_image="$(python3 - "$selected_images" <<'PY'
import json, sys
print(json.loads(sys.argv[1])[0])
PY
)"
  TEMP_CONFIG="$(mktemp)"
  chmod 600 "$TEMP_CONFIG"
  cp -- "$CONFIG_FILE" "$TEMP_CONFIG"
  append_config RUN_NAME_PREFIX "e03-${cell}-r${repetition}-s${sequence}"
  append_config RUN_LABELS_JSON "$labels"
  append_config ARTIFACT_ROOT "$SESSION_DIR/runs"
  append_config EXPERIMENT_NAMESPACE "e03-${cell}"
  append_config SMOKE_IMAGE "$first_image"
  append_config SMOKE_BATCH_IMAGES_JSON "$selected_images"
  append_config SMOKE_IMAGE_PULL_POLICY IfNotPresent
  append_config SMOKE_COMMAND_JSON "$E03_SMOKE_COMMAND_JSON"
  append_config SMOKE_CONTAINER_PORT 8080
  append_config SMOKE_SERVICE_PORT 80
  append_config SMOKE_READINESS_PATH /readyz
  append_config SMOKE_REQUEST_PATH /work
  append_config SMOKE_DISABLE_SDK "$APP_SDK_DISABLED"
  append_config SMOKE_HOOKE_INGESTER_URL "$E03_INGESTER_REACHABLE_URL"
  append_config SMOKE_STARTUP_WORK_MIB "$E03_STARTUP_WORK_MIB"
  append_config SMOKE_CPU_REQUEST "$E03_CPU_REQUEST"
  append_config SMOKE_CPU_LIMIT "$E03_CPU_LIMIT"
  append_config SMOKE_MEMORY_REQUEST "$E03_MEMORY_REQUEST"
  append_config SMOKE_MEMORY_LIMIT "$E03_MEMORY_LIMIT"
  append_config NODE_SCALE_CPU_REQUEST "$E03_CPU_REQUEST"
  append_config NODE_SCALE_CPU_LIMIT "$E03_CPU_LIMIT"
  append_config NODE_SCALE_MEMORY_REQUEST "$E03_MEMORY_REQUEST"
  append_config NODE_SCALE_MEMORY_LIMIT "$E03_MEMORY_LIMIT"
  append_config SMOKE_REPETITIONS 1
  append_config NODE_SCALE_REPLICAS 1
  append_config REQUIRE_IMMUTABLE_IMAGE true
  append_config RUNTIME_EVENTS_EXPORT_HOOK "$RUNTIME_EVENTS_EXPORT_HOOK"
  append_config REQUIRE_EXACT_IMAGE_EVENTS true
  append_config REQUIRE_EXACT_POD_EVENTS true
  append_config REQUIRE_EXACT_APP_EVENTS true
  append_config REQUIRE_POD_SUBSTAGES true
  append_config REQUIRE_CNI_SUBSTAGE false
  append_config REQUIRE_DERIVATION_TRACEABILITY true
  append_config EXPECTED_IMAGE_UNPACK_SAMPLES 0
  if is_true "$E03_REQUIRE_UNPACK_SUBSTAGE" && [[ "$cache_state" == cold ]]; then
    append_config EXPECTED_IMAGE_UNPACK_SAMPLES "$concurrency"
  fi
  append_config ROLLOUT_TIMEOUT "$ROLLOUT_TIMEOUT"
  append_config NODE_SCALE_TIMEOUT "$NODE_SCALE_TIMEOUT"
  append_config RESET_MYSQL false
  append_config STOP_MYSQL_ON_EXIT false
  append_config CLEANUP_K8S_ON_SUCCESS true
  append_config CLEANUP_K8S_ON_ERROR true
  append_config REQUIRE_EMPTY_EXPERIMENT_NAMESPACE true
  append_config UNIQUE_EXPERIMENT_NAMESPACE true
  append_config UNIQUE_RESOURCE_NAMES true
  append_config DELETE_EXPERIMENT_NAMESPACE true
  if [[ "$check_mode" == false && "$FIRST_RUN" == false ]]; then append_config SKIP_BUILD true; fi
  if [[ "$node_state" == existing ]]; then
    append_config ENABLE_FIXED_SMOKE true
    append_config ENABLE_NODE_SCALE_SMOKE false
    append_config FIXED_NODE_SELECTOR_KEY kubernetes.io/hostname
    append_config FIXED_NODE_SELECTOR_VALUE "$E03_EXISTING_NODE_NAME"
    append_config FIXED_TAINT_KEY "$FIXED_TAINT_KEY"
    append_config FIXED_TAINT_VALUE "$FIXED_TAINT_VALUE"
    append_config FIXED_TAINT_EFFECT "$FIXED_TAINT_EFFECT"
    append_config REQUIRE_EXACT_NODE_EVENTS false
    append_config ACK_EVENTS_EXPORT_HOOK ""
  else
    append_config ENABLE_FIXED_SMOKE false
    append_config ENABLE_NODE_SCALE_SMOKE true
    append_config REQUIRE_EMPTY_ELASTIC_POOL true
    append_config REQUIRE_NEW_NODE true
    append_config REQUIRE_NODE_UNSCHEDULABLE true
    append_config REQUIRE_TASK_ID_ATTRIBUTION true
    append_config REQUIRE_EXACT_NODE_EVENTS true
    append_config EXPECTED_TASK_COUNT 1
    append_config EXPECTED_MIN_PODS_PER_TASK "$concurrency"
    append_config ACK_EVENTS_EXPORT_HOOK "$ACK_EVENTS_EXPORT_HOOK"
  fi
}

locate_run_dir() {
  local prefix="$1" matches=()
  mapfile -t matches < <(find "$SESSION_DIR/runs" -mindepth 1 -maxdepth 1 -type d -name "${prefix}-*" -print | sort)
  [[ ${#matches[@]} -eq 1 ]] || die "expected one artifact directory for ${prefix}, observed ${#matches[@]}"
  printf '%s' "${matches[0]}"
}

check_permissions() {
  local permission answer args
  for permission in \
    "get nodes" \
    "list nodes" \
    "list pods --all-namespaces" \
    "get namespaces" \
    "create namespaces" \
    "delete namespaces" \
    "get leases.coordination.k8s.io --namespace ${HOOKE_SYSTEM_NAMESPACE}" \
    "create leases.coordination.k8s.io --namespace ${HOOKE_SYSTEM_NAMESPACE}" \
    "delete leases.coordination.k8s.io --namespace ${HOOKE_SYSTEM_NAMESPACE}"; do
    # shellcheck disable=SC2206
    args=($permission)
    answer="$(kube auth can-i "${args[@]}" 2>/dev/null || true)"
    [[ "$answer" == yes ]] || die "kube permission denied: ${permission}"
  done
}

log "E03 preflight: context=${EFFECTIVE_CONTEXT}, runs=$((E03_PILOT_REPETITIONS * 27)), seed=${E03_RANDOM_SEED}"
check_permissions
kube get namespace "$HOOKE_SYSTEM_NAMESPACE" >/dev/null 2>&1 || die "HOOKE_SYSTEM_NAMESPACE does not exist"
validate_existing_node "$SESSION_DIR/existing-node.json" || die "existing E03 Node identity/readiness Gate failed"
run_pool_check "$SESSION_DIR/node-pool-check.json"

elastic_count="$(kube get nodes -l "${ELASTIC_NODE_SELECTOR_KEY}=${ELASTIC_NODE_SELECTOR_VALUE}" \
  --no-headers 2>/dev/null | awk 'NF {count++} END {print count+0}')"
[[ "$elastic_count" == 0 ]] || die "E03 preflight requires the elastic pool to be empty; observed ${elastic_count} Node(s)"

CHECK_IMAGES="$(images_json 100 1)"
mkdir -p "$SESSION_DIR/runs"
for path in existing new; do
  make_child_config 0 0 1 "check-${path}" "$path" cold 100 1 "$CHECK_IMAGES" true
  run_managed "$E03_CHILD_RUN_TIMEOUT_SECONDS" "${path} child preflight" \
    "$SCRIPT_DIR/ack-first-smoke.sh" --config "$TEMP_CONFIG" --check-only
  rm -f -- "$TEMP_CONFIG"
  TEMP_CONFIG=""
done

if [[ "$CHECK_ONLY" == true ]]; then
  cat "$SCHEDULE_FILE"
  log "E03 check-only complete; no workload, cache, Lease, or node change was performed"
  exit 0
fi

[[ "$CONFIRM_E03_EXECUTION" == yes ]] || die "set CONFIRM_E03_EXECUTION=yes before running E03"
acquire_lock

cp -- "$IMAGE_METADATA_PATH" "$SESSION_DIR/image-build.env"
chmod 600 "$SESSION_DIR/image-build.env"
sed -E \
  -e 's/^([A-Za-z0-9_]*(PASSWORD|TOKEN|DSN|SECRET|ACCESS_KEY|CREDENTIAL)[A-Za-z0-9_]*)=.*/\1="<redacted>"/' \
  "$CONFIG_FILE" >"$SESSION_DIR/e03.env.redacted"
chmod 600 "$SESSION_DIR/e03.env.redacted"
kube version -o json >"$SESSION_DIR/kubernetes-version.json"
kube get nodes -o json >"$SESSION_DIR/nodes-at-session-start.json"
python3 - "$SESSION_NAME" "$EFFECTIVE_CONTEXT" "$EFFECTIVE_API_SERVER" "$(git rev-parse HEAD)" \
  "$IMAGE_BUILD_COMMIT" "$E03_RANDOM_SEED" "$E03_PILOT_REPETITIONS" "$E03_EXISTING_NODE_NAME" \
  "$E03_DISK_TYPE" "$E03_REQUIRE_UNPACK_SUBSTAGE" >"$SESSION_DIR/session.json" <<'PY'
import json, sys
keys = ["session","kube_context","api_server","orchestrator_commit","image_build_commit","random_seed","repetitions_per_cell","existing_node","disk_type","require_unpack"]
value = dict(zip(keys, sys.argv[1:]))
value["random_seed"] = int(value["random_seed"])
value["repetitions_per_cell"] = int(value["repetitions_per_cell"])
value["require_unpack"] = value["require_unpack"].lower() in {"1","true","yes","y","on"}
value["matrix"] = {"size_mib":[100,500,1024],"cache":["cold","warm"],"requested_concurrency":[1,2,4],"node":["existing","new"],"excluded":["new-warm"]}
print(json.dumps(value, indent=2, sort_keys=True))
PY
chmod 600 "$SESSION_DIR/session.json"

RUN_INDEX="$SESSION_DIR/run-index.tsv"
printf 'sequence\tblock\trepetition\tcell\tnode_state\tcache_state\tsize_mib\trequested_concurrency\tartifact_dir\tvalidation\n' >"$RUN_INDEX"
chmod 600 "$RUN_INDEX"

while IFS=$'\t' read -r sequence block repetition cell node_state cache_state size concurrency; do
  [[ "$sequence" != sequence ]] || continue
  log "E03 sequence ${sequence}: ${cell}"
  selected_images="$(images_json "$size" "$concurrency")"
  if [[ "$node_state" == existing ]]; then
    validate_existing_node "$SESSION_DIR/existing-node-before-${sequence}.json" || die "existing Node changed before ${cell}"
    if [[ "$cache_state" == cold ]]; then
      prepare_cold_cache "$size" "$concurrency" "$sequence"
    else
      prewarm_images "$size" "$concurrency" "$sequence"
    fi
    wait_privileged_helpers_gone
  else
    wait_elastic_zero
  fi

  make_child_config "$sequence" "$block" "$repetition" "$cell" "$node_state" \
    "$cache_state" "$size" "$concurrency" "$selected_images" false
  prefix="e03-${cell}-r${repetition}-s${sequence}"
  child_log="$SESSION_DIR/run-${sequence}-${cell}.log"
  if ! run_managed "$E03_CHILD_RUN_TIMEOUT_SECONDS" "${cell} child run" \
      "$SCRIPT_DIR/ack-first-smoke.sh" --config "$TEMP_CONFIG" >"$child_log" 2>&1; then
    tail -n 160 "$child_log" >&2 || true
    die "E03 child run failed: ${cell}"
  fi
  cat "$child_log"
  wait_privileged_helpers_gone
  rm -f -- "$TEMP_CONFIG"
  TEMP_CONFIG=""
  FIRST_RUN=false

  run_dir="$(locate_run_dir "$prefix")"
  validation="$run_dir/e03-validation.json"
  selector_key="$ELASTIC_NODE_SELECTOR_KEY"
  selector_value="$ELASTIC_NODE_SELECTOR_VALUE"
  existing_arg=()
  if [[ "$node_state" == existing ]]; then
    selector_key=kubernetes.io/hostname
    selector_value="$E03_EXISTING_NODE_NAME"
    existing_arg=(--existing-node-name "$E03_EXISTING_NODE_NAME")
  fi
  validation_args=(
    validate-run --artifact-dir "$run_dir"
    --node-state "$node_state" --cache-state "$cache_state"
    --size-mib "$size" --requested-concurrency "$concurrency"
    --images-json "$selected_images" --cluster-id "$CLUSTER_ID"
    --selector-key "$selector_key" --selector-value "$selector_value"
    --instance-type "$E03_EXPECTED_INSTANCE_TYPE" --zone "$E03_EXPECTED_ZONE"
    --registry "$E03_IMAGE_REGISTRY_HOST" --disk-type "$E03_DISK_TYPE"
    --min-download-bytes "$(minimum_download_bytes "$size")"
    --max-trigger-spread-ms "$E03_MAX_TRIGGER_SPREAD_MS"
    --output "$validation"
    "${existing_arg[@]}"
  )
  if is_true "$E03_REQUIRE_UNPACK_SUBSTAGE"; then validation_args+=(--require-unpack); fi
  "$HELPER" "${validation_args[@]}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sequence" "$block" "$repetition" "$cell" "$node_state" "$cache_state" \
    "$size" "$concurrency" "$run_dir" "$validation" >>"$RUN_INDEX"
done <"$SCHEDULE_FILE"

wait_privileged_helpers_gone
wait_elastic_zero
"$HELPER" summarize --run-index "$RUN_INDEX" --schedule "$SCHEDULE_FILE" \
  --expected-repetitions "$E03_PILOT_REPETITIONS" --expected-seed "$E03_RANDOM_SEED" \
  --observations "$SESSION_DIR/observations.tsv" --output "$SESSION_DIR/summary.json"

session_child_namespaces_gone || die "E03 child namespace cleanup is incomplete"
release_lock || die "failed to release E03 Lease"
log "E03 pilot code path complete: ${SESSION_DIR}"
