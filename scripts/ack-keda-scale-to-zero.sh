#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${SCRIPT_DIR}/e04-keda-scale-to-zero.py"
APPLICATION_EXPORTER="${SCRIPT_DIR}/export-application-events.py"
CONFIG_FILE="${PROJECT_ROOT}/configs/keda-scale-to-zero.env"
CHECK_ONLY=false

usage() {
  cat <<USAGE
Usage: $0 [--config PATH] [--check-only]

Runs the randomized E04 KEDA scale-to-zero pilot: Redis list -> KEDA
ScaledObject -> worker Deployment, with cooldown 60/300 seconds in paired
randomized blocks.

--check-only validates local configuration, image provenance, Kubernetes
identity/RBAC, KEDA readiness, the external metrics API, and fixed-node
capacity. It does not create a Lease, namespace, Secret, workload, database
run, or metric sampler.
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
: "${CONFIRM_E04_EXECUTION:=no}"
: "${REQUIRE_CLEAN_GIT:=true}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${CLUSTER_ID:=}"
: "${HOOKE_SYSTEM_NAMESPACE:=hooke-system}"
: "${KEDA_NAMESPACE:=keda}"
: "${ARTIFACT_ROOT:=artifacts}"
: "${E04_PILOT_REPETITIONS:=5}"
: "${E04_RANDOM_SEED:=20260724}"
: "${E04_COOLDOWNS_SECONDS:=60,300}"
: "${E04_POLLING_INTERVAL_SECONDS:=5}"
: "${E04_MIN_REPLICAS:=0}"
: "${E04_MAX_REPLICAS:=4}"
: "${E04_LAMBDA_PER_SECOND:=1}"
: "${E04_MESSAGE_COUNT:=12}"
: "${E04_PROCESSING_DURATION:=2s}"
: "${E04_QUEUE_SAMPLE_INTERVAL:=1s}"
: "${E04_METRIC_SAMPLE_INTERVAL_SECONDS:=1}"
: "${E04_METRIC_SAMPLE_MAX_GAP_SECONDS:=5}"
: "${E04_LIST_LENGTH:=1}"
: "${E04_ACTIVATION_LIST_LENGTH:=0}"
: "${E04_ARRIVAL_RATE_RELATIVE_TOLERANCE:=0.15}"
: "${E04_TARGET_ELASTICITY:=0.99}"
: "${E04_MAXIMUM_RECOMMENDED_COOLDOWN_SECONDS:=86400}"
: "${E04_IMAGE_METADATA_FILE:=dist/e04-image.env}"
: "${E04_APP_IMAGE:=}"
: "${E04_REDIS_IMAGE:=}"
: "${E04_NODE_SELECTOR_KEY:=}"
: "${E04_NODE_SELECTOR_VALUE:=}"
: "${E04_TAINT_KEY:=}"
: "${E04_TAINT_VALUE:=}"
: "${E04_TAINT_EFFECT:=NoSchedule}"
: "${E04_REDIS_CPU_REQUEST:=100m}"
: "${E04_REDIS_CPU_LIMIT:=500m}"
: "${E04_REDIS_MEMORY_REQUEST:=128Mi}"
: "${E04_REDIS_MEMORY_LIMIT:=256Mi}"
: "${E04_WORKER_CPU_REQUEST:=100m}"
: "${E04_WORKER_CPU_LIMIT:=500m}"
: "${E04_WORKER_MEMORY_REQUEST:=64Mi}"
: "${E04_WORKER_MEMORY_LIMIT:=128Mi}"
: "${E04_PRODUCER_CPU_REQUEST:=50m}"
: "${E04_PRODUCER_CPU_LIMIT:=250m}"
: "${E04_PRODUCER_MEMORY_REQUEST:=32Mi}"
: "${E04_PRODUCER_MEMORY_LIMIT:=64Mi}"
: "${E04_APP_EVENT_MODE:=log}"
: "${INGESTER_BIND_ADDRESS:=127.0.0.1}"
: "${INGESTER_PORT:=18080}"
: "${CONTROLLER_METRICS_PORT:=18081}"
: "${HOOKE_AUTH_TOKEN:=}"
: "${E04_SCALEDOBJECT_READY_TIMEOUT_SECONDS:=180}"
: "${E04_INITIAL_ZERO_TIMEOUT_SECONDS:=300}"
: "${E04_INITIAL_METRIC_TIMEOUT_SECONDS:=120}"
: "${E04_PRODUCER_TIMEOUT_SECONDS:=900}"
: "${E04_SCALE_ZERO_TIMEOUT_SECONDS:=480}"
: "${E04_METRIC_REQUEST_TIMEOUT_SECONDS:=15}"
: "${E04_METRIC_MAX_CONSECUTIVE_ERRORS:=10}"
: "${CONTROLLER_WARMUP_SECONDS:=5}"
: "${EVENT_SETTLE_SECONDS:=5}"
: "${MYSQL_MODE:=docker}"
: "${MYSQL_DOCKER_IMAGE:=mysql:8.4}"
: "${MYSQL_CONTAINER_NAME:=hooke-e04-mysql}"
: "${MYSQL_VOLUME_NAME:=hooke-e04-mysql-data}"
: "${MYSQL_HOST_PORT:=14306}"
: "${MYSQL_DATABASE:=hooke}"
: "${MYSQL_USER:=hooke}"
: "${MYSQL_PASSWORD:=hooke}"
: "${MYSQL_ROOT_PASSWORD:=root}"
: "${MYSQL_DSN:=}"
: "${RESET_MYSQL:=false}"
: "${STOP_MYSQL_ON_EXIT:=false}"
: "${SKIP_BUILD:=false}"
: "${GOPROXY:=}"
: "${CLEANUP_K8S_ON_SUCCESS:=true}"
: "${CLEANUP_K8S_ON_ERROR:=true}"
: "${E04_QUEUE_KEY:=hooke:e04:queue}"
: "${E04_COMPLETION_KEY:=hooke:e04:completed}"

require_cmd kubectl
require_cmd python3
require_cmd git
require_cmd curl
require_cmd mktemp
[[ -x "$HELPER" ]] || die "E04 helper must be executable: $HELPER"
[[ -x "$APPLICATION_EXPORTER" ]] || die "application exporter must be executable: $APPLICATION_EXPORTER"

[[ "$CONFIRM_KUBE_CONTEXT" == yes ]] || die "set CONFIRM_KUBE_CONTEXT=yes after verifying the target cluster"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
[[ -n "$EXPECTED_API_SERVER_SUBSTRING" ]] || die "EXPECTED_API_SERVER_SUBSTRING is required"
[[ -n "$CLUSTER_ID" ]] || die "CLUSTER_ID is required"
[[ -n "$HOOKE_SYSTEM_NAMESPACE" && -n "$KEDA_NAMESPACE" ]] || die "Hooke and KEDA namespaces are required"
[[ "$E04_PILOT_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die "E04_PILOT_REPETITIONS must be positive"
[[ "$E04_RANDOM_SEED" =~ ^[0-9]+$ ]] || die "E04_RANDOM_SEED must be non-negative"
[[ "$E04_COOLDOWNS_SECONDS" == 60,300 ]] || die "E04 pilot cooldowns are frozen at 60,300"
[[ "$E04_POLLING_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "E04_POLLING_INTERVAL_SECONDS must be positive"
[[ "$E04_MIN_REPLICAS" == 0 ]] || die "E04 pilot requires minReplicaCount=0"
[[ "$E04_MAX_REPLICAS" == 4 ]] || die "E04 pilot requires maxReplicaCount=4"
[[ "$E04_MESSAGE_COUNT" =~ ^[1-9][0-9]*$ ]] || die "E04_MESSAGE_COUNT must be positive"
[[ "$E04_LIST_LENGTH" =~ ^[1-9][0-9]*$ ]] || die "E04_LIST_LENGTH must be positive"
[[ "$E04_ACTIVATION_LIST_LENGTH" =~ ^[0-9]+$ ]] || die "E04_ACTIVATION_LIST_LENGTH must be non-negative"
[[ "$E04_SCALEDOBJECT_READY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid ScaledObject timeout"
[[ "$E04_INITIAL_ZERO_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid initial-zero timeout"
[[ "$E04_INITIAL_METRIC_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid initial-metric timeout"
[[ "$E04_PRODUCER_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid producer timeout"
[[ "$E04_SCALE_ZERO_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid scale-zero timeout"
[[ "$E04_METRIC_MAX_CONSECUTIVE_ERRORS" =~ ^[1-9][0-9]*$ ]] || die "invalid metric error limit"
(( E04_SCALE_ZERO_TIMEOUT_SECONDS >= 300 + E04_POLLING_INTERVAL_SECONDS )) || \
  die "scale-zero timeout must cover the 300-second cooldown"
(( E04_PRODUCER_TIMEOUT_SECONDS <= 3600 )) || die "producer timeout cannot exceed 3600 seconds"
(( E04_SCALE_ZERO_TIMEOUT_SECONDS <= 1800 )) || die "scale-zero timeout cannot exceed 1800 seconds"

python3 - \
  "$E04_LAMBDA_PER_SECOND" "$E04_METRIC_SAMPLE_INTERVAL_SECONDS" \
  "$E04_METRIC_SAMPLE_MAX_GAP_SECONDS" "$E04_ARRIVAL_RATE_RELATIVE_TOLERANCE" \
  "$E04_TARGET_ELASTICITY" "$E04_MAXIMUM_RECOMMENDED_COOLDOWN_SECONDS" \
  "$E04_METRIC_REQUEST_TIMEOUT_SECONDS" "$E04_PROCESSING_DURATION" \
  "$E04_QUEUE_SAMPLE_INTERVAL" <<'PY' >/dev/null || die "invalid E04 numeric/duration configuration"
import re, sys
positive = [float(value) for value in sys.argv[1:8]]
if any(value <= 0 for value in positive[:3] + positive[5:]):
    raise SystemExit(1)
if not 0 <= positive[3] <= 1 or not 0 < positive[4] <= 1:
    raise SystemExit(1)
duration = re.compile(r"^(?:0|[1-9][0-9]*)(?:ms|s|m)$")
if not duration.fullmatch(sys.argv[8]) or not duration.fullmatch(sys.argv[9]):
    raise SystemExit(1)
PY
python3 - "$E04_LAMBDA_PER_SECOND" <<'PY' >/dev/null || die "E04 pilot lambda is frozen at 1 req/s"
import math, sys
raise SystemExit(0 if math.isclose(float(sys.argv[1]), 1.0) else 1)
PY
python3 - \
  "$E04_REDIS_CPU_REQUEST" "$E04_REDIS_CPU_LIMIT" \
  "$E04_REDIS_MEMORY_REQUEST" "$E04_REDIS_MEMORY_LIMIT" \
  "$E04_WORKER_CPU_REQUEST" "$E04_WORKER_CPU_LIMIT" \
  "$E04_WORKER_MEMORY_REQUEST" "$E04_WORKER_MEMORY_LIMIT" \
  "$E04_PRODUCER_CPU_REQUEST" "$E04_PRODUCER_CPU_LIMIT" \
  "$E04_PRODUCER_MEMORY_REQUEST" "$E04_PRODUCER_MEMORY_LIMIT" \
  >/dev/null <<'PY' || die "E04 resource quantities must be positive and requests cannot exceed limits"
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
        if value <= 0:
            raise SystemExit(1)
    except InvalidOperation:
        raise SystemExit(1)
    values.append(value)
for index in range(0, len(values), 2):
    if values[index] > values[index + 1]:
        raise SystemExit(1)
PY

[[ "$E04_APP_EVENT_MODE" == log ]] || die "E04 runner currently requires E04_APP_EVENT_MODE=log"
[[ "$E04_APP_IMAGE" =~ @sha256:[0-9a-fA-F]{64}$ ]] || die "E04_APP_IMAGE must use an immutable digest"
[[ "$E04_REDIS_IMAGE" =~ @sha256:[0-9a-fA-F]{64}$ ]] || die "E04_REDIS_IMAGE must use an immutable digest"
[[ -n "$E04_NODE_SELECTOR_KEY" && -n "$E04_NODE_SELECTOR_VALUE" ]] || die "E04 fixed node selector is required"
if [[ -n "$E04_TAINT_KEY" || -n "$E04_TAINT_VALUE" ]]; then
  [[ -n "$E04_TAINT_KEY" && -n "$E04_TAINT_VALUE" ]] || die "E04 taint key/value must be set together"
  case "$E04_TAINT_EFFECT" in NoSchedule|PreferNoSchedule|NoExecute) ;; *) die "invalid E04_TAINT_EFFECT" ;; esac
fi
[[ "$INGESTER_BIND_ADDRESS" == 127.0.0.1 || "$INGESTER_BIND_ADDRESS" == localhost ]] || \
  die "log mode keeps the E04 ingester local; use a loopback INGESTER_BIND_ADDRESS"

is_true "$REQUIRE_CLEAN_GIT" || die "E04 requires REQUIRE_CLEAN_GIT=true"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die "E04 requires a clean Git worktree"

if [[ "$E04_IMAGE_METADATA_FILE" = /* ]]; then
  IMAGE_METADATA_PATH="$E04_IMAGE_METADATA_FILE"
else
  IMAGE_METADATA_PATH="${PROJECT_ROOT}/${E04_IMAGE_METADATA_FILE}"
fi
[[ -f "$IMAGE_METADATA_PATH" ]] || die "E04 image metadata not found: $IMAGE_METADATA_PATH"

metadata_value() {
  local key="$1" count value
  count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$IMAGE_METADATA_PATH")"
  [[ "$count" == 1 ]] || die "image metadata must contain exactly one ${key}"
  value="$(awk -v prefix="${key}=" 'index($0,prefix)==1 {sub(prefix,""); print; exit}' "$IMAGE_METADATA_PATH")"
  [[ -n "$value" ]] || die "image metadata value is empty: ${key}"
  printf '%s' "$value"
}

IMAGE_BUILD_COMMIT="$(metadata_value E04_APP_IMAGE_BUILD_COMMIT)"
IMAGE_SOURCE_STATE="$(metadata_value E04_APP_IMAGE_SOURCE_STATE)"
METADATA_APP_IMAGE="$(metadata_value E04_APP_IMAGE)"
[[ "$IMAGE_BUILD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "E04 image build commit is invalid"
[[ "$IMAGE_SOURCE_STATE" == clean ]] || die "E04 app image must be built from a clean worktree"
[[ "$METADATA_APP_IMAGE" == "$E04_APP_IMAGE" ]] || die "E04_APP_IMAGE does not match image metadata"
git cat-file -e "${IMAGE_BUILD_COMMIT}^{commit}" 2>/dev/null || die "E04 image build commit is unavailable"
git merge-base --is-ancestor "$IMAGE_BUILD_COMMIT" HEAD || die "E04 image build commit is not an ancestor of HEAD"
IMAGE_BUILD_INPUTS=(
  examples/keda-redis-app/Dockerfile
  examples/keda-redis-app/Dockerfile.dockerignore
  cmd/keda-redis-app
  internal/buildinfo
  internal/event
  internal/redisresp
  internal/transport
  sdk/go
  go.mod
  go.sum
)
git diff --quiet "$IMAGE_BUILD_COMMIT"..HEAD -- "${IMAGE_BUILD_INPUTS[@]}" || \
  die "E04 app image inputs changed since its build; rebuild and push the image"

if ! is_true "$SKIP_BUILD"; then require_cmd go; fi
if [[ "$MYSQL_MODE" == docker ]]; then
  require_cmd docker
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
elif [[ "$MYSQL_MODE" == external ]]; then
  [[ -n "$MYSQL_DSN" ]] || die "MYSQL_DSN is required for external MySQL"
else
  die "MYSQL_MODE must be docker or external"
fi

KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_PATH")
SAMPLER_CONTEXT_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL+=(--context "$KUBE_CONTEXT")
  SAMPLER_CONTEXT_ARGS=(--context "$KUBE_CONTEXT")
  "${KUBECTL[@]}" config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1 || die "kube context not found: $KUBE_CONTEXT"
  EFFECTIVE_CONTEXT="$KUBE_CONTEXT"
else
  EFFECTIVE_CONTEXT="$(kubectl --kubeconfig "$KUBECONFIG_PATH" config current-context)"
fi
[[ -n "$EFFECTIVE_CONTEXT" ]] || die "no effective kube context"
kube() { "${KUBECTL[@]}" "$@"; }

EFFECTIVE_API_SERVER="$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$EFFECTIVE_API_SERVER" == *"$EXPECTED_API_SERVER_SUBSTRING"* ]] || \
  die "API server does not match EXPECTED_API_SERVER_SUBSTRING"

SESSION_STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
SESSION_NAME="e04-keda-scale-to-zero-pilot-${SESSION_STAMP}"
CHECK_TEMP=false
if [[ "$CHECK_ONLY" == true ]]; then
  SESSION_DIR="$(mktemp -d)"
  CHECK_TEMP=true
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
"$HELPER" schedule --repetitions "$E04_PILOT_REPETITIONS" \
  --seed "$E04_RANDOM_SEED" --cooldowns "$E04_COOLDOWNS_SECONDS" \
  --output "$SCHEDULE_FILE"

INGESTER_PID=""
CONTROLLER_PID=""
CONTROLLER_KUBECONFIG=""
SAMPLER_PID=""
SAMPLER_STOP_FILE=""
CURRENT_RUN_ID=""
CURRENT_RUN_STOPPED=true
CURRENT_NAMESPACE=""
CURRENT_NAMESPACE_UID=""
CURRENT_REDIS_SECRET=""
LOCK_ACQUIRED=false
LOCK_UID=""
LOCK_NAME="hooke-e04-keda-pilot"
SUCCESS=false
MYSQL_TOUCHED=false

terminate_pid() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill -TERM "$pid" >/dev/null 2>&1 || true
    for _ in {1..50}; do
      kill -0 "$pid" >/dev/null 2>&1 || { wait "$pid" >/dev/null 2>&1 || true; return 0; }
      sleep 0.1
    done
    kill -KILL "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
}

stop_sampler() {
  local rc=0
  [[ -n "$SAMPLER_PID" ]] || return 0
  [[ -z "$SAMPLER_STOP_FILE" ]] || touch "$SAMPLER_STOP_FILE"
  for _ in {1..200}; do
    if ! kill -0 "$SAMPLER_PID" >/dev/null 2>&1; then
      if wait "$SAMPLER_PID"; then rc=0; else rc=$?; fi
      SAMPLER_PID=""
      SAMPLER_STOP_FILE=""
      return "$rc"
    fi
    sleep 0.1
  done
  terminate_pid "$SAMPLER_PID"
  SAMPLER_PID=""
  SAMPLER_STOP_FILE=""
  return 1
}

verify_current_namespace() {
  local identity name uid owner
  [[ -n "$CURRENT_NAMESPACE" && -n "$CURRENT_NAMESPACE_UID" && -n "$CURRENT_RUN_ID" ]] || return 1
  identity="$(kube --request-timeout=30s get namespace "$CURRENT_NAMESPACE" \
    --ignore-not-found \
    -o jsonpath='{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.metadata.annotations.hooke\.io/run-id}' \
    2>/dev/null)" || return 1
  [[ -n "$identity" ]] || return 1
  IFS=$'\t' read -r name uid owner <<<"$identity"
  [[ "$name" == "$CURRENT_NAMESPACE" && "$uid" == "$CURRENT_NAMESPACE_UID" && "$owner" == "$CURRENT_RUN_ID" ]]
}

delete_current_namespace() {
  local deadline remaining
  verify_current_namespace || { warn "refusing to delete an E04 namespace whose ownership changed"; return 1; }
  python3 - "$CURRENT_NAMESPACE_UID" <<'PY' | \
    kube --request-timeout=30s delete --raw "/api/v1/namespaces/${CURRENT_NAMESPACE}" -f - >/dev/null
import json, sys
print(json.dumps({
    "apiVersion": "v1",
    "kind": "DeleteOptions",
    "preconditions": {"uid": sys.argv[1]},
    "propagationPolicy": "Foreground",
}, separators=(",", ":")))
PY
  deadline=$((SECONDS + 180))
  while true; do
    remaining="$(kube --request-timeout=10s get namespace "$CURRENT_NAMESPACE" --ignore-not-found -o name 2>/dev/null || true)"
    [[ -z "$remaining" ]] && return 0
    (( SECONDS < deadline )) || { warn "E04 namespace deletion timed out: $CURRENT_NAMESPACE"; return 1; }
    sleep 2
  done
}

delete_current_secret() {
  [[ -n "$CURRENT_REDIS_SECRET" ]] || return 0
  verify_current_namespace || return 1
  local identity uid owner
  identity="$(kube -n "$CURRENT_NAMESPACE" get secret "$CURRENT_REDIS_SECRET" \
    --ignore-not-found -o jsonpath='{.metadata.uid}{"\t"}{.metadata.annotations.hooke\.io/run-id}' 2>/dev/null || true)"
  [[ -n "$identity" ]] || return 0
  IFS=$'\t' read -r uid owner <<<"$identity"
  [[ -n "$uid" && "$owner" == "$CURRENT_RUN_ID" ]] || return 1
  python3 - "$uid" <<'PY' | \
    kube --request-timeout=30s delete --raw \
      "/api/v1/namespaces/${CURRENT_NAMESPACE}/secrets/${CURRENT_REDIS_SECRET}" -f - >/dev/null
import json, sys
print(json.dumps({
    "apiVersion": "v1",
    "kind": "DeleteOptions",
    "preconditions": {"uid": sys.argv[1]},
}, separators=(",", ":")))
PY
}

clear_current_run() {
  CURRENT_RUN_ID=""
  CURRENT_RUN_STOPPED=true
  CURRENT_NAMESPACE=""
  CURRENT_NAMESPACE_UID=""
  CURRENT_REDIS_SECRET=""
}

release_lock() {
  [[ "$LOCK_ACQUIRED" == true ]] || return 0
  local identity uid holder
  identity="$(kube -n "$HOOKE_SYSTEM_NAMESPACE" get lease.coordination.k8s.io "$LOCK_NAME" \
    --ignore-not-found -o jsonpath='{.metadata.uid}{"\t"}{.spec.holderIdentity}' 2>/dev/null || true)"
  [[ -n "$identity" ]] || { LOCK_ACQUIRED=false; return 0; }
  IFS=$'\t' read -r uid holder <<<"$identity"
  [[ "$uid" == "$LOCK_UID" && "$holder" == "$SESSION_NAME" ]] || {
    warn "refusing to delete an E04 Lease whose ownership changed"
    return 1
  }
  python3 - "$LOCK_UID" <<'PY' | \
    kube --request-timeout=30s delete --raw \
      "/apis/coordination.k8s.io/v1/namespaces/${HOOKE_SYSTEM_NAMESPACE}/leases/${LOCK_NAME}" -f - >/dev/null
import json, sys
print(json.dumps({
    "apiVersion": "coordination.k8s.io/v1",
    "kind": "DeleteOptions",
    "preconditions": {"uid": sys.argv[1]},
}, separators=(",", ":")))
PY
  LOCK_ACQUIRED=false
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  trap '' INT TERM
  stop_sampler || rc=1
  if [[ -n "$CURRENT_RUN_ID" && "$CURRENT_RUN_STOPPED" == false && -x "$PROJECT_ROOT/bin/hookectl" ]]; then
    token_args=()
    [[ -n "$HOOKE_AUTH_TOKEN" ]] && token_args=(--token "$HOOKE_AUTH_TOKEN")
    "$PROJECT_ROOT/bin/hookectl" run stop --api "http://127.0.0.1:${INGESTER_PORT}" \
      "${token_args[@]}" --run-id "$CURRENT_RUN_ID" >/dev/null 2>&1 || true
    CURRENT_RUN_STOPPED=true
  fi
  terminate_pid "$CONTROLLER_PID"
  terminate_pid "$INGESTER_PID"
  if [[ -n "$CONTROLLER_KUBECONFIG" ]]; then
    rm -f -- "$CONTROLLER_KUBECONFIG"
    CONTROLLER_KUBECONFIG=""
  fi
  if [[ -n "$CURRENT_NAMESPACE" ]]; then
    cleanup_requested="$CLEANUP_K8S_ON_ERROR"
    [[ "$SUCCESS" == true ]] && cleanup_requested="$CLEANUP_K8S_ON_SUCCESS"
    if is_true "$cleanup_requested"; then
      delete_current_namespace || rc=1
    else
      delete_current_secret || rc=1
    fi
  fi
  release_lock || rc=1
  if [[ "$MYSQL_MODE" == docker && "$MYSQL_TOUCHED" == true ]] && is_true "$STOP_MYSQL_ON_EXIT"; then
    docker stop "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  if [[ "$CHECK_TEMP" == true && -n "$SESSION_DIR" ]]; then
    rm -rf -- "$SESSION_DIR"
  fi
  if [[ $rc -ne 0 && "$CHECK_ONLY" == false ]]; then
    warn "E04 failed; retained artifacts: ${SESSION_DIR}"
    [[ -f "$SESSION_DIR/controller.log" ]] && tail -n 80 "$SESSION_DIR/controller.log" >&2 || true
  elif [[ "$CHECK_ONLY" == false ]]; then
    log "E04 artifacts: ${SESSION_DIR}"
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

check_permission() {
  local verb="$1" resource="$2" namespace="${3:-}"
  local answer args=(auth can-i "$verb" "$resource")
  if [[ "$namespace" == "*" ]]; then
    args+=(--all-namespaces)
  elif [[ -n "$namespace" ]]; then
    args+=(--namespace "$namespace")
  fi
  answer="$(kube "${args[@]}" 2>/dev/null || true)"
  [[ "$answer" == yes ]] || die "Kubernetes permission denied: ${verb} ${resource}${namespace:+ in ${namespace}}"
}

for permission in \
  "get namespaces" "create namespaces" "delete namespaces" \
  "get nodes" "list nodes" \
  "get customresourcedefinitions.apiextensions.k8s.io" \
  "get apiservices.apiregistration.k8s.io"; do
  # shellcheck disable=SC2086
  check_permission $permission
done
for permission in \
  "list namespaces" "watch namespaces" \
  "list nodes" "watch nodes" \
  "list pods" "watch pods" \
  "list events" "watch events" \
  "list deployments.apps" "watch deployments.apps" \
  "list horizontalpodautoscalers.autoscaling" "watch horizontalpodautoscalers.autoscaling" \
  "list scaledobjects.keda.sh" "watch scaledobjects.keda.sh"; do
  # shellcheck disable=SC2086
  check_permission $permission "*"
done
for permission in \
  "get deployments.apps" "list deployments.apps" "watch deployments.apps" "create deployments.apps" "delete deployments.apps" \
  "get services" "create services" "delete services" \
  "get secrets" "create secrets" "delete secrets" \
  "get pods" "list pods" "get pods/log" \
  "get jobs.batch" "watch jobs.batch" "create jobs.batch" "delete jobs.batch" \
  "get scaledobjects.keda.sh" "list scaledobjects.keda.sh" "create scaledobjects.keda.sh" "delete scaledobjects.keda.sh" \
  "get horizontalpodautoscalers.autoscaling" "list horizontalpodautoscalers.autoscaling"; do
  # shellcheck disable=SC2086
  check_permission $permission default
done
for permission in \
  "get leases.coordination.k8s.io" "create leases.coordination.k8s.io" "delete leases.coordination.k8s.io"; do
  # shellcheck disable=SC2086
  check_permission $permission "$HOOKE_SYSTEM_NAMESPACE"
done

kube get namespace "$HOOKE_SYSTEM_NAMESPACE" >/dev/null
kube get namespace "$KEDA_NAMESPACE" >/dev/null
kube get customresourcedefinition scaledobjects.keda.sh -o json >"$SESSION_DIR/keda-scaledobject-crd.json"
kube get apiservice v1beta1.external.metrics.k8s.io -o json >"$SESSION_DIR/external-metrics-apiservice.json"
python3 - "$SESSION_DIR/external-metrics-apiservice.json" <<'PY' >/dev/null || die "external metrics APIService is not Available"
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
conditions = payload.get("status", {}).get("conditions", [])
raise SystemExit(0 if any(item.get("type") == "Available" and item.get("status") == "True" for item in conditions) else 1)
PY
kube get --raw "/apis/external.metrics.k8s.io/v1beta1" >"$SESSION_DIR/external-metrics-resources.json"
kube -n "$KEDA_NAMESPACE" get deployments.apps -o json >"$SESSION_DIR/keda-deployments.json"
python3 - "$SESSION_DIR/keda-deployments.json" <<'PY' >/dev/null || die "KEDA operator/metrics deployments are not Ready"
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8")).get("items", [])
ready = {
    item.get("metadata", {}).get("name", ""): int(item.get("status", {}).get("readyReplicas") or 0)
    for item in items
}
operator = any("operator" in name and "metrics" not in name and count > 0 for name, count in ready.items())
metrics = any("metrics" in name and count > 0 for name, count in ready.items())
raise SystemExit(0 if operator and metrics else 1)
PY

kube get nodes -l "${E04_NODE_SELECTOR_KEY}=${E04_NODE_SELECTOR_VALUE}" -o json >"$SESSION_DIR/target-nodes.json"
READY_NODE_COUNT="$(python3 - "$SESSION_DIR/target-nodes.json" "$E04_TAINT_KEY" \
  "$E04_TAINT_VALUE" "$E04_TAINT_EFFECT" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
taint = tuple(sys.argv[2:5])
ready = []
for node in payload.get("items", []):
    conditions = node.get("status", {}).get("conditions", [])
    if not any(item.get("type") == "Ready" and item.get("status") == "True" for item in conditions):
        continue
    if node.get("spec", {}).get("unschedulable") is True:
        continue
    taints = node.get("spec", {}).get("taints", [])
    if taint[0]:
        if not any((item.get("key"), item.get("value"), item.get("effect")) == taint for item in taints):
            continue
    unsupported = [
        item for item in taints
        if item.get("effect") in ("NoSchedule", "NoExecute")
        and (item.get("key"), item.get("value"), item.get("effect")) != taint
    ]
    if unsupported:
        continue
    ready.append(node)
if not ready:
    raise SystemExit(1)
print(len(ready))
PY
)" || die "no Ready fixed Node satisfies the E04 selector/taint"

log "E04 preflight passed: context=${EFFECTIVE_CONTEXT}, fixed_ready=${READY_NODE_COUNT}, runs=$((E04_PILOT_REPETITIONS * 2))"
if [[ "$CHECK_ONLY" == true ]]; then
  cat "$SCHEDULE_FILE"
  log "E04 check-only complete; no Lease, namespace, workload, database run, or sampler was created"
  exit 0
fi

[[ "$CONFIRM_E04_EXECUTION" == yes ]] || die "set CONFIRM_E04_EXECUTION=yes before running E04"

acquire_lock() {
  local lease_json
  lease_json="$(python3 - "$LOCK_NAME" "$HOOKE_SYSTEM_NAMESPACE" "$SESSION_NAME" <<'PY' | kube create -f - -o json
import json, sys
from datetime import datetime, timezone
now = datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
print(json.dumps({
    "apiVersion": "coordination.k8s.io/v1",
    "kind": "Lease",
    "metadata": {"name": sys.argv[1], "namespace": sys.argv[2]},
    "spec": {
        "holderIdentity": sys.argv[3],
        "leaseDurationSeconds": 14400,
        "acquireTime": now,
        "renewTime": now,
    },
}, separators=(",", ":")))
PY
  )" || die "failed to acquire E04 Lease ${HOOKE_SYSTEM_NAMESPACE}/${LOCK_NAME}; another session may be active"
  LOCK_UID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["uid"])' <<<"$lease_json")"
  [[ -n "$LOCK_UID" ]] || die "E04 Lease response has no UID"
  LOCK_ACQUIRED=true
}
acquire_lock

CONTROLLER_KUBECONFIG="$(mktemp "${TMPDIR:-/tmp}/hooke-e04-kubeconfig.XXXXXX")"
chmod 600 "$CONTROLLER_KUBECONFIG"
kube config view --minify --raw --flatten >"$CONTROLLER_KUBECONFIG"
[[ -s "$CONTROLLER_KUBECONFIG" ]] || die "failed to freeze the target kube context for hooke-controller"

cp -- "$IMAGE_METADATA_PATH" "$SESSION_DIR/image-build.env"
chmod 600 "$SESSION_DIR/image-build.env"
sed -E \
  -e 's/^([A-Za-z0-9_]*(PASSWORD|TOKEN|DSN|SECRET|ACCESS_KEY|CREDENTIAL)[A-Za-z0-9_]*)=.*/\1="<redacted>"/' \
  "$CONFIG_FILE" >"$SESSION_DIR/e04.env.redacted"
chmod 600 "$SESSION_DIR/e04.env.redacted"
kube version -o json >"$SESSION_DIR/kubernetes-version.json"
python3 - "$SESSION_NAME" "$EFFECTIVE_CONTEXT" "$EFFECTIVE_API_SERVER" \
  "$(git rev-parse HEAD)" "$IMAGE_BUILD_COMMIT" "$E04_RANDOM_SEED" \
  "$E04_PILOT_REPETITIONS" "$E04_APP_IMAGE" "$E04_REDIS_IMAGE" >"$SESSION_DIR/session.json" <<'PY'
import json, sys
keys = ["session", "kube_context", "api_server", "orchestrator_commit", "image_build_commit", "random_seed", "repetitions_per_cell", "app_image", "redis_image"]
value = dict(zip(keys, sys.argv[1:]))
value["random_seed"] = int(value["random_seed"])
value["repetitions_per_cell"] = int(value["repetitions_per_cell"])
value["design"] = {"lambda": 1, "cooldown_seconds": [60, 300], "min_replicas": 0, "max_replicas": 4}
print(json.dumps(value, indent=2, sort_keys=True))
PY
chmod 600 "$SESSION_DIR/session.json"

port_is_free() {
  python3 - "$1" <<'PY'
import socket, sys
sock = socket.socket()
try:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}
port_is_free "$INGESTER_PORT" || die "INGESTER_PORT is already in use: $INGESTER_PORT"
port_is_free "$CONTROLLER_METRICS_PORT" || die "CONTROLLER_METRICS_PORT is already in use: $CONTROLLER_METRICS_PORT"

if [[ "$MYSQL_MODE" == docker ]]; then
  [[ "$MYSQL_USER" =~ ^[A-Za-z0-9_.-]+$ && "$MYSQL_PASSWORD" =~ ^[A-Za-z0-9_.-]+$ && \
     "$MYSQL_DATABASE" =~ ^[A-Za-z0-9_.-]+$ ]] || \
    die "docker MySQL user/password/database must use [A-Za-z0-9_.-]"
  if is_true "$RESET_MYSQL"; then
    warn "RESET_MYSQL=true: deleting ${MYSQL_CONTAINER_NAME} and ${MYSQL_VOLUME_NAME}"
    docker rm -f "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker volume rm "$MYSQL_VOLUME_NAME" >/dev/null 2>&1 || true
  fi
  if ! docker container inspect "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1; then
    docker volume create "$MYSQL_VOLUME_NAME" >/dev/null
    docker run -d --name "$MYSQL_CONTAINER_NAME" \
      --label hooke.io/component=mysql-e04 \
      -e MYSQL_DATABASE="$MYSQL_DATABASE" \
      -e MYSQL_USER="$MYSQL_USER" \
      -e MYSQL_PASSWORD="$MYSQL_PASSWORD" \
      -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
      -e TZ=UTC \
      -p "127.0.0.1:${MYSQL_HOST_PORT}:3306" \
      -v "${MYSQL_VOLUME_NAME}:/var/lib/mysql" \
      "$MYSQL_DOCKER_IMAGE" \
      --default-time-zone=+00:00 \
      --character-set-server=utf8mb4 \
      --collation-server=utf8mb4_0900_ai_ci \
      >"$SESSION_DIR/mysql-container-id.txt"
  else
    docker start "$MYSQL_CONTAINER_NAME" >/dev/null
  fi
  MYSQL_TOUCHED=true
  mysql_deadline=$((SECONDS + 180))
  until docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER_NAME" \
      mysqladmin ping -h127.0.0.1 -uroot --silent >/dev/null 2>&1; do
    (( SECONDS < mysql_deadline )) || die "E04 MySQL did not become ready"
    sleep 2
  done
  MYSQL_DSN="${MYSQL_USER}:${MYSQL_PASSWORD}@tcp(127.0.0.1:${MYSQL_HOST_PORT})/${MYSQL_DATABASE}?parseTime=true&loc=UTC&multiStatements=true"
fi

if ! is_true "$SKIP_BUILD"; then
  [[ -n "$GOPROXY" ]] && export GOPROXY
  GOTOOLCHAIN=local go mod download
  mkdir -p bin
  for binary in hooke-migrate hooke-ingester hooke-controller hookectl; do
    GOTOOLCHAIN=local go build -trimpath -o "bin/${binary}" "./cmd/${binary}"
  done
else
  for binary in hooke-migrate hooke-ingester hooke-controller hookectl; do
    [[ -x "bin/${binary}" ]] || die "SKIP_BUILD=true but bin/${binary} is missing"
  done
fi

HOOKE_MYSQL_DSN="$MYSQL_DSN" bin/hooke-migrate >"$SESSION_DIR/migrate.log" 2>&1
HOOKE_MYSQL_DSN="$MYSQL_DSN" \
HOOKE_HTTP_ADDR="${INGESTER_BIND_ADDRESS}:${INGESTER_PORT}" \
HOOKE_AUTH_TOKEN="$HOOKE_AUTH_TOKEN" \
  bin/hooke-ingester >"$SESSION_DIR/ingester.log" 2>&1 &
INGESTER_PID=$!

wait_http() {
  local url="$1" timeout_seconds="$2" label="$3" deadline=$((SECONDS + timeout_seconds))
  until curl -fsS --max-time 2 "$url" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "timeout waiting for ${label}"
    sleep 1
  done
}
wait_http "http://127.0.0.1:${INGESTER_PORT}/readyz" 60 "E04 ingester"

KUBECONFIG="$CONTROLLER_KUBECONFIG" \
HOOKE_CLUSTER_ID="$CLUSTER_ID" \
HOOKE_INGESTER_URL="http://127.0.0.1:${INGESTER_PORT}" \
HOOKE_AUTH_TOKEN="$HOOKE_AUTH_TOKEN" \
HOOKE_NAMESPACE="$HOOKE_SYSTEM_NAMESPACE" \
HOOKE_CAPTURE_UNLABELED=false \
HOOKE_ACTIVE_RUN_ID="" \
HOOKE_WATCH_ACTIVE_RUN_CONFIGMAP=false \
HOOKE_METRICS_ADDR="127.0.0.1:${CONTROLLER_METRICS_PORT}" \
  bin/hooke-controller >"$SESSION_DIR/controller.log" 2>&1 &
CONTROLLER_PID=$!
wait_http "http://127.0.0.1:${CONTROLLER_METRICS_PORT}/readyz" 90 "E04 controller"
sleep "$CONTROLLER_WARMUP_SECONDS"
kill -0 "$CONTROLLER_PID" >/dev/null 2>&1 || die "E04 controller exited during startup"

TOKEN_ARGS=()
[[ -n "$HOOKE_AUTH_TOKEN" ]] && TOKEN_ARGS=(--token "$HOOKE_AUTH_TOKEN")
RUN_INDEX="$SESSION_DIR/run-index.tsv"
printf 'sequence\tblock\tcell_id\tcooldown_seconds\trun_id\tnamespace\tartifact_dir\tobservation\n' >"$RUN_INDEX"
chmod 600 "$RUN_INDEX"
OBSERVATION_FILES=()

create_namespace() {
  local response
  response="$(python3 - "$CURRENT_NAMESPACE" "$CURRENT_RUN_ID" <<'PY' | kube create -f - -o json
import json, sys
print(json.dumps({
    "apiVersion": "v1",
    "kind": "Namespace",
    "metadata": {
        "name": sys.argv[1],
        "labels": {"hooke.io/experiment": "E04"},
        "annotations": {"hooke.io/run-id": sys.argv[2]},
    },
}, separators=(",", ":")))
PY
  )" || die "failed to create E04 namespace: $CURRENT_NAMESPACE"
  CURRENT_NAMESPACE_UID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["uid"])' <<<"$response")"
  [[ -n "$CURRENT_NAMESPACE_UID" ]] || die "created E04 namespace has no UID"
}

create_redis_secret() {
  local password
  password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  E04_TEMP_REDIS_PASSWORD="$password" python3 - "$CURRENT_NAMESPACE" "$CURRENT_RUN_ID" "$CURRENT_REDIS_SECRET" <<'PY' | kube create -f - >/dev/null
import json, os, sys
print(json.dumps({
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": sys.argv[3],
        "namespace": sys.argv[1],
        "annotations": {"hooke.io/run-id": sys.argv[2]},
        "labels": {"hooke.io/experiment": "E04"},
    },
    "type": "Opaque",
    "stringData": {"password": os.environ["E04_TEMP_REDIS_PASSWORD"]},
}, separators=(",", ":")))
PY
  unset password
}

write_run_config() {
  local output="$1" sequence="$2" block="$3" cell_id="$4" cooldown="$5"
  export CLUSTER_ID E04_POLLING_INTERVAL_SECONDS E04_MIN_REPLICAS E04_MAX_REPLICAS
  export E04_LAMBDA_PER_SECOND E04_MESSAGE_COUNT E04_PROCESSING_DURATION
  export E04_QUEUE_SAMPLE_INTERVAL E04_METRIC_SAMPLE_MAX_GAP_SECONDS
  export E04_LIST_LENGTH E04_ACTIVATION_LIST_LENGTH E04_ARRIVAL_RATE_RELATIVE_TOLERANCE
  export E04_APP_IMAGE E04_REDIS_IMAGE E04_NODE_SELECTOR_KEY E04_NODE_SELECTOR_VALUE
  export E04_TAINT_KEY E04_TAINT_VALUE E04_TAINT_EFFECT E04_PRODUCER_TIMEOUT_SECONDS
  export E04_REDIS_CPU_REQUEST E04_REDIS_CPU_LIMIT E04_REDIS_MEMORY_REQUEST E04_REDIS_MEMORY_LIMIT
  export E04_WORKER_CPU_REQUEST E04_WORKER_CPU_LIMIT E04_WORKER_MEMORY_REQUEST E04_WORKER_MEMORY_LIMIT
  export E04_PRODUCER_CPU_REQUEST E04_PRODUCER_CPU_LIMIT E04_PRODUCER_MEMORY_REQUEST E04_PRODUCER_MEMORY_LIMIT
  export E04_QUEUE_KEY E04_COMPLETION_KEY
  python3 - "$output" "$sequence" "$block" "$cell_id" "$cooldown" <<'PY'
import json, os, sys
def env(name): return os.environ[name]
payload = {
    "sequence": int(sys.argv[2]),
    "block": int(sys.argv[3]),
    "cell_id": sys.argv[4],
    "cooldown_seconds": int(sys.argv[5]),
    "cluster_id": env("CLUSTER_ID"),
    "polling_interval_seconds": int(env("E04_POLLING_INTERVAL_SECONDS")),
    "min_replicas": int(env("E04_MIN_REPLICAS")),
    "max_replicas": int(env("E04_MAX_REPLICAS")),
    "lambda_per_second": float(env("E04_LAMBDA_PER_SECOND")),
    "message_count": int(env("E04_MESSAGE_COUNT")),
    "processing_duration": env("E04_PROCESSING_DURATION"),
    "queue_sample_interval": env("E04_QUEUE_SAMPLE_INTERVAL"),
    "metric_sample_max_gap_seconds": float(env("E04_METRIC_SAMPLE_MAX_GAP_SECONDS")),
    "list_length": env("E04_LIST_LENGTH"),
    "activation_list_length": env("E04_ACTIVATION_LIST_LENGTH"),
    "arrival_rate_relative_tolerance": float(env("E04_ARRIVAL_RATE_RELATIVE_TOLERANCE")),
    "app_image": env("E04_APP_IMAGE"),
    "redis_image": env("E04_REDIS_IMAGE"),
    "node_selector_key": env("E04_NODE_SELECTOR_KEY"),
    "node_selector_value": env("E04_NODE_SELECTOR_VALUE"),
    "taint_key": env("E04_TAINT_KEY"),
    "taint_value": env("E04_TAINT_VALUE"),
    "taint_effect": env("E04_TAINT_EFFECT"),
    "producer_timeout_seconds": int(env("E04_PRODUCER_TIMEOUT_SECONDS")),
    "queue_key": env("E04_QUEUE_KEY"),
    "completion_key": env("E04_COMPLETION_KEY"),
    "redis_name": "redis",
    "worker_name": "worker",
    "producer_name": "producer",
    "scaled_object_name": "worker-scaler",
}
for role in ("redis", "worker", "producer"):
    upper = role.upper()
    for resource in ("cpu", "memory"):
        for bound in ("request", "limit"):
            payload[f"{role}_{resource}_{bound}"] = env(f"E04_{upper}_{resource.upper()}_{bound.upper()}")
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(payload, stream, indent=2, sort_keys=True)
    stream.write("\n")
PY
  chmod 600 "$output"
}

wait_baseline() {
  local run_dir="$1" timeout="$E04_INITIAL_ZERO_TIMEOUT_SECONDS"
  (( E04_SCALEDOBJECT_READY_TIMEOUT_SECONDS > timeout )) && timeout="$E04_SCALEDOBJECT_READY_TIMEOUT_SECONDS"
  local deadline=$((SECONDS + timeout))
  while true; do
    kube -n "$CURRENT_NAMESPACE" get scaledobject.keda.sh worker-scaler -o json \
      >"$run_dir/scaledobject-current.json" 2>/dev/null || true
    kube -n "$CURRENT_NAMESPACE" get deployment.apps worker -o json \
      >"$run_dir/worker-current.json" 2>/dev/null || true
    if python3 - "$run_dir/scaledobject-current.json" "$run_dir/worker-current.json" <<'PY' >/dev/null 2>&1
import json, sys
so = json.load(open(sys.argv[1], encoding="utf-8"))
deployment = json.load(open(sys.argv[2], encoding="utf-8"))
conditions = so.get("status", {}).get("conditions", [])
ready = any(item.get("type") == "Ready" and item.get("status") == "True" for item in conditions)
active = next((item.get("status") for item in conditions if item.get("type") == "Active"), "")
hpa = so.get("status", {}).get("hpaName", "")
status = deployment.get("status", {})
zero = deployment.get("spec", {}).get("replicas") == 0 and all(int(status.get(key) or 0) == 0 for key in ("replicas", "readyReplicas", "availableReplicas"))
raise SystemExit(0 if ready and active in ("", "False") and hpa and zero else 1)
PY
    then
      cp -- "$run_dir/scaledobject-current.json" "$run_dir/scaledobject-initial.json"
      cp -- "$run_dir/worker-current.json" "$run_dir/worker-initial.json"
      HPA_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"]["hpaName"])' "$run_dir/scaledobject-current.json")"
      kube -n "$CURRENT_NAMESPACE" get hpa.autoscaling "$HPA_NAME" -o json >"$run_dir/hpa-initial.json"
      python3 - "$run_dir/worker-initial.json" "$run_dir/scaledobject-initial.json" \
        >"$run_dir/initial-state.json" <<'PY'
import json, sys
print(json.dumps({
    "deployment": json.load(open(sys.argv[1], encoding="utf-8")),
    "scaled_object": json.load(open(sys.argv[2], encoding="utf-8")),
}, indent=2, sort_keys=True))
PY
      return 0
    fi
    (( SECONDS < deadline )) || die "ScaledObject did not become Ready+Inactive with worker replicas zero"
    sleep 2
  done
}

wait_initial_zero_metric() {
  local capture_file="$1" deadline=$((SECONDS + E04_INITIAL_METRIC_TIMEOUT_SECONDS))
  while true; do
    if [[ -s "$capture_file" ]] && python3 - "$capture_file" <<'PY' >/dev/null 2>&1
import json, re, sys
def number(value):
    match = re.fullmatch(r"([+-]?(?:\d+(?:\.\d*)?|\.\d+))(m)?", value)
    if not match: return None
    result = float(match.group(1))
    return result / 1000 if match.group(2) else result
for line in open(sys.argv[1], encoding="utf-8"):
    row = json.loads(line)
    for item in (row.get("payload") or {}).get("items", []):
        if number(str(item.get("value") or "")) == 0:
            raise SystemExit(0)
raise SystemExit(1)
PY
    then
      return 0
    fi
    [[ -n "$SAMPLER_PID" ]] && kill -0 "$SAMPLER_PID" >/dev/null 2>&1 || die "KEDA metric sampler exited before the initial zero sample"
    (( SECONDS < deadline )) || die "KEDA external metric did not expose an initial zero sample"
    sleep 1
  done
}

capture_application_evidence() {
  local run_dir="$1" pod container role
  mkdir -p "$run_dir/application-logs"
  kube -n "$CURRENT_NAMESPACE" get pods \
    -l 'hooke.io/e04-role in (producer,worker)' -o json >"$run_dir/application-pods.json"
  python3 - "$run_dir/application-pods.json" <<'PY' >/dev/null || die "application Pod snapshot is incomplete"
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8")).get("items", [])
roles = [item.get("metadata", {}).get("labels", {}).get("hooke.io/e04-role") for item in items]
if roles.count("producer") != 1 or roles.count("worker") < 1:
    raise SystemExit(1)
for item in items:
    statuses = item.get("status", {}).get("containerStatuses", [])
    if len(statuses) != 1 or not statuses[0].get("containerID"):
        raise SystemExit(1)
PY
  while IFS=$'\t' read -r pod container role; do
    [[ -n "$pod" && -n "$container" ]] || continue
    kube -n "$CURRENT_NAMESPACE" logs "$pod" -c "$container" \
      >"$run_dir/application-logs/${role}-${pod}-${container}.log"
  done < <(python3 - "$run_dir/application-pods.json" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1], encoding="utf-8")).get("items", []):
    metadata = item.get("metadata", {})
    role = metadata.get("labels", {}).get("hooke.io/e04-role", "")
    for container in item.get("spec", {}).get("containers", []):
        print(metadata.get("name", ""), container.get("name", ""), role, sep="\t")
PY
  )
}

wait_scale_to_zero() {
  local run_dir="$1" deadline=$((SECONDS + E04_SCALE_ZERO_TIMEOUT_SECONDS))
  while true; do
    kube -n "$CURRENT_NAMESPACE" get deployment.apps worker -o json \
      >"$run_dir/worker-scale-zero-current.json" 2>/dev/null || true
    kube -n "$CURRENT_NAMESPACE" get scaledobject.keda.sh worker-scaler -o json \
      >"$run_dir/scaledobject-scale-zero-current.json" 2>/dev/null || true
    if python3 - "$run_dir/worker-scale-zero-current.json" "$run_dir/scaledobject-scale-zero-current.json" <<'PY' >/dev/null 2>&1
import json, sys
deployment = json.load(open(sys.argv[1], encoding="utf-8"))
so = json.load(open(sys.argv[2], encoding="utf-8"))
status = deployment.get("status", {})
zero = deployment.get("spec", {}).get("replicas") == 0 and all(int(status.get(key) or 0) == 0 for key in ("replicas", "readyReplicas", "availableReplicas"))
conditions = so.get("status", {}).get("conditions", [])
inactive = any(item.get("type") == "Active" and item.get("status") == "False" for item in conditions)
raise SystemExit(0 if zero and inactive else 1)
PY
    then
      return 0
    fi
    (( SECONDS < deadline )) || die "worker did not scale to zero before the E04 timeout"
    sleep 2
  done
}

while IFS=$'\t' read -r sequence block cell_id cooldown; do
  [[ "$sequence" != sequence ]] || continue
  run_dir="$SESSION_DIR/runs/$(printf '%02d' "$sequence")-${cell_id}"
  mkdir -p "$run_dir"
  chmod 700 "$run_dir"
  run_name="e04-${cell_id}-b${block}-s${sequence}-${SESSION_STAMP}"
  labels_json="$(python3 - "$sequence" "$block" "$cell_id" "$cooldown" <<'PY'
import json, sys
print(json.dumps({
    "experiment": "E04",
    "sequence": int(sys.argv[1]),
    "block": int(sys.argv[2]),
    "cell": sys.argv[3],
    "cooldown_seconds": int(sys.argv[4]),
}, separators=(",", ":")))
PY
  )"
  log "E04 sequence ${sequence}: ${cell_id}"
  bin/hookectl run create --api "http://127.0.0.1:${INGESTER_PORT}" \
    "${TOKEN_ARGS[@]}" --cluster "$CLUSTER_ID" --name "$run_name" \
    --slo-seconds "$E04_PRODUCER_TIMEOUT_SECONDS" --labels-json "$labels_json" \
    >"$run_dir/run.json"
  CURRENT_RUN_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_id"])' "$run_dir/run.json")"
  CURRENT_RUN_STOPPED=false
  namespace_suffix="$(tr '[:upper:]' '[:lower:]' <<<"${CURRENT_RUN_ID:0:8}")"
  CURRENT_NAMESPACE="e04-${sequence}-${namespace_suffix}"
  CURRENT_REDIS_SECRET="redis-auth"
  create_namespace
  create_redis_secret

  run_config="$run_dir/run-config.json"
  write_run_config "$run_config" "$sequence" "$block" "$cell_id" "$cooldown"
  "$HELPER" render --config "$run_config" --namespace "$CURRENT_NAMESPACE" \
    --run-id "$CURRENT_RUN_ID" --redis-secret "$CURRENT_REDIS_SECRET" \
    --base-output "$run_dir/base-manifest.json" \
    --producer-output "$run_dir/producer-manifest.json"
  RUN_START_NS="$(python3 -c 'import time; print(time.time_ns())')"
  printf '%s\n' "$RUN_START_NS" >"$run_dir/run-start-ns.txt"
  kube apply -f "$run_dir/base-manifest.json" >"$run_dir/base-apply.log"
  kube -n "$CURRENT_NAMESPACE" rollout status deployment/redis \
    --timeout="${E04_SCALEDOBJECT_READY_TIMEOUT_SECONDS}s" >"$run_dir/redis-rollout.log"
  wait_baseline "$run_dir"

  SAMPLER_STOP_FILE="$run_dir/stop-keda-sampler"
  rm -f -- "$SAMPLER_STOP_FILE"
  "$HELPER" sample-keda --kubeconfig "$KUBECONFIG_PATH" \
    "${SAMPLER_CONTEXT_ARGS[@]}" \
    --namespace "$CURRENT_NAMESPACE" --scaled-object worker-scaler \
    --output "$run_dir/keda-metric-captures.ndjson" \
    --stop-file "$SAMPLER_STOP_FILE" \
    --interval-seconds "$E04_METRIC_SAMPLE_INTERVAL_SECONDS" \
    --request-timeout-seconds "$E04_METRIC_REQUEST_TIMEOUT_SECONDS" \
    --max-consecutive-errors "$E04_METRIC_MAX_CONSECUTIVE_ERRORS" \
    >"$run_dir/keda-sampler.log" 2>&1 &
  SAMPLER_PID=$!
  wait_initial_zero_metric "$run_dir/keda-metric-captures.ndjson"

  kube apply -f "$run_dir/producer-manifest.json" >"$run_dir/producer-apply.log"
  if ! kube -n "$CURRENT_NAMESPACE" wait --for=condition=Complete job/producer \
      --timeout="${E04_PRODUCER_TIMEOUT_SECONDS}s" >"$run_dir/producer-wait.log" 2>&1; then
    kube -n "$CURRENT_NAMESPACE" get pods -o wide >"$run_dir/pods-on-producer-failure.txt" 2>&1 || true
    kube -n "$CURRENT_NAMESPACE" logs job/producer >"$run_dir/producer-failure.log" 2>&1 || true
    die "E04 producer did not complete: ${cell_id}"
  fi
  capture_application_evidence "$run_dir"
  wait_scale_to_zero "$run_dir"
  sleep "$(python3 -c 'import sys; print(max(1.0, 2*float(sys.argv[1])))' "$E04_METRIC_SAMPLE_INTERVAL_SECONDS")"
  stop_sampler || die "KEDA metric sampler failed: ${cell_id}"
  RUN_END_NS="$(python3 -c 'import time; print(time.time_ns())')"
  printf '%s\n' "$RUN_END_NS" >"$run_dir/run-end-ns.txt"

  kube -n "$CURRENT_NAMESPACE" get deployment.apps worker -o json >"$run_dir/worker-final.json"
  kube -n "$CURRENT_NAMESPACE" get scaledobject.keda.sh worker-scaler -o json >"$run_dir/scaledobject-final.json"
  kube -n "$CURRENT_NAMESPACE" get hpa.autoscaling -o json >"$run_dir/hpa-final.json"
  kube -n "$CURRENT_NAMESPACE" get events -o json >"$run_dir/kubernetes-events.json"

  "$APPLICATION_EXPORTER" --cluster-id "$CLUSTER_ID" --run-id "$CURRENT_RUN_ID" \
    --pods "$run_dir/application-pods.json" --logs-dir "$run_dir/application-logs" \
    --start-ns "$RUN_START_NS" --end-ns "$RUN_END_NS" \
    --output "$run_dir/application-events.ndjson" \
    >"$run_dir/application-export.log" 2>&1
  "$HELPER" normalize-samples --input "$run_dir/keda-metric-captures.ndjson" \
    --cluster-id "$CLUSTER_ID" --run-id "$CURRENT_RUN_ID" \
    --start-ns "$RUN_START_NS" --end-ns "$RUN_END_NS" \
    --output "$run_dir/keda-sample-events.ndjson"
  for import_file in "$run_dir/application-events.ndjson" "$run_dir/keda-sample-events.ndjson"; do
    bin/hookectl events import --api "http://127.0.0.1:${INGESTER_PORT}" \
      "${TOKEN_ARGS[@]}" --cluster "$CLUSTER_ID" --run-id "$CURRENT_RUN_ID" \
      --file "$import_file" >"$run_dir/import-$(basename "$import_file").log"
  done
  sleep "$EVENT_SETTLE_SECONDS"
  bin/hookectl run stop --api "http://127.0.0.1:${INGESTER_PORT}" \
    "${TOKEN_ARGS[@]}" --run-id "$CURRENT_RUN_ID" >"$run_dir/run-stop.json"
  CURRENT_RUN_STOPPED=true
  sleep 1
  HOOKE_MYSQL_DSN="$MYSQL_DSN" bin/hookectl events export \
    --run-id "$CURRENT_RUN_ID" \
    --file "$run_dir/events.ndjson"
  observation="$run_dir/observation.json"
  "$HELPER" validate-run --events "$run_dir/events.ndjson" \
    --initial-state "$run_dir/initial-state.json" \
    --scaled-object "$run_dir/scaledobject-final.json" \
    --config "$run_config" --output "$observation"
  OBSERVATION_FILES+=("$observation")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sequence" "$block" "$cell_id" "$cooldown" "$CURRENT_RUN_ID" \
    "$CURRENT_NAMESPACE" "$run_dir" "$observation" >>"$RUN_INDEX"

  if is_true "$CLEANUP_K8S_ON_SUCCESS"; then
    delete_current_namespace || die "failed to delete successful E04 namespace"
  else
    delete_current_secret || die "failed to delete E04 Redis Secret"
  fi
  clear_current_run
done <"$SCHEDULE_FILE"

summary_args=(
  summarize --schedule "$SCHEDULE_FILE"
  --target-elasticity "$E04_TARGET_ELASTICITY"
  --maximum-cooldown-seconds "$E04_MAXIMUM_RECOMMENDED_COOLDOWN_SECONDS"
  --output-json "$SESSION_DIR/summary.json"
  --output-tsv "$SESSION_DIR/observations.tsv"
)
for observation in "${OBSERVATION_FILES[@]}"; do
  summary_args+=(--observation "$observation")
done
"$HELPER" "${summary_args[@]}"

release_lock || die "failed to release E04 Lease"
SUCCESS=true
log "E04 pilot complete: ${SESSION_DIR}"
