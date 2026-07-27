#!/usr/bin/env python3
"""Generate and validate the cumulative E07 end-to-end tuning smoke."""

from __future__ import annotations

import argparse
import calendar
import csv
import json
import re
import sys
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable


RFC3339_RE = re.compile(
    r"^(?P<base>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})"
    r"(?P<fraction>\.\d+)?(?P<zone>Z|[+-]\d{2}:\d{2})$"
)
QUANTITY_RE = re.compile(
    r"^(?P<number>[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"
    r"(?P<suffix>n|u|m|k|K|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?$"
)
DECIMAL_MULTIPLIERS = {
    "": Decimal(1),
    "n": Decimal("1e-9"),
    "u": Decimal("1e-6"),
    "m": Decimal("1e-3"),
    "k": Decimal("1e3"),
    "K": Decimal("1e3"),
    "M": Decimal("1e6"),
    "G": Decimal("1e9"),
    "T": Decimal("1e12"),
    "P": Decimal("1e15"),
    "E": Decimal("1e18"),
    "Ki": Decimal(1024),
    "Mi": Decimal(1024) ** 2,
    "Gi": Decimal(1024) ** 3,
    "Ti": Decimal(1024) ** 4,
    "Pi": Decimal(1024) ** 5,
    "Ei": Decimal(1024) ** 6,
}
SCHEDULE_FIELDS = (
    "sequence",
    "cell_id",
    "node_mode",
    "cooldown_seconds",
    "queue_mode",
    "n",
    "k",
    "argo_variant",
)
APPLICATION_EVENT_TYPES = (
    "READINESS_PROBE_FIRST_SUCCESS",
    "GANG_BARRIER_ENTER",
    "GANG_BARRIER_EXIT",
    "USEFUL_WORK_STARTED",
    "USEFUL_WORK_FINISHED",
)


class ValidationError(ValueError):
    pass


def atomic_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def atomic_json(path: Path, value: Any) -> None:
    atomic_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def load_ndjson(path: Path) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValidationError(f"{path}:{line_number} is not an object")
        output.append(value)
    return output


def timestamp_ns(value: str) -> int:
    match = RFC3339_RE.fullmatch(value.strip())
    if not match:
        raise ValidationError(f"invalid RFC3339 timestamp: {value!r}")
    zone = "+00:00" if match.group("zone") == "Z" else match.group("zone")
    parsed = datetime.fromisoformat(match.group("base") + zone)
    seconds = calendar.timegm(parsed.astimezone(timezone.utc).timetuple())
    fraction = (match.group("fraction") or "")[1:]
    nanos = int((fraction + "000000000")[:9]) if fraction else 0
    return seconds * 1_000_000_000 + nanos


def quantity(value: str) -> Decimal:
    match = QUANTITY_RE.fullmatch(value.strip())
    if not match:
        raise ValidationError(f"unsupported Kubernetes quantity: {value!r}")
    try:
        number = Decimal(match.group("number"))
    except InvalidOperation as exc:
        raise ValidationError(f"invalid Kubernetes quantity: {value!r}") from exc
    return number * DECIMAL_MULTIPLIERS[match.group("suffix") or ""]


def generate_schedule(
    baseline_cooldown: int,
    candidate_cooldown: int,
    members: int,
    baseline_minimum: int,
    candidate_minimum: int,
) -> list[dict[str, Any]]:
    if baseline_cooldown <= candidate_cooldown or candidate_cooldown <= 0:
        raise ValidationError(
            "cooldowns require baseline > candidate > 0"
        )
    if members < 2:
        raise ValidationError("E07 requires at least two Job members")
    if not (1 <= candidate_minimum <= baseline_minimum <= members):
        raise ValidationError(
            "barriers require 1 <= candidate k <= baseline k <= n"
        )
    if candidate_minimum == baseline_minimum:
        raise ValidationError("candidate k must differ from baseline k")
    values = (
        ("B0", "cold", baseline_cooldown, "direct", baseline_minimum, "baseline"),
        ("B1", "warm", baseline_cooldown, "direct", baseline_minimum, "baseline"),
        ("B2", "warm", candidate_cooldown, "direct", baseline_minimum, "baseline"),
        ("B3", "warm", candidate_cooldown, "ack", candidate_minimum, "baseline"),
        ("B4", "warm", candidate_cooldown, "ack", candidate_minimum, "tuned"),
    )
    return [
        {
            "sequence": index,
            "cell_id": cell_id,
            "node_mode": node_mode,
            "cooldown_seconds": cooldown,
            "queue_mode": queue_mode,
            "n": members,
            "k": minimum,
            "argo_variant": argo_variant,
        }
        for index, (
            cell_id,
            node_mode,
            cooldown,
            queue_mode,
            minimum,
            argo_variant,
        ) in enumerate(values, 1)
    ]


def write_tsv(
    path: Path, fields: Iterable[str], rows: Iterable[dict[str, Any]]
) -> None:
    fields = tuple(fields)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(
            stream, fieldnames=fields, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fields})
    temporary.replace(path)


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def pod_effective_request(pod: dict[str, Any], resource: str) -> Decimal:
    spec = pod.get("spec") or {}

    def request(container: dict[str, Any]) -> Decimal:
        raw = (
            (container.get("resources") or {})
            .get("requests", {})
            .get(resource)
        )
        return quantity(str(raw)) if raw is not None else Decimal(0)

    regular = sum(
        (request(container) for container in spec.get("containers", [])),
        Decimal(0),
    )
    restartable_init = Decimal(0)
    init_peak = Decimal(0)
    for container in spec.get("initContainers", []):
        value = request(container)
        if container.get("restartPolicy") == "Always":
            restartable_init += value
        else:
            init_peak = max(init_peak, restartable_init + value)
    containers = max(regular + restartable_init, init_peak)
    overhead_raw = (spec.get("overhead") or {}).get(resource)
    overhead = (
        quantity(str(overhead_raw))
        if overhead_raw is not None
        else Decimal(0)
    )
    return containers + overhead


def node_ready(node: dict[str, Any]) -> bool:
    return any(
        condition.get("type") == "Ready"
        and condition.get("status") == "True"
        for condition in (node.get("status") or {}).get("conditions", [])
    )


def daemon_owned(pod: dict[str, Any]) -> bool:
    return any(
        owner.get("kind") == "DaemonSet"
        for owner in (pod.get("metadata") or {}).get("ownerReferences", [])
    )


def bytes_to_mib(value: Decimal) -> float:
    return float(value / (Decimal(1024) ** 2))


def headroom_evidence(
    nodes_payload: dict[str, Any],
    pods_payload: dict[str, Any],
    pool_label: str,
    pool_id: str,
    pool_max_nodes: int,
    anchor_memory: str,
    phase_peak_memory: str,
    safety_memory: str,
) -> dict[str, Any]:
    if not pool_label or not pool_id:
        raise ValidationError("node-pool label and ID are required")
    if pool_max_nodes <= 0:
        raise ValidationError("node-pool maximum must be positive")
    nodes = [
        node
        for node in nodes_payload.get("items", [])
        if str((node.get("metadata") or {}).get("labels", {}).get(pool_label) or "")
        == pool_id
    ]
    if not nodes:
        raise ValidationError("no Nodes match the configured node pool")
    if len(nodes) >= pool_max_nodes:
        raise ValidationError(
            f"node pool is already at maximum {pool_max_nodes}"
        )
    if any(not node_ready(node) for node in nodes):
        raise ValidationError("not every baseline node-pool Node is Ready")
    if any((node.get("spec") or {}).get("unschedulable") for node in nodes):
        raise ValidationError("a baseline node-pool Node is unschedulable")

    pods = [
        pod
        for pod in pods_payload.get("items", [])
        if (pod.get("status") or {}).get("phase") not in {"Succeeded", "Failed"}
    ]
    by_node: dict[str, list[dict[str, Any]]] = {}
    for pod in pods:
        node_name = str((pod.get("spec") or {}).get("nodeName") or "")
        if node_name:
            by_node.setdefault(node_name, []).append(pod)

    rows: list[dict[str, Any]] = []
    fresh_headrooms: list[Decimal] = []
    for node in sorted(
        nodes, key=lambda value: str((value.get("metadata") or {}).get("name") or "")
    ):
        metadata = node.get("metadata") or {}
        status = node.get("status") or {}
        name = str(metadata.get("name") or "")
        uid = str(metadata.get("uid") or "")
        if not name or not uid:
            raise ValidationError("baseline Node identity is incomplete")
        allocatable = quantity(str(status.get("allocatable", {}).get("memory") or "0"))
        requested = sum(
            (pod_effective_request(pod, "memory") for pod in by_node.get(name, [])),
            Decimal(0),
        )
        daemon_requested = sum(
            (
                pod_effective_request(pod, "memory")
                for pod in by_node.get(name, [])
                if daemon_owned(pod)
            ),
            Decimal(0),
        )
        available = allocatable - requested
        fresh = allocatable - daemon_requested
        if min(allocatable, available, fresh) <= 0:
            raise ValidationError(f"node {name} has invalid memory headroom")
        fresh_headrooms.append(fresh)
        rows.append(
            {
                "name": name,
                "uid": uid,
                "allocatable_memory_mib": bytes_to_mib(allocatable),
                "requested_memory_mib": bytes_to_mib(requested),
                "available_memory_mib": bytes_to_mib(available),
                "daemon_memory_mib": bytes_to_mib(daemon_requested),
                "fresh_memory_headroom_mib": bytes_to_mib(fresh),
            }
        )

    anchor = quantity(anchor_memory)
    phase_peak = quantity(phase_peak_memory)
    safety = quantity(safety_memory)
    if min(anchor, phase_peak, safety) <= 0:
        raise ValidationError("anchor, phase peak, and safety must be positive")
    max_current_available = max(
        quantity(f"{row['available_memory_mib']}Mi") for row in rows
    )
    if anchor <= max_current_available:
        raise ValidationError(
            "anchor memory must exceed every current Node's available memory"
        )
    conservative_fresh = min(fresh_headrooms)
    required_fresh = anchor + phase_peak + safety
    if required_fresh > conservative_fresh:
        raise ValidationError(
            "anchor plus phase peak and safety do not fit a fresh Node"
        )
    return {
        "gate": "PASS",
        "pool_label": pool_label,
        "pool_id": pool_id,
        "pool_max_nodes": pool_max_nodes,
        "baseline_node_count": len(nodes),
        "baseline_nodes": rows,
        "anchor_memory_mib": bytes_to_mib(anchor),
        "phase_peak_memory_mib": bytes_to_mib(phase_peak),
        "safety_memory_mib": bytes_to_mib(safety),
        "max_current_available_memory_mib": bytes_to_mib(
            max_current_available
        ),
        "conservative_fresh_memory_headroom_mib": bytes_to_mib(
            conservative_fresh
        ),
        "required_fresh_memory_mib": bytes_to_mib(required_fresh),
    }


def expected_digest(image: str) -> str:
    if "@sha256:" not in image:
        raise ValidationError("expected image is not digest pinned")
    digest = image.rsplit("@sha256:", 1)[1].lower()
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValidationError("expected image digest is invalid")
    return digest


def indexed_rank(pod: dict[str, Any]) -> int:
    annotations = (pod.get("metadata") or {}).get("annotations") or {}
    value = annotations.get("batch.kubernetes.io/job-completion-index")
    if value is None:
        raise ValidationError("Job Pod has no completion index")
    return int(value)


def validate_gang_pods(
    pods_payload: dict[str, Any],
    n: int,
    expected_node: str,
    expected_image: str,
) -> set[str]:
    items = pods_payload.get("items", [])
    if len(items) != n:
        raise ValidationError(f"gang Job has {len(items)} Pods, expected {n}")
    digest = expected_digest(expected_image)
    ranks: set[int] = set()
    pod_uids: set[str] = set()
    for pod in items:
        metadata = pod.get("metadata") or {}
        uid = str(metadata.get("uid") or "")
        rank = indexed_rank(pod)
        if not uid or uid in pod_uids:
            raise ValidationError("gang Pod UID is empty or duplicated")
        if rank in ranks:
            raise ValidationError("gang completion index is duplicated")
        pod_uids.add(uid)
        ranks.add(rank)
        if (pod.get("status") or {}).get("phase") != "Succeeded":
            raise ValidationError(f"gang Pod rank {rank} did not succeed")
        if (pod.get("spec") or {}).get("nodeName") != expected_node:
            raise ValidationError(f"gang Pod rank {rank} escaped target Node")
        statuses = {
            str(item.get("name") or ""): item
            for item in (pod.get("status") or {}).get("containerStatuses", [])
        }
        image_id = str((statuses.get("gang-worker") or {}).get("imageID") or "")
        if digest not in image_id.lower():
            raise ValidationError(f"gang Pod rank {rank} imageID drifted")
    if ranks != set(range(n)):
        raise ValidationError(
            f"gang completion indices are {sorted(ranks)}, expected 0..{n - 1}"
        )
    return pod_uids


def condition_status(resource: dict[str, Any], condition_type: str) -> str:
    for condition in (resource.get("status") or {}).get("conditions", []):
        if condition.get("type") == condition_type:
            return str(condition.get("status") or "")
    return ""


def metric_number(value: str) -> float:
    match = re.fullmatch(
        r"(?P<number>[+-]?(?:\d+(?:\.\d*)?|\.\d+))(?P<suffix>m)?",
        value,
    )
    if not match:
        raise ValidationError(f"unsupported external metric value: {value!r}")
    result = float(match.group("number"))
    return result / 1000 if match.group("suffix") else result


def validate_zero_deployment(
    deployment: dict[str, Any], label: str
) -> None:
    status = deployment.get("status") or {}
    if (deployment.get("spec") or {}).get("replicas") != 0:
        raise ValidationError(f"{label} worker spec.replicas is not zero")
    for field in ("replicas", "readyReplicas", "availableReplicas"):
        if int(status.get(field) or 0) != 0:
            raise ValidationError(f"{label} worker status.{field} is not zero")


def validate_keda_spec(
    scaled_object: dict[str, Any], config: dict[str, Any]
) -> None:
    spec = scaled_object.get("spec") or {}
    expected = {
        "pollingInterval": int(config["polling_interval_seconds"]),
        "cooldownPeriod": int(config["cooldown_seconds"]),
        "minReplicaCount": int(config["min_replicas"]),
        "maxReplicaCount": int(config["max_replicas"]),
    }
    for field, value in expected.items():
        if spec.get(field) != value:
            raise ValidationError(
                f"ScaledObject spec.{field}={spec.get(field)!r}, expected {value}"
            )
    if spec.get("scaleTargetRef", {}).get("name") != config["worker_name"]:
        raise ValidationError("ScaledObject target Deployment drifted")
    redis = [
        trigger
        for trigger in spec.get("triggers", [])
        if trigger.get("type") == "redis"
    ]
    if len(redis) != 1:
        raise ValidationError("ScaledObject must have exactly one Redis trigger")
    metadata = redis[0].get("metadata") or {}
    if metadata.get("listName") != config["queue_key"]:
        raise ValidationError("ScaledObject Redis queue key drifted")
    if str(metadata.get("listLength")) != str(config["list_length"]):
        raise ValidationError("ScaledObject Redis listLength drifted")


def message_lifecycle(
    events: list[dict[str, Any]], message_count: int
) -> tuple[int, int]:
    required = (
        "MESSAGE_ENQUEUED",
        "MESSAGE_DEQUEUED",
        "MESSAGE_PROCESSING_STARTED",
        "MESSAGE_PROCESSED",
    )
    by_type: dict[str, dict[str, int]] = {}
    for event_type in required:
        values: dict[str, int] = {}
        for item in events:
            if (
                item.get("event_type") != event_type
                or item.get("source_component") != "application-event-log"
                or item.get("approximate") is True
            ):
                continue
            attributes = item.get("attributes") or {}
            message_id = str(attributes.get("message_id") or "")
            if not message_id or message_id in values:
                raise ValidationError(
                    f"{event_type} has a missing or duplicate message_id"
                )
            values[message_id] = int(item.get("event_time_ns") or 0)
        if len(values) != message_count:
            raise ValidationError(
                f"{event_type} count is {len(values)}, expected {message_count}"
            )
        by_type[event_type] = values
    identities = set(by_type[required[0]])
    if any(set(by_type[event_type]) != identities for event_type in required[1:]):
        raise ValidationError("KEDA message lifecycle identity sets differ")
    for message_id in identities:
        values = [by_type[event_type][message_id] for event_type in required]
        if min(values) <= 0 or values != sorted(values):
            raise ValidationError(
                f"message {message_id} lifecycle is out of order"
            )
    return min(by_type["MESSAGE_ENQUEUED"].values()), max(
        by_type["MESSAGE_PROCESSED"].values()
    )


def summarize_keda(args: argparse.Namespace) -> dict[str, Any]:
    config = load_json(Path(args.config))
    initial = load_json(Path(args.initial_state))
    final_scaled_object = load_json(Path(args.final_scaled_object))
    final_deployment = load_json(Path(args.final_deployment))
    state_captures = load_ndjson(Path(args.state_captures))
    metric_captures = load_ndjson(Path(args.metric_captures))
    events = load_ndjson(Path(args.application_events))
    message_count = int(config.get("message_count") or 0)
    if message_count <= 0:
        raise ValidationError("KEDA message count must be positive")

    initial_scaled_object = initial.get("scaled_object") or {}
    initial_deployment = initial.get("deployment") or {}
    validate_keda_spec(initial_scaled_object, config)
    validate_keda_spec(final_scaled_object, config)
    validate_zero_deployment(initial_deployment, "initial")
    validate_zero_deployment(final_deployment, "final")
    if condition_status(initial_scaled_object, "Ready") != "True":
        raise ValidationError("ScaledObject was not initially Ready")
    if condition_status(initial_scaled_object, "Active") not in {"", "False"}:
        raise ValidationError("ScaledObject was active before producer start")
    if condition_status(final_scaled_object, "Active") != "False":
        raise ValidationError("ScaledObject was not finally inactive")

    first_enqueue_ns, last_processed_ns = message_lifecycle(events, message_count)
    digest = expected_digest(args.expected_image)
    desired_positive: list[int] = []
    active_true: list[int] = []
    inactive_after_active: list[int] = []
    worker_ready: list[int] = []
    scale_zero: list[int] = []
    active_seen = False
    for capture in sorted(
        state_captures, key=lambda item: int(item.get("observed_time_ns") or 0)
    ):
        observed = int(capture.get("observed_time_ns") or 0)
        if observed <= 0:
            raise ValidationError("KEDA state capture has no observation time")
        scaled_object = capture.get("scaled_object") or {}
        deployment = capture.get("deployment") or {}
        hpa = capture.get("hpa") or {}
        active = condition_status(scaled_object, "Active")
        if active == "True" and observed >= first_enqueue_ns:
            active_true.append(observed)
            active_seen = True
        elif active == "False" and active_seen:
            inactive_after_active.append(observed)
        if int((hpa.get("status") or {}).get("desiredReplicas") or 0) > 0:
            desired_positive.append(observed)
        deployment_status = deployment.get("status") or {}
        if (
            active_seen
            and observed > last_processed_ns
            and (deployment.get("spec") or {}).get("replicas") == 0
            and int(deployment_status.get("replicas") or 0) == 0
            and int(deployment_status.get("readyReplicas") or 0) == 0
        ):
            scale_zero.append(observed)
        for pod in (capture.get("pods") or {}).get("items", []):
            labels = (pod.get("metadata") or {}).get("labels") or {}
            if labels.get("hooke.io/e04-role") != "worker":
                continue
            ready = any(
                condition.get("type") == "Ready"
                and condition.get("status") == "True"
                for condition in (pod.get("status") or {}).get("conditions", [])
            )
            if not ready:
                continue
            if (pod.get("spec") or {}).get("nodeName") != args.expected_node:
                raise ValidationError("KEDA worker escaped target Node")
            statuses = (pod.get("status") or {}).get("containerStatuses", [])
            if not statuses or digest not in str(statuses[0].get("imageID") or "").lower():
                raise ValidationError("KEDA worker immutable image drifted")
            worker_ready.append(observed)
    if not active_true:
        raise ValidationError("ScaledObject never became active")
    if not inactive_after_active:
        raise ValidationError("ScaledObject never became inactive after activation")
    if not desired_positive:
        raise ValidationError("HPA never requested a positive replica count")
    if not worker_ready:
        raise ValidationError("no ready KEDA worker was sampled")
    if not scale_zero:
        raise ValidationError("worker scale-to-zero was not sampled")

    metric_values: list[tuple[int, float]] = []
    for capture in metric_captures:
        if capture.get("error"):
            raise ValidationError(
                f"external metric capture failed: {capture.get('error')}"
            )
        observed = int(capture.get("observed_time_ns") or 0)
        for item in (capture.get("payload") or {}).get("items", []):
            metric_values.append(
                (observed, metric_number(str(item.get("value") or "")))
            )
    metric_values.sort()
    if not metric_values:
        raise ValidationError("no external metric values were captured")
    positive = [item for item in metric_values if item[1] > 0]
    if not positive:
        raise ValidationError("external metric never became positive")
    first_positive = positive[0][0]
    if not any(value == 0 and observed < first_positive for observed, value in metric_values):
        raise ValidationError("external metric has no initial zero")
    if not any(value == 0 and observed > first_positive for observed, value in metric_values):
        raise ValidationError("external metric has no post-active zero")

    inactive_ns = min(inactive_after_active)
    scale_zero_ns = min(value for value in scale_zero if value >= inactive_ns)
    observed_cooldown = (scale_zero_ns - inactive_ns) / 1e9
    configured_cooldown = int(config["cooldown_seconds"])
    polling = int(config["polling_interval_seconds"])
    lower = max(0.0, configured_cooldown - 2 * polling - 5)
    upper = configured_cooldown + 3 * polling + 30
    if not lower <= observed_cooldown <= upper:
        raise ValidationError(
            f"scale-to-zero delay {observed_cooldown:.3f}s is outside "
            f"[{lower:.3f}, {upper:.3f}]"
        )
    first_ready_ns = min(worker_ready)
    return {
        "result": "PASS",
        "cell_id": str(config.get("cell_id") or ""),
        "sequence": int(config.get("sequence") or 0),
        "cooldown_seconds": configured_cooldown,
        "polling_interval_seconds": polling,
        "message_count": message_count,
        "worker_pod_count": len(
            {
                str(item.get("pod_uid") or "")
                for item in events
                if item.get("event_type") == "MESSAGE_PROCESSED"
                and item.get("pod_uid")
            }
        ),
        "metric_sample_count": len(metric_values),
        "observed_scale_to_zero_seconds": observed_cooldown,
        "fixed_node": args.expected_node,
        "image": args.expected_image,
        "times_ns": {
            "first_enqueue": first_enqueue_ns,
            "first_active": min(active_true),
            "first_hpa_positive_desired": min(desired_positive),
            "first_worker_ready": first_ready_ns,
            "last_message_processed": last_processed_ns,
            "inactive": inactive_ns,
            "scale_to_zero": scale_zero_ns,
        },
    }


def summarize_direct_gang(args: argparse.Namespace) -> dict[str, Any]:
    job = load_json(Path(args.job))
    pods = load_json(Path(args.pods))
    events = load_ndjson(Path(args.application_events))
    captures = load_ndjson(Path(args.queueunit_captures))
    metadata = job.get("metadata") or {}
    spec = job.get("spec") or {}
    status = job.get("status") or {}
    job_name = str(metadata.get("name") or "")
    job_uid = str(metadata.get("uid") or "")
    if not job_name or not job_uid:
        raise ValidationError("direct Job identity is incomplete")
    if spec.get("suspend") is not False:
        raise ValidationError("direct Job was not explicitly unsuspended")
    if int(spec.get("parallelism") or 0) != args.n:
        raise ValidationError("direct Job parallelism does not equal n")
    if int(spec.get("completions") or 0) != args.n:
        raise ValidationError("direct Job completions does not equal n")
    if int(status.get("succeeded") or 0) != args.n:
        raise ValidationError("direct Job did not report all members succeeded")
    for capture in captures:
        for queueunit in capture.get("items", []):
            consumer = (queueunit.get("spec") or {}).get("consumerRef") or {}
            if (
                consumer.get("kind") == "Job"
                and consumer.get("name") == job_name
            ):
                raise ValidationError("direct Job unexpectedly created a QueueUnit")

    pod_uids = validate_gang_pods(
        pods, args.n, args.expected_node, args.expected_image
    )
    ranks_by_type: dict[str, set[int]] = {}
    for item in events:
        if (
            item.get("workload_uid") != job_uid
            or item.get("workload_name") != job_name
        ):
            continue
        event_type = str(item.get("event_type") or "")
        if event_type not in APPLICATION_EVENT_TYPES:
            continue
        if item.get("pod_uid") not in pod_uids:
            raise ValidationError(f"{event_type} has an unknown gang Pod UID")
        attributes = item.get("attributes") or {}
        rank = int(attributes.get("rank", -1))
        if int(attributes.get("admission_members") or 0) != args.n:
            raise ValidationError(f"{event_type} did not preserve full n")
        ranks_by_type.setdefault(event_type, set()).add(rank)
    for event_type in APPLICATION_EVENT_TYPES:
        if ranks_by_type.get(event_type) != set(range(args.n)):
            raise ValidationError(
                f"{event_type} does not cover every direct Job rank"
            )
    return {
        "gate": "PASS",
        "job_name": job_name,
        "job_uid": job_uid,
        "queue_mode": "direct",
        "queue_admission_policy": "direct-job",
        "queue_admission_members": args.n,
        "application_barrier_policy": "k-of-n",
        "application_barrier_minimum": args.k,
        "n": args.n,
        "k": args.k,
        "fixed_node": args.expected_node,
        "image": args.expected_image,
        "required_application_events": args.n * len(APPLICATION_EVENT_TYPES),
    }


def validate_common_gang(
    cell: dict[str, Any],
    gang: dict[str, Any],
    pods_payload: dict[str, Any],
    expected_node: str,
    expected_image: str,
) -> None:
    n = int(cell["n"])
    k = int(cell["k"])
    validate_gang_pods(pods_payload, n, expected_node, expected_image)
    if int(gang.get("n") or 0) != n or int(gang.get("k") or 0) != k:
        raise ValidationError("gang summary n/k do not match E07 cell")
    if int(gang.get("queue_admission_members") or 0) != n:
        raise ValidationError("gang admission did not request full n")
    if int(gang.get("application_barrier_minimum") or 0) != k:
        raise ValidationError("gang application barrier does not match k")
    expected_policy = "whole-job" if cell["queue_mode"] == "ack" else "direct-job"
    if gang.get("queue_admission_policy") != expected_policy:
        raise ValidationError("gang admission policy does not match cell")
    if cell["queue_mode"] == "ack":
        if not gang.get("queueunit_name"):
            raise ValidationError("ACK Queue cell has no QueueUnit evidence")
        if gang.get("queueunit_phase") not in {"Dequeued", "Succeed"}:
            raise ValidationError("ACK QueueUnit never reached an admitted phase")
    elif gang.get("gate") != "PASS":
        raise ValidationError("direct gang summary did not pass")


def summarize_cell(args: argparse.Namespace) -> dict[str, Any]:
    cell = load_json(Path(args.cell_config))
    timing = load_json(Path(args.timing))
    keda = load_json(Path(args.keda_summary))
    gang = load_json(Path(args.gang_summary))
    gang_pods = load_json(Path(args.gang_pods))
    argo = load_json(Path(args.argo_summary))
    expected_node = str(args.expected_node)

    for field in SCHEDULE_FIELDS:
        if field not in cell:
            raise ValidationError(f"cell config is missing {field}")
    if keda.get("result") != "PASS":
        raise ValidationError("KEDA phase did not pass E04 validation")
    if int(keda.get("cooldown_seconds") or 0) != int(
        cell["cooldown_seconds"]
    ):
        raise ValidationError("KEDA cooldown does not match E07 cell")
    if int(keda.get("message_count") or 0) != args.message_count:
        raise ValidationError("KEDA message count drifted")
    if int(keda.get("worker_pod_count") or 0) < 1:
        raise ValidationError("KEDA never produced a ready worker")
    if int((keda.get("times_ns") or {}).get("scale_to_zero") or 0) <= 0:
        raise ValidationError("KEDA phase has no scale-to-zero evidence")

    validate_common_gang(
        cell, gang, gang_pods, expected_node, args.gang_image
    )
    if argo.get("gate") != "PASS":
        raise ValidationError("Argo phase did not pass E06 validation")
    if argo.get("variant") != cell["argo_variant"]:
        raise ValidationError("Argo variant does not match E07 cell")
    if argo.get("fixed_node") != expected_node:
        raise ValidationError("Argo summary is not pinned to the E07 Node")
    if argo.get("image") != args.argo_image:
        raise ValidationError("Argo immutable image drifted")

    keys = (
        "cell_started_ns",
        "node_ready_ns",
        "keda_started_ns",
        "keda_finished_ns",
        "gang_started_ns",
        "gang_finished_ns",
        "argo_started_ns",
        "argo_finished_ns",
        "cell_finished_ns",
    )
    times = [int(timing.get(key) or 0) for key in keys]
    if any(value <= 0 for value in times):
        raise ValidationError("cell timing has a missing timestamp")
    if times != sorted(times):
        raise ValidationError("E07 phase timestamps are not sequential")
    if cell["node_mode"] == "warm" and times[1] != times[0]:
        raise ValidationError("warm cell must start with an already-ready Node")
    if cell["node_mode"] == "cold" and times[1] <= times[0]:
        raise ValidationError("cold cell did not include Node provisioning")
    e2e_seconds = (times[-1] - times[0]) / 1e9
    return {
        **{field: cell[field] for field in SCHEDULE_FIELDS},
        "gate": "PASS",
        "target_node": expected_node,
        "node_provision_seconds": (times[1] - times[0]) / 1e9,
        "keda_phase_seconds": (times[3] - times[2]) / 1e9,
        "gang_phase_seconds": (times[5] - times[4]) / 1e9,
        "argo_phase_seconds": (times[7] - times[6]) / 1e9,
        "e2e_seconds": e2e_seconds,
        "keda": keda,
        "gang": gang,
        "argo": argo,
        "timing": {key: value for key, value in zip(keys, times)},
    }


def normalized_schedule(rows: list[dict[str, str]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for row in rows:
        output.append(
            {
                **{key: row[key] for key in SCHEDULE_FIELDS},
                "sequence": int(row["sequence"]),
                "cooldown_seconds": int(row["cooldown_seconds"]),
                "n": int(row["n"]),
                "k": int(row["k"]),
            }
        )
    return output


def validate_provisioning(
    evidence: dict[str, Any],
    target_node: str,
    first_cell: dict[str, Any],
) -> None:
    if evidence.get("gate") != "PASS":
        raise ValidationError("Node provisioning evidence did not pass")
    baseline_names = {
        str(item.get("name") or "")
        for item in evidence.get("baseline_nodes", [])
    }
    if not baseline_names or "" in baseline_names:
        raise ValidationError("baseline Node identities are incomplete")
    if target_node in baseline_names:
        raise ValidationError("B0 target Node was already present at baseline")
    if evidence.get("target_node") != target_node:
        raise ValidationError("anchor target Node differs from E07 cells")
    if evidence.get("anchor_node") != target_node:
        raise ValidationError("anchor Pod was not bound to the E07 target Node")
    if int(evidence.get("node_ready_ns") or 0) <= int(
        evidence.get("anchor_created_ns") or 0
    ):
        raise ValidationError("Node ready time does not follow anchor creation")
    if float(first_cell.get("node_provision_seconds") or 0) <= 0:
        raise ValidationError("B0 did not measure Node provisioning")


def aggregate(
    schedule: list[dict[str, Any]],
    cells: list[dict[str, Any]],
    provisioning: dict[str, Any],
) -> dict[str, Any]:
    if len(schedule) != 5 or len(cells) != 5:
        raise ValidationError("E07 smoke requires exactly five cells")
    expected = generate_schedule(
        int(schedule[0]["cooldown_seconds"]),
        int(schedule[2]["cooldown_seconds"]),
        int(schedule[0]["n"]),
        int(schedule[0]["k"]),
        int(schedule[3]["k"]),
    )
    if schedule != expected:
        raise ValidationError("E07 schedule differs from cumulative B0..B4 protocol")
    ordered = sorted(cells, key=lambda item: int(item.get("sequence") or 0))
    for scheduled, observed in zip(schedule, ordered):
        if observed.get("gate") != "PASS":
            raise ValidationError(f"{scheduled['cell_id']} did not pass")
        for field in SCHEDULE_FIELDS:
            if observed.get(field) != scheduled[field]:
                raise ValidationError(
                    f"{scheduled['cell_id']} observed {field} drifted"
                )
    nodes = {str(item.get("target_node") or "") for item in ordered}
    if len(nodes) != 1 or "" in nodes:
        raise ValidationError("E07 cells do not share exactly one target Node")
    target_node = next(iter(nodes))
    validate_provisioning(provisioning, target_node, ordered[0])

    by_id = {str(item["cell_id"]): item for item in ordered}
    if float(by_id["B0"]["e2e_seconds"]) <= float(by_id["B1"]["e2e_seconds"]):
        raise ValidationError("cold B0 was not slower than warm B1")
    if int(by_id["B2"]["cooldown_seconds"]) >= int(
        by_id["B1"]["cooldown_seconds"]
    ):
        raise ValidationError("B2 did not activate the shorter cooldown")
    for cell_id in ("B3", "B4"):
        cell = by_id[cell_id]
        if cell["queue_mode"] != "ack":
            raise ValidationError(f"{cell_id} did not activate ACK Queue")
        if int(cell["gang"]["queue_admission_members"]) != int(cell["n"]):
            raise ValidationError(f"{cell_id} did not admit whole n")
        if int(cell["gang"]["application_barrier_minimum"]) != int(cell["k"]):
            raise ValidationError(f"{cell_id} did not apply candidate k")
    if by_id["B4"]["argo_variant"] != "tuned":
        raise ValidationError("B4 did not activate the tuned Argo DAG")
    if int(by_id["B4"]["argo"]["critical_path_length"]) != 5:
        raise ValidationError("B4 tuned Argo critical path is not five stages")
    if float(by_id["B4"]["argo"]["bc_overlap_seconds"]) <= 0:
        raise ValidationError("B4 tuned Argo B/C stages did not overlap")

    return {
        "experiment": "E07 cumulative end-to-end tuning smoke",
        "scope": "smoke",
        "gate": "PASS",
        "cell_count": 5,
        "passed_cells": 5,
        "target_node": target_node,
        "baseline_node_count": int(
            provisioning.get("baseline_node_count") or 0
        ),
        "node_provision_seconds": float(ordered[0]["node_provision_seconds"]),
        "cold_vs_warm_seconds": {
            "cold_b0": float(by_id["B0"]["e2e_seconds"]),
            "warm_b1": float(by_id["B1"]["e2e_seconds"]),
            "difference": float(by_id["B0"]["e2e_seconds"])
            - float(by_id["B1"]["e2e_seconds"]),
        },
        "activation_checks": {
            "warm_node_from_b1": True,
            "shorter_keda_cooldown_from_b2": True,
            "ack_whole_job_and_candidate_k_from_b3": True,
            "parallel_argo_dag_from_b4": True,
        },
        "interpretation": (
            "Functional smoke only; candidate values are not statistically optimal."
        ),
        "provisioning": provisioning,
        "cells": ordered,
    }


def report_markdown(summary: dict[str, Any]) -> str:
    lines = [
        "# E07 端到端累积调优冒烟报告",
        "",
        f"- Gate: **{summary['gate']}**",
        "- 范围：单次 1×5 功能冒烟，不是正式实验或统计结论",
        f"- 单元：{summary['passed_cells']}/{summary['cell_count']} PASS",
        f"- 统一目标节点：`{summary['target_node']}`",
        f"- B0 节点拉起：{summary['node_provision_seconds']:.3f} s",
        "",
        "| 单元 | 节点 | KEDA cooldown | Job admission | n/k | Argo | E2E (s) | Gate |",
        "|---|---|---:|---|---:|---|---:|---|",
    ]
    for cell in summary["cells"]:
        lines.append(
            "| {cell_id} | {node_mode} | {cooldown_seconds} | "
            "{queue_mode} | {n}/{k} | {argo_variant} | "
            "{e2e_seconds:.3f} | {gate} |".format(**cell)
        )
    lines.extend(
        [
            "",
            "B0 包含真实 Node provisioning；B1 起复用同一节点；B2 启用较短 "
            "KEDA cooldown；B3 启用 ACK Queue 整 Job（完整 n）准入并由应用层执行 "
            "k-of-n barrier；B4 再启用可并行的 Argo DAG。",
            "",
            "E2E 边界包含每个单元的 KEDA scale-to-zero 等待。这是本冒烟的统一编排"
            "边界，不代表普通用户请求延迟。除 B0/B1 的冷暖节点检查外，不要求各单元"
            "耗时单调下降；候选 cooldown/k 不能据此称为最优值。",
            "",
        ]
    )
    return "\n".join(lines)


def command_schedule(args: argparse.Namespace) -> int:
    rows = generate_schedule(
        args.baseline_cooldown,
        args.candidate_cooldown,
        args.n,
        args.baseline_k,
        args.candidate_k,
    )
    write_tsv(Path(args.output), SCHEDULE_FIELDS, rows)
    return 0


def command_headroom(args: argparse.Namespace) -> int:
    result = headroom_evidence(
        load_json(Path(args.nodes)),
        load_json(Path(args.pods)),
        args.pool_label,
        args.pool_id,
        args.pool_max_nodes,
        args.anchor_memory,
        args.phase_peak_memory,
        args.safety_memory,
    )
    atomic_json(Path(args.output), result)
    return 0


def command_direct_gang(args: argparse.Namespace) -> int:
    atomic_json(Path(args.output), summarize_direct_gang(args))
    return 0


def command_keda(args: argparse.Namespace) -> int:
    atomic_json(Path(args.output), summarize_keda(args))
    return 0


def command_cell(args: argparse.Namespace) -> int:
    atomic_json(Path(args.output), summarize_cell(args))
    return 0


def command_aggregate(args: argparse.Namespace) -> int:
    schedule = normalized_schedule(read_tsv(Path(args.schedule)))
    cells = [load_json(Path(path)) for path in args.cell]
    result = aggregate(
        schedule, cells, load_json(Path(args.provisioning_evidence))
    )
    atomic_json(Path(args.output), result)
    write_tsv(
        Path(args.tsv),
        (
            "sequence",
            "cell_id",
            "node_mode",
            "cooldown_seconds",
            "queue_mode",
            "n",
            "k",
            "argo_variant",
            "node_provision_seconds",
            "keda_phase_seconds",
            "gang_phase_seconds",
            "argo_phase_seconds",
            "e2e_seconds",
            "gate",
        ),
        result["cells"],
    )
    atomic_text(Path(args.report), report_markdown(result))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    schedule = commands.add_parser("schedule")
    schedule.add_argument("--baseline-cooldown", type=int, required=True)
    schedule.add_argument("--candidate-cooldown", type=int, required=True)
    schedule.add_argument("--n", type=int, required=True)
    schedule.add_argument("--baseline-k", type=int, required=True)
    schedule.add_argument("--candidate-k", type=int, required=True)
    schedule.add_argument("--output", required=True)
    schedule.set_defaults(handler=command_schedule)

    headroom = commands.add_parser("headroom")
    headroom.add_argument("--nodes", required=True)
    headroom.add_argument("--pods", required=True)
    headroom.add_argument("--pool-label", required=True)
    headroom.add_argument("--pool-id", required=True)
    headroom.add_argument("--pool-max-nodes", type=int, required=True)
    headroom.add_argument("--anchor-memory", required=True)
    headroom.add_argument("--phase-peak-memory", required=True)
    headroom.add_argument("--safety-memory", required=True)
    headroom.add_argument("--output", required=True)
    headroom.set_defaults(handler=command_headroom)

    direct = commands.add_parser("summarize-direct-gang")
    direct.add_argument("--job", required=True)
    direct.add_argument("--pods", required=True)
    direct.add_argument("--application-events", required=True)
    direct.add_argument("--queueunit-captures", required=True)
    direct.add_argument("--n", type=int, required=True)
    direct.add_argument("--k", type=int, required=True)
    direct.add_argument("--expected-node", required=True)
    direct.add_argument("--expected-image", required=True)
    direct.add_argument("--output", required=True)
    direct.set_defaults(handler=command_direct_gang)

    keda = commands.add_parser("summarize-keda")
    keda.add_argument("--config", required=True)
    keda.add_argument("--initial-state", required=True)
    keda.add_argument("--final-scaled-object", required=True)
    keda.add_argument("--final-deployment", required=True)
    keda.add_argument("--state-captures", required=True)
    keda.add_argument("--metric-captures", required=True)
    keda.add_argument("--application-events", required=True)
    keda.add_argument("--expected-node", required=True)
    keda.add_argument("--expected-image", required=True)
    keda.add_argument("--output", required=True)
    keda.set_defaults(handler=command_keda)

    cell = commands.add_parser("summarize-cell")
    cell.add_argument("--cell-config", required=True)
    cell.add_argument("--timing", required=True)
    cell.add_argument("--keda-summary", required=True)
    cell.add_argument("--gang-summary", required=True)
    cell.add_argument("--gang-pods", required=True)
    cell.add_argument("--argo-summary", required=True)
    cell.add_argument("--expected-node", required=True)
    cell.add_argument("--message-count", type=int, required=True)
    cell.add_argument("--gang-image", required=True)
    cell.add_argument("--argo-image", required=True)
    cell.add_argument("--output", required=True)
    cell.set_defaults(handler=command_cell)

    aggregate_parser = commands.add_parser("aggregate")
    aggregate_parser.add_argument("--schedule", required=True)
    aggregate_parser.add_argument("--cell", action="append", required=True)
    aggregate_parser.add_argument("--provisioning-evidence", required=True)
    aggregate_parser.add_argument("--output", required=True)
    aggregate_parser.add_argument("--tsv", required=True)
    aggregate_parser.add_argument("--report", required=True)
    aggregate_parser.set_defaults(handler=command_aggregate)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError, ValueError, json.JSONDecodeError) as exc:
        print(f"e07-end-to-end-tuning: {exc}", file=sys.stderr)
        raise SystemExit(1)
