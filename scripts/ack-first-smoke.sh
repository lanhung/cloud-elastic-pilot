#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/configs/smoke.env"
CHECK_ONLY=false

usage() {
  cat <<USAGE
Usage:
  $0 [--config PATH] [--check-only]

Examples:
  cp configs/smoke.env.example configs/smoke.env
  ${EDITOR:-vi} configs/smoke.env
  $0 --config configs/smoke.env
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "--config requires a path" >&2; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$PROJECT_ROOT"

log()  { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

if [[ ! -f "$CONFIG_FILE" ]]; then
  die "config not found: $CONFIG_FILE (copy configs/smoke.env.example first)"
fi

# shellcheck disable=SC1090
set -a
source "$CONFIG_FILE"
set +a

: "${CONFIRM_KUBE_CONTEXT:=no}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${CLUSTER_ID:=ack-smoke}"
: "${RUN_NAME_PREFIX:=first-smoke}"
: "${RUN_LABELS_JSON:={}}"
: "${SLO_SECONDS:=30}"
: "${EXPERIMENT_NAMESPACE:=hooke-experiments}"
: "${HOOKE_SYSTEM_NAMESPACE:=hooke-system}"
: "${SKIP_BUILD:=false}"
: "${GOPROXY:=}"
: "${INGESTER_PORT:=18080}"
: "${INGESTER_BIND_ADDRESS:=127.0.0.1}"
: "${CONTROLLER_METRICS_PORT:=18081}"
: "${HOOKE_AUTH_TOKEN:=}"
: "${CONTROLLER_WARMUP_SECONDS:=5}"
: "${EVENT_SETTLE_SECONDS:=5}"
: "${ARTIFACT_ROOT:=artifacts}"
: "${MYSQL_MODE:=docker}"
: "${MYSQL_DOCKER_IMAGE:=mysql:8.4}"
: "${MYSQL_CONTAINER_NAME:=hooke-smoke-mysql}"
: "${MYSQL_VOLUME_NAME:=hooke-smoke-mysql-data}"
: "${MYSQL_HOST_PORT:=13306}"
: "${MYSQL_DATABASE:=hooke}"
: "${MYSQL_USER:=hooke}"
: "${MYSQL_PASSWORD:=hooke}"
: "${MYSQL_ROOT_PASSWORD:=root}"
: "${RESET_MYSQL:=false}"
: "${MYSQL_DSN:=}"
: "${STOP_MYSQL_ON_EXIT:=false}"
: "${SMOKE_WORKLOAD_NAME:=hooke-smoke-app}"
: "${SMOKE_IMAGE:=nginx:1.27-alpine}"
: "${SMOKE_IMAGE_PULL_POLICY:=IfNotPresent}"
: "${SMOKE_COMMAND_JSON:=[]}"
: "${SMOKE_CONTAINER_PORT:=80}"
: "${SMOKE_SERVICE_PORT:=80}"
: "${SMOKE_READINESS_PATH:=/}"
: "${SMOKE_REQUEST_PATH:=/}"
: "${SMOKE_DISABLE_SDK:=true}"
: "${SMOKE_HOOKE_INGESTER_URL:=http://hooke-ingester.hooke-system.svc:8080}"
: "${SMOKE_STARTUP_WORK_MIB:=0}"
: "${SMOKE_CLOCK_OFFSET_NS:=}"
: "${SMOKE_CLOCK_UNCERTAINTY_NS:=}"
: "${REQUIRE_IMMUTABLE_IMAGE:=false}"
: "${SMOKE_CPU_REQUEST:=100m}"
: "${SMOKE_CPU_LIMIT:=500m}"
: "${SMOKE_MEMORY_REQUEST:=64Mi}"
: "${SMOKE_MEMORY_LIMIT:=256Mi}"
: "${ENABLE_FIXED_SMOKE:=true}"
: "${SMOKE_REPETITIONS:=3}"
: "${ROLLOUT_TIMEOUT:=5m}"
: "${ENABLE_HTTP_CHECK:=true}"
: "${FIXED_NODE_SELECTOR_KEY:=}"
: "${FIXED_NODE_SELECTOR_VALUE:=}"
: "${FIXED_TAINT_KEY:=}"
: "${FIXED_TAINT_VALUE:=}"
: "${FIXED_TAINT_EFFECT:=NoSchedule}"
: "${ENABLE_NODE_SCALE_SMOKE:=false}"
: "${NODE_SCALE_WORKLOAD_NAME:=hooke-node-scale-smoke}"
: "${ELASTIC_NODE_SELECTOR_KEY:=hooke.io/pool}"
: "${ELASTIC_NODE_SELECTOR_VALUE:=elastic}"
: "${ELASTIC_TAINT_KEY:=hooke.io/experiment}"
: "${ELASTIC_TAINT_VALUE:=true}"
: "${ELASTIC_TAINT_EFFECT:=NoSchedule}"
: "${NODE_SCALE_REPLICAS:=1}"
: "${NODE_SCALE_CPU_REQUEST:=500m}"
: "${NODE_SCALE_CPU_LIMIT:=1000m}"
: "${NODE_SCALE_MEMORY_REQUEST:=256Mi}"
: "${NODE_SCALE_MEMORY_LIMIT:=512Mi}"
: "${NODE_SCALE_TIMEOUT:=20m}"
: "${ENABLE_SECOND_NODE_SCALE_WAVE:=false}"
: "${NODE_SCALE_SECOND_WORKLOAD_NAME:=hooke-node-scale-wave2}"
: "${NODE_SCALE_SECOND_REPLICAS:=1}"
: "${NODE_SCALE_SECOND_CPU_REQUEST:=$NODE_SCALE_CPU_REQUEST}"
: "${NODE_SCALE_SECOND_CPU_LIMIT:=$NODE_SCALE_CPU_LIMIT}"
: "${NODE_SCALE_SECOND_MEMORY_REQUEST:=$NODE_SCALE_MEMORY_REQUEST}"
: "${NODE_SCALE_SECOND_MEMORY_LIMIT:=$NODE_SCALE_MEMORY_LIMIT}"
: "${NODE_SCALE_WAVE_STAGGER_SECONDS:=10}"
: "${REQUIRE_EMPTY_ELASTIC_POOL:=true}"
: "${REQUIRE_NEW_NODE:=true}"
: "${REQUIRE_NODE_UNSCHEDULABLE:=true}"
: "${ACK_EVENTS_NDJSON:=}"
: "${ACK_EVENTS_EXPORT_HOOK:=}"
: "${ACK_ADAPTER_CONFIG:=configs/ack-adapter.yaml}"
: "${RUNTIME_EVENTS_NDJSON:=}"
: "${RUNTIME_EVENTS_EXPORT_HOOK:=}"
: "${REQUIRE_EXACT_NODE_EVENTS:=false}"
: "${REQUIRE_EXACT_IMAGE_EVENTS:=false}"
: "${REQUIRE_EXACT_POD_EVENTS:=false}"
: "${REQUIRE_EXACT_APP_EVENTS:=false}"
: "${REQUIRE_POD_SUBSTAGES:=false}"
: "${REQUIRE_CNI_SUBSTAGE:=$REQUIRE_POD_SUBSTAGES}"
: "${REQUIRE_DERIVATION_TRACEABILITY:=false}"
: "${ATTRIBUTION_WINDOW:=10m}"
: "${REQUIRE_TASK_ID_ATTRIBUTION:=false}"
: "${EXPECTED_TASK_COUNT:=0}"
: "${EXPECTED_MIN_PODS_PER_TASK:=0}"
: "${CLEANUP_K8S_ON_SUCCESS:=true}"
: "${CLEANUP_K8S_ON_ERROR:=false}"
: "${REQUIRE_EMPTY_EXPERIMENT_NAMESPACE:=true}"
: "${UNIQUE_EXPERIMENT_NAMESPACE:=true}"
: "${UNIQUE_RESOURCE_NAMES:=true}"
: "${DELETE_EXPERIMENT_NAMESPACE:=true}"
: "${APP_AUTH_SECRET_NAME:=hooke-app-auth}"

[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
if is_true "$ENABLE_FIXED_SMOKE"; then
  [[ "$SMOKE_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die "SMOKE_REPETITIONS must be a positive integer"
fi
[[ "$NODE_SCALE_REPLICAS" =~ ^[1-9][0-9]*$ ]] || die "NODE_SCALE_REPLICAS must be a positive integer"
[[ "$NODE_SCALE_SECOND_REPLICAS" =~ ^[1-9][0-9]*$ ]] || die "NODE_SCALE_SECOND_REPLICAS must be a positive integer"
[[ "$NODE_SCALE_WAVE_STAGGER_SECONDS" =~ ^[0-9]+$ ]] || die "NODE_SCALE_WAVE_STAGGER_SECONDS must be a non-negative integer"
[[ "$EXPECTED_TASK_COUNT" =~ ^[0-9]+$ ]] || die "EXPECTED_TASK_COUNT must be a non-negative integer"
[[ "$EXPECTED_MIN_PODS_PER_TASK" =~ ^[0-9]+$ ]] || die "EXPECTED_MIN_PODS_PER_TASK must be a non-negative integer"
[[ "$SLO_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "SLO_SECONDS must be numeric"
[[ "$SMOKE_STARTUP_WORK_MIB" =~ ^[0-9]+$ ]] || die "SMOKE_STARTUP_WORK_MIB must be a non-negative integer"
[[ -z "$SMOKE_CLOCK_OFFSET_NS" || "$SMOKE_CLOCK_OFFSET_NS" =~ ^-?[0-9]+$ ]] || die "SMOKE_CLOCK_OFFSET_NS must be an integer when set"
[[ -z "$SMOKE_CLOCK_UNCERTAINTY_NS" || "$SMOKE_CLOCK_UNCERTAINTY_NS" =~ ^[0-9]+$ ]] || die "SMOKE_CLOCK_UNCERTAINTY_NS must be non-negative when set"
[[ -n "$SMOKE_IMAGE" ]] || die "SMOKE_IMAGE is required"
if is_true "$REQUIRE_IMMUTABLE_IMAGE"; then
  [[ "$SMOKE_IMAGE" =~ @sha256:[0-9a-fA-F]{64}$ ]] || die "SMOKE_IMAGE must be pinned by sha256 digest"
fi

if [[ -n "$FIXED_NODE_SELECTOR_KEY" || -n "$FIXED_NODE_SELECTOR_VALUE" ]]; then
  [[ -n "$FIXED_NODE_SELECTOR_KEY" && -n "$FIXED_NODE_SELECTOR_VALUE" ]] || die "FIXED_NODE_SELECTOR_KEY and VALUE must be set together"
fi
if [[ -n "$FIXED_TAINT_KEY" || -n "$FIXED_TAINT_VALUE" ]]; then
  [[ -n "$FIXED_TAINT_KEY" && -n "$FIXED_TAINT_VALUE" ]] || die "FIXED_TAINT_KEY and VALUE must be set together"
  case "$FIXED_TAINT_EFFECT" in
    NoSchedule|PreferNoSchedule|NoExecute) ;;
    *) die "FIXED_TAINT_EFFECT must be NoSchedule, PreferNoSchedule, or NoExecute" ;;
  esac
fi
if is_true "$ENABLE_NODE_SCALE_SMOKE"; then
  [[ -n "$ELASTIC_NODE_SELECTOR_KEY" && -n "$ELASTIC_NODE_SELECTOR_VALUE" ]] || die "elastic node selector is required when node-scale smoke is enabled"
fi
if [[ -n "$ACK_EVENTS_EXPORT_HOOK" ]]; then
  [[ -x "$ACK_EVENTS_EXPORT_HOOK" ]] || die "ACK_EVENTS_EXPORT_HOOK must be executable: $ACK_EVENTS_EXPORT_HOOK"
fi
if [[ -n "$RUNTIME_EVENTS_EXPORT_HOOK" ]]; then
  [[ -x "$RUNTIME_EVENTS_EXPORT_HOOK" ]] || die "RUNTIME_EVENTS_EXPORT_HOOK must be executable: $RUNTIME_EVENTS_EXPORT_HOOK"
fi
if is_true "$REQUIRE_EXACT_NODE_EVENTS" && [[ -z "$ACK_EVENTS_NDJSON" && -z "$ACK_EVENTS_EXPORT_HOOK" ]]; then
  die "exact Node events require ACK_EVENTS_NDJSON or ACK_EVENTS_EXPORT_HOOK"
fi
if { is_true "$REQUIRE_EXACT_IMAGE_EVENTS" || is_true "$REQUIRE_EXACT_POD_EVENTS"; } && \
   [[ -z "$RUNTIME_EVENTS_NDJSON" && -z "$RUNTIME_EVENTS_EXPORT_HOOK" ]]; then
  die "exact Image/Pod events require RUNTIME_EVENTS_NDJSON or RUNTIME_EVENTS_EXPORT_HOOK"
fi

require_cmd kubectl
require_cmd curl
require_cmd python3
python3 - "$RUN_LABELS_JSON" <<'PY' >/dev/null || die "RUN_LABELS_JSON must be a JSON object"
import json, sys
value = json.loads(sys.argv[1])
if not isinstance(value, dict):
    raise SystemExit(1)
PY
python3 - "$SMOKE_COMMAND_JSON" <<'PY' >/dev/null || die "SMOKE_COMMAND_JSON must be a JSON string array"
import json, sys
value = json.loads(sys.argv[1])
if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
    raise SystemExit(1)
PY
if ! is_true "$SKIP_BUILD"; then require_cmd go; fi
if [[ "$MYSQL_MODE" == "docker" ]]; then
  require_cmd docker
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
elif [[ "$MYSQL_MODE" == "external" ]]; then
  [[ -n "$MYSQL_DSN" ]] || die "MYSQL_DSN is required when MYSQL_MODE=external"
  require_cmd mysql
else
  die "MYSQL_MODE must be docker or external"
fi

export KUBECONFIG="$KUBECONFIG_PATH"
KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_PATH")
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL+=(--context "$KUBE_CONTEXT")
  "${KUBECTL[@]}" config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1 || die "kube context not found: $KUBE_CONTEXT"
  EFFECTIVE_CONTEXT="$KUBE_CONTEXT"
else
  EFFECTIVE_CONTEXT="$(kubectl --kubeconfig "$KUBECONFIG_PATH" config current-context)"
  [[ -n "$EFFECTIVE_CONTEXT" ]] || die "no current kube context"
  warn "KUBE_CONTEXT is empty; using current context: $EFFECTIVE_CONTEXT"
fi

kube() { "${KUBECTL[@]}" "$@"; }

[[ "$CONFIRM_KUBE_CONTEXT" == "yes" ]] || die "set CONFIRM_KUBE_CONTEXT=yes after verifying KUBE_CONTEXT"
EFFECTIVE_API_SERVER="$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if [[ -n "$EXPECTED_API_SERVER_SUBSTRING" && "$EFFECTIVE_API_SERVER" != *"$EXPECTED_API_SERVER_SUBSTRING"* ]]; then
  die "API server does not contain EXPECTED_API_SERVER_SUBSTRING=${EXPECTED_API_SERVER_SUBSTRING}"
fi

RUN_STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
RUN_NAME="${RUN_NAME_PREFIX}-${RUN_STAMP}"
if is_true "$UNIQUE_EXPERIMENT_NAMESPACE"; then
  # Kubernetes Events can outlive their Pods. Reusing a namespace lets the
  # informer's initial list assign those historical Events to the new run.
  # A per-run namespace prevents that contamination by construction.
  namespace_suffix="$(tr '[:upper:]' '[:lower:]' <<<"$RUN_STAMP")"
  max_prefix_length=$((63 - 1 - ${#namespace_suffix}))
  namespace_prefix="${EXPERIMENT_NAMESPACE:0:max_prefix_length}"
  while [[ "$namespace_prefix" == *- ]]; do namespace_prefix="${namespace_prefix%-}"; done
  [[ -n "$namespace_prefix" ]] || die "EXPERIMENT_NAMESPACE has no usable prefix"
  EXPERIMENT_NAMESPACE="${namespace_prefix}-${namespace_suffix}"
fi
[[ ${#EXPERIMENT_NAMESPACE} -le 63 && "$EXPERIMENT_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
  die "invalid Kubernetes namespace: ${EXPERIMENT_NAMESPACE}"
if [[ "$ARTIFACT_ROOT" = /* ]]; then
  ARTIFACT_BASE="$ARTIFACT_ROOT"
else
  ARTIFACT_BASE="${PROJECT_ROOT}/${ARTIFACT_ROOT}"
fi
ARTIFACT_DIR="${ARTIFACT_BASE}/${RUN_NAME}"
mkdir -p "$ARTIFACT_DIR"
chmod 700 "$ARTIFACT_DIR"

RUN_ID=""
INGESTER_PID=""
CONTROLLER_PID=""
PORT_FORWARD_PID=""
SUCCESS=false
MYSQL_STARTED_BY_SCRIPT=false
MYSQL_TOUCHED=false
K8S_MUTATED=false
RUN_STOPPED=false
NODE_SCALE_WORKLOAD_ACTIVE=false
NAMESPACE_EXISTED=false
NAMESPACE_CREATED_BY_RUN=false
PREVIOUS_NAMESPACE_RUN_ID=""
EXPERIMENT_NAMESPACE_UID=""
EXPERIMENT_NAMESPACE_RUN_ID=""

terminate_pid() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill -TERM "$pid" >/dev/null 2>&1 || true
    for _ in {1..30}; do
      kill -0 "$pid" >/dev/null 2>&1 || return 0
      sleep 0.2
    done
    kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
}

verify_namespace_ownership() {
  local actual actual_name actual_uid actual_run_id
  if [[ -z "$EXPERIMENT_NAMESPACE_UID" || -z "$EXPERIMENT_NAMESPACE_RUN_ID" ]]; then
    warn "experiment namespace ownership was not captured"
    return 1
  fi
  if ! actual="$(kube --request-timeout=30s get namespace "$EXPERIMENT_NAMESPACE" \
      --ignore-not-found \
      -o jsonpath='{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.metadata.annotations.hooke\.io/run-id}' \
      2>/dev/null)"; then
    warn "failed to verify experiment namespace ownership"
    return 1
  fi
  [[ -n "$actual" ]] || {
    warn "experiment namespace no longer exists: ${EXPERIMENT_NAMESPACE}"
    return 1
  }
  IFS=$'\t' read -r actual_name actual_uid actual_run_id <<<"$actual"
  if [[ "$actual_name" != "$EXPERIMENT_NAMESPACE" || \
        "$actual_uid" != "$EXPERIMENT_NAMESPACE_UID" || \
        "$actual_run_id" != "$EXPERIMENT_NAMESPACE_RUN_ID" ]]; then
    warn "refusing to mutate namespace whose UID or run owner changed: ${EXPERIMENT_NAMESPACE}"
    return 1
  fi
}

delete_owned_namespace() {
  local remaining deadline
  verify_namespace_ownership || return 1
  if ! python3 - "$EXPERIMENT_NAMESPACE_UID" <<'PY' | \
      kube --request-timeout=30s delete --raw "/api/v1/namespaces/${EXPERIMENT_NAMESPACE}" -f - >/dev/null
import json, sys
print(json.dumps({
    "apiVersion": "v1",
    "kind": "DeleteOptions",
    "preconditions": {"uid": sys.argv[1]},
    "propagationPolicy": "Foreground",
}, separators=(",", ":")))
PY
  then
    warn "UID-preconditioned namespace deletion failed: ${EXPERIMENT_NAMESPACE}"
    return 1
  fi
  deadline=$((SECONDS + 180))
  while true; do
    if ! remaining="$(kube --request-timeout=10s get namespace "$EXPERIMENT_NAMESPACE" \
        --ignore-not-found -o name 2>/dev/null)"; then
      warn "failed to verify namespace deletion: ${EXPERIMENT_NAMESPACE}"
      return 1
    fi
    [[ -z "$remaining" ]] && return 0
    (( SECONDS < deadline )) || {
      warn "experiment namespace still exists after deletion request: ${EXPERIMENT_NAMESPACE}"
      return 1
    }
    sleep 2
  done
}

delete_owned_namespaced_resource() {
  local resource="$1" api_path="$2" name="$3"
  local identity uid owner
  verify_namespace_ownership || return 1
  if ! identity="$(kube --request-timeout=30s -n "$EXPERIMENT_NAMESPACE" get "$resource" "$name" \
      --ignore-not-found \
      -o jsonpath='{.metadata.uid}{"\t"}{.metadata.annotations.hooke\.io/run-id}' 2>/dev/null)"; then
    warn "failed to inspect owned ${resource}/${name}"
    return 1
  fi
  [[ -n "$identity" ]] || return 0
  IFS=$'\t' read -r uid owner <<<"$identity"
  if [[ -z "$uid" || "$owner" != "$RUN_ID" ]]; then
    warn "refusing to delete ${resource}/${name} without exact run ownership"
    return 1
  fi
  if ! python3 - "$uid" <<'PY' | \
      kube --request-timeout=30s delete --raw "${api_path}/${name}" -f - >/dev/null
import json, sys
print(json.dumps({
    "apiVersion": "v1",
    "kind": "DeleteOptions",
    "preconditions": {"uid": sys.argv[1]},
    "propagationPolicy": "Background",
}, separators=(",", ":")))
PY
  then
    warn "UID-preconditioned deletion failed for ${resource}/${name}"
    return 1
  fi
}

restore_existing_namespace_annotation() {
  verify_namespace_ownership || return 1
  if ! kube --request-timeout=30s get namespace "$EXPERIMENT_NAMESPACE" -o json | \
      python3 /dev/fd/3 "$EXPERIMENT_NAMESPACE_UID" "$RUN_ID" "$PREVIOUS_NAMESPACE_RUN_ID" 3<<'PY' | \
      kube --request-timeout=30s replace -f - >/dev/null
import json, sys
payload = json.load(sys.stdin)
metadata = payload.get("metadata", {})
annotations = metadata.setdefault("annotations", {})
if metadata.get("uid") != sys.argv[1] or annotations.get("hooke.io/run-id") != sys.argv[2]:
    raise SystemExit(1)
previous = sys.argv[3]
if previous:
    annotations["hooke.io/run-id"] = previous
else:
    annotations.pop("hooke.io/run-id", None)
print(json.dumps(payload, separators=(",", ":")))
PY
  then
    warn "failed to restore experiment namespace annotation with resourceVersion CAS"
    return 1
  fi
}

cleanup_k8s() {
  local delete_resources="$1"
  [[ "$K8S_MUTATED" == true ]] || return 0
  verify_namespace_ownership || return 1
  if is_true "$delete_resources" && is_true "$DELETE_EXPERIMENT_NAMESPACE" && \
      [[ "$NAMESPACE_CREATED_BY_RUN" == true ]]; then
    delete_owned_namespace
    return $?
  fi
  local cleanup_failed=false
  # The per-run application token is never retained for post-failure diagnosis.
  delete_owned_namespaced_resource secret \
    "/api/v1/namespaces/${EXPERIMENT_NAMESPACE}/secrets" "$APP_AUTH_SECRET_NAME" || cleanup_failed=true
  if is_true "$delete_resources"; then
    local name
    for name in "$SMOKE_WORKLOAD_NAME" "$NODE_SCALE_WORKLOAD_NAME" "$NODE_SCALE_SECOND_WORKLOAD_NAME"; do
      delete_owned_namespaced_resource deployment \
        "/apis/apps/v1/namespaces/${EXPERIMENT_NAMESPACE}/deployments" "$name" || cleanup_failed=true
      delete_owned_namespaced_resource service \
        "/api/v1/namespaces/${EXPERIMENT_NAMESPACE}/services" "$name" || cleanup_failed=true
    done
  fi
  if [[ "$NAMESPACE_EXISTED" == true ]]; then
    restore_existing_namespace_annotation || cleanup_failed=true
  fi
  [[ "$cleanup_failed" == false ]]
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  trap '' INT TERM
  if [[ "$NODE_SCALE_WORKLOAD_ACTIVE" == true ]] && ! stop_node_scale_workloads; then
    warn "failed to stop the owned node-scale workload during cleanup"
    rc=1
  fi
  terminate_pid "$PORT_FORWARD_PID"
  terminate_pid "$CONTROLLER_PID"
  if [[ -n "$RUN_ID" && "$RUN_STOPPED" == false && -x "$PROJECT_ROOT/bin/hookectl" ]]; then
    token_args=()
    [[ -n "$HOOKE_AUTH_TOKEN" ]] && token_args=(--token "$HOOKE_AUTH_TOKEN")
    "$PROJECT_ROOT/bin/hookectl" run stop --api "http://127.0.0.1:${INGESTER_PORT}" \
      "${token_args[@]}" --run-id "$RUN_ID" >/dev/null 2>&1 || true
    RUN_STOPPED=true
  fi
  terminate_pid "$INGESTER_PID"
  if [[ "$SUCCESS" == true ]]; then
    if ! cleanup_k8s "$CLEANUP_K8S_ON_SUCCESS"; then rc=1; fi
  else
    if ! cleanup_k8s "$CLEANUP_K8S_ON_ERROR"; then rc=1; fi
  fi
  if [[ "$MYSQL_MODE" == "docker" && "$MYSQL_TOUCHED" == true ]] && is_true "$STOP_MYSQL_ON_EXIT"; then
    docker stop "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  if [[ $rc -ne 0 ]]; then
    warn "smoke failed; logs and generated YAML are in: $ARTIFACT_DIR"
    [[ -f "$ARTIFACT_DIR/ingester.log" ]] && tail -n 40 "$ARTIFACT_DIR/ingester.log" >&2 || true
    [[ -f "$ARTIFACT_DIR/controller.log" ]] && tail -n 60 "$ARTIFACT_DIR/controller.log" >&2 || true
  else
    log "artifacts: $ARTIFACT_DIR"
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

wait_http() {
  local url="$1" timeout_seconds="$2" label="$3"
  local deadline=$((SECONDS + timeout_seconds))
  until curl -fsS --max-time 2 "$url" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "timeout waiting for $label at $url"
    sleep 1
  done
}

pick_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}


port_is_free() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
}

wait_for_zero_pods() {
  local workload="$1" timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  while true; do
    local count listing
    verify_namespace_ownership || return 1
    if ! listing="$(kube --request-timeout=30s -n "$EXPERIMENT_NAMESPACE" get pods \
        -l "app=${workload}" --no-headers 2>/dev/null)"; then
      warn "failed to list ${workload} Pods while waiting for termination"
      return 1
    fi
    count="$(awk 'NF {count++} END {print count+0}' <<<"$listing")"
    [[ "$count" == "0" ]] && return 0
    (( SECONDS < deadline )) || {
      warn "timeout waiting for ${workload} pods to terminate"
      return 1
    }
    sleep 2
  done
}

scale_owned_deployment() {
  local name="$1" replicas="$2" identity uid owner patch
  verify_namespace_ownership || return 1
  if ! identity="$(kube --request-timeout=30s -n "$EXPERIMENT_NAMESPACE" get deployment "$name" \
      -o jsonpath='{.metadata.uid}{"\t"}{.metadata.annotations.hooke\.io/run-id}' 2>/dev/null)"; then
    warn "failed to inspect deployment/${name} before scaling"
    return 1
  fi
  IFS=$'\t' read -r uid owner <<<"$identity"
  if [[ -z "$uid" || "$owner" != "$RUN_ID" ]]; then
    warn "refusing to scale deployment/${name} without exact UID/run ownership"
    return 1
  fi
  patch="$(python3 - "$uid" "$RUN_ID" "$replicas" <<'PY'
import json, sys
print(json.dumps([
    {"op": "test", "path": "/metadata/uid", "value": sys.argv[1]},
    {"op": "test", "path": "/metadata/annotations/hooke.io~1run-id", "value": sys.argv[2]},
    {"op": "replace", "path": "/spec/replicas", "value": int(sys.argv[3])},
], separators=(",", ":")))
PY
)" || return 1
  kube --request-timeout=30s -n "$EXPERIMENT_NAMESPACE" patch deployment "$name" \
    --type=json -p "$patch" >/dev/null
}

run_measured_rollout() {
  local workload="$1" iteration="$2" path="$3" replicas="$4" timeout="$5" log_file="$6"
  python3 /dev/fd/3 \
    "$ARTIFACT_DIR/orchestrator-timing.tsv" "$KUBECONFIG_PATH" "$EFFECTIVE_CONTEXT" "$CLUSTER_ID" "$RUN_ID" \
    "$EXPERIMENT_NAMESPACE" "$EXPERIMENT_NAMESPACE_UID" "$workload" "$iteration" "$path" \
    "$replicas" "$timeout" "$log_file" 3<<'PY'
import csv
import json
import os
import pathlib
import socket
import subprocess
import sys
import time

(
    output_path,
    kubeconfig,
    context,
    cluster_id,
    run_id,
    namespace,
    namespace_uid,
    workload,
    iteration,
    path,
    replicas_text,
    rollout_timeout,
    log_path,
) = sys.argv[1:]
replicas = int(replicas_text)
kubectl = ["kubectl", "--kubeconfig", kubeconfig]
if context:
    kubectl += ["--context", context]


def command(*args, **kwargs):
    return subprocess.run(kubectl + list(args), check=False, **kwargs)


def get_json(*args):
    completed = command(*args, "-o", "json", stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "kubectl get failed")
    return json.loads(completed.stdout)


namespace_payload = get_json("get", "namespace", namespace)
namespace_metadata = namespace_payload.get("metadata", {})
if (
    namespace_metadata.get("uid") != namespace_uid
    or (namespace_metadata.get("annotations") or {}).get("hooke.io/run-id") != run_id
):
    raise SystemExit("experiment namespace ownership changed before measured rollout")

deployment = get_json("-n", namespace, "get", "deployment", workload)
metadata = deployment.get("metadata", {})
deployment_uid = str(metadata.get("uid") or "")
generation_before = int(metadata.get("generation") or 0)
if not deployment_uid or (metadata.get("annotations") or {}).get("hooke.io/run-id") != run_id:
    raise SystemExit("deployment ownership is not bound to the measured run")

patch = json.dumps(
    [
        {"op": "test", "path": "/metadata/uid", "value": deployment_uid},
        {
            "op": "test",
            "path": "/metadata/annotations/hooke.io~1run-id",
            "value": run_id,
        },
        {"op": "replace", "path": "/spec/replicas", "value": replicas},
    ],
    separators=(",", ":"),
)
start_ns = time.monotonic_ns()
with open(log_path, "w", encoding="utf-8") as log:
    scale = command(
        "-n",
        namespace,
        "patch",
        "deployment",
        workload,
        "--type=json",
        "-p",
        patch,
        stdout=log,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if scale.returncode == 0:
        rollout = command(
            "-n",
            namespace,
            "rollout",
            "status",
            f"deployment/{workload}",
            f"--timeout={rollout_timeout}",
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
        )
        rollout_rc = rollout.returncode
    else:
        rollout_rc = -1
end_ns = time.monotonic_ns()

generation_after = 0
observed_generation = 0
pod_uid = ""
pod_name = ""
replica_set_uid = ""
replica_set_name = ""
evidence_rc = 0
if scale.returncode == 0 and rollout_rc == 0:
    try:
        after = get_json("-n", namespace, "get", "deployment", workload)
        after_metadata = after.get("metadata", {})
        if (
            after_metadata.get("uid") != deployment_uid
            or (after_metadata.get("annotations") or {}).get("hooke.io/run-id") != run_id
        ):
            raise RuntimeError("deployment identity changed during measured rollout")
        generation_after = int(after_metadata.get("generation") or 0)
        observed_generation = int(after.get("status", {}).get("observedGeneration") or 0)
        pods = get_json("-n", namespace, "get", "pods", "-l", f"app={workload}")
        ready = []
        for pod in pods.get("items", []):
            pod_metadata = pod.get("metadata", {})
            owners = pod_metadata.get("ownerReferences") or []
            replica_owners = [
                owner
                for owner in owners
                if owner.get("kind") == "ReplicaSet"
                and owner.get("controller") is True
                and owner.get("uid")
                and owner.get("name")
            ]
            owned = False
            current_replica_set = None
            if len(replica_owners) == 1:
                owner = replica_owners[0]
                replica_set = get_json(
                    "-n", namespace, "get", "replicaset", str(owner["name"])
                )
                replica_metadata = replica_set.get("metadata", {})
                replica_parents = replica_metadata.get("ownerReferences") or []
                owned = (
                    replica_metadata.get("uid") == owner["uid"]
                    and any(
                        parent.get("kind") == "Deployment"
                        and parent.get("controller") is True
                        and parent.get("uid") == deployment_uid
                        for parent in replica_parents
                    )
                )
                if owned:
                    current_replica_set = replica_metadata
            conditions = pod.get("status", {}).get("conditions") or []
            is_ready = any(
                item.get("type") == "Ready" and item.get("status") == "True"
                for item in conditions
            )
            if owned and is_ready and not pod_metadata.get("deletionTimestamp"):
                ready.append((pod, current_replica_set))
        if replicas != 1 or len(ready) != 1:
            raise RuntimeError("E02 measured rollout requires exactly one Ready owned Pod")
        pod_metadata = ready[0][0].get("metadata", {})
        replica_metadata = ready[0][1] or {}
        pod_uid = str(pod_metadata.get("uid") or "")
        pod_name = str(pod_metadata.get("name") or "")
        replica_set_uid = str(replica_metadata.get("uid") or "")
        replica_set_name = str(replica_metadata.get("name") or "")
        if (
            not pod_uid
            or not pod_name
            or not replica_set_uid
            or not replica_set_name
            or (pod_metadata.get("annotations") or {}).get("hooke.io/run-id") != run_id
            or observed_generation < generation_after
        ):
            raise RuntimeError("post-rollout Deployment/Pod evidence is incomplete")
    except (json.JSONDecodeError, RuntimeError, ValueError) as exc:
        evidence_rc = 125
        with open(log_path, "a", encoding="utf-8") as log:
            print(f"evidence error: {exc}", file=log)

try:
    boot_id = pathlib.Path("/proc/sys/kernel/random/boot_id").read_text(encoding="utf-8").strip()
except OSError:
    boot_id = ""
fields = [
    "cluster_id",
    "run_id",
    "namespace",
    "namespace_uid",
    "workload",
    "iteration",
    "path",
    "requested_replicas",
    "clock_type",
    "clock_source",
    "source_host",
    "boot_id",
    "start_monotonic_ns",
    "end_monotonic_ns",
    "scale_rc",
    "rollout_rc",
    "evidence_rc",
    "deployment_uid",
    "replica_set_uid",
    "replica_set_name",
    "deployment_generation_before",
    "deployment_generation_after",
    "observed_generation",
    "pod_uid",
    "pod_name",
]
row = {
    "cluster_id": cluster_id,
    "run_id": run_id,
    "namespace": namespace,
    "namespace_uid": namespace_uid,
    "workload": workload,
    "iteration": iteration,
    "path": path,
    "requested_replicas": replicas,
    "clock_type": "CLOCK_MONOTONIC",
    "clock_source": "python-time.monotonic_ns",
    "source_host": socket.gethostname(),
    "boot_id": boot_id,
    "start_monotonic_ns": start_ns,
    "end_monotonic_ns": end_ns,
    "scale_rc": scale.returncode,
    "rollout_rc": rollout_rc,
    "evidence_rc": evidence_rc,
    "deployment_uid": deployment_uid,
    "replica_set_uid": replica_set_uid,
    "replica_set_name": replica_set_name,
    "deployment_generation_before": generation_before,
    "deployment_generation_after": generation_after,
    "observed_generation": observed_generation,
    "pod_uid": pod_uid,
    "pod_name": pod_name,
}
target = pathlib.Path(output_path)
needs_header = not target.exists() or target.stat().st_size == 0
with target.open("a", encoding="utf-8", newline="") as stream:
    writer = csv.DictWriter(stream, fieldnames=fields, delimiter="\t", lineterminator="\n")
    if needs_header:
        writer.writeheader()
    writer.writerow(row)
target.chmod(0o600)
if scale.returncode != 0:
    raise SystemExit(scale.returncode)
if rollout_rc != 0:
    raise SystemExit(rollout_rc)
raise SystemExit(evidence_rc)
PY
}

stop_node_scale_workloads() {
  [[ "$NODE_SCALE_WORKLOAD_ACTIVE" == true ]] || return 0
  if ! scale_owned_deployment "$NODE_SCALE_WORKLOAD_NAME" 0; then return 1; fi
  if ! wait_for_zero_pods "$NODE_SCALE_WORKLOAD_NAME" 300; then return 1; fi
  if is_true "$ENABLE_SECOND_NODE_SCALE_WAVE"; then
    if ! scale_owned_deployment "$NODE_SCALE_SECOND_WORKLOAD_NAME" 0; then return 1; fi
    if ! wait_for_zero_pods "$NODE_SCALE_SECOND_WORKLOAD_NAME" 300; then return 1; fi
  fi
  NODE_SCALE_WORKLOAD_ACTIVE=false
}

write_workload_yaml() {
  local file="$1" name="$2" replicas="$3" cpu_request="$4" cpu_limit="$5" mem_request="$6" mem_limit="$7" selector_key="$8" selector_value="$9" taint_key="${10}" taint_value="${11}" taint_effect="${12}"
  cat >"$file" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app: ${name}
    hooke.io/experiment: "true"
  annotations:
    hooke.io/run-id: "${RUN_ID}"
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
        hooke.io/experiment: "true"
      annotations:
        hooke.io/run-id: "${RUN_ID}"
    spec:
      terminationGracePeriodSeconds: 5
YAML
  if [[ -n "$selector_key" ]]; then
    cat >>"$file" <<YAML
      nodeSelector:
        "${selector_key}": "${selector_value}"
YAML
  fi
  if [[ -n "$taint_key" ]]; then
    cat >>"$file" <<YAML
      tolerations:
        - key: "${taint_key}"
          operator: "Equal"
          value: "${taint_value}"
          effect: "${taint_effect}"
YAML
  fi
  cat >>"$file" <<YAML
      containers:
        - name: app
          image: "${SMOKE_IMAGE}"
          imagePullPolicy: ${SMOKE_IMAGE_PULL_POLICY}
          command: ${SMOKE_COMMAND_JSON}
          ports:
            - name: http
              containerPort: ${SMOKE_CONTAINER_PORT}
          env:
            - name: HOOKE_SDK_DISABLED
              value: "${SMOKE_DISABLE_SDK}"
            - name: HOOKE_STARTUP_WORK_MIB
              value: "${SMOKE_STARTUP_WORK_MIB}"
            - name: HOOKE_INGESTER_URL
              value: "${SMOKE_HOOKE_INGESTER_URL}"
            - name: HOOKE_CLUSTER_ID
              value: "${CLUSTER_ID}"
            - name: HOOKE_RUN_ID
              value: "${RUN_ID}"
            - name: HOOKE_CLOCK_OFFSET_NS
              value: "${SMOKE_CLOCK_OFFSET_NS}"
            - name: HOOKE_CLOCK_UNCERTAINTY_NS
              value: "${SMOKE_CLOCK_UNCERTAINTY_NS}"
            - name: HOOKE_AUTH_TOKEN
              valueFrom:
                secretKeyRef:
                  name: "${APP_AUTH_SECRET_NAME}"
                  key: token
                  optional: true
            - name: HOOKE_WORKLOAD_KIND
              value: "Deployment"
            - name: HOOKE_WORKLOAD_NAME
              value: "${name}"
            - name: HOOKE_CONTAINER_NAME
              value: "app"
            - name: POD_NAMESPACE
              valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
            - name: POD_NAME
              valueFrom: {fieldRef: {fieldPath: metadata.name}}
            - name: POD_UID
              valueFrom: {fieldRef: {fieldPath: metadata.uid}}
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
          readinessProbe:
            httpGet:
              path: "${SMOKE_READINESS_PATH}"
              port: http
            periodSeconds: 1
            timeoutSeconds: 1
            failureThreshold: 30
          resources:
            requests:
              cpu: "${cpu_request}"
              memory: "${mem_request}"
            limits:
              cpu: "${cpu_limit}"
              memory: "${mem_limit}"
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${EXPERIMENT_NAMESPACE}
  labels:
    app: ${name}
    hooke.io/experiment: "true"
  annotations:
    hooke.io/run-id: "${RUN_ID}"
spec:
  selector:
    app: ${name}
  ports:
    - name: http
      port: ${SMOKE_SERVICE_PORT}
      targetPort: http
YAML
}

http_check() {
  local workload="$1" iteration="$2"
  is_true "$ENABLE_HTTP_CHECK" || return 0
  local port
  port="$(pick_free_port)"
  local pf_log="$ARTIFACT_DIR/port-forward-${workload}-${iteration}.log"
  kube -n "$EXPERIMENT_NAMESPACE" port-forward --address=127.0.0.1 "service/${workload}" \
    "${port}:${SMOKE_SERVICE_PORT}" >"$pf_log" 2>&1 &
  PORT_FORWARD_PID=$!
  local deadline=$((SECONDS + 30))
  while ! python3 - "$port" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket()
s.settimeout(0.5)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
  do
    kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1 || die "kubectl port-forward exited; see $pf_log"
    (( SECONDS < deadline )) || die "timeout waiting for port-forward; see $pf_log"
    sleep 1
  done
  curl -fsS --max-time 10 "http://127.0.0.1:${port}${SMOKE_REQUEST_PATH}" \
    >"$ARTIFACT_DIR/http-${workload}-${iteration}.out"
  terminate_pid "$PORT_FORWARD_PID"
  PORT_FORWARD_PID=""
}

snapshot_pods() {
  local workload="$1" iteration="$2"
  kube -n "$EXPERIMENT_NAMESPACE" get pods -l "app=${workload}" -o wide \
    >"$ARTIFACT_DIR/pods-${workload}-${iteration}.txt"
  kube -n "$EXPERIMENT_NAMESPACE" get pods -l "app=${workload}" -o json \
    >"$ARTIFACT_DIR/pods-${workload}-${iteration}.json"
}

snapshot_pod_logs() {
  local workload="$1" iteration="$2"
  kube -n "$EXPERIMENT_NAMESPACE" logs -l "app=${workload}" --all-containers=true --prefix=true --tail=-1 \
    >"$ARTIFACT_DIR/pod-logs-${workload}-${iteration}.ndjson"
}

run_fixed_smoke() {
  if ! is_true "$ENABLE_FIXED_SMOKE"; then
    log "S01/S02: skipped (ENABLE_FIXED_SMOKE=false)"
    return 0
  fi
  log "S01/S02: fixed-node Pod/Image/App smoke (${SMOKE_REPETITIONS} repetitions)"
  local yaml="$ARTIFACT_DIR/${SMOKE_WORKLOAD_NAME}.yaml"
  write_workload_yaml "$yaml" "$SMOKE_WORKLOAD_NAME" 0 \
    "$SMOKE_CPU_REQUEST" "$SMOKE_CPU_LIMIT" "$SMOKE_MEMORY_REQUEST" "$SMOKE_MEMORY_LIMIT" \
    "$FIXED_NODE_SELECTOR_KEY" "$FIXED_NODE_SELECTOR_VALUE" \
    "$FIXED_TAINT_KEY" "$FIXED_TAINT_VALUE" "$FIXED_TAINT_EFFECT"
  verify_namespace_ownership || die "namespace ownership changed before fixed workload creation"
  kube create -f "$yaml" >"$ARTIFACT_DIR/apply-fixed.txt"
  wait_for_zero_pods "$SMOKE_WORKLOAD_NAME" 120

  local i
  for ((i=1; i<=SMOKE_REPETITIONS; i++)); do
    log "fixed-node repetition ${i}/${SMOKE_REPETITIONS}: scale 0 -> 1"
    if ! run_measured_rollout "$SMOKE_WORKLOAD_NAME" "$i" fixed 1 "$ROLLOUT_TIMEOUT" \
      "$ARTIFACT_DIR/rollout-fixed-${i}.log"; then
      kube -n "$EXPERIMENT_NAMESPACE" describe deployment "$SMOKE_WORKLOAD_NAME" >"$ARTIFACT_DIR/describe-fixed-deployment-${i}.txt" 2>&1 || true
      kube -n "$EXPERIMENT_NAMESPACE" describe pods -l "app=${SMOKE_WORKLOAD_NAME}" >"$ARTIFACT_DIR/describe-fixed-pods-${i}.txt" 2>&1 || true
      die "fixed workload rollout failed; inspect artifact logs"
    fi
    snapshot_pods "$SMOKE_WORKLOAD_NAME" "$i"
    http_check "$SMOKE_WORKLOAD_NAME" "$i"
    snapshot_pod_logs "$SMOKE_WORKLOAD_NAME" "$i"
    sleep "$EVENT_SETTLE_SECONDS"
    scale_owned_deployment "$SMOKE_WORKLOAD_NAME" 0
    wait_for_zero_pods "$SMOKE_WORKLOAD_NAME" 180
    sleep 2
  done
}

run_node_scale_smoke() {
  is_true "$ENABLE_NODE_SCALE_SMOKE" || { log "S03: skipped (ENABLE_NODE_SCALE_SMOKE=false)"; return 0; }
  log "S03: real ACK node-scale smoke"

  local existing_count
  existing_count="$(kube get nodes -l "${ELASTIC_NODE_SELECTOR_KEY}=${ELASTIC_NODE_SELECTOR_VALUE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if is_true "$REQUIRE_EMPTY_ELASTIC_POOL" && [[ "$existing_count" != "0" ]]; then
    die "elastic selector currently matches ${existing_count} node(s); set pool min=0 or disable REQUIRE_EMPTY_ELASTIC_POOL"
  fi

  kube get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,CREATED:.metadata.creationTimestamp,PROVIDER:.spec.providerID' --no-headers | sort \
    >"$ARTIFACT_DIR/nodes-before.txt"
  kube get nodes -o json >"$ARTIFACT_DIR/nodes-before.json"
  kube get nodes -o name | sort >"$ARTIFACT_DIR/node-names-before.txt"
  kube get nodes -l "${ELASTIC_NODE_SELECTOR_KEY}=${ELASTIC_NODE_SELECTOR_VALUE}" -o name | sort \
    >"$ARTIFACT_DIR/elastic-node-names-before.txt"

  local yaml="$ARTIFACT_DIR/${NODE_SCALE_WORKLOAD_NAME}.yaml"
  write_workload_yaml "$yaml" "$NODE_SCALE_WORKLOAD_NAME" 0 \
    "$NODE_SCALE_CPU_REQUEST" "$NODE_SCALE_CPU_LIMIT" "$NODE_SCALE_MEMORY_REQUEST" "$NODE_SCALE_MEMORY_LIMIT" \
    "$ELASTIC_NODE_SELECTOR_KEY" "$ELASTIC_NODE_SELECTOR_VALUE" \
    "$ELASTIC_TAINT_KEY" "$ELASTIC_TAINT_VALUE" "$ELASTIC_TAINT_EFFECT"
  verify_namespace_ownership || die "namespace ownership changed before node-scale workload creation"
  kube create -f "$yaml" >"$ARTIFACT_DIR/apply-node-scale.txt"

  if is_true "$ENABLE_SECOND_NODE_SCALE_WAVE"; then
    local second_yaml="$ARTIFACT_DIR/${NODE_SCALE_SECOND_WORKLOAD_NAME}.yaml"
    write_workload_yaml "$second_yaml" "$NODE_SCALE_SECOND_WORKLOAD_NAME" 0 \
      "$NODE_SCALE_SECOND_CPU_REQUEST" "$NODE_SCALE_SECOND_CPU_LIMIT" \
      "$NODE_SCALE_SECOND_MEMORY_REQUEST" "$NODE_SCALE_SECOND_MEMORY_LIMIT" \
      "$ELASTIC_NODE_SELECTOR_KEY" "$ELASTIC_NODE_SELECTOR_VALUE" \
      "$ELASTIC_TAINT_KEY" "$ELASTIC_TAINT_VALUE" "$ELASTIC_TAINT_EFFECT"
    verify_namespace_ownership || die "namespace ownership changed before second-wave workload creation"
    kube create -f "$second_yaml" >"$ARTIFACT_DIR/apply-node-scale-wave2.txt"
  fi

  date -u +'%Y-%m-%dT%H:%M:%S.%NZ' >"$ARTIFACT_DIR/wave1-trigger-utc.txt"
  NODE_SCALE_WORKLOAD_ACTIVE=true
  if is_true "$ENABLE_SECOND_NODE_SCALE_WAVE"; then
    scale_owned_deployment "$NODE_SCALE_WORKLOAD_NAME" "$NODE_SCALE_REPLICAS"
    sleep "$NODE_SCALE_WAVE_STAGGER_SECONDS"
    date -u +'%Y-%m-%dT%H:%M:%S.%NZ' >"$ARTIFACT_DIR/wave2-trigger-utc.txt"
    scale_owned_deployment "$NODE_SCALE_SECOND_WORKLOAD_NAME" "$NODE_SCALE_SECOND_REPLICAS"
    if ! kube -n "$EXPERIMENT_NAMESPACE" rollout status "deployment/${NODE_SCALE_WORKLOAD_NAME}" --timeout="$NODE_SCALE_TIMEOUT" \
      >"$ARTIFACT_DIR/rollout-node-scale.log" 2>&1; then
      kube -n "$EXPERIMENT_NAMESPACE" get pods -l "app=${NODE_SCALE_WORKLOAD_NAME}" -o wide >"$ARTIFACT_DIR/node-scale-pods.txt" 2>&1 || true
      kube -n "$EXPERIMENT_NAMESPACE" describe pods -l "app=${NODE_SCALE_WORKLOAD_NAME}" >"$ARTIFACT_DIR/describe-node-scale-pods.txt" 2>&1 || true
      kube get events -A --sort-by=.lastTimestamp >"$ARTIFACT_DIR/kubernetes-events.txt" 2>&1 || true
      die "node-scale workload did not become Ready before ${NODE_SCALE_TIMEOUT}"
    fi
    if ! kube -n "$EXPERIMENT_NAMESPACE" rollout status "deployment/${NODE_SCALE_SECOND_WORKLOAD_NAME}" --timeout="$NODE_SCALE_TIMEOUT" \
      >"$ARTIFACT_DIR/rollout-node-scale-wave2.log" 2>&1; then
      kube -n "$EXPERIMENT_NAMESPACE" get pods -l "app=${NODE_SCALE_SECOND_WORKLOAD_NAME}" -o wide >"$ARTIFACT_DIR/node-scale-wave2-pods.txt" 2>&1 || true
      kube -n "$EXPERIMENT_NAMESPACE" describe pods -l "app=${NODE_SCALE_SECOND_WORKLOAD_NAME}" >"$ARTIFACT_DIR/describe-node-scale-wave2-pods.txt" 2>&1 || true
      die "second node-scale wave did not become Ready before ${NODE_SCALE_TIMEOUT}"
    fi
  elif ! run_measured_rollout "$NODE_SCALE_WORKLOAD_NAME" 1 node-scale \
      "$NODE_SCALE_REPLICAS" "$NODE_SCALE_TIMEOUT" "$ARTIFACT_DIR/rollout-node-scale.log"; then
    kube -n "$EXPERIMENT_NAMESPACE" get pods -l "app=${NODE_SCALE_WORKLOAD_NAME}" -o wide >"$ARTIFACT_DIR/node-scale-pods.txt" 2>&1 || true
    kube -n "$EXPERIMENT_NAMESPACE" describe pods -l "app=${NODE_SCALE_WORKLOAD_NAME}" >"$ARTIFACT_DIR/describe-node-scale-pods.txt" 2>&1 || true
    kube get events -A --sort-by=.lastTimestamp >"$ARTIFACT_DIR/kubernetes-events.txt" 2>&1 || true
    die "node-scale measured rollout failed; inspect ${ARTIFACT_DIR}/rollout-node-scale.log"
  fi

  snapshot_pods "$NODE_SCALE_WORKLOAD_NAME" "1"
  http_check "$NODE_SCALE_WORKLOAD_NAME" "1"
  snapshot_pod_logs "$NODE_SCALE_WORKLOAD_NAME" "1"
  if is_true "$ENABLE_SECOND_NODE_SCALE_WAVE"; then
    snapshot_pods "$NODE_SCALE_SECOND_WORKLOAD_NAME" "1"
    http_check "$NODE_SCALE_SECOND_WORKLOAD_NAME" "1"
    snapshot_pod_logs "$NODE_SCALE_SECOND_WORKLOAD_NAME" "1"
  fi
  sleep "$EVENT_SETTLE_SECONDS"

  kube get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,CREATED:.metadata.creationTimestamp,PROVIDER:.spec.providerID' --no-headers | sort \
    >"$ARTIFACT_DIR/nodes-after.txt"
  kube get nodes -o json >"$ARTIFACT_DIR/nodes-after.json"
  kube -n "$EXPERIMENT_NAMESPACE" get events -o json >"$ARTIFACT_DIR/kubernetes-events.json"
  kube get nodes -o name | sort >"$ARTIFACT_DIR/node-names-after.txt"
  kube get nodes -l "${ELASTIC_NODE_SELECTOR_KEY}=${ELASTIC_NODE_SELECTOR_VALUE}" -o name | sort \
    >"$ARTIFACT_DIR/elastic-node-names-after.txt"
  comm -13 "$ARTIFACT_DIR/elastic-node-names-before.txt" "$ARTIFACT_DIR/elastic-node-names-after.txt" \
    >"$ARTIFACT_DIR/new-node-names.txt"

  if is_true "$REQUIRE_NEW_NODE" && [[ ! -s "$ARTIFACT_DIR/new-node-names.txt" ]]; then
    die "no new Node name observed during S03"
  fi

  if [[ -z "$RUNTIME_EVENTS_EXPORT_HOOK" ]]; then
    stop_node_scale_workloads
  else
    log "keeping node-scale workload active until runtime journals are exported"
  fi
  if [[ -n "$ACK_EVENTS_EXPORT_HOOK" ]]; then
    date -u +'%Y-%m-%dT%H:%M:%S.%NZ' >"$ARTIFACT_DIR/wave-end-utc.txt"
    ACK_EVENTS_NDJSON="$ARTIFACT_DIR/ack-events.ndjson"
    log "exporting exact ACK/GOATScaler events with configured hook"
    "$ACK_EVENTS_EXPORT_HOOK" \
      --cluster-id "$CLUSTER_ID" --run-id "$RUN_ID" \
      --start-file "$ARTIFACT_DIR/wave1-trigger-utc.txt" \
      --end-file "$ARTIFACT_DIR/wave-end-utc.txt" \
      --output "$ACK_EVENTS_NDJSON" \
      >"$ARTIFACT_DIR/ack-events-export.log" 2>&1
    [[ -s "$ACK_EVENTS_NDJSON" ]] || die "ACK_EVENTS_EXPORT_HOOK produced no events"
  fi
  if [[ -n "$ACK_EVENTS_NDJSON" ]]; then
    [[ -f "$ACK_EVENTS_NDJSON" ]] || die "ACK_EVENTS_NDJSON not found: $ACK_EVENTS_NDJSON"
    [[ -f "$ACK_ADAPTER_CONFIG" ]] || die "ACK_ADAPTER_CONFIG not found: $ACK_ADAPTER_CONFIG"
    local generated_config="$ARTIFACT_DIR/ack-adapter.generated.yaml"
    awk -v cid="$CLUSTER_ID" -v rid="$RUN_ID" '
      /^cluster_id:/ { print "cluster_id: " cid; next }
      /^default_run_id:/ { print "default_run_id: \"" rid "\""; next }
      { print }
    ' "$ACK_ADAPTER_CONFIG" >"$generated_config"
    log "importing ACK/GOATScaler NDJSON: $ACK_EVENTS_NDJSON"
    HOOKE_INGESTER_URL="http://127.0.0.1:${INGESTER_PORT}" \
    HOOKE_AUTH_TOKEN="$HOOKE_AUTH_TOKEN" \
    HOOKE_ACTIVE_RUN_ID="$RUN_ID" \
      "$PROJECT_ROOT/bin/hooke-ack-adapter" --config "$generated_config" --stdin \
      <"$ACK_EVENTS_NDJSON" >"$ARTIFACT_DIR/ack-adapter.log" 2>&1
    sleep "$EVENT_SETTLE_SECONDS"
  else
    warn "ACK_EVENTS_NDJSON is empty; Node layer start remains approximate (POD_UNSCHEDULABLE -> NODE_READY)"
  fi
}

mysql_docker_exec() {
  docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" "$MYSQL_CONTAINER_NAME" \
    mysql --default-character-set=utf8mb4 -u"$MYSQL_USER" "$MYSQL_DATABASE" "$@"
}

mysql_external_exec() {
  # External mode uses separate connection fields only for report queries.
  # MYSQL_DSN is used by Go; MYSQL CLI_* variables are required here.
  : "${MYSQL_CLI_HOST:?MYSQL_CLI_HOST is required for external mode reports}"
  : "${MYSQL_CLI_PORT:=3306}"
  : "${MYSQL_CLI_USER:?MYSQL_CLI_USER is required for external mode reports}"
  : "${MYSQL_CLI_PASSWORD:=}"
  MYSQL_PWD="$MYSQL_CLI_PASSWORD" mysql --default-character-set=utf8mb4 \
    -h"$MYSQL_CLI_HOST" -P"$MYSQL_CLI_PORT" -u"$MYSQL_CLI_USER" "$MYSQL_DATABASE" "$@"
}

mysql_exec() {
  if [[ "$MYSQL_MODE" == "docker" ]]; then
    mysql_docker_exec "$@"
  else
    mysql_external_exec "$@"
  fi
}

mysql_scalar() {
  mysql_exec --batch --skip-column-names -e "$1" | tr -d '\r' | tail -n 1
}

count_nonempty_lines() {
  awk 'NF { count++ } END { print count + 0 }' "$1"
}

node_name_sql_list() {
  local file="$1" entry name separator=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry#node/}"
    [[ "$name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "invalid Node name in ${file}: ${entry}"
    printf "%s'%s'" "$separator" "$name"
    separator=","
  done <"$file"
}

write_reports_and_gate() {
  log "S04: correlate, calculate, and validate"
  HOOKE_MYSQL_DSN="$MYSQL_DSN" "$PROJECT_ROOT/bin/hookectl" calculate \
    --dsn "$MYSQL_DSN" --run-id "$RUN_ID" >"$ARTIFACT_DIR/calculation.json"
  HOOKE_MYSQL_DSN="$MYSQL_DSN" "$PROJECT_ROOT/bin/hookectl" report \
    --dsn "$MYSQL_DSN" --run-id "$RUN_ID" >"$ARTIFACT_DIR/report.json"
  HOOKE_MYSQL_DSN="$MYSQL_DSN" "$PROJECT_ROOT/bin/hookectl" attribution \
    --dsn "$MYSQL_DSN" --run-id "$RUN_ID" --window "$ATTRIBUTION_WINDOW" >"$ARTIFACT_DIR/attribution.json"

  mysql_exec --batch --raw -e "
SELECT event_type, approximate, COUNT(*) AS event_count
FROM raw_events WHERE run_id='${RUN_ID}'
GROUP BY event_type, approximate ORDER BY event_type, approximate;" \
    >"$ARTIFACT_DIR/events.tsv"

  mysql_exec --batch --raw -e "
SELECT pod_name, container_name, node_name, complete,
       ROUND(node_latency_ms,3) AS node_ms,
       ROUND(image_latency_ms,3) AS image_ms,
       ROUND(pod_latency_ms,3) AS pod_ms,
       ROUND(app_latency_ms,3) AS app_ms,
       ROUND(total_latency_ms,3) AS total_ms,
       ROUND(overlap_ms,3) AS overlap_ms,
       ROUND(unattributed_ms,3) AS unattributed_ms,
       ROUND(exact_coverage,3) AS exact_coverage,
       invalid_order_count,
       quality
FROM pod_traces WHERE run_id='${RUN_ID}'
ORDER BY pod_name, container_name;" >"$ARTIFACT_DIR/traces.tsv"

  mysql_exec --batch --raw -e "
SELECT pod_uid, pod_name, node_name,
       trigger_time_ns, node_start_ns, node_ready_ns,
       image_pull_start_ns, image_pull_end_ns, image_unpack_end_ns,
       sync_pod_start_ns,
       pod_sandbox_start_ns, pod_sandbox_end_ns,
       container_started_ns, readiness_success_ns,
       JSON_UNQUOTE(JSON_EXTRACT(quality,'$.node_clock_uncertainty_unknown')) AS node_clock_uncertainty_unknown,
       JSON_UNQUOTE(JSON_EXTRACT(quality,'$.sandbox_clock_uncertainty_unknown')) AS sandbox_clock_uncertainty_unknown
FROM pod_traces WHERE run_id='${RUN_ID}'
ORDER BY pod_name, container_name;" >"$ARTIFACT_DIR/trace-timestamps.tsv"

  mysql_exec --batch --raw -e "
SELECT cluster_id, run_id, namespace, pod_uid, pod_name, node_name, event_type, event_time_ns,
       source_component, approximate
FROM raw_events
WHERE run_id='${RUN_ID}'
  AND event_type IN ('POD_CREATED','POD_SCHEDULED','POD_SANDBOX_START','POD_SANDBOX_END')
ORDER BY pod_uid, event_time_ns, event_type;" >"$ARTIFACT_DIR/pod-lifecycle-events.tsv"

  mysql_exec --batch --raw -e "
SELECT MAX(cluster_id) AS cluster_id,
       MAX(run_id) AS run_id,
       MAX(namespace) AS namespace,
       pod_uid,
       MAX(pod_name) AS pod_name,
       event_type,
       event_uid,
       MAX(event_count) AS attempts,
       MIN(event_time_ns) AS first_event_time_ns,
       MAX(event_time_ns) AS last_event_time_ns,
       MAX(reason) AS reason,
       MAX(message) AS message
FROM (
  SELECT cluster_id, run_id, namespace, pod_uid, pod_name, event_type,
         COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.kubernetes_event_uid')),''), event_id) AS event_uid,
         CAST(COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.count')),''),'1') AS UNSIGNED) AS event_count,
         event_time_ns, reason,
         JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.message')) AS message
  FROM raw_events
  WHERE run_id='${RUN_ID}'
    AND event_type IN ('POD_SANDBOX_FAILED','CNI_SETUP_FAILED')
) failures
GROUP BY pod_uid, event_type, event_uid
ORDER BY pod_name, event_type, first_event_time_ns;" >"$ARTIFACT_DIR/sandbox-failures.tsv"

  mysql_exec --batch --raw -e "
SELECT node_name, event_type,
       JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) AS task_id,
       JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.provider_id')) AS provider_id,
       event_time_ns, approximate
FROM raw_events
WHERE run_id='${RUN_ID}'
  AND node_name IN (
    SELECT DISTINCT node_name FROM pod_traces
    WHERE run_id='${RUN_ID}' AND node_name IS NOT NULL
  )
ORDER BY node_name, event_time_ns, event_type;" >"$ARTIFACT_DIR/target-node-events.tsv"

  mysql_exec --batch --raw -e "
SELECT scope, metric_name, metric_value, unit, sample_count, details
FROM metric_results WHERE run_id='${RUN_ID}'
ORDER BY scope, metric_name;" >"$ARTIFACT_DIR/metrics.tsv"

  mysql_exec --batch --raw -e "SELECT * FROM v_trace_quality WHERE run_id='${RUN_ID}';" \
    >"$ARTIFACT_DIR/trace-quality.tsv"

  mysql_exec --batch --raw -e "
SELECT pod_uid,
       MAX(pod_name) AS pod_name,
       MAX(JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id'))) AS task_id,
       MAX(JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.provision_node_name'))) AS provision_node_name,
       MAX(node_name) AS scheduled_node
FROM raw_events
WHERE run_id='${RUN_ID}' AND pod_uid IS NOT NULL AND source_component='kubernetes-pod-watch'
GROUP BY pod_uid
HAVING task_id IS NOT NULL
ORDER BY pod_name;" >"$ARTIFACT_DIR/task-links.tsv"

  local event_count trace_count complete_count pod_created scheduled started ready readiness pod_samples app_samples unschedulable_events unschedulable_pods node_ready provision_requested task_pods node_tasks provider_nodes unique_tasks max_pods_per_task attribution_conflicts task_precision task_recall
  local node_samples image_samples exact_node_samples exact_image_samples exact_pod_samples exact_app_samples invalid_order_count
  local untraceable_primary_samples
  local sandbox_samples cni_samples exact_sandbox_samples exact_cni_samples
  local sandbox_failure_attempts cni_failure_attempts sandbox_failed_pods cni_failed_pods
  local observed_nodes elastic_nodes_before elastic_nodes_after new_nodes new_ready_nodes new_task_nodes new_provider_nodes new_node_predicate new_node_names_sql controller_errors ingester_errors
  event_count="$(mysql_scalar "SELECT COUNT(*) FROM raw_events WHERE run_id='${RUN_ID}';")"
  trace_count="$(mysql_scalar "SELECT COUNT(*) FROM pod_traces WHERE run_id='${RUN_ID}';")"
  complete_count="$(mysql_scalar "SELECT COUNT(*) FROM pod_traces WHERE run_id='${RUN_ID}' AND complete=1;")"
  pod_created="$(mysql_scalar "SELECT COUNT(DISTINCT pod_uid) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='POD_CREATED' AND pod_uid IS NOT NULL;")"
  scheduled="$(mysql_scalar "SELECT COUNT(DISTINCT pod_uid) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='POD_SCHEDULED' AND pod_uid IS NOT NULL;")"
  started="$(mysql_scalar "SELECT COUNT(DISTINCT pod_uid) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='CONTAINER_STARTED' AND pod_uid IS NOT NULL;")"
  ready="$(mysql_scalar "SELECT COUNT(DISTINCT pod_uid) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='POD_READY' AND pod_uid IS NOT NULL;")"
  readiness="$(mysql_scalar "SELECT COUNT(DISTINCT pod_uid) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='READINESS_PROBE_FIRST_SUCCESS' AND pod_uid IS NOT NULL;")"
  node_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND layer='node' AND primary_sample=1;")"
  image_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND layer='image' AND primary_sample=1;")"
  pod_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND layer='pod' AND primary_sample=1;")"
  app_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND layer='app' AND primary_sample=1;")"
  exact_node_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND layer='node' AND primary_sample=1 AND approximate=0;")"
  exact_image_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND layer='image' AND primary_sample=1 AND approximate=0;")"
  exact_pod_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND layer='pod' AND primary_sample=1 AND approximate=0;")"
  exact_app_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND layer='app' AND primary_sample=1 AND approximate=0;")"
  invalid_order_count="$(mysql_scalar "SELECT COALESCE(SUM(invalid_order_count),0) FROM pod_traces WHERE run_id='${RUN_ID}';")"
  untraceable_primary_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND primary_sample=1 AND (source_start_event_id IS NULL OR source_end_event_id IS NULL);")"
  sandbox_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND stage='sandbox' AND primary_sample=0;")"
  cni_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND stage='cni' AND primary_sample=0;")"
  exact_sandbox_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND stage='sandbox' AND primary_sample=0 AND approximate=0 AND source_start_event_id IS NOT NULL AND source_end_event_id IS NOT NULL;")"
  exact_cni_samples="$(mysql_scalar "SELECT COUNT(*) FROM layer_samples WHERE run_id='${RUN_ID}' AND stage='cni' AND primary_sample=0 AND approximate=0 AND source_start_event_id IS NOT NULL AND source_end_event_id IS NOT NULL;")"
  sandbox_failed_pods="$(mysql_scalar "SELECT COUNT(DISTINCT pod_uid) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='POD_SANDBOX_FAILED' AND pod_uid IS NOT NULL;")"
  cni_failed_pods="$(mysql_scalar "SELECT COUNT(DISTINCT pod_uid) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='CNI_SETUP_FAILED' AND pod_uid IS NOT NULL;")"
  sandbox_failure_attempts="$(mysql_scalar "SELECT COALESCE(SUM(attempts),0) FROM (SELECT COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.kubernetes_event_uid')),''), event_id) AS event_uid, MAX(CAST(COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.count')),''),'1') AS UNSIGNED)) AS attempts FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='POD_SANDBOX_FAILED' GROUP BY event_uid) sandbox_failures;")"
  cni_failure_attempts="$(mysql_scalar "SELECT COALESCE(SUM(attempts),0) FROM (SELECT COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.kubernetes_event_uid')),''), event_id) AS event_uid, MAX(CAST(COALESCE(NULLIF(JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.count')),''),'1') AS UNSIGNED)) AS attempts FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='CNI_SETUP_FAILED' GROUP BY event_uid) cni_failures;")"
  unschedulable_events="$(mysql_scalar "SELECT COUNT(*) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='POD_UNSCHEDULABLE';")"
  unschedulable_pods="$(mysql_scalar "SELECT COUNT(DISTINCT pod_uid) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='POD_UNSCHEDULABLE' AND pod_uid IS NOT NULL;")"
  node_ready="$(mysql_scalar "SELECT COUNT(*) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='NODE_READY';")"
  provision_requested="$(mysql_scalar "SELECT COUNT(*) FROM raw_events WHERE run_id='${RUN_ID}' AND event_type='ACK_PROVISION_REQUESTED';")"
  task_pods="$(mysql_scalar "SELECT COUNT(DISTINCT pod_uid) FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-pod-watch' AND pod_uid IS NOT NULL AND JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) IS NOT NULL;")"
  node_tasks="$(mysql_scalar "SELECT COUNT(DISTINCT node_name) FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-node-watch' AND node_name IS NOT NULL AND (event_type IN ('NODE_CREATED','NODE_READY') OR (event_type='ACK_PROVISION_TASK_UPDATED' AND pod_uid IS NULL)) AND JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) IS NOT NULL;")"
  provider_nodes="$(mysql_scalar "SELECT COUNT(DISTINCT node_name) FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-node-watch' AND node_name IS NOT NULL AND event_type IN ('NODE_CREATED','NODE_READY','ACK_PROVISION_TASK_UPDATED') AND JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.provider_id')) IS NOT NULL;")"
  unique_tasks="$(mysql_scalar "SELECT COUNT(DISTINCT JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id'))) FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-pod-watch' AND pod_uid IS NOT NULL AND JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) IS NOT NULL;")"
  max_pods_per_task="$(mysql_scalar "SELECT COALESCE(MAX(pod_count),0) FROM (SELECT JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) AS task_id, COUNT(DISTINCT pod_uid) AS pod_count FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-pod-watch' AND pod_uid IS NOT NULL AND JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) IS NOT NULL GROUP BY task_id) task_counts;")"
  attribution_conflicts="$(mysql_scalar "SELECT COALESCE(MAX(metric_value),0) FROM metric_results WHERE run_id='${RUN_ID}' AND scope='attribution' AND metric_name='conflict_count';")"
  task_precision="$(mysql_scalar "SELECT COALESCE(MAX(metric_value),0) FROM metric_results WHERE run_id='${RUN_ID}' AND scope='attribution/task-id' AND metric_name='precision';")"
  task_recall="$(mysql_scalar "SELECT COALESCE(MAX(metric_value),0) FROM metric_results WHERE run_id='${RUN_ID}' AND scope='attribution/task-id' AND metric_name='recall';")"

  observed_nodes="$(mysql_scalar "SELECT COUNT(DISTINCT node_name) FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-node-watch' AND node_name IS NOT NULL;")"
  elastic_nodes_before=0
  elastic_nodes_after=0
  new_nodes=0
  new_node_predicate="1=0"
  if is_true "$ENABLE_NODE_SCALE_SMOKE"; then
    elastic_nodes_before="$(count_nonempty_lines "$ARTIFACT_DIR/elastic-node-names-before.txt")"
    elastic_nodes_after="$(count_nonempty_lines "$ARTIFACT_DIR/elastic-node-names-after.txt")"
    new_nodes="$(count_nonempty_lines "$ARTIFACT_DIR/new-node-names.txt")"
    if (( new_nodes > 0 )); then
      new_node_names_sql="$(node_name_sql_list "$ARTIFACT_DIR/new-node-names.txt")"
      new_node_predicate="node_name IN (${new_node_names_sql})"
    fi
  fi
  mysql_exec --batch --raw -e "
SELECT node_name, event_type,
       JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) AS task_id,
       JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.provider_id')) AS provider_id,
       event_time_ns, approximate
FROM raw_events
WHERE run_id='${RUN_ID}' AND source_component='kubernetes-node-watch'
  AND ${new_node_predicate}
ORDER BY node_name, event_time_ns, event_type;" >"$ARTIFACT_DIR/new-node-events.tsv"
  new_ready_nodes="$(mysql_scalar "SELECT COUNT(DISTINCT node_name) FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-node-watch' AND event_type='NODE_READY' AND ${new_node_predicate};")"
  new_task_nodes="$(mysql_scalar "SELECT COUNT(DISTINCT node_name) FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-node-watch' AND ${new_node_predicate} AND JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) IN (SELECT current_task_id FROM (SELECT DISTINCT JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) AS current_task_id FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-pod-watch' AND pod_uid IS NOT NULL AND JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) IS NOT NULL) current_tasks);")"
  new_provider_nodes="$(mysql_scalar "SELECT COUNT(DISTINCT node_name) FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-node-watch' AND ${new_node_predicate} AND JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.provider_id')) IS NOT NULL AND JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) IN (SELECT current_task_id FROM (SELECT DISTINCT JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) AS current_task_id FROM raw_events WHERE run_id='${RUN_ID}' AND source_component='kubernetes-pod-watch' AND pod_uid IS NOT NULL AND JSON_UNQUOTE(JSON_EXTRACT(attributes,'$.task_id')) IS NOT NULL) current_tasks);")"

  controller_errors="$(awk '/"level":"ERROR"/ { count++ } END { print count + 0 }' "$ARTIFACT_DIR/controller.log")"
  ingester_errors="$(awk '/"level":"ERROR"/ { count++ } END { print count + 0 }' "$ARTIFACT_DIR/ingester.log")"

  local expected_traces=0
  if is_true "$ENABLE_FIXED_SMOKE"; then
    expected_traces="$SMOKE_REPETITIONS"
  fi
  if is_true "$ENABLE_NODE_SCALE_SMOKE"; then
    expected_traces=$((expected_traces + NODE_SCALE_REPLICAS))
    if is_true "$ENABLE_SECOND_NODE_SCALE_WAVE"; then
      expected_traces=$((expected_traces + NODE_SCALE_SECOND_REPLICAS))
    fi
  fi

  local gate=PASS
  local reasons=()
  (( event_count > 0 )) || { gate=FAIL; reasons+=("no raw events"); }
  (( pod_created == expected_traces )) || { gate=FAIL; reasons+=("POD_CREATED ${pod_created} != expected ${expected_traces}"); }
  (( scheduled == expected_traces )) || { gate=FAIL; reasons+=("POD_SCHEDULED ${scheduled} != expected ${expected_traces}"); }
  (( started == expected_traces )) || { gate=FAIL; reasons+=("CONTAINER_STARTED ${started} != expected ${expected_traces}"); }
  (( ready == expected_traces )) || { gate=FAIL; reasons+=("POD_READY ${ready} != expected ${expected_traces}"); }
  (( readiness == expected_traces )) || { gate=FAIL; reasons+=("READINESS events ${readiness} != expected ${expected_traces}"); }
  (( trace_count == expected_traces )) || { gate=FAIL; reasons+=("traces ${trace_count} != expected ${expected_traces}"); }
  (( complete_count == expected_traces )) || { gate=FAIL; reasons+=("complete traces ${complete_count} != expected ${expected_traces}"); }
  (( pod_samples == expected_traces )) || { gate=FAIL; reasons+=("pod samples ${pod_samples} != expected ${expected_traces}"); }
  (( app_samples == expected_traces )) || { gate=FAIL; reasons+=("app samples ${app_samples} != expected ${expected_traces}"); }
  (( invalid_order_count == 0 )) || { gate=FAIL; reasons+=("invalid event order count ${invalid_order_count} != 0"); }
  if is_true "$REQUIRE_DERIVATION_TRACEABILITY"; then
    (( untraceable_primary_samples == 0 )) || { gate=FAIL; reasons+=("untraceable primary samples ${untraceable_primary_samples} != 0"); }
  fi
  if is_true "$REQUIRE_POD_SUBSTAGES"; then
    (( sandbox_samples == expected_traces )) || { gate=FAIL; reasons+=("sandbox samples ${sandbox_samples} != expected ${expected_traces}"); }
    (( exact_sandbox_samples == sandbox_samples )) || { gate=FAIL; reasons+=("exact sandbox samples ${exact_sandbox_samples} != sandbox samples ${sandbox_samples}"); }
  fi
  if is_true "$REQUIRE_CNI_SUBSTAGE"; then
    (( cni_samples == expected_traces )) || { gate=FAIL; reasons+=("CNI samples ${cni_samples} != expected ${expected_traces}"); }
    (( exact_cni_samples == cni_samples )) || { gate=FAIL; reasons+=("exact CNI samples ${exact_cni_samples} != CNI samples ${cni_samples}"); }
  fi
  if is_true "$REQUIRE_EXACT_IMAGE_EVENTS"; then
    (( image_samples == expected_traces )) || { gate=FAIL; reasons+=("image samples ${image_samples} != expected ${expected_traces}"); }
    (( exact_image_samples == image_samples )) || { gate=FAIL; reasons+=("exact image samples ${exact_image_samples} != image samples ${image_samples}"); }
  fi
  if is_true "$REQUIRE_EXACT_POD_EVENTS"; then
    (( exact_pod_samples == pod_samples )) || { gate=FAIL; reasons+=("exact pod samples ${exact_pod_samples} != pod samples ${pod_samples}"); }
  fi
  if is_true "$REQUIRE_EXACT_APP_EVENTS"; then
    (( exact_app_samples == app_samples )) || { gate=FAIL; reasons+=("exact app samples ${exact_app_samples} != app samples ${app_samples}"); }
  fi
  (( controller_errors == 0 )) || { gate=FAIL; reasons+=("controller logged ${controller_errors} error(s)"); }
  (( ingester_errors == 0 )) || { gate=FAIL; reasons+=("ingester logged ${ingester_errors} error(s)"); }
  if is_true "$ENABLE_NODE_SCALE_SMOKE"; then
    if is_true "$REQUIRE_EXACT_NODE_EVENTS"; then
      expected_node_samples="$NODE_SCALE_REPLICAS"
      if is_true "$ENABLE_SECOND_NODE_SCALE_WAVE"; then
        expected_node_samples=$((expected_node_samples + NODE_SCALE_SECOND_REPLICAS))
      fi
      (( exact_node_samples == expected_node_samples )) || { gate=FAIL; reasons+=("exact node samples ${exact_node_samples} != expected node samples ${expected_node_samples}"); }
    fi
    if is_true "$REQUIRE_NODE_UNSCHEDULABLE" && (( unschedulable_pods < 1 )); then
      gate=FAIL; reasons+=("no POD_UNSCHEDULABLE during node scale")
    fi
    if is_true "$REQUIRE_NEW_NODE"; then
      (( new_nodes >= 1 )) || { gate=FAIL; reasons+=("no new elastic-pool Node observed"); }
      (( new_ready_nodes == new_nodes )) || { gate=FAIL; reasons+=("new Ready Nodes ${new_ready_nodes} != new elastic-pool Nodes ${new_nodes}"); }
    fi
    if is_true "$REQUIRE_TASK_ID_ATTRIBUTION"; then
      (( provision_requested >= 1 )) || { gate=FAIL; reasons+=("no ACK_PROVISION_REQUESTED event"); }
      (( task_pods == unschedulable_pods )) || { gate=FAIL; reasons+=("task-ID pods ${task_pods} != unschedulable pods ${unschedulable_pods}"); }
      (( new_task_nodes == new_nodes && new_nodes > 0 )) || { gate=FAIL; reasons+=("current-task attributed new Nodes ${new_task_nodes} != new elastic-pool Nodes ${new_nodes}"); }
      (( new_provider_nodes == new_nodes && new_nodes > 0 )) || { gate=FAIL; reasons+=("current-task new Nodes with providerID ${new_provider_nodes} != new elastic-pool Nodes ${new_nodes}"); }
      [[ "$attribution_conflicts" == "0" || "$attribution_conflicts" == "0.0" || "$attribution_conflicts" == "0.000000" ]] || { gate=FAIL; reasons+=("attribution conflicts ${attribution_conflicts} != 0"); }
      [[ "$task_precision" == "1" || "$task_precision" == "1.0" || "$task_precision" == "1.000000" ]] || { gate=FAIL; reasons+=("task-ID precision ${task_precision} != 1"); }
      [[ "$task_recall" == "1" || "$task_recall" == "1.0" || "$task_recall" == "1.000000" ]] || { gate=FAIL; reasons+=("task-ID recall ${task_recall} != 1"); }
      if (( EXPECTED_TASK_COUNT > 0 )); then
        (( unique_tasks == EXPECTED_TASK_COUNT )) || { gate=FAIL; reasons+=("unique tasks ${unique_tasks} != expected ${EXPECTED_TASK_COUNT}"); }
      fi
      if (( EXPECTED_MIN_PODS_PER_TASK > 0 )); then
        (( max_pods_per_task >= EXPECTED_MIN_PODS_PER_TASK )) || { gate=FAIL; reasons+=("max Pods per task ${max_pods_per_task} < expected minimum ${EXPECTED_MIN_PODS_PER_TASK}"); }
      fi
    fi
  fi

  {
    echo "# Hooke ACK first smoke summary"
    echo
    echo "- result: **${gate}**"
    echo "- run_id: \`${RUN_ID}\`"
    echo "- run_name: \`${RUN_NAME}\`"
    echo "- kube_context: \`${EFFECTIVE_CONTEXT}\`"
    echo "- cluster_id: \`${CLUSTER_ID}\`"
    echo "- experiment_namespace: \`${EXPERIMENT_NAMESPACE}\`"
    echo "- raw_events: ${event_count}"
    echo "- traces: ${trace_count}"
    echo "- expected_traces: ${expected_traces}"
    echo "- complete_traces: ${complete_count}"
    echo "- node_layer_samples: ${node_samples}"
    echo "- image_layer_samples: ${image_samples}"
    echo "- pod_layer_samples: ${pod_samples}"
    echo "- app_layer_samples: ${app_samples}"
    echo "- exact_node_samples: ${exact_node_samples}"
    echo "- exact_image_samples: ${exact_image_samples}"
    echo "- exact_pod_samples: ${exact_pod_samples}"
    echo "- exact_app_samples: ${exact_app_samples}"
    echo "- invalid_order_count: ${invalid_order_count}"
    echo "- untraceable_primary_samples: ${untraceable_primary_samples}"
    echo "- sandbox_samples: ${sandbox_samples}"
    echo "- cni_samples: ${cni_samples}"
    echo "- exact_sandbox_samples: ${exact_sandbox_samples}"
    echo "- exact_cni_samples: ${exact_cni_samples}"
    echo "- sandbox_failed_pods: ${sandbox_failed_pods}"
    echo "- sandbox_failure_attempts: ${sandbox_failure_attempts}"
    echo "- cni_failed_pods: ${cni_failed_pods}"
    echo "- cni_failure_attempts: ${cni_failure_attempts}"
    echo "- controller_errors: ${controller_errors}"
    echo "- ingester_errors: ${ingester_errors}"
    echo "- node_scale_enabled: ${ENABLE_NODE_SCALE_SMOKE}"
    echo "- second_node_scale_wave: ${ENABLE_SECOND_NODE_SCALE_WAVE}"
    echo "- pod_unschedulable_events: ${unschedulable_events}"
    echo "- pod_unschedulable_pods: ${unschedulable_pods}"
    echo "- observed_nodes: ${observed_nodes}"
    echo "- observed_node_ready_events: ${node_ready}"
    echo "- elastic_nodes_before: ${elastic_nodes_before}"
    echo "- elastic_nodes_after: ${elastic_nodes_after}"
    echo "- new_elastic_nodes: ${new_nodes}"
    echo "- new_ready_nodes: ${new_ready_nodes}"
    echo "- current_task_new_nodes: ${new_task_nodes}"
    echo "- current_task_new_nodes_with_provider_id: ${new_provider_nodes}"
    echo "- provision_requested_events: ${provision_requested}"
    echo "- task_id_pods: ${task_pods}"
    echo "- observed_task_id_nodes: ${node_tasks}"
    echo "- observed_provider_id_nodes: ${provider_nodes}"
    echo "- unique_tasks: ${unique_tasks}"
    echo "- max_pods_per_task: ${max_pods_per_task}"
    echo "- attribution_conflicts: ${attribution_conflicts}"
    echo "- task_id_precision: ${task_precision}"
    echo "- task_id_recall: ${task_recall}"
    if [[ ${#reasons[@]} -gt 0 ]]; then
      echo
      echo "## Gate failures"
      local reason
      for reason in "${reasons[@]}"; do echo "- ${reason}"; done
    fi
    echo
    echo "## Files"
    echo "- events.tsv"
    echo "- traces.tsv"
    echo "- orchestrator-timing.tsv"
    echo "- trace-timestamps.tsv"
    echo "- pod-lifecycle-events.tsv"
    echo "- sandbox-failures.tsv"
    echo "- target-node-events.tsv"
    echo "- metrics.tsv"
    echo "- calculation.json"
    echo "- report.json"
    echo "- attribution.json"
    echo "- task-links.tsv"
    echo "- new-node-events.tsv"
    echo "- controller.log"
    echo "- ingester.log"
  } >"$ARTIFACT_DIR/summary.md"

  cat "$ARTIFACT_DIR/summary.md"
  [[ "$gate" == PASS ]] || die "Gate-S failed; see $ARTIFACT_DIR/summary.md"
}

log "preflight: context=${EFFECTIVE_CONTEXT}, namespace=${EXPERIMENT_NAMESPACE}, config=${CONFIG_FILE}"
kube cluster-info >"$ARTIFACT_DIR/cluster-info.txt"
kube version -o yaml >"$ARTIFACT_DIR/kubernetes-version.yaml" 2>&1 || true
kube get nodes -o wide >"$ARTIFACT_DIR/nodes-initial.txt"
kube config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}' >"$ARTIFACT_DIR/api-server.txt"

for permission in \
  "get namespaces" \
  "list namespaces" \
  "watch namespaces" \
  "get pods --all-namespaces" \
  "list pods --all-namespaces" \
  "watch pods --all-namespaces" \
  "get pods --subresource=log --namespace ${EXPERIMENT_NAMESPACE}" \
  "create pods --all-namespaces" \
  "delete pods --all-namespaces" \
  "create pods --subresource=exec --all-namespaces" \
  "create pods --subresource=portforward --namespace ${EXPERIMENT_NAMESPACE}" \
  "list nodes" \
  "watch nodes" \
  "list events --all-namespaces" \
  "watch events --all-namespaces" \
  "create namespaces" \
  "delete namespaces" \
  "patch namespaces" \
  "get deployments.apps --namespace ${EXPERIMENT_NAMESPACE}" \
  "list deployments.apps --namespace ${EXPERIMENT_NAMESPACE}" \
  "watch deployments.apps --namespace ${EXPERIMENT_NAMESPACE}" \
  "create deployments.apps --namespace ${EXPERIMENT_NAMESPACE}" \
  "patch deployments.apps --namespace ${EXPERIMENT_NAMESPACE}" \
  "patch deployments.apps --subresource=scale --namespace ${EXPERIMENT_NAMESPACE}" \
  "delete deployments.apps --namespace ${EXPERIMENT_NAMESPACE}" \
  "get replicasets.apps --namespace ${EXPERIMENT_NAMESPACE}" \
  "list horizontalpodautoscalers.autoscaling --all-namespaces" \
  "watch horizontalpodautoscalers.autoscaling --all-namespaces" \
  "get services --namespace ${EXPERIMENT_NAMESPACE}" \
  "create services --namespace ${EXPERIMENT_NAMESPACE}" \
  "delete services --namespace ${EXPERIMENT_NAMESPACE}"; do
  # shellcheck disable=SC2206
  args=($permission)
  answer="$(kube auth can-i "${args[@]}" 2>/dev/null || true)"
  [[ "$answer" == "yes" ]] || die "kube permission denied: kubectl auth can-i ${permission}"
done

if [[ -n "$HOOKE_AUTH_TOKEN" ]]; then
  for permission in \
    "get secrets --namespace ${EXPERIMENT_NAMESPACE}" \
    "create secrets --namespace ${EXPERIMENT_NAMESPACE}" \
    "patch secrets --namespace ${EXPERIMENT_NAMESPACE}" \
    "delete secrets --namespace ${EXPERIMENT_NAMESPACE}"; do
    # shellcheck disable=SC2206
    args=($permission)
    answer="$(kube auth can-i "${args[@]}" 2>/dev/null || true)"
    [[ "$answer" == "yes" ]] || die "kube permission denied: kubectl auth can-i ${permission}"
  done
fi

if [[ "$CHECK_ONLY" == true ]]; then
  log "preflight passed (--check-only); no local service or workload was created"
  SUCCESS=true
  exit 0
fi

# Store a redacted configuration snapshot.
sed -E \
  -e 's/^([A-Za-z0-9_]*(PASSWORD|TOKEN|DSN|SECRET|ACCESS_KEY|CREDENTIAL)[A-Za-z0-9_]*)=.*/\1="<redacted>"/' \
  "$CONFIG_FILE" >"$ARTIFACT_DIR/smoke.env.redacted"

port_is_free "$INGESTER_PORT" || die "INGESTER_PORT is already in use: ${INGESTER_PORT}"
port_is_free "$CONTROLLER_METRICS_PORT" || die "CONTROLLER_METRICS_PORT is already in use: ${CONTROLLER_METRICS_PORT}"

if [[ "$MYSQL_MODE" == "docker" ]]; then
  if [[ ! "$MYSQL_USER" =~ ^[A-Za-z0-9_.-]+$ || ! "$MYSQL_PASSWORD" =~ ^[A-Za-z0-9_.-]+$ || ! "$MYSQL_DATABASE" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    die "docker smoke credentials/database must use simple [A-Za-z0-9_.-] characters; use MYSQL_MODE=external for complex DSNs"
  fi
  if is_true "$RESET_MYSQL"; then
    warn "RESET_MYSQL=true: deleting container and volume ${MYSQL_CONTAINER_NAME}/${MYSQL_VOLUME_NAME}"
    docker rm -f "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker volume rm "$MYSQL_VOLUME_NAME" >/dev/null 2>&1 || true
  fi
  if ! docker container inspect "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1; then
    log "starting local MySQL container: ${MYSQL_CONTAINER_NAME}"
    docker volume create "$MYSQL_VOLUME_NAME" >/dev/null
    docker run -d --name "$MYSQL_CONTAINER_NAME" \
      --label hooke.io/component=mysql-smoke \
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
      >"$ARTIFACT_DIR/mysql-container-id.txt"
    MYSQL_STARTED_BY_SCRIPT=true
  else
    docker start "$MYSQL_CONTAINER_NAME" >/dev/null
  fi
  log "waiting for MySQL"
  mysql_deadline=$((SECONDS + 180))
  until docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER_NAME" \
      mysqladmin ping -h127.0.0.1 -uroot --silent >/dev/null 2>&1; do
    (( SECONDS < mysql_deadline )) || { docker logs "$MYSQL_CONTAINER_NAME" >"$ARTIFACT_DIR/mysql.log" 2>&1 || true; die "MySQL did not become ready"; }
    sleep 2
  done
  MYSQL_DSN="${MYSQL_USER}:${MYSQL_PASSWORD}@tcp(127.0.0.1:${MYSQL_HOST_PORT})/${MYSQL_DATABASE}?parseTime=true&loc=UTC&multiStatements=true"
  MYSQL_TOUCHED=true
fi

if ! is_true "$SKIP_BUILD"; then
  log "downloading Go modules and building smoke binaries"
  [[ -n "$GOPROXY" ]] && export GOPROXY
  GOTOOLCHAIN=local go mod download
  mkdir -p bin
  for bin in hooke-migrate hooke-ingester hooke-controller hookectl hooke-ack-adapter; do
    GOTOOLCHAIN=local go build -trimpath -o "bin/${bin}" "./cmd/${bin}"
  done
else
  for bin in hooke-migrate hooke-ingester hooke-controller hookectl; do
    [[ -x "bin/${bin}" ]] || die "SKIP_BUILD=true but bin/${bin} is missing"
  done
fi

log "applying MySQL schema"
HOOKE_MYSQL_DSN="$MYSQL_DSN" "$PROJECT_ROOT/bin/hooke-migrate" >"$ARTIFACT_DIR/migrate.log" 2>&1

log "starting local ingester on ${INGESTER_BIND_ADDRESS}:${INGESTER_PORT}"
HOOKE_MYSQL_DSN="$MYSQL_DSN" \
HOOKE_HTTP_ADDR="${INGESTER_BIND_ADDRESS}:${INGESTER_PORT}" \
HOOKE_AUTH_TOKEN="$HOOKE_AUTH_TOKEN" \
  "$PROJECT_ROOT/bin/hooke-ingester" >"$ARTIFACT_DIR/ingester.log" 2>&1 &
INGESTER_PID=$!
wait_http "http://127.0.0.1:${INGESTER_PORT}/readyz" 60 "hooke-ingester"

TOKEN_ARGS=()
[[ -n "$HOOKE_AUTH_TOKEN" ]] && TOKEN_ARGS=(--token "$HOOKE_AUTH_TOKEN")
log "creating experiment run: ${RUN_NAME}"
"$PROJECT_ROOT/bin/hookectl" run create \
  --api "http://127.0.0.1:${INGESTER_PORT}" \
  "${TOKEN_ARGS[@]}" \
  --cluster "$CLUSTER_ID" --name "$RUN_NAME" --slo-seconds "$SLO_SECONDS" --labels-json "$RUN_LABELS_JSON" \
  >"$ARTIFACT_DIR/run.json"
RUN_ID="$(python3 - "$ARTIFACT_DIR/run.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f)["run_id"])
PY
)"
[[ -n "$RUN_ID" ]] || die "failed to parse run_id"
log "RUN_ID=${RUN_ID}"
if is_true "$UNIQUE_RESOURCE_NAMES"; then
  resource_suffix="$(tr '[:upper:]' '[:lower:]' <<<"${RUN_ID:0:8}")"
  SMOKE_WORKLOAD_NAME="${SMOKE_WORKLOAD_NAME}-${resource_suffix}"
  NODE_SCALE_WORKLOAD_NAME="${NODE_SCALE_WORKLOAD_NAME}-${resource_suffix}"
  NODE_SCALE_SECOND_WORKLOAD_NAME="${NODE_SCALE_SECOND_WORKLOAD_NAME}-${resource_suffix}"
  APP_AUTH_SECRET_NAME="${APP_AUTH_SECRET_NAME}-${resource_suffix}"
fi

EXPECTED_NAMESPACE_UID=""
if ! namespace_probe="$(kube --request-timeout=30s get namespace "$EXPERIMENT_NAMESPACE" \
    --ignore-not-found -o name 2>/dev/null)"; then
  die "failed to query experiment namespace: ${EXPERIMENT_NAMESPACE}"
fi
if [[ -n "$namespace_probe" ]]; then
  if is_true "$UNIQUE_EXPERIMENT_NAMESPACE"; then
    die "generated experiment namespace already exists: ${EXPERIMENT_NAMESPACE}"
  fi
  NAMESPACE_EXISTED=true
  K8S_MUTATED=true
  if ! namespace_json="$(kube --request-timeout=30s get namespace "$EXPERIMENT_NAMESPACE" -o json)"; then
    die "failed to capture existing experiment namespace"
  fi
  if ! namespace_values="$(printf '%s' "$namespace_json" | python3 /dev/fd/3 3<<'PY'
import json, sys
payload = json.load(sys.stdin)
metadata = payload.get("metadata", {})
name = metadata.get("name", "")
uid = metadata.get("uid", "")
previous = (metadata.get("annotations") or {}).get("hooke.io/run-id", "")
if not name or not uid:
    raise SystemExit(1)
print(name, uid, previous, sep="\t")
PY
  )"; then
    die "existing experiment namespace identity is invalid"
  fi
  IFS=$'\t' read -r namespace_name namespace_uid PREVIOUS_NAMESPACE_RUN_ID <<<"$namespace_values"
  [[ "$namespace_name" == "$EXPERIMENT_NAMESPACE" ]] || die "existing namespace name changed"
  EXPECTED_NAMESPACE_UID="$namespace_uid"
  if ! printf '%s' "$namespace_json" | \
      python3 /dev/fd/3 "$RUN_ID" 3<<'PY' | \
      kube --request-timeout=30s replace -f - >/dev/null
import json, sys
payload = json.load(sys.stdin)
metadata = payload.setdefault("metadata", {})
metadata.setdefault("annotations", {})["hooke.io/run-id"] = sys.argv[1]
print(json.dumps(payload, separators=(",", ":")))
PY
  then
    die "failed to claim existing experiment namespace with resourceVersion CAS"
  fi
else
  if ! created_namespace="$(python3 - "$EXPERIMENT_NAMESPACE" "$RUN_ID" <<'PY' | \
      kube --request-timeout=30s create -f - -o json
import json, sys
print(json.dumps({
    "apiVersion": "v1",
    "kind": "Namespace",
    "metadata": {
        "name": sys.argv[1],
        "annotations": {"hooke.io/run-id": sys.argv[2]},
        "labels": {"hooke.io/experiment": "true"},
    },
}, separators=(",", ":")))
PY
  )"; then
    die "failed to atomically create experiment namespace: ${EXPERIMENT_NAMESPACE}"
  fi
  if ! EXPECTED_NAMESPACE_UID="$(printf '%s' "$created_namespace" | \
      python3 /dev/fd/3 "$EXPERIMENT_NAMESPACE" "$RUN_ID" 3<<'PY'
import json, sys
payload = json.load(sys.stdin)
metadata = payload.get("metadata", {})
if (
    metadata.get("name") != sys.argv[1]
    or (metadata.get("annotations") or {}).get("hooke.io/run-id") != sys.argv[2]
    or not metadata.get("uid")
):
    raise SystemExit(1)
print(metadata["uid"])
PY
  )"; then
    die "created namespace response has no exact ownership identity"
  fi
  NAMESPACE_CREATED_BY_RUN=true
  K8S_MUTATED=true
fi
namespace_identity="$(kube --request-timeout=30s get namespace "$EXPERIMENT_NAMESPACE" \
  -o jsonpath='{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.metadata.annotations.hooke\.io/run-id}')" || \
  die "failed to capture experiment namespace ownership"
IFS=$'\t' read -r namespace_name namespace_uid namespace_run_id <<<"$namespace_identity"
[[ "$namespace_name" == "$EXPERIMENT_NAMESPACE" && "$namespace_uid" == "$EXPECTED_NAMESPACE_UID" && \
   "$namespace_run_id" == "$RUN_ID" ]] || \
  die "experiment namespace ownership does not match the current run"
EXPERIMENT_NAMESPACE_UID="$namespace_uid"
EXPERIMENT_NAMESPACE_RUN_ID="$namespace_run_id"
if is_true "$REQUIRE_EMPTY_EXPERIMENT_NAMESPACE"; then
  verify_namespace_ownership || die "experiment namespace ownership changed before emptiness check"
  existing_pods="$(kube -n "$EXPERIMENT_NAMESPACE" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$existing_pods" == "0" ]] || die "experiment namespace contains ${existing_pods} existing pod(s); use an empty namespace or disable REQUIRE_EMPTY_EXPERIMENT_NAMESPACE"
fi
python3 - "$namespace_name" "$namespace_uid" "$namespace_run_id" "$NAMESPACE_CREATED_BY_RUN" \
  >"$ARTIFACT_DIR/experiment-namespace.json" <<'PY'
import json, sys
print(json.dumps({
    "name": sys.argv[1],
    "uid": sys.argv[2],
    "run_id": sys.argv[3],
    "created_by_run": sys.argv[4].lower() == "true",
}, indent=2, sort_keys=True))
PY
printf '%s\n' "$EXPERIMENT_NAMESPACE" >"$ARTIFACT_DIR/experiment-namespace.txt"
chmod 600 "$ARTIFACT_DIR/experiment-namespace.json" "$ARTIFACT_DIR/experiment-namespace.txt"
if [[ -n "$HOOKE_AUTH_TOKEN" ]]; then
  verify_namespace_ownership || die "experiment namespace ownership changed before Secret creation"
  kube -n "$EXPERIMENT_NAMESPACE" create secret generic "$APP_AUTH_SECRET_NAME" \
    --from-literal="token=${HOOKE_AUTH_TOKEN}" --dry-run=client -o json | \
    python3 /dev/fd/3 "$RUN_ID" 3<<'PY' | kube create -f - >/dev/null
import json, sys
payload = json.load(sys.stdin)
payload.setdefault("metadata", {}).setdefault("annotations", {})["hooke.io/run-id"] = sys.argv[1]
print(json.dumps(payload, separators=(",", ":")))
PY
fi

log "starting local Kubernetes controller"
CONTROLLER_ACTIVE_RUN_ID=""
if is_true "$ENABLE_NODE_SCALE_SMOKE"; then
  CONTROLLER_ACTIVE_RUN_ID="$RUN_ID"
fi
KUBECONFIG="$KUBECONFIG_PATH" \
HOOKE_CLUSTER_ID="$CLUSTER_ID" \
HOOKE_INGESTER_URL="http://127.0.0.1:${INGESTER_PORT}" \
HOOKE_AUTH_TOKEN="$HOOKE_AUTH_TOKEN" \
HOOKE_NAMESPACE="$HOOKE_SYSTEM_NAMESPACE" \
HOOKE_CAPTURE_UNLABELED="false" \
HOOKE_ACTIVE_RUN_ID="$CONTROLLER_ACTIVE_RUN_ID" \
HOOKE_WATCH_ACTIVE_RUN_CONFIGMAP="false" \
HOOKE_METRICS_ADDR="127.0.0.1:${CONTROLLER_METRICS_PORT}" \
  "$PROJECT_ROOT/bin/hooke-controller" >"$ARTIFACT_DIR/controller.log" 2>&1 &
CONTROLLER_PID=$!
wait_http "http://127.0.0.1:${CONTROLLER_METRICS_PORT}/readyz" 90 "hooke-controller"
sleep "$CONTROLLER_WARMUP_SECONDS"
kill -0 "$CONTROLLER_PID" >/dev/null 2>&1 || die "controller exited; see $ARTIFACT_DIR/controller.log"

date -u +'%Y-%m-%dT%H:%M:%S.%NZ' >"$ARTIFACT_DIR/experiment-start-utc.txt"
run_fixed_smoke
run_node_scale_smoke
# Keep a common in-run Node snapshot for both fixed-node and node-scale paths.
# E02 validates this evidence instead of racing a min=0 scale-in after the
# child process exits.
kube get nodes -o json >"$ARTIFACT_DIR/nodes-after.json"
kube -n "$EXPERIMENT_NAMESPACE" get events -o json >"$ARTIFACT_DIR/kubernetes-events.json"
date -u +'%Y-%m-%dT%H:%M:%S.%NZ' >"$ARTIFACT_DIR/experiment-end-utc.txt"

if [[ -n "$RUNTIME_EVENTS_EXPORT_HOOK" ]]; then
  RUNTIME_EVENTS_NDJSON="$ARTIFACT_DIR/runtime-events.ndjson"
  log "exporting exact containerd/kubelet/CRI events with configured hook"
  "$RUNTIME_EVENTS_EXPORT_HOOK" \
    --cluster-id "$CLUSTER_ID" --run-id "$RUN_ID" \
    --start-file "$ARTIFACT_DIR/experiment-start-utc.txt" \
    --end-file "$ARTIFACT_DIR/experiment-end-utc.txt" \
    --artifact-dir "$ARTIFACT_DIR" \
    --output "$RUNTIME_EVENTS_NDJSON" \
    >"$ARTIFACT_DIR/runtime-events-export.log" 2>&1
  [[ -s "$RUNTIME_EVENTS_NDJSON" ]] || die "RUNTIME_EVENTS_EXPORT_HOOK produced no events"
fi
if [[ -n "$RUNTIME_EVENTS_NDJSON" ]]; then
  [[ -f "$RUNTIME_EVENTS_NDJSON" ]] || die "RUNTIME_EVENTS_NDJSON not found: $RUNTIME_EVENTS_NDJSON"
  log "importing normalized runtime events: $RUNTIME_EVENTS_NDJSON"
  "$PROJECT_ROOT/bin/hookectl" events import \
    --api "http://127.0.0.1:${INGESTER_PORT}" "${TOKEN_ARGS[@]}" \
    --cluster "$CLUSTER_ID" --run-id "$RUN_ID" --file "$RUNTIME_EVENTS_NDJSON" \
    >"$ARTIFACT_DIR/runtime-events-import.log" 2>&1
  sleep "$EVENT_SETTLE_SECONDS"
fi

# A journal exporter must inspect a newly provisioned node before GOATScaler is
# allowed to remove it. Release the workload only after the runtime import.
stop_node_scale_workloads

sleep "$EVENT_SETTLE_SECONDS"

log "stopping controller and flushing event batch"
terminate_pid "$CONTROLLER_PID"
CONTROLLER_PID=""

log "stopping experiment run"
"$PROJECT_ROOT/bin/hookectl" run stop \
  --api "http://127.0.0.1:${INGESTER_PORT}" \
  "${TOKEN_ARGS[@]}" --run-id "$RUN_ID"
RUN_STOPPED=true

write_reports_and_gate
SUCCESS=true
log "first smoke completed successfully"
