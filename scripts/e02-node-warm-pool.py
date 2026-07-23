#!/usr/bin/env python3
"""Offline helpers for the E02 cold-node / warm-node experiment.

The shell orchestrator owns all cluster and node-pool mutations.  This module
contains deterministic schedule generation and validation/summary logic so it
can be tested without Kubernetes or ACK credentials.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
import re
import statistics
import sys
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable


VARIANTS = ("cold-node", "warm-node")
SUMMARY_RESULT_RE = re.compile(r"^- result: \*\*(?P<result>[A-Z]+)\*\*$", re.MULTILINE)
SUMMARY_VALUE_RE = re.compile(r"^- (?P<key>[a-z0-9_]+): (?P<value>.+)$", re.MULTILINE)
EVENT_ID_RE = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")


class ValidationError(ValueError):
    """Raised when experiment evidence violates a required invariant."""


def format_kubernetes_microtime(value: datetime | None = None) -> str:
    current = value if value is not None else datetime.now(timezone.utc)
    if current.tzinfo is None or current.utcoffset() is None:
        raise ValidationError("Kubernetes MicroTime requires a timezone-aware value")
    return current.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def read_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValidationError(f"non-finite JSON number {value} in {path}")
            ),
        )
    except FileNotFoundError as exc:
        raise ValidationError(f"missing JSON evidence: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"invalid JSON evidence: {path}: {exc}") from exc


def write_json(path: Path | None, payload: Any) -> None:
    serialized = json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if path is None:
        sys.stdout.write(serialized)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(serialized, encoding="utf-8")
    path.chmod(0o600)


def write_tsv(path: Path | None, rows: list[dict[str, Any]], fields: list[str]) -> None:
    if path is None:
        stream = sys.stdout
        close = False
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        stream = path.open("w", encoding="utf-8", newline="")
        close = True
    try:
        writer = csv.DictWriter(stream, fieldnames=fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: format_tsv(row.get(field)) for field in fields})
    finally:
        if close:
            stream.close()
            path.chmod(0o600)


def format_tsv(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def read_tsv(path: Path) -> list[dict[str, str]]:
    try:
        with path.open(encoding="utf-8", newline="") as stream:
            return list(csv.DictReader(stream, delimiter="\t"))
    except FileNotFoundError as exc:
        raise ValidationError(f"missing TSV evidence: {path}") from exc


def generate_schedule(repetitions: int, seed: int) -> list[dict[str, Any]]:
    if repetitions < 1:
        raise ValidationError("repetitions must be positive")
    if seed < 0:
        raise ValidationError("seed must be non-negative")
    rng = random.Random(seed)
    schedule: list[dict[str, Any]] = []
    sequence = 1
    for block in range(1, repetitions + 1):
        variants = list(VARIANTS)
        rng.shuffle(variants)
        for variant in variants:
            schedule.append(
                {
                    "sequence": sequence,
                    "block": block,
                    "variant": variant,
                    "repetition": block,
                }
            )
            sequence += 1
    return schedule


def condition_true(item: dict[str, Any], condition_type: str) -> bool:
    return any(
        condition.get("type") == condition_type and condition.get("status") == "True"
        for condition in item.get("status", {}).get("conditions", [])
    )


def node_identity(item: dict[str, Any]) -> dict[str, str]:
    metadata = item.get("metadata", {})
    spec = item.get("spec", {})
    return {
        "name": str(metadata.get("name") or ""),
        "uid": str(metadata.get("uid") or ""),
        "provider_id": str(spec.get("providerID") or ""),
    }


def node_labels(item: dict[str, Any]) -> dict[str, str]:
    labels = item.get("metadata", {}).get("labels", {})
    return {str(key): str(value) for key, value in labels.items()}


def require_taint(item: dict[str, Any], key: str, value: str, effect: str) -> None:
    expected = {"key": key, "value": value, "effect": effect}
    taints = item.get("spec", {}).get("taints", [])
    if not isinstance(taints, list) or not any(
        all(taint.get(field) == expected_value for field, expected_value in expected.items())
        for taint in taints
        if isinstance(taint, dict)
    ):
        raise ValidationError(
            f"Node is missing required taint {key}={value}:{effect}"
        )


def pod_targets_pool(
    pod: dict[str, Any], selector_key: str, selector_value: str, node_names: set[str]
) -> bool:
    labels = pod.get("metadata", {}).get("labels", {})
    if str(labels.get("hooke.io/experiment", "")).lower() != "true":
        return False
    spec = pod.get("spec", {})
    selector = spec.get("nodeSelector", {})
    return (
        selector.get(selector_key) == selector_value
        or str(spec.get("nodeName") or "") in node_names
    )


def ready_cni_pods(cni_payload: dict[str, Any], node_name: str) -> list[str]:
    ready: list[str] = []
    for pod in cni_payload.get("items", []):
        if pod.get("spec", {}).get("nodeName") != node_name:
            continue
        if pod.get("metadata", {}).get("deletionTimestamp"):
            continue
        if pod.get("status", {}).get("phase") != "Running":
            continue
        if condition_true(pod, "Ready"):
            ready.append(str(pod.get("metadata", {}).get("name") or ""))
    return sorted(name for name in ready if name)


def non_daemon_workloads(
    pods_payload: dict[str, Any],
    node_names: set[str],
    selector_key: str,
    selector_value: str,
) -> list[str]:
    blockers: list[str] = []
    for pod in pods_payload.get("items", []):
        spec = pod.get("spec", {})
        selector = spec.get("nodeSelector") or {}
        required_terms = (
            ((spec.get("affinity") or {}).get("nodeAffinity") or {})
            .get("requiredDuringSchedulingIgnoredDuringExecution", {})
            .get("nodeSelectorTerms", [])
        )
        affinity_targets_pool = any(
            expression.get("key") == selector_key
            and (
                expression.get("operator") == "Exists"
                or (
                    expression.get("operator") == "In"
                    and selector_value in (expression.get("values") or [])
                )
            )
            for term in required_terms
            if isinstance(term, dict)
            for expression in term.get("matchExpressions", [])
            if isinstance(expression, dict)
        )
        if (
            str(spec.get("nodeName") or "") not in node_names
            and selector.get(selector_key) != selector_value
            and not affinity_targets_pool
        ):
            continue
        if pod.get("status", {}).get("phase") in {"Succeeded", "Failed"}:
            continue
        metadata = pod.get("metadata", {})
        if (metadata.get("annotations") or {}).get("kubernetes.io/config.mirror"):
            continue
        owners = metadata.get("ownerReferences") or []
        if any(
            owner.get("kind") == "DaemonSet" and owner.get("controller") is True
            for owner in owners
            if isinstance(owner, dict)
        ):
            continue
        blockers.append(
            f"{metadata.get('namespace') or ''}/{metadata.get('name') or ''}"
        )
    return sorted(blockers)


def validate_pool_state(
    *,
    mode: str,
    nodes_payload: dict[str, Any],
    pods_payload: dict[str, Any],
    cni_payload: dict[str, Any] | None,
    selector_key: str,
    selector_value: str,
    expected_instance_type: str,
    expected_zone: str,
    taint_key: str,
    taint_value: str,
    taint_effect: str,
    require_cni: bool,
) -> dict[str, Any]:
    if mode not in VARIANTS:
        raise ValidationError(f"unsupported pool mode: {mode}")
    nodes = nodes_payload.get("items", [])
    if not isinstance(nodes, list):
        raise ValidationError("nodes payload does not contain an items array")
    names = {node_identity(item)["name"] for item in nodes}
    residual_pods = [
        str(item.get("metadata", {}).get("namespace") or "")
        + "/"
        + str(item.get("metadata", {}).get("name") or "")
        for item in pods_payload.get("items", [])
        if pod_targets_pool(item, selector_key, selector_value, names)
    ]
    if residual_pods:
        raise ValidationError(
            "elastic pool still has experiment Pod(s): " + ",".join(sorted(residual_pods))
        )
    workload_blockers = non_daemon_workloads(
        pods_payload, names, selector_key, selector_value
    )
    if workload_blockers:
        raise ValidationError(
            "dedicated pool has non-DaemonSet workload(s): "
            + ",".join(workload_blockers)
        )

    if mode == "cold-node":
        if nodes:
            raise ValidationError(f"cold-node requires zero selected Nodes, observed {len(nodes)}")
        return {
            "valid": True,
            "mode": mode,
            "selected_node_count": 0,
            "selector": f"{selector_key}={selector_value}",
            "residual_experiment_pods": [],
            "non_daemon_workloads": [],
        }

    if len(nodes) != 1:
        raise ValidationError(f"warm-node requires exactly one selected Node, observed {len(nodes)}")
    node = nodes[0]
    identity = node_identity(node)
    if not all(identity.values()):
        raise ValidationError(f"warm Node identity is incomplete: {identity}")
    if not condition_true(node, "Ready"):
        raise ValidationError(f"warm Node is not Ready: {identity['name']}")
    if node.get("spec", {}).get("unschedulable") is True:
        raise ValidationError(f"warm Node is unschedulable: {identity['name']}")
    require_taint(node, taint_key, taint_value, taint_effect)
    labels = node_labels(node)
    if labels.get("node.kubernetes.io/instance-type") != expected_instance_type:
        raise ValidationError(
            "warm Node instance type mismatch: "
            f"{labels.get('node.kubernetes.io/instance-type', '')} != {expected_instance_type}"
        )
    if labels.get("topology.kubernetes.io/zone") != expected_zone:
        raise ValidationError(
            "warm Node zone mismatch: "
            f"{labels.get('topology.kubernetes.io/zone', '')} != {expected_zone}"
        )
    cni_pods: list[str] = []
    if require_cni:
        if cni_payload is None:
            raise ValidationError("warm-node CNI readiness evidence is missing")
        cni_pods = ready_cni_pods(cni_payload, identity["name"])
        if not cni_pods:
            raise ValidationError(f"no Ready CNI Pod found on warm Node {identity['name']}")
    return {
        "valid": True,
        "mode": mode,
        "selected_node_count": 1,
        "selector": f"{selector_key}={selector_value}",
        "node": identity,
        "instance_type": expected_instance_type,
        "zone": expected_zone,
        "taint": {"key": taint_key, "value": taint_value, "effect": taint_effect},
        "cni_ready_pods": cni_pods,
        "residual_experiment_pods": [],
        "non_daemon_workloads": [],
    }


def required_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"control evidence requires non-empty {key}")
    return value


def required_nonnegative_int(payload: dict[str, Any], key: str) -> int:
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValidationError(f"control evidence requires non-negative integer {key}")
    return value


def validate_control_evidence(
    payload: dict[str, Any],
    *,
    expected_action: str,
    expected_cluster_id: str,
    expected_node_pool_id: str,
    expected_node_pool_name: str,
    expected_resource_group_id: str,
    expected_region_id: str,
    expected_api_server: str,
    expected_selector_key: str,
    expected_selector_value: str,
    expected_taint_key: str,
    expected_taint_value: str,
    expected_taint_effect: str,
    expected_min_size: int | None,
    snapshot: dict[str, Any] | None,
) -> dict[str, Any]:
    if payload.get("action") != expected_action:
        raise ValidationError(
            f"control action mismatch: {payload.get('action')} != {expected_action}"
        )
    cluster_id = required_string(payload, "cluster_id")
    node_pool_id = required_string(payload, "node_pool_id")
    node_pool_name = required_string(payload, "node_pool_name")
    resource_group_id = required_string(payload, "resource_group_id")
    region_id = required_string(payload, "region_id")
    api_server = required_string(payload, "api_server")
    required_string(payload, "observed_at")
    if cluster_id != expected_cluster_id:
        raise ValidationError(f"control cluster mismatch: {cluster_id} != {expected_cluster_id}")
    if node_pool_id != expected_node_pool_id:
        raise ValidationError(
            f"control node-pool mismatch: {node_pool_id} != {expected_node_pool_id}"
        )
    if node_pool_name != expected_node_pool_name:
        raise ValidationError("control node-pool name does not match the frozen target")
    if resource_group_id != expected_resource_group_id:
        raise ValidationError("control resource group does not match the frozen target")
    if region_id != expected_region_id:
        raise ValidationError(
            f"control region mismatch: {region_id} != {expected_region_id}"
        )
    if api_server != expected_api_server:
        raise ValidationError("control API server does not match the active kube context")
    expected_selector = {
        "key": expected_selector_key,
        "value": expected_selector_value,
    }
    expected_taint = {
        "key": expected_taint_key,
        "value": expected_taint_value,
        "effect": expected_taint_effect,
    }
    if payload.get("auto_scaling_enabled") is not True:
        raise ValidationError("control evidence does not confirm auto scaling")
    if payload.get("nodepool_type") != "ess":
        raise ValidationError("control evidence does not confirm an ESS node pool")
    if payload.get("is_default") is not False:
        raise ValidationError("E02 refuses the default ACK node pool")
    if payload.get("selector") != expected_selector or payload.get("taint") != expected_taint:
        raise ValidationError("control evidence selector/taint does not match E02")

    if expected_action in {"check", "snapshot"}:
        min_size = required_nonnegative_int(payload, "min_size")
        max_size = required_nonnegative_int(payload, "max_size")
        if min_size > max_size:
            raise ValidationError("control evidence has min_size greater than max_size")
        if min_size > 1:
            raise ValidationError(
                "E02 refuses a node pool whose current minimum is greater than one"
            )
        if max_size < 1:
            raise ValidationError("E02 node pool must allow at least one Node")
    elif expected_action == "set-min":
        requested = required_nonnegative_int(payload, "requested_min_size")
        observed = required_nonnegative_int(payload, "observed_min_size")
        if expected_min_size is None or requested != expected_min_size or observed != expected_min_size:
            raise ValidationError(
                f"node-pool min was not confirmed at {expected_min_size}: "
                f"requested={requested}, observed={observed}"
            )
        observed_max = required_nonnegative_int(payload, "observed_max_size")
        if observed_max < observed:
            raise ValidationError("set-min evidence has max below observed min")
        changed = payload.get("changed")
        if not isinstance(changed, bool):
            raise ValidationError("set-min evidence requires boolean changed")
        if changed:
            required_string(payload, "task_id")
            if payload.get("task_state") != "success":
                raise ValidationError("set-min ACK task did not finish successfully")
    elif expected_action == "restore":
        if snapshot is None:
            raise ValidationError("restore validation requires snapshot evidence")
        observed = required_nonnegative_int(payload, "observed_min_size")
        original = required_nonnegative_int(snapshot, "min_size")
        if observed != original:
            raise ValidationError(f"restored min {observed} != original min {original}")
        if node_pool_id != required_string(snapshot, "node_pool_id"):
            raise ValidationError("restore evidence refers to a different node pool")
        observed_max = required_nonnegative_int(payload, "observed_max_size")
        original_max = required_nonnegative_int(snapshot, "max_size")
        if observed_max != original_max:
            raise ValidationError("restore evidence did not preserve node-pool max")
        if payload.get("prior_mutation_uncertain") is not False:
            raise ValidationError("restore cannot prove the prior mutation reached a terminal state")
        required_string(payload, "task_id")
        if payload.get("task_state") != "success":
            raise ValidationError("restore ACK task did not finish successfully")
        for key in (
            "cluster_id",
            "node_pool_id",
            "node_pool_name",
            "resource_group_id",
            "region_id",
            "api_server",
        ):
            if payload.get(key) != snapshot.get(key):
                raise ValidationError(f"restore evidence {key} differs from snapshot")
    else:
        raise ValidationError(f"unsupported control action: {expected_action}")
    return payload


def parse_summary(path: Path) -> tuple[str, dict[str, str]]:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise ValidationError(f"missing run summary: {path}") from exc
    match = SUMMARY_RESULT_RE.search(text)
    if not match:
        raise ValidationError(f"run summary has no result: {path}")
    values = {match.group("key"): match.group("value").strip(" `") for match in SUMMARY_VALUE_RE.finditer(text)}
    return match.group("result"), values


def read_ndjson(path: Path) -> list[dict[str, Any]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError as exc:
        raise ValidationError(f"missing NDJSON evidence: {path}") from exc
    result: list[dict[str, Any]] = []
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            value = json.loads(
                line,
                parse_constant=lambda constant: (_ for _ in ()).throw(
                    ValidationError(
                        f"non-finite JSON number {constant} at {path}:{number}"
                    )
                ),
            )
        except json.JSONDecodeError as exc:
            raise ValidationError(f"invalid NDJSON at {path}:{number}") from exc
        if not isinstance(value, dict):
            raise ValidationError(f"NDJSON item is not an object at {path}:{number}")
        result.append(value)
    return result


_MISSING = object()


def to_int(value: Any, *, default: Any = _MISSING) -> int:
    if value in (None, "") or str(value).strip().lower() == "null":
        if default is _MISSING:
            raise ValidationError("required integer is missing")
        return int(default)
    if isinstance(value, bool):
        raise ValidationError(f"expected integer, got {value!r}")
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"expected integer, got {value!r}") from exc
    if isinstance(value, float) and value != result:
        raise ValidationError(f"expected integer, got {value!r}")
    return result


def to_optional_int(value: Any) -> int | None:
    if value in (None, "") or str(value).strip().lower() == "null":
        return None
    return to_int(value)


def to_float(value: Any) -> float:
    if value in (None, "") or str(value).strip().lower() == "null":
        raise ValidationError("required number is missing")
    if isinstance(value, bool):
        raise ValidationError(f"expected number, got {value!r}")
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"expected number, got {value!r}") from exc
    if not math.isfinite(result):
        raise ValidationError(f"expected finite number, got {value!r}")
    return result


def to_optional_float(value: Any) -> float | None:
    if value in (None, "") or str(value).strip().lower() == "null":
        return None
    return to_float(value)


def nonnegative_float(value: Any, field: str) -> float:
    result = to_float(value)
    if result < 0:
        raise ValidationError(f"{field} must be non-negative")
    return result


def kubernetes_quantity(value: Any, *, cpu: bool) -> Decimal:
    text = str(value or "").strip()
    if not text:
        raise ValidationError("Kubernetes resource quantity is empty")
    suffixes = {
        "Ki": Decimal(1024),
        "Mi": Decimal(1024) ** 2,
        "Gi": Decimal(1024) ** 3,
        "Ti": Decimal(1024) ** 4,
        "K": Decimal(1000),
        "M": Decimal(1000) ** 2,
        "G": Decimal(1000) ** 3,
    }
    try:
        if cpu and text.endswith("m"):
            return Decimal(text[:-1]) / Decimal(1000)
        for suffix, multiplier in suffixes.items():
            if text.endswith(suffix):
                if cpu:
                    raise ValidationError(f"invalid CPU quantity: {text}")
                return Decimal(text[: -len(suffix)]) * multiplier
        return Decimal(text)
    except InvalidOperation as exc:
        raise ValidationError(f"invalid Kubernetes quantity: {text}") from exc


def require_quantity(actual: Any, expected: str, *, cpu: bool, field: str) -> None:
    if kubernetes_quantity(actual, cpu=cpu) != kubernetes_quantity(expected, cpu=cpu):
        raise ValidationError(f"workload {field} does not match the frozen factor")


def selected_pool_nodes(
    payload: dict[str, Any], selector_key: str, selector_value: str
) -> list[dict[str, Any]]:
    items = payload.get("items", [])
    if not isinstance(items, list):
        raise ValidationError("node snapshot does not contain an items array")
    return [item for item in items if node_labels(item).get(selector_key) == selector_value]


def pool_identities(
    payload: dict[str, Any], selector_key: str, selector_value: str
) -> list[dict[str, str]]:
    return sorted(
        (node_identity(item) for item in selected_pool_nodes(payload, selector_key, selector_value)),
        key=lambda item: item["name"],
    )


def snapshot_workload_pod(artifact_dir: Path) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    for path in sorted(artifact_dir.glob("pods-*.json")):
        payload = read_json(path)
        for pod in payload.get("items", []):
            if str(pod.get("metadata", {}).get("labels", {}).get("hooke.io/experiment", "")).lower() == "true":
                candidates.append(pod)
    unique = {str(item.get("metadata", {}).get("uid") or ""): item for item in candidates}
    unique.pop("", None)
    if len(unique) != 1:
        raise ValidationError(f"expected one snapshotted workload Pod, observed {len(unique)}")
    return next(iter(unique.values()))


def failure_attempts(
    path: Path,
    *,
    cluster_id: str,
    run_id: str,
    namespace: str,
    pod_uid: str,
    pod_name: str,
) -> dict[str, int]:
    attempts = {"POD_SANDBOX_FAILED": 0, "CNI_SETUP_FAILED": 0}
    seen: set[tuple[str, str]] = set()
    for row in read_tsv(path):
        event_type = row.get("event_type", "")
        if event_type not in attempts:
            continue
        if (
            row.get("cluster_id") != cluster_id
            or row.get("run_id") != run_id
            or row.get("namespace") != namespace
        ):
            raise ValidationError(f"{event_type} evidence is not bound to this run")
        row_uid = str(row.get("pod_uid") or "")
        row_name = str(row.get("pod_name") or "")
        if row_uid != pod_uid or row_name != pod_name:
            raise ValidationError(
                f"{event_type} evidence has an incomplete or conflicting Pod identity"
            )
        if event_type in attempts:
            event_uid = str(row.get("event_uid") or "")
            if not event_uid:
                raise ValidationError(f"{event_type} evidence has no event UID")
            key = (event_type, event_uid)
            if key in seen:
                raise ValidationError(f"duplicate failure evidence: {event_type}/{event_uid}")
            seen.add(key)
            count = to_int(row.get("attempts"))
            if count < 1:
                raise ValidationError(f"{event_type} attempts must be positive")
            attempts[event_type] += count
    return attempts


def scheduled_time(
    path: Path,
    *,
    cluster_id: str,
    run_id: str,
    namespace: str,
    pod_uid: str,
    pod_name: str,
    node_name: str,
) -> int:
    matches: list[int] = []
    for row in read_tsv(path):
        if row.get("pod_uid") != pod_uid or row.get("event_type") != "POD_SCHEDULED":
            continue
        if (
            row.get("cluster_id") != cluster_id
            or row.get("run_id") != run_id
            or row.get("namespace") != namespace
            or row.get("pod_name") != pod_name
            or row.get("node_name") != node_name
        ):
            raise ValidationError("POD_SCHEDULED evidence does not match the workload Pod/Node")
        event_time = to_int(row.get("event_time_ns"))
        if event_time <= 0:
            raise ValidationError("POD_SCHEDULED timestamp must be positive")
        matches.append(event_time)
    if len(matches) != 1:
        raise ValidationError(f"expected one POD_SCHEDULED row, observed {len(matches)}")
    return matches[0]


def exact_runtime_events(events: Iterable[dict[str, Any]], pod_uid: str, event_type: str) -> list[dict[str, Any]]:
    return [
        item
        for item in events
        if item.get("pod_uid") == pod_uid
        and item.get("event_type") == event_type
        and item.get("approximate") is False
    ]


def validate_run(
    *,
    variant: str,
    artifact_dir: Path,
    pool_before_path: Path,
    pool_after_path: Path,
    warm_state_path: Path | None,
    expected_cluster_id: str,
    expected_image: str,
    expected_instance_type: str,
    expected_zone: str,
    selector_key: str,
    selector_value: str,
    taint_key: str,
    taint_value: str,
    taint_effect: str,
    expected_command: list[str],
    expected_startup_work_mib: int,
    expected_cpu_request: str,
    expected_cpu_limit: str,
    expected_memory_request: str,
    expected_memory_limit: str,
    min_download_bytes: int,
    require_warm_cni: bool,
) -> dict[str, Any]:
    if variant not in VARIANTS:
        raise ValidationError(f"unsupported run variant: {variant}")
    if min_download_bytes < 1:
        raise ValidationError("minimum image download bytes must be positive")
    if expected_startup_work_mib < 0:
        raise ValidationError("startup work MiB must be non-negative")
    result, summary = parse_summary(artifact_dir / "summary.md")
    if result != "PASS":
        raise ValidationError(f"child Gate failed: {result}")
    run_id = str(summary.get("run_id") or "")
    if not run_id:
        raise ValidationError("child summary has no run_id")
    run_payload = read_json(artifact_dir / "run.json")
    if (
        run_payload.get("run_id") != run_id
        or run_payload.get("cluster_id") != expected_cluster_id
    ):
        raise ValidationError("run.json identity does not match the child summary/cluster")
    labels = run_payload.get("labels")
    if not isinstance(labels, dict):
        raise ValidationError("run.json has no experiment labels")
    if (
        labels.get("experiment") != "E02-node-warm-pool"
        or labels.get("phase") != "pilot"
        or labels.get("variant") != variant
        or labels.get("image_ref") != expected_image
        or labels.get("image_state") != "cold"
        or to_int(labels.get("replicas")) != 1
    ):
        raise ValidationError("run labels do not match the frozen E02 treatment")
    label_sequence = to_int(labels.get("sequence"))
    label_block = to_int(labels.get("block"))
    label_repetition = to_int(labels.get("repetition"))
    label_seed = to_int(labels.get("random_seed"))
    if min(label_sequence, label_block, label_repetition) < 1 or label_seed < 0:
        raise ValidationError("run labels contain an invalid schedule identity")
    image_build_commit = str(labels.get("image_build_commit") or "")
    orchestrator_commit = str(labels.get("orchestrator_commit") or "")
    if not image_build_commit or not orchestrator_commit:
        raise ValidationError("run labels have no build/orchestrator commit identity")

    traces = read_tsv(artifact_dir / "traces.tsv")
    if len(traces) != 1:
        raise ValidationError(f"expected one trace, observed {len(traces)}")
    trace = traces[0]
    if to_int(trace.get("complete")) != 1:
        raise ValidationError("trace is incomplete")
    if to_int(trace.get("invalid_order_count")) != 0:
        raise ValidationError("trace has invalid event order")
    exact_coverage = nonnegative_float(trace.get("exact_coverage"), "exact_coverage")
    if exact_coverage != 1.0:
        raise ValidationError("trace exact coverage is not 1")
    trace_node_ms_raw = to_optional_float(trace.get("node_ms"))
    if trace_node_ms_raw is not None and trace_node_ms_raw < 0:
        raise ValidationError("trace node_ms must be non-negative")
    if variant == "cold-node" and trace_node_ms_raw is None:
        raise ValidationError("cold run is missing node_ms")
    if variant == "warm-node" and trace_node_ms_raw is not None:
        raise ValidationError("warm run unexpectedly has node_ms")
    trace_image_ms = nonnegative_float(trace.get("image_ms"), "image_ms")
    trace_pod_ms = nonnegative_float(trace.get("pod_ms"), "pod_ms")
    trace_app_ms = nonnegative_float(trace.get("app_ms"), "app_ms")
    trace_total_ms_raw = nonnegative_float(trace.get("total_ms"), "total_ms")
    trace_overlap_ms_raw = nonnegative_float(trace.get("overlap_ms"), "overlap_ms")
    trace_unattributed_ms_raw = nonnegative_float(
        trace.get("unattributed_ms"), "unattributed_ms"
    )
    try:
        quality = json.loads(str(trace.get("quality") or ""))
    except json.JSONDecodeError as exc:
        raise ValidationError("trace quality is not valid JSON") from exc
    if not isinstance(quality, dict):
        raise ValidationError("trace quality is not an object")

    pod = snapshot_workload_pod(artifact_dir)
    pod_name = str(pod.get("metadata", {}).get("name") or "")
    pod_namespace = str(pod.get("metadata", {}).get("namespace") or "")
    pod_uid = str(pod.get("metadata", {}).get("uid") or "")
    scheduled_node = str(pod.get("spec", {}).get("nodeName") or "")
    if not pod_name or not pod_namespace or not pod_uid or not scheduled_node:
        raise ValidationError("workload Pod identity is incomplete")
    if trace.get("pod_name") != pod_name:
        raise ValidationError("trace Pod name does not match the snapshotted Pod")
    if trace.get("node_name") != scheduled_node:
        raise ValidationError("trace node does not match snapshotted Pod node")
    pod_metadata = pod.get("metadata", {})
    pod_labels = pod_metadata.get("labels") or {}
    pod_annotations = pod_metadata.get("annotations") or {}
    workload = str(pod_labels.get("app") or "")
    if (
        not workload
        or str(pod_labels.get("hooke.io/experiment", "")).lower() != "true"
        or pod_annotations.get("hooke.io/run-id") != run_id
        or not pod_namespace.startswith(f"e02-{variant}-")
    ):
        raise ValidationError("workload Pod metadata does not match the E02 treatment/run")

    namespace_evidence = read_json(artifact_dir / "experiment-namespace.json")
    if (
        namespace_evidence.get("name") != pod_namespace
        or namespace_evidence.get("run_id") != run_id
        or namespace_evidence.get("created_by_run") is not True
        or not namespace_evidence.get("uid")
    ):
        raise ValidationError("experiment Namespace ownership evidence is invalid")

    timings = read_tsv(artifact_dir / "orchestrator-timing.tsv")
    if len(timings) != 1:
        raise ValidationError(f"expected one orchestrator timing row, observed {len(timings)}")
    timing = timings[0]
    expected_path = "node-scale" if variant == "cold-node" else "fixed"
    if (
        timing.get("cluster_id") != expected_cluster_id
        or timing.get("run_id") != run_id
        or timing.get("namespace") != pod_namespace
        or timing.get("namespace_uid") != namespace_evidence.get("uid")
        or timing.get("workload") != workload
        or timing.get("path") != expected_path
        or timing.get("pod_uid") != pod_uid
        or timing.get("pod_name") != pod_name
        or to_int(timing.get("iteration")) != 1
        or to_int(timing.get("requested_replicas")) != 1
        or timing.get("clock_type") != "CLOCK_MONOTONIC"
        or timing.get("clock_source") != "python-time.monotonic_ns"
        or not timing.get("source_host")
        or not re.fullmatch(
            r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            str(timing.get("boot_id") or ""),
        )
    ):
        raise ValidationError("orchestrator timing identity/clock provenance is invalid")
    if any(to_int(timing.get(field)) != 0 for field in ("scale_rc", "rollout_rc", "evidence_rc")):
        raise ValidationError("measured scale/rollout did not complete successfully")
    start_monotonic_ns = to_int(timing.get("start_monotonic_ns"))
    end_monotonic_ns = to_int(timing.get("end_monotonic_ns"))
    if start_monotonic_ns <= 0 or end_monotonic_ns <= start_monotonic_ns:
        raise ValidationError("orchestrator timing interval is invalid")
    e2e_ms = (end_monotonic_ns - start_monotonic_ns) / 1_000_000
    deployment_uid = str(timing.get("deployment_uid") or "")
    replica_set_uid = str(timing.get("replica_set_uid") or "")
    replica_set_name = str(timing.get("replica_set_name") or "")
    generation_before = to_int(timing.get("deployment_generation_before"))
    generation_after = to_int(timing.get("deployment_generation_after"))
    observed_generation = to_int(timing.get("observed_generation"))
    if (
        not deployment_uid
        or not replica_set_uid
        or not replica_set_name
        or generation_before < 1
        or generation_after <= generation_before
        or observed_generation < generation_after
    ):
        raise ValidationError("measured Deployment rollout identity/generation is invalid")
    owner_references = pod_metadata.get("ownerReferences") or []
    if len(
        [
            owner
            for owner in owner_references
            if owner.get("kind") == "ReplicaSet"
            and owner.get("controller") is True
            and owner.get("uid") == replica_set_uid
            and owner.get("name") == replica_set_name
        ]
    ) != 1:
        raise ValidationError("workload Pod owner does not match measured ReplicaSet evidence")

    container_name = str(trace.get("container_name") or "")
    containers = pod.get("spec", {}).get("containers", [])
    target_containers = [item for item in containers if item.get("name") == container_name]
    if not container_name or len(target_containers) != 1:
        raise ValidationError("trace container does not identify one workload container")
    if target_containers[0].get("image") != expected_image:
        raise ValidationError("workload Pod image does not match the frozen digest")
    container_spec = target_containers[0]
    if (
        container_spec.get("imagePullPolicy") != "IfNotPresent"
        or container_spec.get("command") != expected_command
    ):
        raise ValidationError("workload image pull policy/command is not frozen")
    resources = container_spec.get("resources") or {}
    requests = resources.get("requests") or {}
    limits = resources.get("limits") or {}
    require_quantity(requests.get("cpu"), expected_cpu_request, cpu=True, field="CPU request")
    require_quantity(limits.get("cpu"), expected_cpu_limit, cpu=True, field="CPU limit")
    require_quantity(
        requests.get("memory"), expected_memory_request, cpu=False, field="memory request"
    )
    require_quantity(limits.get("memory"), expected_memory_limit, cpu=False, field="memory limit")
    env_values = {
        str(item.get("name") or ""): item.get("value")
        for item in container_spec.get("env") or []
        if isinstance(item, dict) and "value" in item
    }
    expected_env = {
        "HOOKE_CLUSTER_ID": expected_cluster_id,
        "HOOKE_RUN_ID": run_id,
        "HOOKE_STARTUP_WORK_MIB": str(expected_startup_work_mib),
        "HOOKE_WORKLOAD_KIND": "Deployment",
        "HOOKE_WORKLOAD_NAME": workload,
        "HOOKE_CONTAINER_NAME": container_name,
    }
    if any(env_values.get(key) != value for key, value in expected_env.items()):
        raise ValidationError("workload environment does not match the frozen factors/run")
    container_statuses = pod.get("status", {}).get("containerStatuses", [])
    target_statuses = [
        item
        for item in container_statuses
        if isinstance(item, dict) and item.get("name") == container_name
    ]
    if len(target_statuses) != 1:
        raise ValidationError("workload Pod snapshot has no unique target container status")
    container_id = str(target_statuses[0].get("containerID") or "")
    if not container_id.startswith("containerd://"):
        raise ValidationError("target container does not have a containerd container ID")
    container_id = container_id.removeprefix("containerd://")
    if not container_id:
        raise ValidationError("target container ID is empty")
    expected_digest = expected_image.rsplit("@", 1)[-1].lower()
    if pod.get("spec", {}).get("nodeSelector", {}).get(selector_key) != selector_value:
        raise ValidationError("workload Pod does not target the frozen elastic-pool selector")
    expected_toleration = {"key": taint_key, "value": taint_value, "effect": taint_effect}
    tolerations = pod.get("spec", {}).get("tolerations", [])
    if not isinstance(tolerations, list) or not any(
        all(item.get(field) == expected for field, expected in expected_toleration.items())
        and item.get("operator", "Equal") == "Equal"
        for item in tolerations
        if isinstance(item, dict)
    ):
        raise ValidationError("workload Pod has no exact elastic-pool toleration")

    before = pool_identities(read_json(pool_before_path), selector_key, selector_value)
    after_payload = read_json(pool_after_path)
    after_nodes = selected_pool_nodes(after_payload, selector_key, selector_value)
    after = sorted((node_identity(item) for item in after_nodes), key=lambda item: item["name"])
    after_by_name = {
        node_identity(item)["name"]: item for item in after_nodes
    }
    if variant == "cold-node":
        if before:
            raise ValidationError(f"cold run started with {len(before)} elastic Node(s)")
        if len(after) != 1:
            raise ValidationError(f"cold run must add exactly one elastic Node, observed {len(after)}")
        if after[0]["name"] != scheduled_node:
            raise ValidationError("cold workload was not scheduled on the new elastic Node")
        if not after[0]["uid"] or not after[0]["provider_id"]:
            raise ValidationError("new elastic Node identity is incomplete")
        if to_int(summary.get("exact_node_samples")) != 1:
            raise ValidationError("cold run does not have one exact Node sample")
        if to_int(summary.get("new_elastic_nodes")) != 1:
            raise ValidationError("cold run did not report one new elastic Node")
    else:
        if len(before) != 1 or len(after) != 1:
            raise ValidationError("warm run requires exactly one elastic Node before and after")
        if before != after:
            raise ValidationError("warm elastic Node identity changed during the run")
        if before[0]["name"] != scheduled_node:
            raise ValidationError("warm workload was not scheduled on the baseline Node")
        if warm_state_path is None:
            raise ValidationError("warm run requires pre-run state evidence")
        warm_state = read_json(warm_state_path)
        if (
            warm_state.get("valid") is not True
            or warm_state.get("mode") != "warm-node"
            or warm_state.get("selected_node_count") != 1
            or warm_state.get("selector") != f"{selector_key}={selector_value}"
            or warm_state.get("instance_type") != expected_instance_type
            or warm_state.get("zone") != expected_zone
            or warm_state.get("taint") != expected_toleration
            or warm_state.get("residual_experiment_pods") != []
            or warm_state.get("non_daemon_workloads") != []
        ):
            raise ValidationError("warm state evidence is incomplete or inconsistent")
        if warm_state.get("node") != before[0]:
            raise ValidationError("warm state evidence does not match the baseline Node")
        if require_warm_cni:
            cni_pods = warm_state.get("cni_ready_pods")
            if not isinstance(cni_pods, list) or not cni_pods:
                raise ValidationError("warm state has no Ready CNI Pod evidence")
        if to_int(summary.get("node_layer_samples")) != 0:
            raise ValidationError("warm run unexpectedly contains a Node layer sample")
        if to_int(summary.get("pod_unschedulable_events")) != 0:
            raise ValidationError("warm run emitted POD_UNSCHEDULABLE")
        if to_int(summary.get("provision_requested_events")) != 0:
            raise ValidationError("warm run triggered ACK node provisioning")

    node = after_by_name.get(scheduled_node)
    if node is None:
        raise ValidationError("scheduled node is absent from post-run pool snapshot")
    labels = node_labels(node)
    instance_type = labels.get("node.kubernetes.io/instance-type", "")
    zone = labels.get("topology.kubernetes.io/zone", "")
    if instance_type != expected_instance_type:
        raise ValidationError(f"run instance type mismatch: {instance_type} != {expected_instance_type}")
    if zone != expected_zone:
        raise ValidationError(f"run zone mismatch: {zone} != {expected_zone}")
    require_taint(node, taint_key, taint_value, taint_effect)
    node_uid = str(node.get("metadata", {}).get("uid") or "")
    provider_id = str(node.get("spec", {}).get("providerID") or "")
    if not node_uid or not provider_id:
        raise ValidationError("scheduled Node identity is incomplete")

    pod_start_event = str(quality.get("pod_start_event") or "")
    image_start_event = str(quality.get("image_start_event") or "")
    image_end_event = str(quality.get("image_end_event") or "")
    app_end_event = str(quality.get("app_end_event") or "")
    if (
        pod_start_event not in {"POD_SANDBOX_START", "SYNC_POD_START"}
        or image_start_event != "IMAGE_PULL_START"
        or image_end_event not in {"IMAGE_PULL_END", "IMAGE_UNPACK_END"}
        or app_end_event != "READINESS_PROBE_FIRST_SUCCESS"
    ):
        raise ValidationError("trace selected unsupported/non-exact layer endpoints")

    runtime_events = read_ndjson(artifact_dir / "runtime-events.ndjson")
    exact_by_type: dict[str, dict[str, Any]] = {}
    required_event_types = {
        "POD_SANDBOX_START",
        "POD_SANDBOX_END",
        "IMAGE_PULL_START",
        "IMAGE_PULL_END",
        "CONTAINER_STARTED",
        "READINESS_PROBE_FIRST_SUCCESS",
        pod_start_event,
        image_end_event,
    }
    seen_event_ids: set[str] = set()
    for event_type in sorted(required_event_types):
        matches = exact_runtime_events(runtime_events, pod_uid, event_type)
        if len(matches) != 1:
            raise ValidationError(
                f"expected one exact {event_type} for workload Pod, observed {len(matches)}"
            )
        item = matches[0]
        required_identity = {
            "cluster_id": expected_cluster_id,
            "run_id": run_id,
            "pod_name": pod_name,
            "namespace": pod_namespace,
            "node_name": scheduled_node,
            "node_uid": node_uid,
        }
        for key, expected in required_identity.items():
            if item.get(key) != expected:
                raise ValidationError(f"{event_type} {key} does not match run evidence")
        event_time_ns = to_int(item.get("event_time_ns"))
        event_id = str(item.get("event_id") or "")
        if event_time_ns <= 0:
            raise ValidationError(f"{event_type} timestamp must be positive")
        if not EVENT_ID_RE.fullmatch(event_id):
            raise ValidationError(
                f"{event_type} event ID is not a 26-character Crockford identifier"
            )
        if event_id in seen_event_ids:
            raise ValidationError(f"{event_type} has a duplicate event ID")
        seen_event_ids.add(event_id)
        if (
            item.get("clock_type") != "realtime"
            or to_int(item.get("source_time_ns")) != event_time_ns
            or item.get("source_instance") != scheduled_node
        ):
            raise ValidationError(f"{event_type} has invalid runtime clock provenance")
        exact_by_type[event_type] = item
    selected_event_ids = {
        pod_start_event: str(quality.get("pod_start_event_id") or ""),
        "IMAGE_PULL_START": str(quality.get("image_start_event_id") or ""),
        image_end_event: str(quality.get("image_end_event_id") or ""),
        "CONTAINER_STARTED": str(quality.get("container_started_event_id") or ""),
        "READINESS_PROBE_FIRST_SUCCESS": str(quality.get("app_end_event_id") or ""),
    }
    for event_type, selected_event_id in selected_event_ids.items():
        if not selected_event_id or exact_by_type[event_type].get("event_id") != selected_event_id:
            raise ValidationError(f"trace {event_type} event ID does not match exact evidence")
    cache_hits = [
        item
        for item in runtime_events
        if item.get("pod_uid") == pod_uid and item.get("event_type") == "IMAGE_CACHE_HIT"
    ]
    if cache_hits:
        raise ValidationError("target image was a cache hit; E02 requires cold image in both variants")
    sandbox_id = ""
    for event_type in ("POD_SANDBOX_START", "POD_SANDBOX_END"):
        item = exact_by_type[event_type]
        attributes = item.get("attributes")
        if (
            item.get("source_component") != "containerd-cri-journal"
            or not isinstance(attributes, dict)
            or attributes.get("precision") != "containerd-cri-journal"
            or attributes.get("runtime_operation") != "RunPodSandbox"
            or attributes.get("association") != "pod-uid+sandbox-id"
            or not str(attributes.get("sandbox_id") or "")
        ):
            raise ValidationError(f"{event_type} has invalid sandbox provenance")
        current_sandbox_id = str(attributes["sandbox_id"])
        if sandbox_id and current_sandbox_id != sandbox_id:
            raise ValidationError("sandbox start/end evidence uses different sandbox IDs")
        sandbox_id = current_sandbox_id

    for event_type in ("IMAGE_PULL_START", "IMAGE_PULL_END", "CONTAINER_STARTED"):
        item = exact_by_type[event_type]
        attributes = item.get("attributes")
        expected_operation = "PullImage" if event_type.startswith("IMAGE_PULL") else "StartContainer"
        if (
            item.get("source_component") != "containerd-cri-journal"
            or item.get("container_name") != container_name
            or item.get("container_id") != container_id
            or item.get("image_ref") != expected_image
            or str(item.get("image_digest") or "").lower() != expected_digest
            or not isinstance(attributes, dict)
            or attributes.get("precision") != "containerd-cri-journal"
            or attributes.get("runtime_operation") != expected_operation
            or attributes.get("association") != "pod-uid+sandbox-id+container-id"
            or attributes.get("sandbox_id") != sandbox_id
        ):
            raise ValidationError(f"{event_type} has invalid container runtime provenance")
    if image_end_event == "IMAGE_UNPACK_END":
        unpack = exact_by_type[image_end_event]
        if (
            unpack.get("source_component") != "containerd-cri-journal"
            or unpack.get("container_name") != container_name
            or unpack.get("container_id") != container_id
            or unpack.get("image_ref") != expected_image
            or str(unpack.get("image_digest") or "").lower() != expected_digest
        ):
            raise ValidationError("IMAGE_UNPACK_END has invalid container/image provenance")
    if exact_by_type["IMAGE_PULL_START"].get("result") != "started":
        raise ValidationError("IMAGE_PULL_START result is not started")
    if exact_by_type["IMAGE_PULL_END"].get("result") != "success":
        raise ValidationError("IMAGE_PULL_END result is not success")
    if exact_by_type["CONTAINER_STARTED"].get("result") != "success":
        raise ValidationError("CONTAINER_STARTED result is not success")

    readiness = exact_by_type["READINESS_PROBE_FIRST_SUCCESS"]
    readiness_attributes = readiness.get("attributes")
    if (
        readiness.get("source_component") != "application-event-log"
        or readiness.get("container_name") != container_name
        or readiness.get("container_id") != container_id
        or readiness.get("image_ref") != expected_image
        or str(readiness.get("image_digest") or "").lower() != expected_digest
        or not isinstance(readiness_attributes, dict)
        or readiness_attributes.get("precision") != "application-source-timestamp"
        or readiness_attributes.get("persistence") != "container-stdout"
    ):
        raise ValidationError("READINESS_PROBE_FIRST_SUCCESS has invalid application provenance")
    pull_end_attributes = exact_by_type["IMAGE_PULL_END"].get("attributes")
    if not isinstance(pull_end_attributes, dict):
        raise ValidationError("IMAGE_PULL_END has no attributes object")
    image_download_bytes = to_int(pull_end_attributes.get("download_bytes"))
    if image_download_bytes < min_download_bytes:
        raise ValidationError(
            f"image download bytes {image_download_bytes} are below cold-image floor "
            f"{min_download_bytes}"
        )

    failures = failure_attempts(
        artifact_dir / "sandbox-failures.tsv",
        cluster_id=expected_cluster_id,
        run_id=run_id,
        namespace=pod_namespace,
        pod_uid=pod_uid,
        pod_name=pod_name,
    )
    expected_failure_summary = {
        "POD_SANDBOX_FAILED": ("sandbox_failure_attempts", "sandbox_failed_pods"),
        "CNI_SETUP_FAILED": ("cni_failure_attempts", "cni_failed_pods"),
    }
    for event_type, (attempt_field, pod_field) in expected_failure_summary.items():
        attempts = failures[event_type]
        if (
            to_int(summary.get(attempt_field)) != attempts
            or to_int(summary.get(pod_field)) != (1 if attempts else 0)
        ):
            raise ValidationError(f"summary does not reconcile {event_type} evidence")
    if variant == "warm-node" and any(failures.values()):
        raise ValidationError(
            "warm capacity had sandbox/CNI failures: " + json.dumps(failures, sort_keys=True)
        )

    timestamps = read_tsv(artifact_dir / "trace-timestamps.tsv")
    timestamp_rows = [row for row in timestamps if row.get("pod_uid") == pod_uid]
    if len(timestamp_rows) != 1:
        raise ValidationError("expected one trace timestamp row")
    timestamp = timestamp_rows[0]
    if timestamp.get("pod_name") != pod_name or timestamp.get("node_name") != scheduled_node:
        raise ValidationError("trace timestamp row does not match the workload Pod/Node")
    sandbox_start_ns = to_int(timestamp.get("pod_sandbox_start_ns"))
    sandbox_end_ns = to_int(timestamp.get("pod_sandbox_end_ns"))
    if sandbox_start_ns <= 0 or sandbox_end_ns < sandbox_start_ns:
        raise ValidationError("invalid successful sandbox timestamps")
    runtime_sandbox_start_ns = to_int(exact_by_type["POD_SANDBOX_START"].get("event_time_ns"))
    runtime_sandbox_end_ns = to_int(exact_by_type["POD_SANDBOX_END"].get("event_time_ns"))
    if (sandbox_start_ns, sandbox_end_ns) != (
        runtime_sandbox_start_ns,
        runtime_sandbox_end_ns,
    ):
        raise ValidationError("trace sandbox timestamps do not match exact runtime evidence")
    image_start_ns = to_int(exact_by_type["IMAGE_PULL_START"].get("event_time_ns"))
    pull_end_ns = to_int(exact_by_type["IMAGE_PULL_END"].get("event_time_ns"))
    image_end_ns = to_int(exact_by_type[image_end_event].get("event_time_ns"))
    sync_pod_start_ns = to_int(exact_by_type[pod_start_event].get("event_time_ns"))
    if pull_end_ns < image_start_ns or image_end_ns < pull_end_ns:
        raise ValidationError("IMAGE_PULL_END precedes IMAGE_PULL_START")
    container_started_ns = to_int(exact_by_type["CONTAINER_STARTED"].get("event_time_ns"))
    readiness_ns = to_int(readiness.get("event_time_ns"))
    if not (
        sandbox_start_ns <= sync_pod_start_ns <= container_started_ns
        and sandbox_end_ns <= image_start_ns <= image_end_ns <= container_started_ns <= readiness_ns
    ):
        raise ValidationError("runtime/application event order is inconsistent")
    timestamp_bindings = {
        "pod_sandbox_start_ns": sandbox_start_ns,
        "pod_sandbox_end_ns": sandbox_end_ns,
        "image_pull_start_ns": image_start_ns,
        "image_pull_end_ns": pull_end_ns,
        "sync_pod_start_ns": sync_pod_start_ns,
        "container_started_ns": container_started_ns,
        "readiness_success_ns": readiness_ns,
    }
    for field, expected in timestamp_bindings.items():
        if to_int(timestamp.get(field)) != expected:
            raise ValidationError(f"trace {field} does not match exact event evidence")
    unpack_timestamp = to_optional_int(timestamp.get("image_unpack_end_ns"))
    if image_end_event == "IMAGE_UNPACK_END":
        if unpack_timestamp != image_end_ns:
            raise ValidationError("trace image unpack end does not match exact event evidence")
    elif unpack_timestamp is not None:
        raise ValidationError("trace selected PullImage end but has an unexpected unpack endpoint")
    exact_image_ms = (image_end_ns - image_start_ns) / 1_000_000
    if not math.isclose(trace_image_ms, exact_image_ms, rel_tol=0, abs_tol=0.000501):
        raise ValidationError("trace image_ms does not match selected exact image endpoints")
    exact_pod_ms = (container_started_ns - sync_pod_start_ns) / 1_000_000
    if not math.isclose(trace_pod_ms, exact_pod_ms, rel_tol=0, abs_tol=0.000501):
        raise ValidationError("trace pod_ms does not match selected exact Pod endpoints")
    exact_app_ms = (readiness_ns - container_started_ns) / 1_000_000
    if not math.isclose(trace_app_ms, exact_app_ms, rel_tol=0, abs_tol=0.000501):
        raise ValidationError("trace app_ms does not match exact container/readiness endpoints")
    trigger_time_ns = to_int(timestamp.get("trigger_time_ns"))
    if trigger_time_ns <= 0 or readiness_ns < trigger_time_ns:
        raise ValidationError("trace raw total endpoints are invalid")
    calculated_trace_total_ms = (readiness_ns - trigger_time_ns) / 1_000_000
    if not math.isclose(
        trace_total_ms_raw, calculated_trace_total_ms, rel_tol=0, abs_tol=0.000501
    ):
        raise ValidationError("trace total_ms does not match its raw mixed-clock endpoints")
    scheduled_time(
        artifact_dir / "pod-lifecycle-events.tsv",
        cluster_id=expected_cluster_id,
        run_id=run_id,
        namespace=pod_namespace,
        pod_uid=pod_uid,
        pod_name=pod_name,
        node_name=scheduled_node,
    )
    # POD_SCHEDULED is a Kubernetes timestamp and sandbox timestamps come from
    # the node runtime journal.  No calibration evidence currently links those
    # clocks, so retain the raw artifacts but do not manufacture an interval.
    scheduled_to_start_ms: float | None = None
    scheduled_to_end_ms: float | None = None

    node_start_ns = to_optional_int(timestamp.get("node_start_ns"))
    node_ready_ns = to_optional_int(timestamp.get("node_ready_ns"))
    node_to_sandbox_start_ms: float | None = None
    node_to_sandbox_end_ms: float | None = None
    node_sandbox_clock_known: bool | None = None
    if variant == "cold-node":
        if (
            node_start_ns is None
            or node_ready_ns is None
            or node_start_ns <= 0
            or node_ready_ns < node_start_ns
        ):
            raise ValidationError("cold run has invalid raw Node endpoints")
        calculated_trace_node_ms = (node_ready_ns - node_start_ns) / 1_000_000
        if trace_node_ms_raw is None or not math.isclose(
            trace_node_ms_raw, calculated_trace_node_ms, rel_tol=0, abs_tol=0.000501
        ):
            raise ValidationError("trace node_ms does not match its raw mixed-clock endpoints")
        # NODE_READY comes from the Kubernetes/control-plane evidence while
        # sandbox times come from the node journal.  Boolean uncertainty flags
        # do not prove a shared clock domain or supply an offset calibration.
        # Preserve both raw timestamps, but never derive a cross-source delta.
        node_sandbox_clock_known = False
    elif node_start_ns is not None or node_ready_ns is not None:
        raise ValidationError("warm run unexpectedly has Node layer timestamps")

    return {
        "valid": True,
        "variant": variant,
        "cluster_id": expected_cluster_id,
        "run_id": run_id,
        "sequence": label_sequence,
        "block": label_block,
        "repetition": label_repetition,
        "random_seed": label_seed,
        "image": expected_image,
        "image_build_commit": image_build_commit,
        "orchestrator_commit": orchestrator_commit,
        "artifact_dir": str(artifact_dir),
        "namespace": pod_namespace,
        "namespace_uid": namespace_evidence["uid"],
        "workload": workload,
        "deployment_uid": deployment_uid,
        "replica_set_uid": replica_set_uid,
        "pod_uid": pod_uid,
        "pod_name": pod_name,
        "node_name": scheduled_node,
        "node_uid": node_uid,
        "provider_id": provider_id,
        "instance_type": instance_type,
        "zone": zone,
        "complete": True,
        "exact_coverage": exact_coverage,
        "node_ms": None,
        "image_ms": exact_image_ms,
        "pod_ms": exact_pod_ms,
        "app_ms": exact_app_ms,
        "e2e_ms": e2e_ms,
        "orchestrator_rollout_ms": e2e_ms,
        "overlap_ms": None,
        "unattributed_ms": None,
        "trace_node_ms_raw": trace_node_ms_raw,
        "trace_total_ms_raw": trace_total_ms_raw,
        "trace_overlap_ms_raw": trace_overlap_ms_raw,
        "trace_unattributed_ms_raw": trace_unattributed_ms_raw,
        "image_download_bytes": image_download_bytes,
        "sandbox_failure_attempts": failures["POD_SANDBOX_FAILED"],
        "cni_failure_attempts": failures["CNI_SETUP_FAILED"],
        "scheduled_to_sandbox_start_ms": scheduled_to_start_ms,
        "scheduled_to_sandbox_end_ms": scheduled_to_end_ms,
        "scheduled_sandbox_clock_known": False,
        "node_ready_to_sandbox_start_ms": node_to_sandbox_start_ms,
        "node_ready_to_sandbox_end_ms": node_to_sandbox_end_ms,
        "node_sandbox_clock_known": node_sandbox_clock_known,
    }


OBSERVATION_FIELDS = [
    "sequence",
    "block",
    "variant",
    "repetition",
    "random_seed",
    "cluster_id",
    "run_id",
    "image",
    "image_build_commit",
    "orchestrator_commit",
    "namespace",
    "namespace_uid",
    "workload",
    "deployment_uid",
    "replica_set_uid",
    "node_name",
    "node_uid",
    "provider_id",
    "instance_type",
    "zone",
    "complete",
    "exact_coverage",
    "node_ms",
    "image_ms",
    "pod_ms",
    "app_ms",
    "e2e_ms",
    "orchestrator_rollout_ms",
    "overlap_ms",
    "unattributed_ms",
    "trace_node_ms_raw",
    "trace_total_ms_raw",
    "trace_overlap_ms_raw",
    "trace_unattributed_ms_raw",
    "image_download_bytes",
    "sandbox_failure_attempts",
    "cni_failure_attempts",
    "scheduled_to_sandbox_start_ms",
    "scheduled_to_sandbox_end_ms",
    "scheduled_sandbox_clock_known",
    "node_ready_to_sandbox_start_ms",
    "node_ready_to_sandbox_end_ms",
    "node_sandbox_clock_known",
    "artifact_dir",
]


def describe(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "min": None, "median": None, "max": None}
    return {
        "count": len(values),
        "min": min(values),
        "median": statistics.median(values),
        "max": max(values),
    }


def summarize_runs(
    index_path: Path,
    expected_repetitions: int,
    schedule_path: Path,
    expected_seed: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    if expected_repetitions < 1:
        raise ValidationError("expected repetitions must be positive")
    index = read_tsv(index_path)
    expected = expected_repetitions * len(VARIANTS)
    if len(index) != expected:
        raise ValidationError(f"run index has {len(index)} rows, expected {expected}")
    schedule = read_tsv(schedule_path)
    generated_schedule = generate_schedule(expected_repetitions, expected_seed)
    normalized_schedule = [
        {
            "sequence": to_int(row.get("sequence")),
            "block": to_int(row.get("block")),
            "variant": str(row.get("variant") or ""),
            "repetition": to_int(row.get("repetition")),
        }
        for row in schedule
    ]
    if normalized_schedule != generated_schedule:
        raise ValidationError("schedule evidence does not match the frozen seed/design")
    index_schedule = [
        {
            "sequence": to_int(row.get("sequence")),
            "block": to_int(row.get("block")),
            "variant": str(row.get("variant") or ""),
            "repetition": to_int(row.get("repetition")),
        }
        for row in index
    ]
    if index_schedule != generated_schedule:
        raise ValidationError("run index order does not match schedule evidence")
    observations: list[dict[str, Any]] = []
    seen_keys: set[tuple[str, int]] = set()
    seen_sequences: set[int] = set()
    seen_run_ids: set[str] = set()
    seen_cluster_ids: set[str] = set()
    seen_images: set[str] = set()
    seen_image_commits: set[str] = set()
    seen_orchestrator_commits: set[str] = set()
    seen_artifacts: set[Path] = set()
    seen_validations: set[Path] = set()
    for row in index:
        variant = row.get("variant", "")
        repetition = to_int(row.get("repetition"))
        block = to_int(row.get("block"))
        sequence = to_int(row.get("sequence"))
        key = (variant, repetition)
        if variant not in VARIANTS or key in seen_keys:
            raise ValidationError(f"invalid or duplicate run index key: {key}")
        if repetition < 1 or repetition > expected_repetitions or block != repetition:
            raise ValidationError(f"run index has invalid block/repetition for {key}")
        if sequence < 1 or sequence > expected or sequence in seen_sequences:
            raise ValidationError(f"invalid or duplicate sequence: {sequence}")
        artifact_text = str(row.get("artifact_dir") or "")
        validation_text = str(row.get("validation") or "")
        if not artifact_text or not validation_text:
            raise ValidationError(f"run index is missing artifact/validation path for {key}")
        artifact_path = Path(artifact_text).resolve()
        validation_path = Path(validation_text).resolve()
        if artifact_path in seen_artifacts or validation_path in seen_validations:
            raise ValidationError(f"run index reuses artifact or validation evidence for {key}")
        validation = read_json(validation_path)
        if validation.get("valid") is not True or validation.get("variant") != variant:
            raise ValidationError(f"invalid run validation for {key}")
        if (
            to_int(validation.get("sequence")) != sequence
            or to_int(validation.get("block")) != block
            or to_int(validation.get("repetition")) != repetition
            or to_int(validation.get("random_seed")) != expected_seed
        ):
            raise ValidationError(f"run labels do not match the indexed schedule for {key}")
        run_id = str(validation.get("run_id") or "")
        cluster_id = str(validation.get("cluster_id") or "")
        if not run_id or run_id in seen_run_ids:
            raise ValidationError(f"missing or duplicate run_id for {key}: {run_id!r}")
        if not cluster_id:
            raise ValidationError(f"validation has no cluster_id for {key}")
        validation_artifact = str(validation.get("artifact_dir") or "")
        if not validation_artifact or Path(validation_artifact).resolve() != artifact_path:
            raise ValidationError(f"validation artifact path does not match run index for {key}")
        if validation.get("complete") is not True or to_float(
            validation.get("exact_coverage")
        ) != 1.0:
            raise ValidationError(f"validation is incomplete or inexact for {key}")
        seen_keys.add(key)
        seen_sequences.add(sequence)
        seen_run_ids.add(run_id)
        seen_cluster_ids.add(cluster_id)
        seen_images.add(str(validation.get("image") or ""))
        seen_image_commits.add(str(validation.get("image_build_commit") or ""))
        seen_orchestrator_commits.add(str(validation.get("orchestrator_commit") or ""))
        seen_artifacts.add(artifact_path)
        seen_validations.add(validation_path)
        observation = dict(validation)
        observation.update(
            {
                "sequence": sequence,
                "block": block,
                "variant": variant,
                "repetition": repetition,
            }
        )
        observations.append(observation)
    expected_keys = {
        (variant, repetition)
        for variant in VARIANTS
        for repetition in range(1, expected_repetitions + 1)
    }
    if seen_keys != expected_keys:
        raise ValidationError("run index does not contain the complete variant/repetition grid")
    if seen_sequences != set(range(1, expected + 1)):
        raise ValidationError("run index sequences are not unique and contiguous")
    if len(seen_cluster_ids) != 1:
        raise ValidationError("run validations do not belong to one cluster")
    if (
        len(seen_images) != 1
        or "" in seen_images
        or len(seen_image_commits) != 1
        or "" in seen_image_commits
        or len(seen_orchestrator_commits) != 1
        or "" in seen_orchestrator_commits
    ):
        raise ValidationError("run validations do not share one frozen image/build/orchestrator")
    observations.sort(key=lambda item: item["sequence"])

    by_block: dict[int, dict[str, dict[str, Any]]] = {}
    for observation in observations:
        by_block.setdefault(int(observation["block"]), {})[observation["variant"]] = observation
    if set(by_block) != set(range(1, expected_repetitions + 1)) or any(
        set(pair) != set(VARIANTS) for pair in by_block.values()
    ):
        raise ValidationError("each paired block must contain exactly one cold and one warm run")
    for block, pair in by_block.items():
        observed_sequences = {int(item["sequence"]) for item in pair.values()}
        expected_sequences = {2 * block - 1, 2 * block}
        if observed_sequences != expected_sequences:
            raise ValidationError(
                f"paired block {block} is not adjacent in the randomized schedule"
            )

    variants: dict[str, Any] = {}
    for variant in VARIANTS:
        selected = [item for item in observations if item["variant"] == variant]
        metrics: dict[str, Any] = {}
        for key in (
            "node_ms",
            "image_ms",
            "pod_ms",
            "app_ms",
            "e2e_ms",
            "overlap_ms",
            "unattributed_ms",
            "scheduled_to_sandbox_start_ms",
            "scheduled_to_sandbox_end_ms",
            "node_ready_to_sandbox_start_ms",
            "node_ready_to_sandbox_end_ms",
        ):
            values = [
                nonnegative_float(item[key], key)
                for item in selected
                if item.get(key) is not None
            ]
            metrics[key] = describe(values)
        variants[variant] = {
            "runs": len(selected),
            "complete_runs": sum(1 for item in selected if item.get("complete")),
            "sandbox_failure_attempts": sum(int(item["sandbox_failure_attempts"]) for item in selected),
            "cni_failure_attempts": sum(int(item["cni_failure_attempts"]) for item in selected),
            "image_download_bytes": describe(
                [float(to_int(item["image_download_bytes"])) for item in selected]
            ),
            "metrics_ms": metrics,
        }
    paired: list[dict[str, Any]] = []
    for block in range(1, expected_repetitions + 1):
        cold = by_block[block]["cold-node"]
        warm = by_block[block]["warm-node"]
        cold_e2e = nonnegative_float(cold.get("e2e_ms"), "cold e2e_ms")
        warm_e2e = nonnegative_float(warm.get("e2e_ms"), "warm e2e_ms")
        reduction = cold_e2e - warm_e2e
        paired.append(
            {
                "block": block,
                "cold_run_id": cold["run_id"],
                "warm_run_id": warm["run_id"],
                "cold_e2e_ms": cold_e2e,
                "warm_e2e_ms": warm_e2e,
                "e2e_reduction_ms": reduction,
                "e2e_reduction_ratio": reduction / cold_e2e if cold_e2e > 0 else None,
            }
        )
    reduction_ms = [float(item["e2e_reduction_ms"]) for item in paired]
    reduction_ratios = [
        float(item["e2e_reduction_ratio"])
        for item in paired
        if item["e2e_reduction_ratio"] is not None
    ]
    comparison = {
        "paired_blocks": paired,
        "paired_e2e_reduction_ms": describe(reduction_ms),
        "paired_e2e_reduction_ratio": describe(reduction_ratios),
        "median_e2e_reduction_ms": statistics.median(reduction_ms),
        "median_e2e_reduction_ratio": (
            statistics.median(reduction_ratios) if reduction_ratios else None
        ),
    }
    summary = {
        "experiment": "E02-node-warm-pool",
        "phase": "pilot",
        "expected_repetitions_per_variant": expected_repetitions,
        "random_seed": expected_seed,
        "total_runs": len(observations),
        "variants": variants,
        "comparison": comparison,
        "percentiles_suppressed": ["p95", "p99"],
        "e2e_definition": "operator-host CLOCK_MONOTONIC scale request to successful Deployment rollout",
        "audit_only_raw_fields": [
            "trace_node_ms_raw",
            "trace_total_ms_raw",
            "trace_overlap_ms_raw",
            "trace_unattributed_ms_raw",
        ],
        "clock_note": (
            "Paired e2e_ms is the operator-host CLOCK_MONOTONIC scale-to-rollout interval. "
            "Uncalibrated trace node/total/overlap/unattributed values are audit-only raw "
            "fields; scientific interval fields are null and excluded from aggregates."
        ),
    }
    return observations, summary


def command_schedule(args: argparse.Namespace) -> int:
    rows = generate_schedule(args.repetitions, args.seed)
    write_tsv(args.output, rows, ["sequence", "block", "variant", "repetition"])
    return 0


def command_microtime(_args: argparse.Namespace) -> int:
    sys.stdout.write(format_kubernetes_microtime() + "\n")
    return 0


def command_validate_state(args: argparse.Namespace) -> int:
    try:
        payload = validate_pool_state(
            mode=args.mode,
            nodes_payload=read_json(args.nodes),
            pods_payload=read_json(args.pods),
            cni_payload=read_json(args.cni) if args.cni else None,
            selector_key=args.selector_key,
            selector_value=args.selector_value,
            expected_instance_type=args.instance_type,
            expected_zone=args.zone,
            taint_key=args.taint_key,
            taint_value=args.taint_value,
            taint_effect=args.taint_effect,
            require_cni=args.require_cni,
        )
    except ValidationError as exc:
        write_json(args.output, {"valid": False, "mode": args.mode, "reason": str(exc)})
        raise
    write_json(args.output, payload)
    return 0


def command_validate_control(args: argparse.Namespace) -> int:
    payload = read_json(args.evidence)
    snapshot = read_json(args.snapshot) if args.snapshot else None
    validate_control_evidence(
        payload,
        expected_action=args.action,
        expected_cluster_id=args.cluster_id,
        expected_node_pool_id=args.node_pool_id,
        expected_node_pool_name=args.node_pool_name,
        expected_resource_group_id=args.resource_group_id,
        expected_region_id=args.region_id,
        expected_api_server=args.api_server,
        expected_selector_key=args.selector_key,
        expected_selector_value=args.selector_value,
        expected_taint_key=args.taint_key,
        expected_taint_value=args.taint_value,
        expected_taint_effect=args.taint_effect,
        expected_min_size=args.min_size,
        snapshot=snapshot,
    )
    return 0


def command_validate_run(args: argparse.Namespace) -> int:
    try:
        expected_command = json.loads(args.command_json)
    except json.JSONDecodeError as exc:
        raise ValidationError("--command-json must be valid JSON") from exc
    if not isinstance(expected_command, list) or not all(
        isinstance(item, str) for item in expected_command
    ):
        raise ValidationError("--command-json must be an array of strings")
    payload = validate_run(
        variant=args.variant,
        artifact_dir=args.artifact_dir,
        pool_before_path=args.pool_before,
        pool_after_path=args.pool_after,
        warm_state_path=args.warm_state,
        expected_cluster_id=args.cluster_id,
        expected_image=args.image,
        expected_instance_type=args.instance_type,
        expected_zone=args.zone,
        selector_key=args.selector_key,
        selector_value=args.selector_value,
        taint_key=args.taint_key,
        taint_value=args.taint_value,
        taint_effect=args.taint_effect,
        expected_command=expected_command,
        expected_startup_work_mib=args.startup_work_mib,
        expected_cpu_request=args.cpu_request,
        expected_cpu_limit=args.cpu_limit,
        expected_memory_request=args.memory_request,
        expected_memory_limit=args.memory_limit,
        min_download_bytes=args.min_download_bytes,
        require_warm_cni=args.require_warm_cni,
    )
    write_json(args.output, payload)
    return 0


def command_summarize(args: argparse.Namespace) -> int:
    observations, summary = summarize_runs(
        args.run_index,
        args.expected_repetitions,
        args.schedule,
        args.expected_seed,
    )
    write_tsv(args.observations, observations, OBSERVATION_FIELDS)
    write_json(args.output, summary)
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    microtime = commands.add_parser(
        "microtime", help="emit an RFC3339 UTC timestamp for Kubernetes MicroTime"
    )
    microtime.set_defaults(handler=command_microtime)

    schedule = commands.add_parser("schedule", help="generate a randomized paired-block schedule")
    schedule.add_argument("--repetitions", type=int, required=True)
    schedule.add_argument("--seed", type=int, required=True)
    schedule.add_argument("--output", type=Path)
    schedule.set_defaults(handler=command_schedule)

    state = commands.add_parser("validate-state", help="validate a cold/warm Kubernetes pool snapshot")
    state.add_argument("--mode", choices=VARIANTS, required=True)
    state.add_argument("--nodes", type=Path, required=True)
    state.add_argument("--pods", type=Path, required=True)
    state.add_argument("--cni", type=Path)
    state.add_argument("--selector-key", required=True)
    state.add_argument("--selector-value", required=True)
    state.add_argument("--instance-type", required=True)
    state.add_argument("--zone", required=True)
    state.add_argument("--taint-key", required=True)
    state.add_argument("--taint-value", required=True)
    state.add_argument("--taint-effect", choices=("NoSchedule",), required=True)
    state.add_argument("--require-cni", action="store_true")
    state.add_argument("--output", type=Path)
    state.set_defaults(handler=command_validate_state)

    control = commands.add_parser("validate-control", help="validate node-pool hook evidence")
    control.add_argument("--evidence", type=Path, required=True)
    control.add_argument("--action", choices=("check", "snapshot", "set-min", "restore"), required=True)
    control.add_argument("--cluster-id", required=True)
    control.add_argument("--node-pool-id", required=True)
    control.add_argument("--node-pool-name", required=True)
    control.add_argument("--resource-group-id", required=True)
    control.add_argument("--region-id", required=True)
    control.add_argument("--api-server", required=True)
    control.add_argument("--selector-key", required=True)
    control.add_argument("--selector-value", required=True)
    control.add_argument("--taint-key", required=True)
    control.add_argument("--taint-value", required=True)
    control.add_argument("--taint-effect", choices=("NoSchedule",), required=True)
    control.add_argument("--min-size", type=int)
    control.add_argument("--snapshot", type=Path)
    control.set_defaults(handler=command_validate_control)

    run = commands.add_parser("validate-run", help="validate one completed E02 child run")
    run.add_argument("--variant", choices=VARIANTS, required=True)
    run.add_argument("--artifact-dir", type=Path, required=True)
    run.add_argument("--pool-before", type=Path, required=True)
    run.add_argument("--pool-after", type=Path, required=True)
    run.add_argument("--warm-state", type=Path)
    run.add_argument("--cluster-id", required=True)
    run.add_argument("--image", required=True)
    run.add_argument("--instance-type", required=True)
    run.add_argument("--zone", required=True)
    run.add_argument("--selector-key", required=True)
    run.add_argument("--selector-value", required=True)
    run.add_argument("--taint-key", required=True)
    run.add_argument("--taint-value", required=True)
    run.add_argument("--taint-effect", choices=("NoSchedule",), required=True)
    run.add_argument("--command-json", required=True)
    run.add_argument("--startup-work-mib", type=int, required=True)
    run.add_argument("--cpu-request", required=True)
    run.add_argument("--cpu-limit", required=True)
    run.add_argument("--memory-request", required=True)
    run.add_argument("--memory-limit", required=True)
    run.add_argument("--min-download-bytes", type=int, required=True)
    run.add_argument("--require-warm-cni", action="store_true")
    run.add_argument("--output", type=Path, required=True)
    run.set_defaults(handler=command_validate_run)

    summary = commands.add_parser("summarize", help="aggregate validated pilot runs")
    summary.add_argument("--run-index", type=Path, required=True)
    summary.add_argument("--schedule", type=Path, required=True)
    summary.add_argument("--expected-repetitions", type=int, required=True)
    summary.add_argument("--expected-seed", type=int, required=True)
    summary.add_argument("--observations", type=Path, required=True)
    summary.add_argument("--output", type=Path, required=True)
    summary.set_defaults(handler=command_summarize)
    return root


def main() -> int:
    args = parser().parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError) as exc:
        print(f"e02-node-warm-pool: {exc}", file=sys.stderr)
        raise SystemExit(1)
