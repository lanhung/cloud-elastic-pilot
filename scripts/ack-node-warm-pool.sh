#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${SCRIPT_DIR}/e02-node-warm-pool.py"
CONFIG_FILE="${PROJECT_ROOT}/configs/node-warm-pool.env"
CHECK_ONLY=false

usage() {
  cat <<USAGE
Usage: $0 [--config PATH] [--check-only]

Runs the randomized paired-block E02 cold-node / warm-node pilot. The default
is five repetitions per variant. --check-only performs only local validation,
Kubernetes reads, child preflights, and the node-pool hook's read-only check.
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
: "${CONFIRM_E02_POOL_MUTATION:=no}"
: "${REQUIRE_CLEAN_GIT:=true}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${CLUSTER_ID:=}"
: "${HOOKE_SYSTEM_NAMESPACE:=hooke-system}"
: "${ARTIFACT_ROOT:=artifacts}"
: "${E02_PILOT_REPETITIONS:=5}"
: "${E02_RANDOM_SEED:=20260722}"
: "${E02_NODE_POOL_ID:=}"
: "${E02_NODE_POOL_NAME:=}"
: "${E02_NODE_POOL_RESOURCE_GROUP_ID:=}"
: "${E02_NODE_POOL_CONTROL_HOOK:=}"
: "${ALIYUN_CLI_REGION:=}"
: "${E02_ACK_CONTROL_TIMEOUT_SECONDS:=120}"
: "${E02_ACK_STABILITY_POLLS:=3}"
: "${E02_POOL_STATE_TIMEOUT_SECONDS:=2400}"
: "${E02_POOL_POLL_SECONDS:=15}"
: "${E02_WARM_STABILITY_SECONDS:=30}"
: "${E02_RESTORE_STABILITY_SECONDS:=30}"
: "${E02_NODE_POOL_HOOK_TIMEOUT_SECONDS:=600}"
: "${E02_CHILD_CLEANUP_TIMEOUT_SECONDS:=180}"
: "${E02_CHILD_RUN_TIMEOUT_SECONDS:=3600}"
: "${E02_CACHE_HOOK_TIMEOUT_SECONDS:=300}"
: "${E02_IMAGE_METADATA_FILE:=dist/e01-images.env}"
: "${E02_IMAGE:=}"
: "${E02_SMOKE_COMMAND_JSON:=[\"/smoke-app\"]}"
: "${E02_STARTUP_WORK_MIB:=0}"
: "${E02_APP_EVENT_MODE:=log}"
: "${E02_INGESTER_REACHABLE_URL:=}"
: "${INGESTER_BIND_ADDRESS:=127.0.0.1}"
: "${HOOKE_AUTH_TOKEN:=}"
: "${E02_CPU_REQUEST:=500m}"
: "${E02_CPU_LIMIT:=1000m}"
: "${E02_MEMORY_REQUEST:=256Mi}"
: "${E02_MEMORY_LIMIT:=512Mi}"
: "${E02_EXPECTED_INSTANCE_TYPE:=}"
: "${E02_EXPECTED_ZONE:=}"
: "${ELASTIC_NODE_SELECTOR_KEY:=}"
: "${ELASTIC_NODE_SELECTOR_VALUE:=}"
: "${ELASTIC_TAINT_KEY:=}"
: "${ELASTIC_TAINT_VALUE:=}"
: "${ELASTIC_TAINT_EFFECT:=NoSchedule}"
: "${E02_REQUIRE_CNI_READY:=true}"
: "${E02_CNI_NAMESPACE:=kube-system}"
: "${E02_CNI_POD_SELECTOR:=}"
: "${CONFIRM_NEW_NODE_COLD_SOURCE:=no}"
: "${CACHE_RESET_HOOK:=}"
: "${CACHE_VERIFY_HOOK:=}"
: "${ACK_EVENTS_EXPORT_HOOK:=}"
: "${RUNTIME_EVENTS_EXPORT_HOOK:=}"
: "${E01_HOST_HELPER_IMAGE:=}"
: "${ACK_SLS_REGION:=}"
: "${ACK_SLS_PROJECT:=}"
: "${ACK_SLS_LOGSTORE:=}"
: "${E02_REQUIRE_CNI_SUBSTAGE:=false}"
: "${NODE_SCALE_TIMEOUT:=20m}"
: "${E02_APP_ROLLOUT_TIMEOUT:=5m}"
: "${MYSQL_MODE:=docker}"
: "${MYSQL_CONTAINER_NAME:=hooke-e02-mysql}"
: "${MYSQL_VOLUME_NAME:=hooke-e02-mysql-data}"
: "${MYSQL_HOST_PORT:=13306}"
: "${RESET_MYSQL:=false}"
: "${STOP_MYSQL_ON_EXIT:=false}"

[[ "$CONFIRM_KUBE_CONTEXT" == "yes" ]] || die "set CONFIRM_KUBE_CONTEXT=yes after verifying the target cluster"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
[[ -n "$CLUSTER_ID" ]] || die "CLUSTER_ID is required"
[[ -n "$EXPECTED_API_SERVER_SUBSTRING" ]] || die "EXPECTED_API_SERVER_SUBSTRING is required"
[[ "$E02_PILOT_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die "E02_PILOT_REPETITIONS must be positive"
[[ "$E02_RANDOM_SEED" =~ ^[0-9]+$ ]] || die "E02_RANDOM_SEED must be non-negative"
[[ "$E02_POOL_STATE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E02_POOL_STATE_TIMEOUT_SECONDS must be positive"
[[ "$E02_POOL_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E02_POOL_POLL_SECONDS must be positive"
(( E02_POOL_POLL_SECONDS <= 60 )) || die "E02_POOL_POLL_SECONDS cannot exceed 60"
[[ "$E02_WARM_STABILITY_SECONDS" =~ ^[0-9]+$ ]] || die "E02_WARM_STABILITY_SECONDS must be non-negative"
(( E02_WARM_STABILITY_SECONDS <= 60 )) || die "E02_WARM_STABILITY_SECONDS cannot exceed 60"
[[ "$E02_RESTORE_STABILITY_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E02_RESTORE_STABILITY_SECONDS must be positive"
(( E02_RESTORE_STABILITY_SECONDS <= 120 )) || die "E02_RESTORE_STABILITY_SECONDS cannot exceed 120"
[[ "$E02_ACK_CONTROL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E02_ACK_CONTROL_TIMEOUT_SECONDS must be positive"
(( E02_ACK_CONTROL_TIMEOUT_SECONDS <= 600 )) || die "E02_ACK_CONTROL_TIMEOUT_SECONDS cannot exceed 600"
[[ "$E02_ACK_STABILITY_POLLS" =~ ^[1-9][0-9]*$ ]] || die "E02_ACK_STABILITY_POLLS must be positive"
(( E02_ACK_STABILITY_POLLS >= 2 && E02_ACK_STABILITY_POLLS <= 20 )) || die "E02_ACK_STABILITY_POLLS must be between 2 and 20"
[[ "$E02_NODE_POOL_HOOK_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E02_NODE_POOL_HOOK_TIMEOUT_SECONDS must be positive"
(( E02_NODE_POOL_HOOK_TIMEOUT_SECONDS <= 1800 )) || die "E02_NODE_POOL_HOOK_TIMEOUT_SECONDS cannot exceed 1800"
(( E02_NODE_POOL_HOOK_TIMEOUT_SECONDS >= E02_ACK_CONTROL_TIMEOUT_SECONDS * 3 + 30 )) || \
  die "E02_NODE_POOL_HOOK_TIMEOUT_SECONDS must allow prior-task, restore-task, and convergence waits"
[[ "$E02_CHILD_CLEANUP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E02_CHILD_CLEANUP_TIMEOUT_SECONDS must be positive"
(( E02_CHILD_CLEANUP_TIMEOUT_SECONDS <= 600 )) || die "E02_CHILD_CLEANUP_TIMEOUT_SECONDS cannot exceed 600"
[[ "$E02_CHILD_RUN_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E02_CHILD_RUN_TIMEOUT_SECONDS must be positive"
(( E02_CHILD_RUN_TIMEOUT_SECONDS <= 7200 )) || die "E02_CHILD_RUN_TIMEOUT_SECONDS cannot exceed 7200"
[[ "$E02_CACHE_HOOK_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E02_CACHE_HOOK_TIMEOUT_SECONDS must be positive"
(( E02_CACHE_HOOK_TIMEOUT_SECONDS <= 600 )) || die "E02_CACHE_HOOK_TIMEOUT_SECONDS cannot exceed 600"
[[ -n "$E02_NODE_POOL_ID" ]] || die "E02_NODE_POOL_ID is required"
[[ -n "$E02_NODE_POOL_NAME" ]] || die "E02_NODE_POOL_NAME is required"
[[ -n "$E02_NODE_POOL_RESOURCE_GROUP_ID" ]] || die "E02_NODE_POOL_RESOURCE_GROUP_ID is required"
[[ -n "$ALIYUN_CLI_REGION" ]] || die "ALIYUN_CLI_REGION is required"
[[ -n "$ELASTIC_NODE_SELECTOR_KEY" && -n "$ELASTIC_NODE_SELECTOR_VALUE" ]] || die "elastic-node selector is required"
[[ "$ELASTIC_NODE_SELECTOR_KEY" == node.alibabacloud.com/nodepool-id ]] || \
  die "E02 requires the ACK node-pool identity selector"
[[ "$ELASTIC_NODE_SELECTOR_VALUE" == "$E02_NODE_POOL_ID" ]] || \
  die "elastic selector value must equal E02_NODE_POOL_ID"
[[ -n "$ELASTIC_TAINT_KEY" && -n "$ELASTIC_TAINT_VALUE" ]] || die "elastic-node taint is required"
[[ "$ELASTIC_TAINT_EFFECT" == NoSchedule ]] || die "E02 requires ELASTIC_TAINT_EFFECT=NoSchedule"
[[ -n "$E02_EXPECTED_INSTANCE_TYPE" ]] || die "E02_EXPECTED_INSTANCE_TYPE is required"
[[ -n "$E02_EXPECTED_ZONE" ]] || die "E02_EXPECTED_ZONE is required"
[[ "$E02_STARTUP_WORK_MIB" =~ ^[0-9]+$ ]] || die "E02_STARTUP_WORK_MIB must be non-negative"
[[ "$E02_IMAGE" =~ @sha256:[0-9a-fA-F]{64}$ ]] || die "E02_IMAGE must use an immutable sha256 digest"
[[ "$CONFIRM_NEW_NODE_COLD_SOURCE" == "yes" ]] || die "set CONFIRM_NEW_NODE_COLD_SOURCE=yes only for fresh empty-cache elastic instances"
if is_true "$E02_REQUIRE_CNI_READY"; then
  [[ -n "$E02_CNI_NAMESPACE" && -n "$E02_CNI_POD_SELECTOR" ]] || die "CNI namespace and Pod selector are required"
fi
[[ -x "$E02_NODE_POOL_CONTROL_HOOK" ]] || die "E02_NODE_POOL_CONTROL_HOOK must be executable"
[[ -x "$CACHE_RESET_HOOK" ]] || die "CACHE_RESET_HOOK must be executable"
[[ -x "$CACHE_VERIFY_HOOK" ]] || die "CACHE_VERIFY_HOOK must be executable"
[[ -x "$ACK_EVENTS_EXPORT_HOOK" ]] || die "ACK_EVENTS_EXPORT_HOOK must be executable"
[[ -x "$RUNTIME_EVENTS_EXPORT_HOOK" ]] || die "RUNTIME_EVENTS_EXPORT_HOOK must be executable"
[[ -x "$HELPER" ]] || die "E02 helper must be executable: $HELPER"
[[ -n "$E01_HOST_HELPER_IMAGE" ]] || die "E01_HOST_HELPER_IMAGE is required"
[[ -n "$ACK_SLS_REGION" && -n "$ACK_SLS_PROJECT" && -n "$ACK_SLS_LOGSTORE" ]] || \
  die "ACK_SLS_REGION, ACK_SLS_PROJECT, and ACK_SLS_LOGSTORE are required"

case "$E02_APP_EVENT_MODE" in
  log) APP_SDK_DISABLED=true ;;
  sdk)
    APP_SDK_DISABLED=false
    [[ -n "$E02_INGESTER_REACHABLE_URL" ]] || die "E02_INGESTER_REACHABLE_URL is required in sdk mode"
    [[ "$E02_INGESTER_REACHABLE_URL" != *"127.0.0.1"* && "$E02_INGESTER_REACHABLE_URL" != *"localhost"* ]] || die "E02 ingester URL must be reachable from Pods"
    [[ "$INGESTER_BIND_ADDRESS" != "127.0.0.1" && "$INGESTER_BIND_ADDRESS" != "localhost" ]] || die "INGESTER_BIND_ADDRESS must accept Pod traffic"
    [[ -n "$HOOKE_AUTH_TOKEN" ]] || die "HOOKE_AUTH_TOKEN is required in sdk mode"
    ;;
  *) die "E02_APP_EVENT_MODE must be log or sdk" ;;
esac

require_cmd kubectl
require_cmd python3
require_cmd git
require_cmd timeout
require_cmd setsid
is_true "$REQUIRE_CLEAN_GIT" || die "E02 requires REQUIRE_CLEAN_GIT=true"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die "E02 requires a clean Git worktree"

if [[ "$E02_IMAGE_METADATA_FILE" = /* ]]; then
  IMAGE_METADATA_PATH="$E02_IMAGE_METADATA_FILE"
else
  IMAGE_METADATA_PATH="${PROJECT_ROOT}/${E02_IMAGE_METADATA_FILE}"
fi
[[ -f "$IMAGE_METADATA_PATH" ]] || die "image metadata not found: $IMAGE_METADATA_PATH"

metadata_value() {
  local key="$1" count value
  count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$IMAGE_METADATA_PATH")"
  [[ "$count" == "1" ]] || die "image metadata must contain exactly one ${key} entry"
  value="$(awk -v prefix="${key}=" 'index($0, prefix) == 1 { sub(prefix, ""); print; exit }' "$IMAGE_METADATA_PATH")"
  printf '%s' "$value"
}

IMAGE_BUILD_COMMIT="$(metadata_value E01_IMAGE_BUILD_COMMIT)"
IMAGE_SOURCE_STATE="$(metadata_value E01_IMAGE_SOURCE_STATE)"
METADATA_SMALL_IMAGE="$(metadata_value E01_SMALL_IMAGE)"
IMAGE_PADDING_MIB="$(metadata_value E01_SMALL_PADDING_MIB)"
[[ "$IMAGE_BUILD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "image build commit is invalid"
[[ "$IMAGE_SOURCE_STATE" == "clean" ]] || die "E02 requires an image built from a clean worktree"
[[ "$METADATA_SMALL_IMAGE" == "$E02_IMAGE" ]] || die "E02_IMAGE does not match E01_SMALL_IMAGE metadata"
[[ "$IMAGE_PADDING_MIB" =~ ^[1-9][0-9]*$ ]] || die "E01_SMALL_PADDING_MIB metadata is invalid"
IMAGE_MIN_DOWNLOAD_BYTES=$((IMAGE_PADDING_MIB * 1024 * 1024))
git cat-file -e "${IMAGE_BUILD_COMMIT}^{commit}" 2>/dev/null || die "image build commit is unavailable locally"
git merge-base --is-ancestor "$IMAGE_BUILD_COMMIT" HEAD || die "image build commit is not an ancestor of HEAD"
IMAGE_BUILD_INPUTS=(
  examples/smoke-app/Dockerfile
  examples/smoke-app/Dockerfile.dockerignore
  cmd/smoke-app
  sdk/go
  internal/buildinfo
  internal/event
  internal/transport
  tools/e01-image-padding
  go.mod
  go.sum
)
git diff --quiet "$IMAGE_BUILD_COMMIT"..HEAD -- "${IMAGE_BUILD_INPUTS[@]}" || die "smoke-app image inputs changed since ${IMAGE_BUILD_COMMIT}; rebuild the E01 small image"

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
if [[ "$EFFECTIVE_API_SERVER" != *"$EXPECTED_API_SERVER_SUBSTRING"* ]]; then
  die "API server does not contain EXPECTED_API_SERVER_SUBSTRING"
fi

SESSION_STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
SESSION_NAME="e02-node-warm-pool-pilot-${SESSION_STAMP}"
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
"$HELPER" schedule --repetitions "$E02_PILOT_REPETITIONS" --seed "$E02_RANDOM_SEED" --output "$SCHEDULE_FILE"

TEMP_CONFIG=""
CHILD_RUN_PREFIX=""
POOL_SNAPSHOT=""
POOL_MUTATED=false
LOCK_ACQUIRED=false
LOCK_NAME=""
LOCK_HOLDER="$SESSION_NAME"
LOCK_UID=""
ACTIVE_CHILD_PID=""
E02_NODE_POOL_CONTROL_STATE_FILE="$SESSION_DIR/node-pool-control-state.json"
export E02_NODE_POOL_CONTROL_STATE_FILE

terminate_active_child() {
  local pid="${ACTIVE_CHILD_PID:-}" remaining
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
  [[ -z "$ACTIVE_CHILD_PID" ]] || die "cannot start ${label}; another managed child is active"
  setsid timeout --signal=TERM --kill-after=10s "${timeout_seconds}s" "$@" &
  ACTIVE_CHILD_PID=$!
  if wait "$ACTIVE_CHILD_PID"; then rc=0; else rc=$?; fi
  ACTIVE_CHILD_PID=""
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    warn "${label} exceeded ${timeout_seconds}s"
  fi
  return "$rc"
}

validate_control() {
  local action="$1" evidence="$2"; shift 2
  "$HELPER" validate-control --evidence "$evidence" --action "$action" \
    --cluster-id "$CLUSTER_ID" --node-pool-id "$E02_NODE_POOL_ID" \
    --node-pool-name "$E02_NODE_POOL_NAME" \
    --resource-group-id "$E02_NODE_POOL_RESOURCE_GROUP_ID" \
    --region-id "$ALIYUN_CLI_REGION" --api-server "$EFFECTIVE_API_SERVER" \
    --selector-key "$ELASTIC_NODE_SELECTOR_KEY" --selector-value "$ELASTIC_NODE_SELECTOR_VALUE" \
    --taint-key "$ELASTIC_TAINT_KEY" --taint-value "$ELASTIC_TAINT_VALUE" \
    --taint-effect "$ELASTIC_TAINT_EFFECT" "$@"
}

run_pool_hook() {
  local action="$1" evidence="$2"; shift 2
  if [[ -e "$evidence" ]]; then
    if ! mv -f -- "$evidence" "${evidence}.previous"; then
      warn "could not rotate previous node-pool evidence for ${action}"
      return 1
    fi
  fi
  if ! run_managed "$E02_NODE_POOL_HOOK_TIMEOUT_SECONDS" "node-pool ${action}" \
      "$E02_NODE_POOL_CONTROL_HOOK" \
      --action "$action" \
      --cluster-id "$CLUSTER_ID" \
      --node-pool-id "$E02_NODE_POOL_ID" \
      --node-pool-name "$E02_NODE_POOL_NAME" \
      --resource-group-id "$E02_NODE_POOL_RESOURCE_GROUP_ID" \
      --expected-api-server "$EFFECTIVE_API_SERVER" \
      --selector-key "$ELASTIC_NODE_SELECTOR_KEY" \
      --selector-value "$ELASTIC_NODE_SELECTOR_VALUE" \
      --taint-key "$ELASTIC_TAINT_KEY" \
      --taint-value "$ELASTIC_TAINT_VALUE" \
      --taint-effect "$ELASTIC_TAINT_EFFECT" \
      --evidence "$evidence" "$@"; then
    warn "node-pool hook failed for ${action}"
    return 1
  fi
  if [[ ! -s "$evidence" ]]; then
    warn "node-pool hook produced no evidence for ${action}"
    return 1
  fi
  chmod 600 "$evidence"
}

restore_pool() {
  [[ "$POOL_MUTATED" == true ]] || return 0
  local evidence="$SESSION_DIR/node-pool-restore.json"
  local original_min restore_mode state_prefix state_evidence stable_evidence cloud_check
  original_min="$(python3 - "$POOL_SNAPSHOT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["min_size"])
PY
)" || {
    warn "could not read original node-pool minimum from snapshot"
    return 1
  }
  if [[ "$original_min" == 0 ]] && ! assert_scale_down_safe restore; then
    warn "refusing unsafe node-pool restore to min=0"
    return 1
  fi
  log "restoring node-pool configuration from pre-experiment snapshot"
  if ! run_pool_hook restore "$evidence" --snapshot "$POOL_SNAPSHOT"; then
    warn "node-pool restore hook failed; manual recovery is required"
    return 1
  fi
  if ! validate_control restore "$evidence" --snapshot "$POOL_SNAPSHOT"; then
    warn "node-pool restore evidence failed validation; manual verification is required"
    return 1
  fi
  restore_mode=cold-node
  [[ "$original_min" == 1 ]] && restore_mode=warm-node
  state_prefix="$SESSION_DIR/restore-state"
  state_evidence="$SESSION_DIR/restore-state.json"
  if ! wait_pool_state "$restore_mode" "$state_prefix" "$state_evidence"; then
    warn "node-pool API config was restored but Kubernetes state is not yet ${restore_mode}"
    return 1
  fi
  sleep "$E02_RESTORE_STABILITY_SECONDS"
  stable_evidence="$SESSION_DIR/restore-state-stable.json"
  if ! wait_pool_state "$restore_mode" "$state_prefix" "$stable_evidence"; then
    warn "restored Kubernetes state did not remain stable"
    return 1
  fi
  if [[ "$restore_mode" == warm-node ]] && ! same_state_node "$state_evidence" "$stable_evidence"; then
    warn "restored warm Node changed during the stability window"
    return 1
  fi
  cloud_check="$SESSION_DIR/node-pool-restore-final-check.json"
  if ! run_pool_hook check "$cloud_check" || ! validate_control check "$cloud_check"; then
    warn "final cloud-side restore verification failed"
    return 1
  fi
  if ! python3 - "$POOL_SNAPSHOT" "$cloud_check" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    snapshot = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    current = json.load(stream)
raise SystemExit(0 if (
    snapshot.get("min_size") == current.get("min_size") and
    snapshot.get("max_size") == current.get("max_size")
) else 1)
PY
  then
    warn "final cloud-side min/max differs from the pre-experiment snapshot"
    return 1
  fi
  POOL_MUTATED=false
}

release_lock() {
  [[ "$LOCK_ACQUIRED" == true ]] || return 0
  local identity holder uid remaining deadline
  if ! identity="$(kube --request-timeout=30s -n "$HOOKE_SYSTEM_NAMESPACE" get lease "$LOCK_NAME" \
      -o jsonpath='{.metadata.uid}{"\t"}{.spec.holderIdentity}' 2>/dev/null)"; then
    warn "failed to read E02 Lease before release"
    return 1
  fi
  IFS=$'\t' read -r uid holder <<<"$identity"
  if [[ -z "$LOCK_UID" || "$uid" != "$LOCK_UID" || "$holder" != "$LOCK_HOLDER" ]]; then
    warn "refusing to delete E02 lock whose UID or holder changed"
    return 1
  fi
  if ! python3 - "$LOCK_UID" <<'PY' | kube --request-timeout=30s delete \
      --raw "/apis/coordination.k8s.io/v1/namespaces/${HOOKE_SYSTEM_NAMESPACE}/leases/${LOCK_NAME}" \
      -f - >/dev/null
import json, sys
print(json.dumps({
    "apiVersion": "v1",
    "kind": "DeleteOptions",
    "preconditions": {"uid": sys.argv[1]},
    "propagationPolicy": "Background",
}, separators=(",", ":")))
PY
  then
    warn "UID-preconditioned deletion failed for E02 Lease ${HOOKE_SYSTEM_NAMESPACE}/${LOCK_NAME}"
    return 1
  fi
  deadline=$((SECONDS + 30))
  while true; do
    if ! remaining="$(kube --request-timeout=10s -n "$HOOKE_SYSTEM_NAMESPACE" get lease "$LOCK_NAME" \
        --ignore-not-found -o name 2>/dev/null)"; then
      warn "failed to verify E02 Lease deletion"
      return 1
    fi
    [[ -z "$remaining" ]] && break
    (( SECONDS < deadline )) || {
      warn "E02 Lease still exists after deletion request"
      return 1
    }
    sleep 1
  done
  LOCK_ACQUIRED=false
  LOCK_UID=""
}

cleanup_child_namespaces() {
  [[ -d "$SESSION_DIR/runs" ]] || return 0
  local run_dirs=() listing run_dir file values namespace uid run_id actual actual_uid actual_run remaining deadline
  if ! listing="$(find "$SESSION_DIR/runs" -mindepth 1 -maxdepth 1 -type d -print | sort)"; then
    warn "failed to enumerate child run directories during cleanup"
    return 1
  fi
  if [[ -n "$listing" ]]; then
    mapfile -t run_dirs <<<"$listing"
  fi
  for run_dir in "${run_dirs[@]}"; do
    file="$run_dir/experiment-namespace.json"
    if [[ ! -f "$file" ]]; then
      warn "child artifact has no namespace ownership evidence: ${run_dir}"
      return 1
    fi
    if ! values="$(python3 - "$file" "$run_dir/run.json" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    ownership = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    run = json.load(stream)
name = ownership.get("name")
uid = ownership.get("uid")
run_id = ownership.get("run_id")
if ownership.get("created_by_run") is not True:
    raise SystemExit(1)
if not isinstance(name, str) or not re.fullmatch(r"e02-(cold|warm)-node-[a-z0-9-]+", name):
    raise SystemExit(1)
if not isinstance(uid, str) or not uid or not isinstance(run_id, str) or not run_id:
    raise SystemExit(1)
if run.get("run_id") != run_id:
    raise SystemExit(1)
print(name, uid, run_id, sep="\t")
PY
    )"; then
      warn "invalid child namespace ownership evidence: ${file}"
      return 1
    fi
    IFS=$'\t' read -r namespace uid run_id <<<"$values"
    if ! actual="$(kube --request-timeout=30s get namespace "$namespace" --ignore-not-found \
        -o jsonpath='{.metadata.uid}{"\t"}{.metadata.annotations.hooke\.io/run-id}' 2>/dev/null)"; then
      warn "failed to query child namespace ${namespace}"
      return 1
    fi
    [[ -n "$actual" ]] || continue
    IFS=$'\t' read -r actual_uid actual_run <<<"$actual"
    if [[ "$actual_uid" != "$uid" || "$actual_run" != "$run_id" ]]; then
      warn "refusing to delete child namespace whose UID or run owner changed: ${namespace}"
      return 1
    fi
    log "deleting owned child namespace: ${namespace}"
    if ! python3 - "$uid" <<'PY' | kube --request-timeout=30s delete \
        --raw "/api/v1/namespaces/${namespace}" -f - >/dev/null
import json, sys
print(json.dumps({
    "apiVersion": "v1",
    "kind": "DeleteOptions",
    "preconditions": {"uid": sys.argv[1]},
    "propagationPolicy": "Foreground",
}, separators=(",", ":")))
PY
    then
      warn "UID-preconditioned deletion failed for child namespace ${namespace}"
      return 1
    fi
    deadline=$((SECONDS + E02_CHILD_CLEANUP_TIMEOUT_SECONDS))
    while true; do
      if ! remaining="$(kube --request-timeout=10s get namespace "$namespace" --ignore-not-found -o name 2>/dev/null)"; then
        warn "failed to verify child namespace deletion: ${namespace}"
        return 1
      fi
      [[ -z "$remaining" ]] && break
      (( SECONDS < deadline )) || {
        warn "child namespace still exists after cleanup: ${namespace}"
        return 1
      }
      sleep 2
    done
  done
}

cleanup_session_active_run() {
  local active
  if ! active="$(kube --request-timeout=30s -n "$HOOKE_SYSTEM_NAMESPACE" get configmap hooke-active-run \
      --ignore-not-found -o jsonpath='{.data.run_id}' 2>/dev/null)"; then
    warn "failed to query hooke-active-run during cleanup"
    return 1
  fi
  [[ -n "$active" ]] || return 0
  warn "shared hooke-active-run became non-empty during E02; refusing to overwrite owner ${active}"
  return 1
}

cleanup() {
  local rc=$?
  local restored=true
  local workloads_cleared=true
  trap - EXIT
  # Once cleanup starts, protect the node-pool restore and Lease release from a
  # second signal.  INT/TERM handlers below preserve a non-zero exit status and
  # enter cleanup through the EXIT trap.
  trap '' INT TERM
  terminate_active_child
  [[ -z "$TEMP_CONFIG" ]] || { rm -f -- "$TEMP_CONFIG"; TEMP_CONFIG=""; }
  if [[ "$LOCK_ACQUIRED" == true ]] && ! wait_privileged_helpers_gone; then
    rc=1
    workloads_cleared=false
  fi
  if [[ "$LOCK_ACQUIRED" == true ]] && ! cleanup_session_active_run; then
    rc=1
    workloads_cleared=false
  fi
  if [[ "$LOCK_ACQUIRED" == true ]] && ! cleanup_child_namespaces; then
    rc=1
    workloads_cleared=false
  fi
  if ! restore_pool; then
    rc=1
    restored=false
  fi
  if [[ "$restored" == true && "$workloads_cleared" == true ]]; then
    if ! release_lock; then rc=1; fi
  elif [[ "$LOCK_ACQUIRED" == true ]]; then
    warn "child cleanup or node-pool restore is unverified; retaining Lease ${HOOKE_SYSTEM_NAMESPACE}/${LOCK_NAME} for manual recovery"
  fi
  if [[ "$CHECK_ONLY" == true && -n "$SESSION_DIR" && -d "$SESSION_DIR" ]]; then
    rm -rf -- "$SESSION_DIR"
  fi
  exit "$rc"
}
handle_signal() {
  local code="$1"
  trap '' INT TERM
  terminate_active_child
  exit "$code"
}

trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

sanitize_lock_name() {
  python3 - "$1" <<'PY'
import re, sys
value = re.sub(r"[^a-z0-9-]+", "-", sys.argv[1].lower()).strip("-")
value = (value or "pool")[:42].rstrip("-")
print("hooke-e02-" + value)
PY
}

acquire_lock() {
  LOCK_NAME="$(sanitize_lock_name "$E02_NODE_POOL_ID")"
  local acquired_at created identity holder observed_uid
  acquired_at="$("$HELPER" microtime)"
  if ! created="$(python3 - "$LOCK_NAME" "$HOOKE_SYSTEM_NAMESPACE" "$LOCK_HOLDER" "$acquired_at" <<'PY' | kube create -f - -o json
import json, sys
print(json.dumps({
    "apiVersion": "coordination.k8s.io/v1",
    "kind": "Lease",
    "metadata": {
        "name": sys.argv[1],
        "namespace": sys.argv[2],
        "labels": {"hooke.io/experiment": "E02-node-warm-pool"},
    },
    "spec": {
        "holderIdentity": sys.argv[3],
        "acquireTime": sys.argv[4],
        "leaseDurationSeconds": 86400,
    },
}, separators=(",", ":")))
PY
  )"; then
    die "E02 node-pool lock already exists or could not be created: ${HOOKE_SYSTEM_NAMESPACE}/${LOCK_NAME}"
  fi
  if ! identity="$(printf '%s' "$created" | \
      python3 /dev/fd/3 "$LOCK_NAME" "$HOOKE_SYSTEM_NAMESPACE" "$LOCK_HOLDER" 3<<'PY'
import json, sys
payload = json.load(sys.stdin)
metadata = payload.get("metadata", {})
holder = (payload.get("spec") or {}).get("holderIdentity", "")
if (
    metadata.get("name") != sys.argv[1]
    or metadata.get("namespace") != sys.argv[2]
    or holder != sys.argv[3]
    or not metadata.get("uid")
):
    raise SystemExit(1)
print(metadata["uid"], holder, sep="\t")
PY
  )"; then
    die "created E02 Lease response has no exact ownership identity"
  fi
  IFS=$'\t' read -r LOCK_UID holder <<<"$identity"
  LOCK_ACQUIRED=true
  if ! identity="$(kube --request-timeout=30s -n "$HOOKE_SYSTEM_NAMESPACE" get lease "$LOCK_NAME" \
      -o jsonpath='{.metadata.uid}{"\t"}{.spec.holderIdentity}' 2>/dev/null)"; then
    die "created E02 Lease but could not read back its identity"
  fi
  IFS=$'\t' read -r observed_uid holder <<<"$identity"
  [[ "$observed_uid" == "$LOCK_UID" && "$holder" == "$LOCK_HOLDER" ]] || \
    die "created E02 Lease identity does not match this session"
}

capture_pool() {
  local prefix="$1"
  if ! kube --request-timeout=30s get nodes -l "${ELASTIC_NODE_SELECTOR_KEY}=${ELASTIC_NODE_SELECTOR_VALUE}" -o json >"${prefix}-nodes.json"; then
    warn "failed to capture elastic Nodes"
    return 1
  fi
  if ! kube --request-timeout=30s get pods -A -o json >"${prefix}-experiment-pods.json"; then
    warn "failed to capture cluster Pods for dedicated-pool safety"
    return 1
  fi
  if is_true "$E02_REQUIRE_CNI_READY"; then
    if ! kube --request-timeout=30s -n "$E02_CNI_NAMESPACE" get pods -l "$E02_CNI_POD_SELECTOR" -o json >"${prefix}-cni-pods.json"; then
      warn "failed to capture CNI Pods"
      return 1
    fi
  else
    printf '{"items":[]}\n' >"${prefix}-cni-pods.json"
  fi
  chmod 600 "${prefix}-nodes.json" "${prefix}-experiment-pods.json" "${prefix}-cni-pods.json"
}

state_args() {
  local mode="$1" prefix="$2" output="$3"
  local args=(
    validate-state --mode "$mode"
    --nodes "${prefix}-nodes.json"
    --pods "${prefix}-experiment-pods.json"
    --selector-key "$ELASTIC_NODE_SELECTOR_KEY"
    --selector-value "$ELASTIC_NODE_SELECTOR_VALUE"
    --instance-type "$E02_EXPECTED_INSTANCE_TYPE"
    --zone "$E02_EXPECTED_ZONE"
    --taint-key "$ELASTIC_TAINT_KEY"
    --taint-value "$ELASTIC_TAINT_VALUE"
    --taint-effect "$ELASTIC_TAINT_EFFECT"
    --output "$output"
  )
  if is_true "$E02_REQUIRE_CNI_READY" && [[ "$mode" == warm-node ]]; then
    args+=(--require-cni --cni "${prefix}-cni-pods.json")
  fi
  printf '%s\0' "${args[@]}"
}

wait_pool_state() {
  local mode="$1" prefix="$2" output="$3"
  local deadline=$((SECONDS + E02_POOL_STATE_TIMEOUT_SECONDS))
  : >"${prefix}-wait.log"
  while true; do
    if ! capture_pool "$prefix"; then return 1; fi
    local args=()
    mapfile -d '' -t args < <(state_args "$mode" "$prefix" "$output")
    if "$HELPER" "${args[@]}" >>"${prefix}-wait.log" 2>&1; then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      warn "pool did not reach ${mode} state before timeout; see ${prefix}-wait.log"
      return 1
    fi
    sleep "$E02_POOL_POLL_SECONDS"
  done
}

assert_scale_down_safe() {
  local sequence="$1" prefix="$SESSION_DIR/pre-scale-down-${sequence}" count mode output
  local args=()
  capture_pool "$prefix" || return 1
  if ! count="$(python3 - "${prefix}-nodes.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
items = payload.get("items")
if not isinstance(items, list):
    raise SystemExit(1)
print(len(items))
PY
  )"; then
    warn "failed to count selected Nodes before scale-down"
    return 1
  fi
  case "$count" in
    0) mode=cold-node ;;
    1) mode=warm-node ;;
    *)
      warn "refusing node-pool scale-down with ${count} selected Nodes"
      return 1
      ;;
  esac
  output="$SESSION_DIR/pre-scale-down-${sequence}.json"
  mapfile -d '' -t args < <(state_args "$mode" "$prefix" "$output")
  if ! "$HELPER" "${args[@]}"; then
    warn "dedicated node-pool scale-down safety gate failed"
    return 1
  fi
}

same_state_node() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    first = json.load(f)
with open(sys.argv[2], encoding="utf-8") as f:
    second = json.load(f)
raise SystemExit(0 if first.get("node") == second.get("node") else 1)
PY
}

wait_cache_helpers_gone() {
  local deadline=$((SECONDS + E02_POOL_STATE_TIMEOUT_SECONDS))
  while true; do
    local listing count
    if ! listing="$(kube --request-timeout=30s get pods -A -l 'hooke.io/component=e01-cache-helper' \
        --no-headers 2>/dev/null)"; then
      die "failed to query cache helper Pods"
    fi
    count="$(awk 'NF {count++} END {print count+0}' <<<"$listing")"
    [[ "$count" == "0" ]] && return 0
    (( SECONDS < deadline )) || die "cache helper Pods did not terminate before timeout"
    sleep "$E02_POOL_POLL_SECONDS"
  done
}

wait_privileged_helpers_gone() {
  local deadline=$((SECONDS + E02_CHILD_CLEANUP_TIMEOUT_SECONDS)) listing count
  while true; do
    if ! listing="$(kube --request-timeout=30s get pods -A \
        -l 'hooke.io/component in (e01-cache-helper,runtime-journal-exporter)' \
        --no-headers 2>/dev/null)"; then
      warn "failed to query privileged experiment helper Pods"
      return 1
    fi
    count="$(awk 'NF {count++} END {print count+0}' <<<"$listing")"
    [[ "$count" == 0 ]] && return 0
    (( SECONDS < deadline )) || {
      warn "privileged experiment helper Pods remain after timeout"
      return 1
    }
    sleep "$E02_POOL_POLL_SECONDS"
  done
}

append_config() {
  local key="$1" value="$2"
  printf '%s=%q\n' "$key" "$value" >>"$TEMP_CONFIG"
}

make_labels() {
  local sequence="$1" block="$2" variant="$3" repetition="$4"
  python3 - "$sequence" "$block" "$variant" "$repetition" "$E02_RANDOM_SEED" "$E02_IMAGE" "$IMAGE_BUILD_COMMIT" "$(git rev-parse HEAD)" <<'PY'
import json, sys
print(json.dumps({
    "experiment": "E02-node-warm-pool",
    "phase": "pilot",
    "sequence": int(sys.argv[1]),
    "block": int(sys.argv[2]),
    "variant": sys.argv[3],
    "repetition": int(sys.argv[4]),
    "random_seed": int(sys.argv[5]),
    "image_ref": sys.argv[6],
    "image_state": "cold",
    "image_build_commit": sys.argv[7],
    "orchestrator_commit": sys.argv[8],
    "replicas": 1,
}, separators=(",", ":"), sort_keys=True))
PY
}

make_child_config() {
  local variant="$1" sequence="$2" block="$3" repetition="$4" artifact_root="$5" check_mode="$6"
  local prefix="e02-${variant}-r${repetition}-s${sequence}"
  local labels
  labels="$(make_labels "$sequence" "$block" "$variant" "$repetition")"
  TEMP_CONFIG="$(mktemp)"
  chmod 600 "$TEMP_CONFIG"
  cp -- "$CONFIG_FILE" "$TEMP_CONFIG"
  append_config RUN_NAME_PREFIX "$prefix"
  append_config RUN_LABELS_JSON "$labels"
  append_config ARTIFACT_ROOT "$artifact_root"
  append_config EXPERIMENT_NAMESPACE "e02-${variant}"
  append_config INGESTER_BIND_ADDRESS "$INGESTER_BIND_ADDRESS"
  append_config SMOKE_HOOKE_INGESTER_URL "$E02_INGESTER_REACHABLE_URL"
  append_config SMOKE_IMAGE "$E02_IMAGE"
  append_config SMOKE_IMAGE_PULL_POLICY "IfNotPresent"
  append_config SMOKE_COMMAND_JSON "$E02_SMOKE_COMMAND_JSON"
  append_config SMOKE_CONTAINER_PORT "8080"
  append_config SMOKE_SERVICE_PORT "80"
  append_config SMOKE_READINESS_PATH "/readyz"
  append_config SMOKE_REQUEST_PATH "/work"
  append_config SMOKE_DISABLE_SDK "$APP_SDK_DISABLED"
  append_config SMOKE_STARTUP_WORK_MIB "$E02_STARTUP_WORK_MIB"
  append_config REQUIRE_IMMUTABLE_IMAGE "true"
  append_config SMOKE_REPETITIONS "1"
  append_config NODE_SCALE_REPLICAS "1"
  append_config SMOKE_CPU_REQUEST "$E02_CPU_REQUEST"
  append_config SMOKE_CPU_LIMIT "$E02_CPU_LIMIT"
  append_config SMOKE_MEMORY_REQUEST "$E02_MEMORY_REQUEST"
  append_config SMOKE_MEMORY_LIMIT "$E02_MEMORY_LIMIT"
  append_config NODE_SCALE_CPU_REQUEST "$E02_CPU_REQUEST"
  append_config NODE_SCALE_CPU_LIMIT "$E02_CPU_LIMIT"
  append_config NODE_SCALE_MEMORY_REQUEST "$E02_MEMORY_REQUEST"
  append_config NODE_SCALE_MEMORY_LIMIT "$E02_MEMORY_LIMIT"
  append_config ROLLOUT_TIMEOUT "$E02_APP_ROLLOUT_TIMEOUT"
  append_config NODE_SCALE_TIMEOUT "$NODE_SCALE_TIMEOUT"
  append_config RUNTIME_EVENTS_EXPORT_HOOK "$RUNTIME_EVENTS_EXPORT_HOOK"
  append_config REQUIRE_EXACT_IMAGE_EVENTS "true"
  append_config REQUIRE_EXACT_POD_EVENTS "true"
  append_config REQUIRE_EXACT_APP_EVENTS "true"
  append_config REQUIRE_POD_SUBSTAGES "true"
  append_config REQUIRE_CNI_SUBSTAGE "$E02_REQUIRE_CNI_SUBSTAGE"
  append_config REQUIRE_DERIVATION_TRACEABILITY "true"
  append_config RESET_MYSQL "false"
  append_config STOP_MYSQL_ON_EXIT "false"
  append_config CLEANUP_K8S_ON_SUCCESS "true"
  append_config CLEANUP_K8S_ON_ERROR "true"
  append_config REQUIRE_EMPTY_EXPERIMENT_NAMESPACE "true"
  append_config UNIQUE_EXPERIMENT_NAMESPACE "true"
  append_config UNIQUE_RESOURCE_NAMES "true"
  append_config DELETE_EXPERIMENT_NAMESPACE "true"
  if [[ "$check_mode" == false && "$FIRST_RUN" == false ]]; then
    append_config SKIP_BUILD "true"
  fi
  if [[ "$variant" == cold-node ]]; then
    append_config ENABLE_FIXED_SMOKE "false"
    append_config ENABLE_NODE_SCALE_SMOKE "true"
    append_config REQUIRE_EMPTY_ELASTIC_POOL "true"
    append_config REQUIRE_NEW_NODE "true"
    append_config REQUIRE_NODE_UNSCHEDULABLE "true"
    append_config REQUIRE_TASK_ID_ATTRIBUTION "true"
    append_config REQUIRE_EXACT_NODE_EVENTS "true"
    append_config ACK_EVENTS_EXPORT_HOOK "$ACK_EVENTS_EXPORT_HOOK"
  else
    append_config ENABLE_FIXED_SMOKE "true"
    append_config ENABLE_NODE_SCALE_SMOKE "false"
    append_config FIXED_NODE_SELECTOR_KEY "$ELASTIC_NODE_SELECTOR_KEY"
    append_config FIXED_NODE_SELECTOR_VALUE "$ELASTIC_NODE_SELECTOR_VALUE"
    append_config FIXED_TAINT_KEY "$ELASTIC_TAINT_KEY"
    append_config FIXED_TAINT_VALUE "$ELASTIC_TAINT_VALUE"
    append_config FIXED_TAINT_EFFECT "$ELASTIC_TAINT_EFFECT"
    append_config REQUIRE_EXACT_NODE_EVENTS "false"
    append_config ACK_EVENTS_EXPORT_HOOK ""
  fi
  CHILD_RUN_PREFIX="$prefix"
}

locate_run_dir() {
  local prefix="$1" root="$2"
  local matches=()
  mapfile -t matches < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name "${prefix}-*" -print | sort)
  [[ ${#matches[@]} -eq 1 ]] || die "expected one artifact directory for ${prefix}, observed ${#matches[@]}"
  printf '%s' "${matches[0]}"
}

check_permissions() {
  local permission answer args
  for permission in \
    "list nodes" \
    "list pods --all-namespaces" \
    "list pods --namespace ${E02_CNI_NAMESPACE}" \
    "get namespaces" \
    "get configmaps --namespace ${HOOKE_SYSTEM_NAMESPACE}" \
    "get leases.coordination.k8s.io --namespace ${HOOKE_SYSTEM_NAMESPACE}" \
    "create leases.coordination.k8s.io --namespace ${HOOKE_SYSTEM_NAMESPACE}" \
    "delete leases.coordination.k8s.io --namespace ${HOOKE_SYSTEM_NAMESPACE}"; do
    # shellcheck disable=SC2206
    args=($permission)
    answer="$(kube auth can-i "${args[@]}" 2>/dev/null || true)"
    [[ "$answer" == yes ]] || die "kube permission denied: kubectl auth can-i ${permission}"
  done
}

log "E02 preflight: context=${EFFECTIVE_CONTEXT}, runs=$((E02_PILOT_REPETITIONS * 2)), seed=${E02_RANDOM_SEED}"
check_permissions
kube get namespace "$HOOKE_SYSTEM_NAMESPACE" >/dev/null 2>&1 || die "HOOKE_SYSTEM_NAMESPACE does not exist: $HOOKE_SYSTEM_NAMESPACE"

POOL_CHECK="$SESSION_DIR/node-pool-check.json"
run_pool_hook check "$POOL_CHECK"
validate_control check "$POOL_CHECK"

FIRST_RUN=true
CHECK_ARTIFACT_ROOT="$SESSION_DIR/child-checks"
mkdir -p "$CHECK_ARTIFACT_ROOT"
for variant in cold-node warm-node; do
  make_child_config "$variant" 0 0 1 "$CHECK_ARTIFACT_ROOT" true
  run_managed "$E02_CHILD_RUN_TIMEOUT_SECONDS" "${variant} child preflight" \
    "$SCRIPT_DIR/ack-first-smoke.sh" --config "$TEMP_CONFIG" --check-only
  rm -f -- "$TEMP_CONFIG"
  TEMP_CONFIG=""
done

if [[ "$CHECK_ONLY" == true ]]; then
  capture_pool "$SESSION_DIR/current-pool"
  cat "$SCHEDULE_FILE"
  log "E02 check-only complete; no workload, cache, Lease, or node-pool mutation was performed"
  exit 0
fi

[[ "$CONFIRM_E02_POOL_MUTATION" == yes ]] || die "set CONFIRM_E02_POOL_MUTATION=yes before changing node-pool min size"
acquire_lock
if ! ACTIVE_RUN="$(kube --request-timeout=30s -n "$HOOKE_SYSTEM_NAMESPACE" get configmap hooke-active-run \
    --ignore-not-found -o jsonpath='{.data.run_id}' 2>/dev/null)"; then
  die "failed to query hooke-active-run after acquiring the E02 Lease"
fi
[[ -z "$ACTIVE_RUN" ]] || die "another Hooke run is active: $ACTIVE_RUN"

POOL_SNAPSHOT="$SESSION_DIR/node-pool-snapshot.json"
run_pool_hook snapshot "$POOL_SNAPSHOT"
validate_control snapshot "$POOL_SNAPSHOT"

cp -- "$IMAGE_METADATA_PATH" "$SESSION_DIR/image-build.env"
chmod 600 "$SESSION_DIR/image-build.env"
sed -E \
  -e 's/^([A-Za-z0-9_]*(PASSWORD|TOKEN|DSN|SECRET|ACCESS_KEY|CREDENTIAL)[A-Za-z0-9_]*)=.*/\1="<redacted>"/' \
  "$CONFIG_FILE" >"$SESSION_DIR/e02.env.redacted"
chmod 600 "$SESSION_DIR/e02.env.redacted"
kube version -o json >"$SESSION_DIR/kubernetes-version.json"
kube get nodes -o json >"$SESSION_DIR/nodes-at-session-start.json"
python3 - "$SESSION_NAME" "$EFFECTIVE_CONTEXT" "$EFFECTIVE_API_SERVER" "$(git rev-parse HEAD)" "$IMAGE_BUILD_COMMIT" "$E02_RANDOM_SEED" "$E02_PILOT_REPETITIONS" "$E02_IMAGE" "$E02_NODE_POOL_ID" >"$SESSION_DIR/session.json" <<'PY'
import json, sys
keys = ["session", "kube_context", "api_server", "orchestrator_commit", "image_build_commit", "random_seed", "repetitions_per_variant", "image", "node_pool_id"]
value = dict(zip(keys, sys.argv[1:]))
value["random_seed"] = int(value["random_seed"])
value["repetitions_per_variant"] = int(value["repetitions_per_variant"])
print(json.dumps(value, indent=2, sort_keys=True))
PY
chmod 600 "$SESSION_DIR/session.json"

RUN_INDEX="$SESSION_DIR/run-index.tsv"
printf 'sequence\tblock\tvariant\trepetition\tartifact_dir\tvalidation\n' >"$RUN_INDEX"
chmod 600 "$RUN_INDEX"
FIRST_RUN=true

while IFS=$'\t' read -r sequence block variant repetition; do
  [[ "$sequence" != sequence ]] || continue
  log "E02 sequence ${sequence}: block=${block}, variant=${variant}, repetition=${repetition}"
  desired_min=0
  [[ "$variant" == warm-node ]] && desired_min=1
  if [[ "$desired_min" == 0 ]]; then
    assert_scale_down_safe "$sequence" || die "refusing unsafe dedicated-pool scale-down"
  fi
  control_evidence="$SESSION_DIR/node-pool-set-${sequence}-${variant}.json"
  # Treat any mutation attempt as state-changing, even if the hook exits before
  # writing valid evidence. The EXIT trap must still restore the snapshot.
  POOL_MUTATED=true
  run_pool_hook set-min "$control_evidence" --min-size "$desired_min"
  validate_control set-min "$control_evidence" --min-size "$desired_min"

  state_prefix="$SESSION_DIR/state-${sequence}-${variant}"
  state_evidence="$SESSION_DIR/state-${sequence}-${variant}.json"
  if [[ "$variant" == cold-node ]]; then
    wait_pool_state cold-node "$state_prefix" "$state_evidence"
  else
    initial_state="$SESSION_DIR/state-${sequence}-${variant}-initial.json"
    wait_pool_state warm-node "$state_prefix" "$initial_state"
    if (( E02_WARM_STABILITY_SECONDS > 0 )); then sleep "$E02_WARM_STABILITY_SECONDS"; fi
    wait_pool_state warm-node "$state_prefix" "$state_evidence"
    same_state_node "$initial_state" "$state_evidence" || die "warm Node changed during stability window"
    run_managed "$E02_CACHE_HOOK_TIMEOUT_SECONDS" "warm cache reset" \
      "$CACHE_RESET_HOOK" --image "$E02_IMAGE" \
      --selector-key "$ELASTIC_NODE_SELECTOR_KEY" --selector-value "$ELASTIC_NODE_SELECTOR_VALUE" \
      --reason e02-warm-node-cold-image --evidence "$SESSION_DIR/cache-reset-${sequence}.json"
    run_managed "$E02_CACHE_HOOK_TIMEOUT_SECONDS" "warm cache verification" \
      "$CACHE_VERIFY_HOOK" --state cold --image "$E02_IMAGE" \
      --selector-key "$ELASTIC_NODE_SELECTOR_KEY" --selector-value "$ELASTIC_NODE_SELECTOR_VALUE" \
      --evidence "$SESSION_DIR/cache-cold-${sequence}.json"
    wait_cache_helpers_gone
    final_state="$SESSION_DIR/state-${sequence}-${variant}-post-cache.json"
    wait_pool_state warm-node "$state_prefix" "$final_state"
    same_state_node "$state_evidence" "$final_state" || die "warm Node changed during cache preparation"
    cp -- "$final_state" "$state_evidence"
  fi

  pool_before="$SESSION_DIR/pool-before-run-${sequence}.json"
  cp -- "${state_prefix}-nodes.json" "$pool_before"
  chmod 600 "$pool_before"

  make_child_config "$variant" "$sequence" "$block" "$repetition" "$SESSION_DIR/runs" false
  run_prefix="$CHILD_RUN_PREFIX"
  child_log="$SESSION_DIR/run-${sequence}-${variant}-r${repetition}.log"
  if ! run_managed "$E02_CHILD_RUN_TIMEOUT_SECONDS" "${variant} child run" \
      "$SCRIPT_DIR/ack-first-smoke.sh" --config "$TEMP_CONFIG" >"$child_log" 2>&1; then
    tail -n 120 "$child_log" >&2 || true
    die "${variant} child run failed; see ${child_log}"
  fi
  cat "$child_log"
  rm -f -- "$TEMP_CONFIG"
  TEMP_CONFIG=""
  FIRST_RUN=false

  run_dir="$(locate_run_dir "$run_prefix" "$SESSION_DIR/runs")"
  cleanup_session_active_run || die "failed to verify child active-run cleanup"
  pool_after_prefix="$SESSION_DIR/pool-after-run-${sequence}"
  capture_pool "$pool_after_prefix"
  # Use the child's in-run node snapshot for the Gate.  With min=0, ACK may
  # remove a cold Node after the workload is released but before this parent
  # process regains control; that is a valid run, not missing evidence.
  pool_after="$run_dir/nodes-after.json"
  validation="$run_dir/e02-validation.json"
  validation_args=(
    validate-run --variant "$variant" --artifact-dir "$run_dir"
    --cluster-id "$CLUSTER_ID"
    --pool-before "$pool_before" --pool-after "$pool_after"
    --selector-key "$ELASTIC_NODE_SELECTOR_KEY"
    --selector-value "$ELASTIC_NODE_SELECTOR_VALUE"
    --taint-key "$ELASTIC_TAINT_KEY" --taint-value "$ELASTIC_TAINT_VALUE"
    --taint-effect "$ELASTIC_TAINT_EFFECT"
    --image "$E02_IMAGE" --instance-type "$E02_EXPECTED_INSTANCE_TYPE"
    --command-json "$E02_SMOKE_COMMAND_JSON"
    --startup-work-mib "$E02_STARTUP_WORK_MIB"
    --cpu-request "$E02_CPU_REQUEST" --cpu-limit "$E02_CPU_LIMIT"
    --memory-request "$E02_MEMORY_REQUEST" --memory-limit "$E02_MEMORY_LIMIT"
    --min-download-bytes "$IMAGE_MIN_DOWNLOAD_BYTES"
    --zone "$E02_EXPECTED_ZONE" --output "$validation"
  )
  if [[ "$variant" == warm-node ]]; then
    validation_args+=(--warm-state "$state_evidence")
    if is_true "$E02_REQUIRE_CNI_READY"; then validation_args+=(--require-warm-cni); fi
  fi
  "$HELPER" "${validation_args[@]}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sequence" "$block" "$variant" "$repetition" "$run_dir" "$validation" >>"$RUN_INDEX"
done <"$SCHEDULE_FILE"

wait_privileged_helpers_gone || die "privileged experiment helpers remain"
"$HELPER" summarize --run-index "$RUN_INDEX" --schedule "$SCHEDULE_FILE" \
  --expected-repetitions "$E02_PILOT_REPETITIONS" \
  --expected-seed "$E02_RANDOM_SEED" \
  --observations "$SESSION_DIR/observations.tsv" \
  --output "$SESSION_DIR/summary.json"

cleanup_child_namespaces || die "failed to verify E02 child namespace cleanup"
restore_pool || die "node-pool restore failed"
release_lock || die "failed to release E02 Lease"
log "E02 pilot code path complete: ${SESSION_DIR}"
