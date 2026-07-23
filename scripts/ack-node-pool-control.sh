#!/usr/bin/env bash
set -Eeuo pipefail

ACTION=""
CLUSTER_ID=""
NODE_POOL_ID=""
NODE_POOL_NAME=""
RESOURCE_GROUP_ID=""
EXPECTED_API_SERVER=""
SELECTOR_KEY=""
SELECTOR_VALUE=""
TAINT_KEY=""
TAINT_VALUE=""
TAINT_EFFECT=""
EVIDENCE=""
MIN_SIZE=""
SNAPSHOT=""

usage() {
  cat <<'USAGE'
Usage: ack-node-pool-control.sh --action check|snapshot|set-min|restore \
  --cluster-id ID --node-pool-id ID --node-pool-name NAME \
  --resource-group-id ID --expected-api-server URL \
  --selector-key KEY --selector-value VALUE \
  --taint-key KEY --taint-value VALUE --taint-effect NoSchedule \
  --evidence PATH [--min-size 0|1] [--snapshot PATH]

Uses Alibaba Cloud CLI DescribeClusterDetail, DescribeClusterNodePoolDetail,
ModifyClusterNodePool, and DescribeTaskInfo. The check action is read-only.
Credentials must come from an Alibaba Cloud CLI profile or RAM role.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) [[ $# -ge 2 ]] || exit 2; ACTION="$2"; shift 2 ;;
    --cluster-id) [[ $# -ge 2 ]] || exit 2; CLUSTER_ID="$2"; shift 2 ;;
    --node-pool-id) [[ $# -ge 2 ]] || exit 2; NODE_POOL_ID="$2"; shift 2 ;;
    --node-pool-name) [[ $# -ge 2 ]] || exit 2; NODE_POOL_NAME="$2"; shift 2 ;;
    --resource-group-id) [[ $# -ge 2 ]] || exit 2; RESOURCE_GROUP_ID="$2"; shift 2 ;;
    --expected-api-server) [[ $# -ge 2 ]] || exit 2; EXPECTED_API_SERVER="$2"; shift 2 ;;
    --selector-key) [[ $# -ge 2 ]] || exit 2; SELECTOR_KEY="$2"; shift 2 ;;
    --selector-value) [[ $# -ge 2 ]] || exit 2; SELECTOR_VALUE="$2"; shift 2 ;;
    --taint-key) [[ $# -ge 2 ]] || exit 2; TAINT_KEY="$2"; shift 2 ;;
    --taint-value) [[ $# -ge 2 ]] || exit 2; TAINT_VALUE="$2"; shift 2 ;;
    --taint-effect) [[ $# -ge 2 ]] || exit 2; TAINT_EFFECT="$2"; shift 2 ;;
    --evidence) [[ $# -ge 2 ]] || exit 2; EVIDENCE="$2"; shift 2 ;;
    --min-size) [[ $# -ge 2 ]] || exit 2; MIN_SIZE="$2"; shift 2 ;;
    --snapshot) [[ $# -ge 2 ]] || exit 2; SNAPSHOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { printf 'ack-node-pool-control: %s\n' "$*" >&2; exit 1; }
warn() { printf 'ack-node-pool-control: %s\n' "$*" >&2; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

case "$ACTION" in check|snapshot|set-min|restore) ;; *) die "invalid --action" ;; esac
[[ -n "$CLUSTER_ID" && -n "$NODE_POOL_ID" ]] || die "cluster and node-pool IDs are required"
[[ -n "$NODE_POOL_NAME" && -n "$RESOURCE_GROUP_ID" ]] || \
  die "exact node-pool name and resource-group ID are required"
[[ -n "$EXPECTED_API_SERVER" ]] || die "--expected-api-server is required"
[[ -n "$SELECTOR_KEY" && -n "$SELECTOR_VALUE" ]] || die "selector key/value are required"
[[ "$SELECTOR_KEY" == node.alibabacloud.com/nodepool-id && "$SELECTOR_VALUE" == "$NODE_POOL_ID" ]] || \
  die "selector must be node.alibabacloud.com/nodepool-id=<node-pool-id>"
[[ -n "$TAINT_KEY" && -n "$TAINT_VALUE" && "$TAINT_EFFECT" == NoSchedule ]] || \
  die "an exact NoSchedule taint is required"
[[ -n "$EVIDENCE" ]] || die "--evidence is required"
if [[ "$ACTION" == set-min ]]; then
  [[ "$MIN_SIZE" == 0 || "$MIN_SIZE" == 1 ]] || die "set-min requires --min-size 0 or 1"
elif [[ "$ACTION" == restore ]]; then
  [[ -f "$SNAPSHOT" ]] || die "restore requires an existing --snapshot file"
fi

: "${ALIYUN_CLI_BIN:=aliyun}"
: "${ALIYUN_CLI_PROFILE:=}"
: "${ALIYUN_CLI_REGION:=}"
: "${E02_ACK_CONTROL_TIMEOUT_SECONDS:=120}"
: "${E02_ACK_CONTROL_POLL_SECONDS:=2}"
: "${E02_ACK_STABILITY_POLLS:=3}"
: "${E02_NODE_POOL_CONTROL_STATE_FILE:=}"
[[ -n "$ALIYUN_CLI_REGION" ]] || die "ALIYUN_CLI_REGION is required"
[[ "$E02_ACK_CONTROL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid control timeout"
[[ "$E02_ACK_CONTROL_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "invalid control poll interval"
[[ "$E02_ACK_STABILITY_POLLS" =~ ^[1-9][0-9]*$ ]] || die "stability polls must be a positive integer"
(( E02_ACK_CONTROL_TIMEOUT_SECONDS <= 600 )) || die "control timeout cannot exceed 600 seconds"
(( E02_ACK_CONTROL_POLL_SECONDS <= 30 )) || die "control poll interval cannot exceed 30 seconds"
(( E02_ACK_STABILITY_POLLS >= 2 )) || die "stability polls must be at least two"
(( E02_ACK_STABILITY_POLLS <= 20 )) || die "stability polls cannot exceed 20"
if [[ "$ACTION" == set-min || "$ACTION" == restore ]]; then
  [[ -n "$E02_NODE_POOL_CONTROL_STATE_FILE" ]] || \
    die "E02_NODE_POOL_CONTROL_STATE_FILE is required for mutations"
  [[ -d "$(dirname "$E02_NODE_POOL_CONTROL_STATE_FILE")" ]] || \
    die "control state parent directory does not exist"
fi

require_cmd "$ALIYUN_CLI_BIN"
require_cmd jq
require_cmd mktemp
require_cmd python3

ALIYUN=("$ALIYUN_CLI_BIN")
[[ -z "$ALIYUN_CLI_PROFILE" ]] || ALIYUN+=(--profile "$ALIYUN_CLI_PROFILE")
ALIYUN+=(--region "$ALIYUN_CLI_REGION")

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

atomic_write() {
  local destination="$1" payload="$2" prefix="$3"
  local parent temporary
  parent="$(dirname "$destination")"
  [[ -d "$parent" ]] || die "output parent directory does not exist: $parent"
  temporary="$(mktemp "${parent}/.${prefix}.XXXXXX")"
  chmod 600 "$temporary"
  printf '%s\n' "$payload" >"$temporary"
  mv -f -- "$temporary" "$destination"
}

normalize_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

value = sys.argv[1].strip()
parsed = urlsplit(value)
if parsed.scheme.lower() != "https" or not parsed.hostname:
    raise SystemExit(1)
if parsed.username or parsed.password or parsed.query or parsed.fragment:
    raise SystemExit(1)
host = parsed.hostname.lower()
if ":" in host:
    host = f"[{host}]"
port = parsed.port
authority = host if port in (None, 443) else f"{host}:{port}"
path = parsed.path.rstrip("/")
print(f"https://{authority}{path}")
PY
}

describe_cluster() {
  local output="$1" endpoint normalized expected_normalized matched=false
  if ! "${ALIYUN[@]}" cs DescribeClusterDetail --ClusterId "$CLUSTER_ID" >"$output"; then
    die "DescribeClusterDetail failed"
  fi
  chmod 600 "$output"
  jq -e --arg cluster "$CLUSTER_ID" --arg region "$ALIYUN_CLI_REGION" '
    (.cluster_id == $cluster) and (.region_id == $region) and (.state == "running") and
    ((.master_url | type) == "string") and
    (try ((.master_url | fromjson | type) == "object") catch false)
  ' "$output" >/dev/null || die "ACK cluster identity, region, state, or endpoint metadata is invalid"
  expected_normalized="$(normalize_url "$EXPECTED_API_SERVER")" || die "invalid expected API server URL"
  while IFS= read -r endpoint; do
    [[ -n "$endpoint" ]] || continue
    normalized="$(normalize_url "$endpoint")" || continue
    if [[ "$normalized" == "$expected_normalized" ]]; then
      matched=true
      break
    fi
  done < <(jq -r '.master_url | fromjson | [.api_server_endpoint, .intranet_api_server_endpoint][]? | select(type == "string")' "$output")
  [[ "$matched" == true ]] || die "kubeconfig API server is not an endpoint of the ACK cluster"
}

describe_pool() {
  local output="$1"
  if ! "${ALIYUN[@]}" cs DescribeClusterNodePoolDetail \
      --ClusterId "$CLUSTER_ID" --NodepoolId "$NODE_POOL_ID" >"$output"; then
    die "DescribeClusterNodePoolDetail failed"
  fi
  chmod 600 "$output"
  jq -e \
    --arg pool "$NODE_POOL_ID" --arg name "$NODE_POOL_NAME" \
    --arg resource_group "$RESOURCE_GROUP_ID" --arg region "$ALIYUN_CLI_REGION" \
    --arg tk "$TAINT_KEY" --arg tv "$TAINT_VALUE" --arg te "$TAINT_EFFECT" '
    (.nodepool_info.nodepool_id == $pool) and
    (.nodepool_info.name == $name) and
    (.nodepool_info.resource_group_id == $resource_group) and
    (.nodepool_info.region_id == $region) and
    (.nodepool_info.type == "ess") and
    (.nodepool_info.is_default == false) and
    (.auto_scaling.enable == true) and
    ((.auto_scaling.min_instances | type) == "number") and
    ((.auto_scaling.min_instances | floor) == .auto_scaling.min_instances) and
    ((.auto_scaling.max_instances | type) == "number") and
    ((.auto_scaling.max_instances | floor) == .auto_scaling.max_instances) and
    (.auto_scaling.min_instances >= 0) and
    (.auto_scaling.min_instances <= .auto_scaling.max_instances) and
    (.auto_scaling.max_instances >= 1) and
    (.auto_scaling.min_instances <= 1) and
    (.kubernetes_config.unschedulable == false) and
    any(.kubernetes_config.taints[]?; .key == $tk and .value == $tv and .effect == $te)
  ' "$output" >/dev/null || die "node pool identity or E02 safety configuration is invalid"
}

read_fields() {
  local input="$1"
  OBSERVED_MIN="$(jq -er '.auto_scaling.min_instances' "$input")"
  OBSERVED_MAX="$(jq -er '.auto_scaling.max_instances' "$input")"
  OBSERVED_STATE="$(jq -er '.status.state' "$input")"
}

wait_stable_pool() {
  local expected_min="$1" expected_max="$2" output="$3"
  local deadline=$((SECONDS + E02_ACK_CONTROL_TIMEOUT_SECONDS)) stable=0
  while true; do
    describe_pool "$output"
    read_fields "$output"
    if [[ "$OBSERVED_MIN" == "$expected_min" && "$OBSERVED_MAX" == "$expected_max" && "$OBSERVED_STATE" == active ]]; then
      stable=$((stable + 1))
      (( stable >= E02_ACK_STABILITY_POLLS )) && return 0
    else
      stable=0
    fi
    (( SECONDS < deadline )) || die "node-pool configuration was not continuously stable before timeout"
    sleep "$E02_ACK_CONTROL_POLL_SECONDS"
  done
}

write_evidence() {
  atomic_write "$EVIDENCE" "$1" "ack-node-pool-evidence"
}

write_control_state() {
  local phase="$1" action="$2" requested="$3" maximum="$4"
  local request_id="$5" task_id="$6" task_state="$7" uncertain="$8"
  local payload
  payload="$(jq -cn \
    --arg cluster "$CLUSTER_ID" --arg pool "$NODE_POOL_ID" \
    --arg phase "$phase" --arg action "$action" \
    --arg request_id "$request_id" --arg task_id "$task_id" --arg task_state "$task_state" \
    --arg updated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson requested "$requested" --argjson maximum "$maximum" --argjson uncertain "$uncertain" '
      {
        version:1, cluster_id:$cluster, node_pool_id:$pool,
        phase:$phase, action:$action, requested_min_size:$requested,
        expected_max_size:$maximum,
        request_id:(if $request_id == "" then null else $request_id end),
        task_id:(if $task_id == "" then null else $task_id end),
        task_state:(if $task_state == "" then null else $task_state end),
        prior_mutation_uncertain:$uncertain, updated_at:$updated_at
      }')"
  atomic_write "$E02_NODE_POOL_CONTROL_STATE_FILE" "$payload" "ack-node-pool-state"
}

safe_observation() {
  local action="$1" min="$2" max="$3" state="$4"
  jq -cn \
    --arg action "$action" --arg cluster "$CLUSTER_ID" --arg pool "$NODE_POOL_ID" \
    --arg name "$NODE_POOL_NAME" --arg resource_group "$RESOURCE_GROUP_ID" \
    --arg region "$ALIYUN_CLI_REGION" --arg api_server "$EXPECTED_API_SERVER" \
    --arg selector_key "$SELECTOR_KEY" --arg selector_value "$SELECTOR_VALUE" \
    --arg taint_key "$TAINT_KEY" --arg taint_value "$TAINT_VALUE" --arg taint_effect "$TAINT_EFFECT" \
    --arg state "$state" --arg observed_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson min "$min" --argjson max "$max" '
      {
        action:$action, cluster_id:$cluster, node_pool_id:$pool,
        node_pool_name:$name, resource_group_id:$resource_group,
        region_id:$region, api_server:$api_server,
        min_size:$min, max_size:$max, auto_scaling_enabled:true,
        nodepool_type:"ess", is_default:false, status_state:$state,
        selector:{key:$selector_key,value:$selector_value},
        taint:{key:$taint_key,value:$taint_value,effect:$taint_effect},
        observed_at:$observed_at
      }'
}

wait_task_terminal() {
  local task_id="$1" output="$2" deadline=$((SECONDS + E02_ACK_CONTROL_TIMEOUT_SECONDS))
  while true; do
    if ! "${ALIYUN[@]}" cs DescribeTaskInfo --task_id "$task_id" >"$output"; then
      (( SECONDS < deadline )) || {
        warn "DescribeTaskInfo remained unavailable for ${task_id} until timeout"
        return 1
      }
      sleep "$E02_ACK_CONTROL_POLL_SECONDS"
      continue
    fi
    chmod 600 "$output"
    # ModifyClusterNodePool was submitted against the exact cluster/node-pool
    # path and its response was identity-checked. DescribeTaskInfo defines
    # target as a generic task object and does not guarantee that target.id is
    # the node-pool ID, so bind the follow-up only by immutable task and cluster
    # identity. The exact pool is re-described after task completion.
    if ! jq -e --arg task "$task_id" --arg cluster "$CLUSTER_ID" '
      (.task_id == $task) and (.cluster_id == $cluster) and
      ((.state == "running") or (.state == "success") or (.state == "fail"))
    ' "$output" >/dev/null; then
      warn "DescribeTaskInfo returned identity-invalid task evidence"
      return 1
    fi
    TASK_STATE="$(jq -er '.state' "$output")"
    [[ "$TASK_STATE" == success ]] && return 0
    [[ "$TASK_STATE" == fail ]] && return 2
    (( SECONDS < deadline )) || {
      warn "ACK task ${task_id} did not reach a terminal state before timeout"
      return 1
    }
    sleep "$E02_ACK_CONTROL_POLL_SECONDS"
  done
}

modify_min() {
  local action="$1" requested="$2" expected_max="$3" response="$4" observed="$5" uncertain="$6"
  local body task_output rc
  body="$(jq -cn --argjson min "$requested" --argjson max "$expected_max" \
    '{auto_scaling:{enable:true,min_instances:$min,max_instances:$max}}')"
  # Persist intent before the API call. If the process dies before the response
  # is durably recorded, restore treats the prior mutation as ambiguous and the
  # parent retains its Lease for manual recovery.
  write_control_state submitting "$action" "$requested" "$expected_max" "" "" "" "$uncertain"
  if ! "${ALIYUN[@]}" cs ModifyClusterNodePool \
      --ClusterId "$CLUSTER_ID" --NodepoolId "$NODE_POOL_ID" --body "$body" >"$response"; then
    die "ModifyClusterNodePool failed; mutation acceptance is uncertain"
  fi
  chmod 600 "$response"
  # ACK has returned two response shapes for this operation: older responses
  # include nodepool_id, while the current response binds the task to the
  # cluster with both cluster_id and instanceId. The request path already
  # contains the exact node-pool ID, and wait_stable_pool re-describes it.
  jq -e --arg pool "$NODE_POOL_ID" --arg cluster "$CLUSTER_ID" '
    (
      (.nodepool_id? == $pool) or
      ((.cluster_id? == $cluster) and (.instanceId? == $cluster))
    ) and
    ((.request_id | type) == "string") and (.request_id | length > 0) and
    ((.task_id | type) == "string") and (.task_id | length > 0)
  ' "$response" >/dev/null || die "ModifyClusterNodePool returned invalid task evidence"
  REQUEST_ID="$(jq -er '.request_id' "$response")"
  TASK_ID="$(jq -er '.task_id' "$response")"
  write_control_state accepted "$action" "$requested" "$expected_max" \
    "$REQUEST_ID" "$TASK_ID" running "$uncertain"
  task_output="$WORK_DIR/task-${action}.json"
  if wait_task_terminal "$TASK_ID" "$task_output"; then
    :
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then
      write_control_state terminal "$action" "$requested" "$expected_max" \
        "$REQUEST_ID" "$TASK_ID" fail "$uncertain"
      die "ACK task ${TASK_ID} failed"
    fi
    die "ACK task ${TASK_ID} completion is unverified"
  fi
  wait_stable_pool "$requested" "$expected_max" "$observed"
  TASK_STATE=success
  write_control_state completed "$action" "$requested" "$expected_max" \
    "$REQUEST_ID" "$TASK_ID" "$TASK_STATE" "$uncertain"
}

PRIOR_MUTATION_UNCERTAIN=false
settle_prior_mutation() {
  [[ -f "$E02_NODE_POOL_CONTROL_STATE_FILE" ]] || return 0
  jq -e --arg cluster "$CLUSTER_ID" --arg pool "$NODE_POOL_ID" '
    (.version == 1) and (.cluster_id == $cluster) and (.node_pool_id == $pool) and
    ((.phase | type) == "string") and ((.prior_mutation_uncertain | type) == "boolean")
  ' "$E02_NODE_POOL_CONTROL_STATE_FILE" >/dev/null || return 1
  local phase task_id prior_task="$WORK_DIR/prior-task.json" rc
  phase="$(jq -er '.phase' "$E02_NODE_POOL_CONTROL_STATE_FILE")"
  if [[ "$(jq -r '.prior_mutation_uncertain' "$E02_NODE_POOL_CONTROL_STATE_FILE")" == true ]]; then
    PRIOR_MUTATION_UNCERTAIN=true
  fi
  case "$phase" in
    submitting)
      PRIOR_MUTATION_UNCERTAIN=true
      ;;
    accepted)
      task_id="$(jq -er '.task_id | select(type == "string" and length > 0)' "$E02_NODE_POOL_CONTROL_STATE_FILE")" || return 1
      if wait_task_terminal "$task_id" "$prior_task"; then
        :
      else
        rc=$?
        [[ $rc -eq 2 ]] || return 1
      fi
      ;;
    noop|completed|terminal) ;;
    *) return 1 ;;
  esac
}

CLUSTER="$WORK_DIR/cluster.json"
CURRENT="$WORK_DIR/current.json"
describe_cluster "$CLUSTER"
describe_pool "$CURRENT"
read_fields "$CURRENT"
if [[ "$ACTION" != restore ]]; then
  [[ "$OBSERVED_STATE" == active ]] || die "node pool must be active before ${ACTION}"
fi

case "$ACTION" in
  check|snapshot)
    write_evidence "$(safe_observation "$ACTION" "$OBSERVED_MIN" "$OBSERVED_MAX" "$OBSERVED_STATE")"
    ;;
  set-min)
    (( MIN_SIZE <= OBSERVED_MAX )) || die "requested min exceeds current max"
    RESPONSE="$WORK_DIR/modify.json"
    OBSERVED="$WORK_DIR/observed.json"
    CHANGED=false
    REQUEST_ID=""
    TASK_ID=""
    TASK_STATE=""
    if [[ "$OBSERVED_MIN" != "$MIN_SIZE" ]]; then
      modify_min set-min "$MIN_SIZE" "$OBSERVED_MAX" "$RESPONSE" "$OBSERVED" false
      CHANGED=true
    else
      cp -- "$CURRENT" "$OBSERVED"
      write_control_state noop set-min "$MIN_SIZE" "$OBSERVED_MAX" "" "" "" false
    fi
    read_fields "$OBSERVED"
    write_evidence "$(jq -cn \
      --arg cluster "$CLUSTER_ID" --arg pool "$NODE_POOL_ID" \
      --arg name "$NODE_POOL_NAME" --arg resource_group "$RESOURCE_GROUP_ID" \
      --arg region "$ALIYUN_CLI_REGION" --arg api_server "$EXPECTED_API_SERVER" \
      --arg selector_key "$SELECTOR_KEY" --arg selector_value "$SELECTOR_VALUE" \
      --arg taint_key "$TAINT_KEY" --arg taint_value "$TAINT_VALUE" --arg taint_effect "$TAINT_EFFECT" \
      --arg request_id "$REQUEST_ID" --arg task_id "$TASK_ID" --arg task_state "$TASK_STATE" \
      --arg observed_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      --argjson requested "$MIN_SIZE" --argjson observed "$OBSERVED_MIN" \
      --argjson max "$OBSERVED_MAX" --argjson changed "$CHANGED" '
        {
          action:"set-min", cluster_id:$cluster, node_pool_id:$pool,
          node_pool_name:$name, resource_group_id:$resource_group,
          region_id:$region, api_server:$api_server,
          requested_min_size:$requested, observed_min_size:$observed,
          observed_max_size:$max, changed:$changed, auto_scaling_enabled:true,
          nodepool_type:"ess", is_default:false,
          selector:{key:$selector_key,value:$selector_value},
          taint:{key:$taint_key,value:$taint_value,effect:$taint_effect},
          request_id:(if $request_id == "" then null else $request_id end),
          task_id:(if $task_id == "" then null else $task_id end),
          task_state:(if $task_state == "" then null else $task_state end),
          observed_at:$observed_at
        }')"
    ;;
  restore)
    jq -e \
      --arg cluster "$CLUSTER_ID" --arg pool "$NODE_POOL_ID" \
      --arg name "$NODE_POOL_NAME" --arg resource_group "$RESOURCE_GROUP_ID" \
      --arg region "$ALIYUN_CLI_REGION" --arg api_server "$EXPECTED_API_SERVER" \
      --arg tk "$TAINT_KEY" --arg tv "$TAINT_VALUE" --arg te "$TAINT_EFFECT" '
      (.action == "snapshot") and (.cluster_id == $cluster) and (.node_pool_id == $pool) and
      (.node_pool_name == $name) and (.resource_group_id == $resource_group) and
      (.region_id == $region) and (.api_server == $api_server) and
      (.auto_scaling_enabled == true) and (.nodepool_type == "ess") and (.is_default == false) and
      ((.min_size == 0) or (.min_size == 1)) and
      ((.max_size | type) == "number") and (.max_size >= 1) and (.min_size <= .max_size) and
      (.taint == {key:$tk,value:$tv,effect:$te})
    ' "$SNAPSHOT" >/dev/null || die "snapshot is invalid or belongs to another pool"
    ORIGINAL_MIN="$(jq -er '.min_size' "$SNAPSHOT")"
    ORIGINAL_MAX="$(jq -er '.max_size' "$SNAPSHOT")"
    settle_prior_mutation || die "prior node-pool mutation did not reach a verifiable terminal state"
    # Re-read after settling the prior task, then always submit a restore PUT.
    # A no-op restore task is the ordering fence that prevents a late set-min
    # task from becoming effective after the parent releases its Lease.
    describe_pool "$CURRENT"
    read_fields "$CURRENT"
    [[ "$OBSERVED_STATE" == active ]] || die "node pool is not active after settling the prior task"
    [[ "$OBSERVED_MAX" == "$ORIGINAL_MAX" ]] || die "node-pool max changed since snapshot; refusing partial restore"
    RESPONSE="$WORK_DIR/restore.json"
    OBSERVED="$WORK_DIR/restored.json"
    REQUEST_ID=""
    TASK_ID=""
    TASK_STATE=""
    modify_min restore "$ORIGINAL_MIN" "$ORIGINAL_MAX" "$RESPONSE" "$OBSERVED" "$PRIOR_MUTATION_UNCERTAIN"
    read_fields "$OBSERVED"
    write_evidence "$(jq -cn \
      --arg cluster "$CLUSTER_ID" --arg pool "$NODE_POOL_ID" \
      --arg name "$NODE_POOL_NAME" --arg resource_group "$RESOURCE_GROUP_ID" \
      --arg region "$ALIYUN_CLI_REGION" --arg api_server "$EXPECTED_API_SERVER" \
      --arg selector_key "$SELECTOR_KEY" --arg selector_value "$SELECTOR_VALUE" \
      --arg taint_key "$TAINT_KEY" --arg taint_value "$TAINT_VALUE" --arg taint_effect "$TAINT_EFFECT" \
      --arg request_id "$REQUEST_ID" --arg task_id "$TASK_ID" --arg task_state "$TASK_STATE" \
      --arg observed_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      --argjson observed "$OBSERVED_MIN" --argjson max "$OBSERVED_MAX" \
      --argjson uncertain "$PRIOR_MUTATION_UNCERTAIN" '
        {
          action:"restore", cluster_id:$cluster, node_pool_id:$pool,
          node_pool_name:$name, resource_group_id:$resource_group,
          region_id:$region, api_server:$api_server,
          observed_min_size:$observed, observed_max_size:$max,
          changed:true, prior_mutation_uncertain:$uncertain,
          auto_scaling_enabled:true, nodepool_type:"ess", is_default:false,
          selector:{key:$selector_key,value:$selector_value},
          taint:{key:$taint_key,value:$taint_value,effect:$taint_effect},
          request_id:$request_id, task_id:$task_id, task_state:$task_state,
          observed_at:$observed_at
        }')"
    [[ "$PRIOR_MUTATION_UNCERTAIN" == false ]] || \
      die "restore completed, but an earlier mutation had no durable task ID; retain the Lease for manual verification"
    ;;
esac
