#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${SCRIPT_DIR}/e08-collector-overhead.py"
CHART="${PROJECT_ROOT}/deploy/helm/hooke"
CONFIG_FILE="${PROJECT_ROOT}/configs/collector-overhead.env"
CHECK_ONLY=false

usage() {
  cat <<'USAGE'
Usage: ack-collector-overhead.sh [--config PATH] [--check-only]

Runs the E08 two-Worker, low-rate ACK smoke in the frozen order:
  collector-off -> collector-on-10-percent -> collector-on-100-percent

The runner installs an isolated Hooke Helm release and requires an existing
ACK-reachable MySQL DSN. It measures Kubernetes Metrics API resource use,
controller queue/delivery counters, persistence latency, trace completeness,
and Pod startup. It intentionally does not run formal KS/CI statistics.

--check-only performs local and read-only cluster checks.
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
: "${CONFIRM_E08_EXECUTION:=no}"
: "${REQUIRE_CLEAN_GIT:=true}"
: "${EXPECTED_API_SERVER_SUBSTRING:=}"
: "${KUBECONFIG_PATH:=$HOME/.kube/config}"
: "${KUBE_CONTEXT:=}"
: "${CLUSTER_ID:=}"
: "${E08_EXPECTED_BRANCH:=experiment/10-collector-overhead-pilot}"
: "${E08_TARGET_NODES:=}"
: "${E08_IMAGE_METADATA_FILE:=dist/e08-image.env}"
: "${E08_IMAGE:=}"
: "${HOOKE_MYSQL_DSN:=}"
: "${E08_SYSTEM_NAMESPACE:=hooke-e08-system}"
: "${E08_HELM_RELEASE:=hooke-e08}"
: "${E08_MYSQL_SECRET:=hooke-e08-mysql}"
: "${E08_LOCK_NAMESPACE:=kube-system}"
: "${E08_LOCK_NAME:=hooke-e08-collector-overhead}"
: "${E08_POD_COUNT:=50}"
: "${E08_PARALLELISM:=2}"
: "${E08_WORK_DURATION:=5s}"
: "${E08_WORKLOAD_CPU:=25m}"
: "${E08_WORKLOAD_MEMORY:=32Mi}"
: "${E08_NODE_AGENT_CPU:=20m}"
: "${E08_NODE_AGENT_MEMORY:=32Mi}"
: "${E08_JOB_TIMEOUT_SECONDS:=900}"
: "${E08_RESOURCE_SAMPLE_INTERVAL_SECONDS:=1}"
: "${E08_COLLECTOR_SETTLE_SECONDS:=5}"
: "${ARTIFACT_ROOT:=artifacts}"
: "${CLEANUP_K8S_ON_SUCCESS:=true}"
: "${CLEANUP_K8S_ON_ERROR:=true}"
# Keep the database credential in this shell only. Child processes receive it
# solely through the Kubernetes Secret created from stdin below.
export -n HOOKE_MYSQL_DSN 2>/dev/null || true

for command in kubectl helm jq python3 git date mktemp; do
  require_cmd "$command"
done
[[ -x "$HELPER" ]] || die "helper must be executable: $HELPER"
[[ -d "$CHART" ]] || die "Hooke Helm chart not found: $CHART"
[[ "$CONFIRM_KUBE_CONTEXT" == yes ]] || \
  die "set CONFIRM_KUBE_CONTEXT=yes after verifying the ACK target"
[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: $KUBECONFIG_PATH"
[[ -n "$KUBE_CONTEXT" && -n "$EXPECTED_API_SERVER_SUBSTRING" ]] || \
  die "KUBE_CONTEXT and EXPECTED_API_SERVER_SUBSTRING are required"
[[ -n "$CLUSTER_ID" ]] || die "CLUSTER_ID is required"
[[ "$E08_IMAGE" =~ ^[^[:space:]@]+@sha256:[0-9a-fA-F]{64}$ ]] || \
  die "E08_IMAGE must be an immutable repository digest"
[[ "$HOOKE_MYSQL_DSN" == *"@tcp("*":3306)/"* ]] || \
  die "HOOKE_MYSQL_DSN must be an ACK-reachable Go MySQL TCP DSN on port 3306"
[[ "$E08_POD_COUNT" =~ ^[1-9][0-9]*$ && "$E08_POD_COUNT" -ge 3 ]] || \
  die "E08_POD_COUNT must be an integer >= 3"
[[ "$E08_PARALLELISM" == 2 ]] || die "E08_PARALLELISM is frozen at 2"
[[ "$E08_WORK_DURATION" =~ ^[1-9][0-9]*(ms|s|m)$ ]] || \
  die "E08_WORK_DURATION must be a positive ms/s/m duration"
[[ "$E08_JOB_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
  die "E08_JOB_TIMEOUT_SECONDS must be positive"
[[ "$E08_RESOURCE_SAMPLE_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
  die "E08_RESOURCE_SAMPLE_INTERVAL_SECONDS must be a positive integer"
[[ "$E08_COLLECTOR_SETTLE_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
  die "E08_COLLECTOR_SETTLE_SECONDS must be positive"

kube() {
  kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" "$@"
}

helm_ack() {
  helm --kubeconfig "$KUBECONFIG_PATH" --kube-context "$KUBE_CONTEXT" "$@"
}

IFS=',' read -r -a RAW_TARGET_NODES <<<"$E08_TARGET_NODES"
TARGET_NODES=()
for raw_node in "${RAW_TARGET_NODES[@]}"; do
  node="${raw_node#"${raw_node%%[![:space:]]*}"}"
  node="${node%"${node##*[![:space:]]}"}"
  [[ -n "$node" ]] && TARGET_NODES+=("$node")
done
[[ "${#TARGET_NODES[@]}" -eq 2 && "${TARGET_NODES[0]}" != "${TARGET_NODES[1]}" ]] || \
  die "E08_TARGET_NODES must contain exactly two distinct node names"

CURRENT_CONTEXT="$(kube config current-context)"
[[ "$CURRENT_CONTEXT" == "$KUBE_CONTEXT" ]] || \
  die "current context ${CURRENT_CONTEXT} does not match ${KUBE_CONTEXT}"
API_SERVER="$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$API_SERVER" == *"$EXPECTED_API_SERVER_SUBSTRING"* ]] || \
  die "API server ${API_SERVER} does not contain the expected ACK identity"
kube version --request-timeout=15s >/dev/null

CURRENT_BRANCH="$(git branch --show-current)"
[[ "$CURRENT_BRANCH" == "$E08_EXPECTED_BRANCH" ]] || \
  die "current branch ${CURRENT_BRANCH} does not match ${E08_EXPECTED_BRANCH}"
if [[ "$REQUIRE_CLEAN_GIT" == true && -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  die "Git worktree must be clean so image and runner evidence share one commit"
fi
GIT_COMMIT="$(git rev-parse HEAD)"
[[ -f "$E08_IMAGE_METADATA_FILE" ]] || \
  die "E08 image metadata not found: $E08_IMAGE_METADATA_FILE"
CONFIGURED_E08_IMAGE="$E08_IMAGE"
# shellcheck disable=SC1090
source "$E08_IMAGE_METADATA_FILE"
[[ "${E08_IMAGE_SOURCE_STATE:-}" == clean ]] || \
  die "E08 image metadata was not produced from a clean worktree"
[[ "${E08_IMAGE_BUILD_COMMIT:-}" == "$GIT_COMMIT" ]] || \
  die "E08 image commit ${E08_IMAGE_BUILD_COMMIT:-missing} does not match ${GIT_COMMIT}"
[[ "${E08_IMAGE:-}" == "$CONFIGURED_E08_IMAGE" ]] || \
  die "configured E08_IMAGE does not match image metadata"
[[ "${E08_IMAGE_PLATFORM:-}" =~ ^linux/(amd64|arm64)$ ]] || \
  die "E08 image metadata must declare linux/amd64 or linux/arm64"
IMAGE_ARCH="${E08_IMAGE_PLATFORM#linux/}"

PREFLIGHT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hooke-e08-preflight.XXXXXX")"
cleanup_preflight() {
  [[ "$PREFLIGHT_DIR" == "${TMPDIR:-/tmp}"/hooke-e08-preflight.* ]] && \
    rm -rf -- "$PREFLIGHT_DIR"
}
trap cleanup_preflight EXIT

kube get nodes -o json >"$PREFLIGHT_DIR/nodes.json"
jq -e \
  --arg first "${TARGET_NODES[0]}" \
  --arg second "${TARGET_NODES[1]}" \
  --arg image_arch "$IMAGE_ARCH" '
    [.items[] | select(.metadata.name == $first or .metadata.name == $second)] as $nodes
    | ($nodes | length) == 2
    and ([$nodes[].metadata.name] | unique | length) == 2
    and ([$nodes[] | select(
      .spec.unschedulable != true
      and any(.status.conditions[]?;
        .type == "Ready" and .status == "True")
      and .metadata.labels["kubernetes.io/hostname"] == .metadata.name
      and .metadata.labels["kubernetes.io/arch"] == $image_arch
      and ((.spec.providerID // "") | length) > 0
      and ([
        .spec.taints[]?
        | select(.effect == "NoSchedule" or .effect == "NoExecute")
      ] | length) == 0
    )] | length) == 2
    and ([$nodes[].spec.providerID] | unique | length) == 2
    and ([
      $nodes[].metadata.labels["node.kubernetes.io/instance-type"]
    ] | map(select(. != null and . != "")) | unique | length) == 1
  ' "$PREFLIGHT_DIR/nodes.json" >/dev/null || \
  die "target nodes must be matching-type, image-compatible, Ready physical ACK Workers"

kube get --raw /apis/metrics.k8s.io/v1beta1/nodes >"$PREFLIGHT_DIR/node-metrics.json"
jq -e \
  --arg first "${TARGET_NODES[0]}" \
  --arg second "${TARGET_NODES[1]}" '
    [.items[] | select(.metadata.name == $first or .metadata.name == $second)]
    | length == 2
  ' "$PREFLIGHT_DIR/node-metrics.json" >/dev/null || \
  die "Metrics API has no fresh samples for both target nodes"

kube get pods --all-namespaces -o json >"$PREFLIGHT_DIR/pods.json"
"$HELPER" check-capacity \
  --nodes "$PREFLIGHT_DIR/nodes.json" \
  --pods "$PREFLIGHT_DIR/pods.json" \
  --target-node "${TARGET_NODES[0]}" \
  --target-node "${TARGET_NODES[1]}" \
  --workload-cpu "$E08_WORKLOAD_CPU" \
  --workload-memory "$E08_WORKLOAD_MEMORY" \
  --node-agent-cpu "$E08_NODE_AGENT_CPU" \
  --node-agent-memory "$E08_NODE_AGENT_MEMORY" \
  --output "$PREFLIGHT_DIR/capacity.json"

if kube get namespace "$E08_SYSTEM_NAMESPACE" >/dev/null 2>&1; then
  die "isolated E08 namespace already exists: $E08_SYSTEM_NAMESPACE"
fi
if helm_ack status "$E08_HELM_RELEASE" -n "$E08_SYSTEM_NAMESPACE" >/dev/null 2>&1; then
  die "isolated E08 Helm release already exists: $E08_HELM_RELEASE"
fi
if kube -n "$E08_LOCK_NAMESPACE" get lease "$E08_LOCK_NAME" >/dev/null 2>&1; then
  die "another E08 runner holds lease ${E08_LOCK_NAMESPACE}/${E08_LOCK_NAME}"
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

can_i create namespaces
can_i get namespaces
can_i patch namespaces
can_i delete namespaces
can_i create secrets "$E08_SYSTEM_NAMESPACE"
can_i get secrets "$E08_SYSTEM_NAMESPACE"
can_i list secrets "$E08_SYSTEM_NAMESPACE"
can_i patch secrets "$E08_SYSTEM_NAMESPACE"
can_i delete secrets "$E08_SYSTEM_NAMESPACE"
can_i create configmaps "$E08_SYSTEM_NAMESPACE"
can_i get configmaps "$E08_SYSTEM_NAMESPACE"
can_i patch configmaps "$E08_SYSTEM_NAMESPACE"
can_i delete configmaps "$E08_SYSTEM_NAMESPACE"
can_i create jobs.batch "$E08_SYSTEM_NAMESPACE"
can_i get jobs.batch "$E08_SYSTEM_NAMESPACE"
can_i watch jobs.batch "$E08_SYSTEM_NAMESPACE"
can_i patch jobs.batch "$E08_SYSTEM_NAMESPACE"
can_i delete jobs.batch "$E08_SYSTEM_NAMESPACE"
can_i get pods "$E08_SYSTEM_NAMESPACE"
can_i list pods "$E08_SYSTEM_NAMESPACE"
can_i watch pods "$E08_SYSTEM_NAMESPACE"
can_i get pods/log "$E08_SYSTEM_NAMESPACE"
can_i get pods/proxy "$E08_SYSTEM_NAMESPACE"
can_i create deployments.apps "$E08_SYSTEM_NAMESPACE"
can_i get deployments.apps "$E08_SYSTEM_NAMESPACE"
can_i watch deployments.apps "$E08_SYSTEM_NAMESPACE"
can_i patch deployments.apps "$E08_SYSTEM_NAMESPACE"
can_i delete deployments.apps "$E08_SYSTEM_NAMESPACE"
can_i create daemonsets.apps "$E08_SYSTEM_NAMESPACE"
can_i get daemonsets.apps "$E08_SYSTEM_NAMESPACE"
can_i watch daemonsets.apps "$E08_SYSTEM_NAMESPACE"
can_i patch daemonsets.apps "$E08_SYSTEM_NAMESPACE"
can_i delete daemonsets.apps "$E08_SYSTEM_NAMESPACE"
can_i create serviceaccounts "$E08_SYSTEM_NAMESPACE"
can_i get serviceaccounts "$E08_SYSTEM_NAMESPACE"
can_i patch serviceaccounts "$E08_SYSTEM_NAMESPACE"
can_i delete serviceaccounts "$E08_SYSTEM_NAMESPACE"
can_i create services "$E08_SYSTEM_NAMESPACE"
can_i get services "$E08_SYSTEM_NAMESPACE"
can_i patch services "$E08_SYSTEM_NAMESPACE"
can_i delete services "$E08_SYSTEM_NAMESPACE"
can_i create networkpolicies.networking.k8s.io "$E08_SYSTEM_NAMESPACE"
can_i get networkpolicies.networking.k8s.io "$E08_SYSTEM_NAMESPACE"
can_i patch networkpolicies.networking.k8s.io "$E08_SYSTEM_NAMESPACE"
can_i delete networkpolicies.networking.k8s.io "$E08_SYSTEM_NAMESPACE"
can_i create clusterroles.rbac.authorization.k8s.io
can_i get clusterroles.rbac.authorization.k8s.io
can_i patch clusterroles.rbac.authorization.k8s.io
can_i delete clusterroles.rbac.authorization.k8s.io
can_i create clusterrolebindings.rbac.authorization.k8s.io
can_i get clusterrolebindings.rbac.authorization.k8s.io
can_i patch clusterrolebindings.rbac.authorization.k8s.io
can_i delete clusterrolebindings.rbac.authorization.k8s.io
can_i create leases.coordination.k8s.io "$E08_LOCK_NAMESPACE"
can_i get leases.coordination.k8s.io "$E08_LOCK_NAMESPACE"
can_i delete leases.coordination.k8s.io "$E08_LOCK_NAMESPACE"

IMAGE_REPOSITORY="${CONFIGURED_E08_IMAGE%@*}"
IMAGE_DIGEST="${CONFIGURED_E08_IMAGE#*@}"
helm lint "$CHART" --set global.clusterID="$CLUSTER_ID" >/dev/null
helm template hooke-e08-check "$CHART" \
  --set global.clusterID="$CLUSTER_ID" \
  --set image.repository="$IMAGE_REPOSITORY" \
  --set image.digest="$IMAGE_DIGEST" >/dev/null

log "ACK preflight PASS: context=${KUBE_CONTEXT}, nodes=${TARGET_NODES[*]}, metrics-api=ready"
if [[ "$CHECK_ONLY" == true ]]; then
  log "E08 check-only PASS; no cluster state was changed"
  exit 0
fi
[[ "$CONFIRM_E08_EXECUTION" == yes ]] || \
  die "set CONFIRM_E08_EXECUTION=yes to authorize the isolated smoke resources"

RUN_STAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
ARTIFACT_DIR="${ARTIFACT_ROOT}/e08-collector-overhead-smoke-${RUN_STAMP}"
mkdir -p "$ARTIFACT_DIR"
chmod 700 "$ARTIFACT_DIR"
cp "$PREFLIGHT_DIR/nodes.json" "$ARTIFACT_DIR/preflight-nodes.json"
cp "$PREFLIGHT_DIR/node-metrics.json" "$ARTIFACT_DIR/preflight-node-metrics.json"
cp "$PREFLIGHT_DIR/capacity.json" "$ARTIFACT_DIR/preflight-capacity.json"
git status --short >"$ARTIFACT_DIR/git-status.txt"
git rev-parse HEAD >"$ARTIFACT_DIR/git-commit.txt"
"$HELPER" schedule \
  --output "$ARTIFACT_DIR/schedule.tsv" \
  --json-output "$ARTIFACT_DIR/schedule.json"
jq -n \
  --arg context "$KUBE_CONTEXT" \
  --arg api_server "$API_SERVER" \
  --arg cluster_id "$CLUSTER_ID" \
  --arg image "$CONFIGURED_E08_IMAGE" \
  --arg image_platform "$E08_IMAGE_PLATFORM" \
  --arg node0 "${TARGET_NODES[0]}" \
  --arg node1 "${TARGET_NODES[1]}" \
  --argjson pod_count "$E08_POD_COUNT" \
  --argjson parallelism "$E08_PARALLELISM" \
  '{
    kube_context: $context,
    api_server: $api_server,
    cluster_id: $cluster_id,
    image: $image,
    image_platform: $image_platform,
    target_nodes: [$node0, $node1],
    pod_count: $pod_count,
    parallelism: $parallelism,
    mysql_dsn_redacted: true
  }' >"$ARTIFACT_DIR/frozen-config.json"

LOCK_CREATED=false
SYSTEM_NAMESPACE_CREATED=false
SUCCESS=false
WORKLOAD_NAMESPACES=()
SAMPLER_PID=""
SAMPLER_STOP_FILE=""

cleanup_cluster() {
  local status=$?
  local should_cleanup=false
  local cleanup_failed=false
  if [[ -n "$SAMPLER_PID" ]]; then
    [[ -n "$SAMPLER_STOP_FILE" ]] && touch "$SAMPLER_STOP_FILE"
    kill "$SAMPLER_PID" >/dev/null 2>&1 || true
    wait "$SAMPLER_PID" 2>/dev/null || true
    SAMPLER_PID=""
  fi
  if [[ "$SUCCESS" == true && "$CLEANUP_K8S_ON_SUCCESS" == true ]]; then
    should_cleanup=true
  elif [[ "$SUCCESS" != true && "$CLEANUP_K8S_ON_ERROR" == true ]]; then
    should_cleanup=true
  fi
  if [[ "$should_cleanup" == true ]]; then
    for namespace in "${WORKLOAD_NAMESPACES[@]}"; do
      kube delete namespace "$namespace" --ignore-not-found \
        --wait=true --timeout=5m >/dev/null 2>&1 || cleanup_failed=true
    done
    if [[ "$SYSTEM_NAMESPACE_CREATED" == true ]]; then
      if helm_ack status "$E08_HELM_RELEASE" -n "$E08_SYSTEM_NAMESPACE" \
        >/dev/null 2>&1; then
        helm_ack uninstall "$E08_HELM_RELEASE" -n "$E08_SYSTEM_NAMESPACE" \
          --wait --timeout 5m >/dev/null 2>&1 || cleanup_failed=true
      fi
      kube delete clusterrole "${E08_HELM_RELEASE}-reader" \
        --ignore-not-found >/dev/null 2>&1 || cleanup_failed=true
      kube delete clusterrolebinding "${E08_HELM_RELEASE}-reader" \
        --ignore-not-found >/dev/null 2>&1 || cleanup_failed=true
      kube delete namespace "$E08_SYSTEM_NAMESPACE" \
        --ignore-not-found --wait=true --timeout=5m \
        >/dev/null 2>&1 || cleanup_failed=true
    fi
    if [[ "$LOCK_CREATED" == true ]]; then
      kube -n "$E08_LOCK_NAMESPACE" delete lease "$E08_LOCK_NAME" \
        --ignore-not-found >/dev/null 2>&1 || cleanup_failed=true
    fi
    if kube get namespace "$E08_SYSTEM_NAMESPACE" >/dev/null 2>&1 \
      || kube get clusterrole "${E08_HELM_RELEASE}-reader" >/dev/null 2>&1 \
      || kube get clusterrolebinding "${E08_HELM_RELEASE}-reader" >/dev/null 2>&1 \
      || kube -n "$E08_LOCK_NAMESPACE" get lease "$E08_LOCK_NAME" \
        >/dev/null 2>&1; then
      cleanup_failed=true
    fi
    if [[ "$cleanup_failed" == true ]]; then
      warn "E08 cleanup left resources or returned an error"
      [[ "$status" -ne 0 ]] || status=1
    elif [[ "$SUCCESS" == true ]]; then
      log "E08 smoke PASS; cleanup complete; artifacts: ${ARTIFACT_DIR}"
    fi
  else
    warn "E08 resources preserved for diagnosis"
  fi
  cleanup_preflight
  return "$status"
}
trap cleanup_cluster EXIT

jq -n \
  --arg namespace "$E08_LOCK_NAMESPACE" \
  --arg name "$E08_LOCK_NAME" \
  --arg holder "${USER:-hooke}@$(hostname)-${RUN_STAMP}" \
  '{
    apiVersion: "coordination.k8s.io/v1",
    kind: "Lease",
    metadata: {namespace: $namespace, name: $name},
    spec: {holderIdentity: $holder}
  }' | kube create -f - >/dev/null
LOCK_CREATED=true

kube create namespace "$E08_SYSTEM_NAMESPACE" >/dev/null
SYSTEM_NAMESPACE_CREATED=true
kube label namespace "$E08_SYSTEM_NAMESPACE" \
  hooke.io/experiment=e08 --overwrite >/dev/null
printf '%s' "$HOOKE_MYSQL_DSN" | \
  kube -n "$E08_SYSTEM_NAMESPACE" create secret generic "$E08_MYSQL_SECRET" \
    --from-file=dsn=/dev/stdin >/dev/null

render_values() {
  local run_id="$1" enabled="$2" percent="$3" output="$4"
  jq -n \
    --arg cluster_id "$CLUSTER_ID" \
    --arg hooke_namespace "$E08_SYSTEM_NAMESPACE" \
    --arg run_id "$run_id" \
    --arg repository "$IMAGE_REPOSITORY" \
    --arg digest "$IMAGE_DIGEST" \
    --arg mysql_secret "$E08_MYSQL_SECRET" \
    --arg node0 "${TARGET_NODES[0]}" \
    --arg node1 "${TARGET_NODES[1]}" \
    --arg node_agent_cpu "$E08_NODE_AGENT_CPU" \
    --arg node_agent_memory "$E08_NODE_AGENT_MEMORY" \
    --argjson enabled "$enabled" \
    --argjson percent "$percent" '
    {
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
        enabled: $enabled,
        replicas: 1,
        captureUnlabeled: false,
        eventSamplePercent: $percent,
        eventQueueSize: 8192,
        eventBatchSize: 100,
        eventFlushInterval: "500ms"
      },
      nodeAgent: {
        enabled: $enabled,
        healthInterval: "30s",
        resources: {
          requests: {cpu: $node_agent_cpu, memory: $node_agent_memory}
        },
        affinity: {
          nodeAffinity: {
            requiredDuringSchedulingIgnoredDuringExecution: {
              nodeSelectorTerms: [{
                matchExpressions: [{
                  key: "kubernetes.io/hostname",
                  operator: "In",
                  values: [$node0, $node1]
                }]
              }]
            }
          }
        }
      },
      ackAdapter: {enabled: false},
      correlator: {enabled: false},
      networkPolicy: {enabled: true}
    }' >"$output"
}

BASE_VALUES="$ARTIFACT_DIR/helm-values-base.json"
render_values "" false 0 "$BASE_VALUES"
log "Installing isolated Hooke ingester and schema"
helm_ack upgrade --install "$E08_HELM_RELEASE" "$CHART" \
  --namespace "$E08_SYSTEM_NAMESPACE" \
  --values "$BASE_VALUES" \
  --rollback-on-failure --wait --timeout 10m >/dev/null
kube -n "$E08_SYSTEM_NAMESPACE" rollout status \
  "deployment/${E08_HELM_RELEASE}-ingester" --timeout=5m >/dev/null

run_hookectl_job() {
  local name="$1"
  shift
  kube -n "$E08_SYSTEM_NAMESPACE" delete job "$name" \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kube -n "$E08_SYSTEM_NAMESPACE" create job "$name" \
    --image="$CONFIGURED_E08_IMAGE" -- "$@" >/dev/null
  if ! kube -n "$E08_SYSTEM_NAMESPACE" wait \
    --for=condition=complete "job/$name" --timeout=180s >/dev/null; then
    kube -n "$E08_SYSTEM_NAMESPACE" logs "job/$name" >&2 || true
    die "hookectl Job failed: $name"
  fi
}

scrape_controller() {
  local output="$1"
  local pod
  pod="$(kube -n "$E08_SYSTEM_NAMESPACE" get pods \
    -l app.kubernetes.io/name=hooke-controller \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$pod" ]] || die "controller Pod not found"
  kube get --raw \
    "/api/v1/namespaces/${E08_SYSTEM_NAMESPACE}/pods/${pod}:8081/proxy/metrics" \
    >"$output"
}

sample_resources() {
  local output="$1" stop_file="$2"
  : >"$output"
  while [[ ! -e "$stop_file" ]]; do
    local sample_file observed
    sample_file="$(mktemp "${TMPDIR:-/tmp}/hooke-e08-metrics.XXXXXX")"
    observed="$(now_ns)"
    if kube get --raw \
      "/apis/metrics.k8s.io/v1beta1/namespaces/${E08_SYSTEM_NAMESPACE}/pods" \
      >"$sample_file" 2>/dev/null; then
      jq -c --argjson observed "$observed" \
        '. + {observed_time_ns: $observed}' "$sample_file" >>"$output"
    fi
    rm -f -- "$sample_file"
    sleep "$E08_RESOURCE_SAMPLE_INTERVAL_SECONDS"
  done
}

export_events() {
  local run_id="$1" cell_dir="$2"
  local job_name="e08-export-${run_id,,}"
  job_name="${job_name:0:63}"
  jq -n \
    --arg namespace "$E08_SYSTEM_NAMESPACE" \
    --arg name "$job_name" \
    --arg image "$CONFIGURED_E08_IMAGE" \
    --arg secret "$E08_MYSQL_SECRET" \
    --arg run_id "$run_id" '{
      apiVersion: "batch/v1",
      kind: "Job",
      metadata: {namespace: $namespace, name: $name},
      spec: {
        backoffLimit: 0,
        template: {
          spec: {
            restartPolicy: "Never",
            containers: [{
              name: "export",
              image: $image,
              imagePullPolicy: "IfNotPresent",
              command: ["/hookectl"],
              args: ["events", "export", "--run-id", $run_id, "--file", "-"],
              env: [{
                name: "HOOKE_MYSQL_DSN",
                valueFrom: {secretKeyRef: {name: $secret, key: "dsn"}}
              }],
              securityContext: {
                allowPrivilegeEscalation: false,
                capabilities: {drop: ["ALL"]}
              }
            }]
          }
        }
      }
    }' >"$cell_dir/export-job.json"
  kube apply -f "$cell_dir/export-job.json" >/dev/null
  if ! kube -n "$E08_SYSTEM_NAMESPACE" wait \
    --for=condition=complete "job/$job_name" --timeout=180s >/dev/null; then
    kube -n "$E08_SYSTEM_NAMESPACE" logs "job/$job_name" >&2 || true
    die "event export failed for run ${run_id}"
  fi
  kube -n "$E08_SYSTEM_NAMESPACE" logs "job/$job_name" >"$cell_dir/events.ndjson"
}

CELL_SUMMARIES=()
while IFS=$'\t' read -r sequence cell_id mode collector_enabled sample_percent; do
  [[ "$sequence" == sequence ]] && continue
  collector_enabled="${collector_enabled,,}"
  [[ "$collector_enabled" == true || "$collector_enabled" == false ]] || \
    die "invalid collector_enabled value in E08 schedule: $collector_enabled"
  CELL_DIR="$ARTIFACT_DIR/${sequence}-${cell_id}"
  mkdir -p "$CELL_DIR"
  WORKLOAD_NAMESPACE="hooke-e08-${RUN_STAMP,,}-${cell_id}"
  WORKLOAD_NAMESPACE="${WORKLOAD_NAMESPACE:0:63}"
  WORKLOAD_NAMESPACES+=("$WORKLOAD_NAMESPACE")

  CREATE_JOB="e08-create-${cell_id}"
  run_hookectl_job "$CREATE_JOB" \
    /hookectl run create \
    --api "http://${E08_HELM_RELEASE}-ingester:8080" \
    --cluster "$CLUSTER_ID" \
    --name "E08 ${mode} ${RUN_STAMP}" \
    --slo-seconds 30 \
    --labels-json "{\"experiment\":\"E08\",\"cell\":\"${cell_id}\",\"scope\":\"smoke\"}"
  kube -n "$E08_SYSTEM_NAMESPACE" logs "job/$CREATE_JOB" \
    >"$CELL_DIR/run-create.json"
  RUN_ID="$(jq -er '.run_id' "$CELL_DIR/run-create.json")" || \
    die "run create returned no run_id"
  [[ "$RUN_ID" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || \
    die "run create returned an invalid ULID"
  printf '%s\n' "$RUN_ID" >"$CELL_DIR/run-id.txt"

  kube create namespace "$WORKLOAD_NAMESPACE" >/dev/null
  kube annotate namespace "$WORKLOAD_NAMESPACE" \
    "hooke.io/run-id=$RUN_ID" --overwrite >/dev/null
  kube label namespace "$WORKLOAD_NAMESPACE" \
    hooke.io/experiment=e08 "hooke.io/cell=$cell_id" --overwrite >/dev/null

  VALUES_FILE="$CELL_DIR/helm-values.json"
  if [[ "$collector_enabled" == true ]]; then
    render_values "$RUN_ID" true "$sample_percent" "$VALUES_FILE"
  else
    render_values "$RUN_ID" false "$sample_percent" "$VALUES_FILE"
  fi
  log "E08 ${cell_id}: mode=${mode}, sample=${sample_percent}%"
  helm_ack upgrade "$E08_HELM_RELEASE" "$CHART" \
    --namespace "$E08_SYSTEM_NAMESPACE" \
    --values "$VALUES_FILE" \
    --rollback-on-failure --wait --timeout 10m >/dev/null

  if [[ "$collector_enabled" == true ]]; then
    kube -n "$E08_SYSTEM_NAMESPACE" rollout status \
      "deployment/${E08_HELM_RELEASE}-controller" --timeout=5m >/dev/null
    kube -n "$E08_SYSTEM_NAMESPACE" rollout status \
      "daemonset/${E08_HELM_RELEASE}-node-agent" --timeout=5m >/dev/null
    kube -n "$E08_SYSTEM_NAMESPACE" get \
      "daemonset/${E08_HELM_RELEASE}-node-agent" -o json \
      >"$CELL_DIR/node-agent-daemonset.json"
    jq -e '
      .status.desiredNumberScheduled == 2
      and .status.numberReady == 2
      and .status.numberAvailable == 2
    ' "$CELL_DIR/node-agent-daemonset.json" >/dev/null || \
      die "node-agent DaemonSet is not Ready on exactly two nodes"
    sleep "$E08_COLLECTOR_SETTLE_SECONDS"
    scrape_controller "$CELL_DIR/controller-metrics-before.prom"
  else
    : >"$CELL_DIR/controller-metrics-before.prom"
    if kube -n "$E08_SYSTEM_NAMESPACE" get pods \
      -l 'app.kubernetes.io/name in (hooke-controller,hooke-node-agent)' \
      -o name | grep -q .; then
      die "collector-off still has collector Pods"
    fi
  fi

  WORKLOAD_JOB="e08-${cell_id}-workload"
  WORKLOAD_MANIFEST="$CELL_DIR/workload-job.json"
  "$HELPER" render-workload \
    --namespace "$WORKLOAD_NAMESPACE" \
    --name "$WORKLOAD_JOB" \
    --run-id "$RUN_ID" \
    --cluster-id "$CLUSTER_ID" \
    --image "$CONFIGURED_E08_IMAGE" \
    --ingester-url \
      "http://${E08_HELM_RELEASE}-ingester.${E08_SYSTEM_NAMESPACE}.svc:8080" \
    --target-node "${TARGET_NODES[0]}" \
    --target-node "${TARGET_NODES[1]}" \
    --completions "$E08_POD_COUNT" \
    --parallelism "$E08_PARALLELISM" \
    --work-duration "$E08_WORK_DURATION" \
    --cpu-request "$E08_WORKLOAD_CPU" \
    --memory-request "$E08_WORKLOAD_MEMORY" \
    --output "$WORKLOAD_MANIFEST"

  STOP_FILE="$CELL_DIR/stop-resource-sampler"
  rm -f -- "$STOP_FILE"
  SAMPLER_STOP_FILE="$STOP_FILE"
  sample_resources "$CELL_DIR/resource-samples.ndjson" "$STOP_FILE" &
  SAMPLER_PID=$!
  kube apply -f "$WORKLOAD_MANIFEST" >/dev/null
  if ! kube -n "$WORKLOAD_NAMESPACE" wait \
    --for=condition=complete "job/$WORKLOAD_JOB" \
    --timeout="${E08_JOB_TIMEOUT_SECONDS}s" >/dev/null; then
    touch "$STOP_FILE"
    wait "$SAMPLER_PID" || true
    kube -n "$WORKLOAD_NAMESPACE" get pods -o wide >&2 || true
    kube -n "$WORKLOAD_NAMESPACE" describe "job/$WORKLOAD_JOB" >&2 || true
    die "E08 workload failed in cell ${cell_id}"
  fi
  touch "$STOP_FILE"
  wait "$SAMPLER_PID"
  SAMPLER_PID=""
  SAMPLER_STOP_FILE=""

  kube -n "$WORKLOAD_NAMESPACE" get "job/$WORKLOAD_JOB" -o json \
    >"$CELL_DIR/workload-job-final.json"
  kube -n "$WORKLOAD_NAMESPACE" get pods \
    -l "hooke.io/e08-job=$WORKLOAD_JOB" -o json \
    >"$CELL_DIR/workload-pods-final.json"
  kube -n "$E08_SYSTEM_NAMESPACE" get pods -o json \
    >"$CELL_DIR/system-pods-final.json"
  kube -n "$WORKLOAD_NAMESPACE" logs \
    -l "hooke.io/e08-job=$WORKLOAD_JOB" --all-containers=true \
    --prefix=true >"$CELL_DIR/workload.log"

  sleep "$E08_COLLECTOR_SETTLE_SECONDS"
  if [[ "$collector_enabled" == true ]]; then
    scrape_controller "$CELL_DIR/controller-metrics-after.prom"
  else
    : >"$CELL_DIR/controller-metrics-after.prom"
  fi

  STOP_JOB="e08-stop-${cell_id}"
  run_hookectl_job "$STOP_JOB" \
    /hookectl run stop \
    --api "http://${E08_HELM_RELEASE}-ingester:8080" \
    --run-id "$RUN_ID"
  kube -n "$E08_SYSTEM_NAMESPACE" logs "job/$STOP_JOB" \
    >"$CELL_DIR/run-stop.json"
  export_events "$RUN_ID" "$CELL_DIR"

  SUMMARY_FILE="$CELL_DIR/summary.json"
  "$HELPER" summarize-cell \
    --cell-id "$cell_id" \
    --run-id "$RUN_ID" \
    --workload-namespace "$WORKLOAD_NAMESPACE" \
    --target-node "${TARGET_NODES[0]}" \
    --target-node "${TARGET_NODES[1]}" \
    --image "$CONFIGURED_E08_IMAGE" \
    --expected-pods "$E08_POD_COUNT" \
    --job "$CELL_DIR/workload-job-final.json" \
    --pods "$CELL_DIR/workload-pods-final.json" \
    --events "$CELL_DIR/events.ndjson" \
    --resource-samples "$CELL_DIR/resource-samples.ndjson" \
    --system-pods "$CELL_DIR/system-pods-final.json" \
    --metrics-before "$CELL_DIR/controller-metrics-before.prom" \
    --metrics-after "$CELL_DIR/controller-metrics-after.prom" \
    --output "$SUMMARY_FILE"
  CELL_SUMMARIES+=("$SUMMARY_FILE")
  kube delete namespace "$WORKLOAD_NAMESPACE" --wait=true --timeout=5m >/dev/null
  log "E08 ${cell_id}: PASS"
done <"$ARTIFACT_DIR/schedule.tsv"

AGGREGATE_ARGS=()
for summary in "${CELL_SUMMARIES[@]}"; do
  AGGREGATE_ARGS+=(--cell "$summary")
done
"$HELPER" aggregate \
  "${AGGREGATE_ARGS[@]}" \
  --output "$ARTIFACT_DIR/summary.json" \
  --report "$ARTIFACT_DIR/report.md"

helm_ack get manifest "$E08_HELM_RELEASE" -n "$E08_SYSTEM_NAMESPACE" \
  >"$ARTIFACT_DIR/hooke-manifest.yaml"
helm_ack list -n "$E08_SYSTEM_NAMESPACE" -o json \
  >"$ARTIFACT_DIR/helm-releases.json"
kube get nodes "${TARGET_NODES[@]}" -o json \
  >"$ARTIFACT_DIR/final-target-nodes.json"

SUCCESS=true
log "E08 evidence gates PASS; starting cleanup"
