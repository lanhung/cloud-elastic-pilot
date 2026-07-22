#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/configs/four-layer-baseline.env"
CHECK_ONLY=false

usage() {
  cat <<USAGE
Usage: $0 [--config PATH] [--check-only]

Runs the randomized E01 four-layer baseline pilot (four cells, five runs each
by default). --check-only performs read-only configuration/cluster checks.
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
: "${REQUIRE_CLEAN_GIT:=true}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${ARTIFACT_ROOT:=artifacts}"
: "${E01_PILOT_REPETITIONS:=5}"
: "${E01_RANDOM_SEED:=20260721}"
: "${E01_REPLICAS:=1}"
: "${E01_IMAGE_METADATA_FILE:=dist/e01-images.env}"
: "${E01_SMALL_IMAGE:=}"
: "${E01_LARGE_IMAGE:=}"
: "${E01_LIGHT_STARTUP_WORK_MIB:=0}"
: "${E01_HEAVY_STARTUP_WORK_MIB:=4096}"
: "${E01_APP_EVENT_MODE:=log}"
: "${E01_INGESTER_REACHABLE_URL:=}"
: "${INGESTER_BIND_ADDRESS:=127.0.0.1}"
: "${HOOKE_AUTH_TOKEN:=}"
: "${FIXED_NODE_SELECTOR_KEY:=}"
: "${FIXED_NODE_SELECTOR_VALUE:=}"
: "${ELASTIC_NODE_SELECTOR_KEY:=}"
: "${ELASTIC_NODE_SELECTOR_VALUE:=}"
: "${CACHE_RESET_HOOK:=}"
: "${CACHE_VERIFY_HOOK:=}"
: "${ACK_EVENTS_EXPORT_HOOK:=}"
: "${RUNTIME_EVENTS_EXPORT_HOOK:=}"
: "${E01_HOST_HELPER_IMAGE:=}"
: "${E01_REQUIRE_CNI_SUBSTAGE:=false}"
: "${CONFIRM_NEW_NODE_COLD_SOURCE:=no}"
: "${E01_PREWARM_TIMEOUT:=15m}"
: "${E01_ELASTIC_ZERO_TIMEOUT:=30m}"
: "${E01_SMOKE_COMMAND_JSON:=[\"/smoke-app\"]}"
: "${E01_CPU_REQUEST:=500m}"
: "${E01_CPU_LIMIT:=1000m}"
: "${E01_MEMORY_REQUEST:=256Mi}"
: "${E01_MEMORY_LIMIT:=512Mi}"

[[ "$CONFIRM_KUBE_CONTEXT" == "yes" ]] || die "set CONFIRM_KUBE_CONTEXT=yes after verifying the target cluster"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
[[ "$E01_PILOT_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die "E01_PILOT_REPETITIONS must be positive"
[[ "$E01_RANDOM_SEED" =~ ^[0-9]+$ ]] || die "E01_RANDOM_SEED must be a non-negative integer"
[[ "$E01_REPLICAS" == "1" ]] || die "the pilot is intentionally fixed at E01_REPLICAS=1; test 4/8 only after pilot quality passes"
[[ "$E01_LIGHT_STARTUP_WORK_MIB" =~ ^[0-9]+$ ]] || die "E01_LIGHT_STARTUP_WORK_MIB must be non-negative"
[[ "$E01_HEAVY_STARTUP_WORK_MIB" =~ ^[1-9][0-9]*$ ]] || die "E01_HEAVY_STARTUP_WORK_MIB must be positive"
[[ "$E01_ELASTIC_ZERO_TIMEOUT" =~ ^[1-9][0-9]*m$ ]] || die "E01_ELASTIC_ZERO_TIMEOUT must use positive whole minutes (for example 30m)"
[[ "$E01_SMALL_IMAGE" =~ @sha256:[0-9a-fA-F]{64}$ ]] || die "E01_SMALL_IMAGE must use an immutable sha256 digest"
[[ "$E01_LARGE_IMAGE" =~ @sha256:[0-9a-fA-F]{64}$ ]] || die "E01_LARGE_IMAGE must use an immutable sha256 digest"
[[ "$E01_SMALL_IMAGE" != "$E01_LARGE_IMAGE" ]] || die "small and large image digests must differ"
[[ "${E01_SMALL_IMAGE##*@}" != "${E01_LARGE_IMAGE##*@}" ]] || die "small and large images resolve to the same content digest"
[[ -n "$FIXED_NODE_SELECTOR_KEY" && -n "$FIXED_NODE_SELECTOR_VALUE" ]] || die "fixed-node selector is required"
[[ -n "$ELASTIC_NODE_SELECTOR_KEY" && -n "$ELASTIC_NODE_SELECTOR_VALUE" ]] || die "elastic-node selector is required"
case "$E01_APP_EVENT_MODE" in
  log)
    APP_SDK_DISABLED=true
    ;;
  sdk)
    APP_SDK_DISABLED=false
    [[ -n "$E01_INGESTER_REACHABLE_URL" ]] || die "E01_INGESTER_REACHABLE_URL is required in sdk application-event mode"
    [[ "$E01_INGESTER_REACHABLE_URL" != *"127.0.0.1"* && "$E01_INGESTER_REACHABLE_URL" != *"localhost"* ]] || die "E01_INGESTER_REACHABLE_URL must be reachable from Pods"
    [[ "$INGESTER_BIND_ADDRESS" != "127.0.0.1" && "$INGESTER_BIND_ADDRESS" != "localhost" ]] || die "INGESTER_BIND_ADDRESS must accept Pod traffic"
    [[ -n "$HOOKE_AUTH_TOKEN" ]] || die "HOOKE_AUTH_TOKEN is required when exposing the pilot ingester"
    ;;
  *) die "E01_APP_EVENT_MODE must be log or sdk" ;;
esac
[[ -x "$CACHE_RESET_HOOK" ]] || die "CACHE_RESET_HOOK must be executable for repeated existing+cold runs"
[[ -x "$CACHE_VERIFY_HOOK" ]] || die "CACHE_VERIFY_HOOK must be executable"
[[ -x "$ACK_EVENTS_EXPORT_HOOK" ]] || die "ACK_EVENTS_EXPORT_HOOK must be executable"
[[ -x "$RUNTIME_EVENTS_EXPORT_HOOK" ]] || die "RUNTIME_EVENTS_EXPORT_HOOK must be executable"
[[ -n "$E01_HOST_HELPER_IMAGE" ]] || die "E01_HOST_HELPER_IMAGE is required by cache/runtime hooks"
[[ "$CONFIRM_NEW_NODE_COLD_SOURCE" == "yes" ]] || die "set CONFIRM_NEW_NODE_COLD_SOURCE=yes only when the elastic pool creates fresh empty-cache instances"

require_cmd kubectl
require_cmd python3
require_cmd git
is_true "$REQUIRE_CLEAN_GIT" || die "E01 requires REQUIRE_CLEAN_GIT=true for reproducible execution"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  die "E01 requires a clean Git worktree so every run maps to the recorded commit"
fi

if [[ "$E01_IMAGE_METADATA_FILE" = /* ]]; then
  IMAGE_METADATA_PATH="$E01_IMAGE_METADATA_FILE"
else
  IMAGE_METADATA_PATH="${PROJECT_ROOT}/${E01_IMAGE_METADATA_FILE}"
fi
[[ -f "$IMAGE_METADATA_PATH" ]] || die "E01 image metadata not found: $IMAGE_METADATA_PATH (run make e01-images-push first)"

metadata_value() {
  local key="$1" count value
  count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$IMAGE_METADATA_PATH")"
  [[ "$count" == "1" ]] || die "image metadata must contain exactly one ${key} entry"
  value="$(awk -v prefix="${key}=" 'index($0, prefix) == 1 { sub(prefix, ""); print; exit }' "$IMAGE_METADATA_PATH")"
  printf '%s' "$value"
}

METADATA_BUILD_COMMIT="$(metadata_value E01_IMAGE_BUILD_COMMIT)"
METADATA_SOURCE_STATE="$(metadata_value E01_IMAGE_SOURCE_STATE)"
METADATA_SMALL_IMAGE="$(metadata_value E01_SMALL_IMAGE)"
METADATA_LARGE_IMAGE="$(metadata_value E01_LARGE_IMAGE)"
CURRENT_GIT_COMMIT="$(git rev-parse HEAD)"
[[ "$METADATA_BUILD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "image metadata build commit is invalid"
[[ "$METADATA_BUILD_COMMIT" == "$CURRENT_GIT_COMMIT" ]] || die "images were built from ${METADATA_BUILD_COMMIT}, but HEAD is ${CURRENT_GIT_COMMIT}"
[[ "$METADATA_SOURCE_STATE" == "clean" ]] || die "E01 images must be built from a clean worktree"
[[ "$METADATA_SMALL_IMAGE" == "$E01_SMALL_IMAGE" ]] || die "E01_SMALL_IMAGE does not match image build metadata"
[[ "$METADATA_LARGE_IMAGE" == "$E01_LARGE_IMAGE" ]] || die "E01_LARGE_IMAGE does not match image build metadata"

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
if [[ -n "$EXPECTED_API_SERVER_SUBSTRING" && "$EFFECTIVE_API_SERVER" != *"$EXPECTED_API_SERVER_SUBSTRING"* ]]; then
  die "API server does not contain EXPECTED_API_SERVER_SUBSTRING"
fi

fixed_ready="$(kube get nodes -l "${FIXED_NODE_SELECTOR_KEY}=${FIXED_NODE_SELECTOR_VALUE}" --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ {count++} END {print count+0}')"
(( fixed_ready > 0 )) || die "no Ready fixed node matches ${FIXED_NODE_SELECTOR_KEY}=${FIXED_NODE_SELECTOR_VALUE}"

SESSION_STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
SESSION_NAME="e01-four-layer-pilot-${SESSION_STAMP}"
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

TEMP_CONFIG=""
PREWARM_NAMESPACE=""
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [[ -z "$TEMP_CONFIG" ]] || { rm -f "$TEMP_CONFIG"; TEMP_CONFIG=""; }
  if [[ -n "$PREWARM_NAMESPACE" ]]; then
    kube delete namespace "$PREWARM_NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  if [[ "$CHECK_ONLY" == true ]]; then
    rm -rf "$SESSION_DIR"
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

SCHEDULE_FILE="$SESSION_DIR/schedule.tsv"
python3 - "$E01_PILOT_REPETITIONS" "$E01_RANDOM_SEED" >"$SCHEDULE_FILE" <<'PY'
import random, sys
repetitions = int(sys.argv[1])
rng = random.Random(int(sys.argv[2]))
cells = ["existing-warm-small-light", "existing-cold-large-light", "new-cold-small-light", "new-cold-large-heavy"]
schedule = [(cell, repetition) for repetition in range(1, repetitions + 1) for cell in cells]
rng.shuffle(schedule)
print("sequence\tcell\trepetition")
for sequence, (cell, repetition) in enumerate(schedule, 1):
    print(f"{sequence}\t{cell}\t{repetition}")
PY

log "preflight passed: context=${EFFECTIVE_CONTEXT}, fixed_ready=${fixed_ready}, runs=$((E01_PILOT_REPETITIONS * 4))"
log "randomization seed: ${E01_RANDOM_SEED}"
if [[ "$CHECK_ONLY" == true ]]; then
  cat "$SCHEDULE_FILE"
  log "check-only complete; no workload or cache was changed"
  exit 0
fi

GIT_COMMIT="$(git rev-parse HEAD)"
cp -- "$IMAGE_METADATA_PATH" "$SESSION_DIR/image-build.env"
chmod 600 "$SESSION_DIR/image-build.env"
kube version -o json >"$SESSION_DIR/kubernetes-version.json"
kube get nodes -o json >"$SESSION_DIR/nodes-at-session-start.json"
python3 - "$SESSION_NAME" "$EFFECTIVE_CONTEXT" "$EFFECTIVE_API_SERVER" "$GIT_COMMIT" "$E01_RANDOM_SEED" "$E01_PILOT_REPETITIONS" "$E01_SMALL_IMAGE" "$E01_LARGE_IMAGE" "$E01_APP_EVENT_MODE" >"$SESSION_DIR/session.json" <<'PY'
import json, sys
keys = ["session", "kube_context", "api_server", "git_commit", "random_seed", "repetitions_per_cell", "small_image", "large_image", "application_event_mode"]
value = dict(zip(keys, sys.argv[1:]))
value["random_seed"] = int(value["random_seed"])
value["repetitions_per_cell"] = int(value["repetitions_per_cell"])
print(json.dumps(value, indent=2, sort_keys=True))
PY

wait_elastic_zero() {
  local deadline=$((SECONDS + ${E01_ELASTIC_ZERO_TIMEOUT%m} * 60))
  while true; do
    local count
    count="$(kube get nodes -l "${ELASTIC_NODE_SELECTOR_KEY}=${ELASTIC_NODE_SELECTOR_VALUE}" --no-headers 2>/dev/null | awk 'NF {count++} END {print count+0}')"
    [[ "$count" == "0" ]] && return 0
    (( SECONDS < deadline )) || die "elastic pool did not return to zero before ${E01_ELASTIC_ZERO_TIMEOUT}"
    sleep 15
  done
}

prewarm_image() {
  local image="$1" sequence="$2"
  PREWARM_NAMESPACE="e01-prewarm-${SESSION_STAMP,,}-${sequence}"
  PREWARM_NAMESPACE="${PREWARM_NAMESPACE:0:63}"
  kube create namespace "$PREWARM_NAMESPACE" >/dev/null
  kube apply -f - >"$SESSION_DIR/prewarm-${sequence}.apply.log" <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: image-prewarm
  namespace: ${PREWARM_NAMESPACE}
spec:
  selector:
    matchLabels: {app: e01-image-prewarm}
  template:
    metadata:
      labels: {app: e01-image-prewarm}
    spec:
      nodeSelector:
        "${FIXED_NODE_SELECTOR_KEY}": "${FIXED_NODE_SELECTOR_VALUE}"
      terminationGracePeriodSeconds: 1
      containers:
        - name: prewarm
          image: "${image}"
          imagePullPolicy: IfNotPresent
          command: ${E01_SMOKE_COMMAND_JSON}
          env:
            - {name: HOOKE_SDK_DISABLED, value: "true"}
            - {name: HOOKE_STARTUP_WORK_MIB, value: "0"}
YAML
  kube -n "$PREWARM_NAMESPACE" rollout status daemonset/image-prewarm --timeout="$E01_PREWARM_TIMEOUT" >"$SESSION_DIR/prewarm-${sequence}.rollout.log"
  kube -n "$PREWARM_NAMESPACE" get pods -o custom-columns='NODE:.spec.nodeName,IMAGE:.status.containerStatuses[0].image,IMAGE_ID:.status.containerStatuses[0].imageID' >"$SESSION_DIR/prewarm-${sequence}.images.tsv"
  kube delete namespace "$PREWARM_NAMESPACE" --wait=true --timeout=5m >/dev/null
  PREWARM_NAMESPACE=""
  "$CACHE_VERIFY_HOOK" --state warm --image "$image" --selector-key "$FIXED_NODE_SELECTOR_KEY" --selector-value "$FIXED_NODE_SELECTOR_VALUE" --evidence "$SESSION_DIR/cache-warm-${sequence}.json"
}

append_config() {
  local key="$1" value="$2"
  printf '%s=%q\n' "$key" "$value" >>"$TEMP_CONFIG"
}

make_labels() {
  local sequence="$1" cell="$2" repetition="$3" node_state="$4" image_state="$5" image_size="$6" app_init="$7" image="$8" work_mib="$9"
  python3 - "$sequence" "$cell" "$repetition" "$node_state" "$image_state" "$image_size" "$app_init" "$image" "$work_mib" "$E01_RANDOM_SEED" "$GIT_COMMIT" <<'PY'
import json, sys
print(json.dumps({
    "experiment": "E01-four-layer-baseline", "phase": "pilot",
    "sequence": int(sys.argv[1]), "cell": sys.argv[2], "repetition": int(sys.argv[3]),
    "node_state": sys.argv[4], "image_state": sys.argv[5], "image_size": sys.argv[6],
    "application_init": sys.argv[7], "image_ref": sys.argv[8],
    "startup_work_mib": int(sys.argv[9]), "random_seed": int(sys.argv[10]),
    "git_commit": sys.argv[11], "replicas": 1,
}, separators=(",", ":"), sort_keys=True))
PY
}

FIRST_RUN=true
while IFS=$'\t' read -r sequence cell repetition; do
  node_state="" image_state="" image_size="" app_init="" image="" work_mib=""
  case "$cell" in
    existing-warm-small-light)
      node_state=existing; image_state=warm; image_size=small; app_init=light; image="$E01_SMALL_IMAGE"; work_mib="$E01_LIGHT_STARTUP_WORK_MIB"
      prewarm_image "$image" "$sequence"
      ;;
    existing-cold-large-light)
      node_state=existing; image_state=cold; image_size=large; app_init=light; image="$E01_LARGE_IMAGE"; work_mib="$E01_LIGHT_STARTUP_WORK_MIB"
      "$CACHE_RESET_HOOK" --image "$image" --selector-key "$FIXED_NODE_SELECTOR_KEY" --selector-value "$FIXED_NODE_SELECTOR_VALUE" --reason e01-existing-cold --evidence "$SESSION_DIR/cache-reset-${sequence}.json"
      "$CACHE_VERIFY_HOOK" --state cold --image "$image" --selector-key "$FIXED_NODE_SELECTOR_KEY" --selector-value "$FIXED_NODE_SELECTOR_VALUE" --evidence "$SESSION_DIR/cache-cold-${sequence}.json"
      ;;
    new-cold-small-light)
      node_state=new; image_state=cold; image_size=small; app_init=light; image="$E01_SMALL_IMAGE"; work_mib="$E01_LIGHT_STARTUP_WORK_MIB"
      wait_elastic_zero
      ;;
    new-cold-large-heavy)
      node_state=new; image_state=cold; image_size=large; app_init=heavy; image="$E01_LARGE_IMAGE"; work_mib="$E01_HEAVY_STARTUP_WORK_MIB"
      wait_elastic_zero
      ;;
    *) die "unknown cell in schedule: $cell" ;;
  esac

  labels="$(make_labels "$sequence" "$cell" "$repetition" "$node_state" "$image_state" "$image_size" "$app_init" "$image" "$work_mib")"
  TEMP_CONFIG="$(mktemp)"
  chmod 600 "$TEMP_CONFIG"
  cp "$CONFIG_FILE" "$TEMP_CONFIG"
  append_config RUN_NAME_PREFIX "e01-${cell}-r${repetition}"
  append_config RUN_LABELS_JSON "$labels"
  append_config ARTIFACT_ROOT "$SESSION_DIR/runs"
  append_config EXPERIMENT_NAMESPACE "e01-${cell}"
  append_config INGESTER_BIND_ADDRESS "$INGESTER_BIND_ADDRESS"
  append_config SMOKE_HOOKE_INGESTER_URL "$E01_INGESTER_REACHABLE_URL"
  append_config SMOKE_IMAGE "$image"
  append_config SMOKE_IMAGE_PULL_POLICY "IfNotPresent"
  append_config SMOKE_COMMAND_JSON "$E01_SMOKE_COMMAND_JSON"
  append_config SMOKE_CONTAINER_PORT "8080"
  append_config SMOKE_SERVICE_PORT "80"
  append_config SMOKE_READINESS_PATH "/readyz"
  append_config SMOKE_REQUEST_PATH "/work"
  append_config SMOKE_DISABLE_SDK "$APP_SDK_DISABLED"
  append_config SMOKE_STARTUP_WORK_MIB "$work_mib"
  append_config REQUIRE_IMMUTABLE_IMAGE "true"
  append_config SMOKE_REPETITIONS "1"
  append_config NODE_SCALE_REPLICAS "1"
  append_config SMOKE_CPU_REQUEST "$E01_CPU_REQUEST"
  append_config SMOKE_CPU_LIMIT "$E01_CPU_LIMIT"
  append_config SMOKE_MEMORY_REQUEST "$E01_MEMORY_REQUEST"
  append_config SMOKE_MEMORY_LIMIT "$E01_MEMORY_LIMIT"
  append_config NODE_SCALE_CPU_REQUEST "$E01_CPU_REQUEST"
  append_config NODE_SCALE_CPU_LIMIT "$E01_CPU_LIMIT"
  append_config NODE_SCALE_MEMORY_REQUEST "$E01_MEMORY_REQUEST"
  append_config NODE_SCALE_MEMORY_LIMIT "$E01_MEMORY_LIMIT"
  append_config ACK_EVENTS_EXPORT_HOOK "$ACK_EVENTS_EXPORT_HOOK"
  append_config RUNTIME_EVENTS_EXPORT_HOOK "$RUNTIME_EVENTS_EXPORT_HOOK"
  append_config REQUIRE_EXACT_IMAGE_EVENTS "true"
  append_config REQUIRE_EXACT_POD_EVENTS "true"
  append_config REQUIRE_EXACT_APP_EVENTS "true"
  append_config REQUIRE_POD_SUBSTAGES "true"
  append_config REQUIRE_CNI_SUBSTAGE "$E01_REQUIRE_CNI_SUBSTAGE"
  append_config REQUIRE_DERIVATION_TRACEABILITY "true"
  append_config RESET_MYSQL "false"
  append_config STOP_MYSQL_ON_EXIT "false"
  if [[ "$FIRST_RUN" == false ]]; then
    append_config SKIP_BUILD "true"
  fi
  if [[ "$node_state" == "existing" ]]; then
    append_config ENABLE_FIXED_SMOKE "true"
    append_config ENABLE_NODE_SCALE_SMOKE "false"
    append_config REQUIRE_EXACT_NODE_EVENTS "false"
  else
    append_config ENABLE_FIXED_SMOKE "false"
    append_config ENABLE_NODE_SCALE_SMOKE "true"
    append_config REQUIRE_EMPTY_ELASTIC_POOL "true"
    append_config REQUIRE_NEW_NODE "true"
    append_config REQUIRE_NODE_UNSCHEDULABLE "true"
    append_config REQUIRE_TASK_ID_ATTRIBUTION "true"
    append_config REQUIRE_EXACT_NODE_EVENTS "true"
  fi

  log "E01 sequence ${sequence}: cell=${cell}, repetition=${repetition}"
  "$SCRIPT_DIR/ack-first-smoke.sh" --config "$TEMP_CONFIG" 2>&1 | tee "$SESSION_DIR/run-${sequence}-${cell}-r${repetition}.log"
  rm -f "$TEMP_CONFIG"
  TEMP_CONFIG=""
  FIRST_RUN=false
done < <(tail -n +2 "$SCHEDULE_FILE")

log "E01 pilot complete: ${SESSION_DIR}"
