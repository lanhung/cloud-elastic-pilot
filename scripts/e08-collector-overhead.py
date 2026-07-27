#!/usr/bin/env python3
"""Generate and validate the low-rate E08 collector-overhead smoke."""

from __future__ import annotations

import argparse
import calendar
import csv
import json
import math
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable


SCHEDULE_FIELDS = (
    "sequence",
    "cell_id",
    "mode",
    "collector_enabled",
    "sample_percent",
)
CONTROLLER_EVENT_TYPES = {
    "POD_CREATED",
    "POD_SCHEDULED",
    "CONTAINER_STARTED",
}
APPLICATION_EVENT_TYPES = {
    "USEFUL_WORK_STARTED",
    "USEFUL_WORK_FINISHED",
}
RFC3339_RE = re.compile(
    r"^(?P<base>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})"
    r"(?P<fraction>\.\d+)?(?P<zone>Z|[+-]\d{2}:\d{2})$"
)
QUANTITY_RE = re.compile(
    r"^(?P<number>[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"
    r"(?P<suffix>n|u|m|k|K|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?$"
)
PROM_SAMPLE_RE = re.compile(
    r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)"
    r"(?:\{(?P<labels>.*)\})?\s+"
    r"(?P<value>[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"
    r"(?:\s+\d+)?$"
)
PROM_LABEL_RE = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"])*)"')
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
    values: list[dict[str, Any]] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValidationError(
                f"{path}:{line_number} is not valid JSON"
            ) from exc
        if not isinstance(value, dict):
            raise ValidationError(f"{path}:{line_number} is not an object")
        values.append(value)
    return values


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
            writer.writerow(
                {
                    field: (
                        str(row.get(field, "")).lower()
                        if isinstance(row.get(field, ""), bool)
                        else row.get(field, "")
                    )
                    for field in fields
                }
            )
    temporary.replace(path)


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


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


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (
        ordered[upper] - ordered[lower]
    ) * (position - lower)


def distribution(values: list[float]) -> dict[str, Any]:
    return {
        "count": len(values),
        "minimum": min(values) if values else None,
        "p50": percentile(values, 0.5),
        "p95": percentile(values, 0.95),
        "maximum": max(values) if values else None,
    }


def generate_schedule() -> list[dict[str, Any]]:
    values = (
        ("off", "collector-off", False, 0),
        ("on10", "collector-on-10-percent", True, 10),
        ("on100", "collector-on-100-percent", True, 100),
    )
    return [
        {
            "sequence": sequence,
            "cell_id": cell_id,
            "mode": mode,
            "collector_enabled": enabled,
            "sample_percent": percent,
        }
        for sequence, (cell_id, mode, enabled, percent) in enumerate(values, 1)
    ]


def workload_manifest(
    *,
    namespace: str,
    name: str,
    run_id: str,
    cluster_id: str,
    image: str,
    ingester_url: str,
    target_nodes: list[str],
    completions: int,
    parallelism: int,
    work_duration: str,
    cpu_request: str,
    memory_request: str,
) -> dict[str, Any]:
    if len(target_nodes) != 2 or len(set(target_nodes)) != 2:
        raise ValidationError("E08 smoke requires exactly two distinct target nodes")
    if completions < 3:
        raise ValidationError("E08 smoke requires at least three workload Pods")
    if parallelism != 2 or parallelism > completions:
        raise ValidationError("E08 smoke parallelism is frozen at two")
    if not re.fullmatch(r".+@sha256:[0-9a-fA-F]{64}", image):
        raise ValidationError("E08 image must be digest pinned")
    if not namespace or not name or not run_id or not cluster_id:
        raise ValidationError("namespace, name, run ID, and cluster ID are required")

    field = lambda path: {"valueFrom": {"fieldRef": {"fieldPath": path}}}
    environment = [
        {"name": "E06_STAGE_NAME", "value": "e08"},
        {"name": "E06_VARIANT", "value": "warmup"},
        {"name": "E06_WORK_DURATION", "value": work_duration},
        {"name": "E06_DEPENDENCY_PROOF", "value": "e08-collector-overhead"},
        {"name": "HOOKE_SDK_DISABLED", "value": "false"},
        {"name": "HOOKE_INGESTER_URL", "value": ingester_url},
        {"name": "HOOKE_CLUSTER_ID", "value": cluster_id},
        {"name": "HOOKE_RUN_ID", "value": run_id},
        {"name": "HOOKE_SOURCE_COMPONENT", "value": "e08-workload"},
        {"name": "HOOKE_CONTAINER_NAME", "value": "worker"},
        {"name": "HOOKE_WORKLOAD_KIND", "value": "Job"},
        {"name": "HOOKE_WORKLOAD_NAME", "value": name},
        {"name": "POD_NAMESPACE", **field("metadata.namespace")},
        {"name": "POD_NAME", **field("metadata.name")},
        {"name": "POD_UID", **field("metadata.uid")},
        {"name": "NODE_NAME", **field("spec.nodeName")},
    ]
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": {
                "app.kubernetes.io/name": "e08-workload",
                "hooke.io/run-id": run_id,
            },
            "annotations": {"hooke.io/run-id": run_id},
        },
        "spec": {
            "completionMode": "Indexed",
            "completions": completions,
            "parallelism": parallelism,
            "backoffLimit": 0,
            "activeDeadlineSeconds": max(300, completions * 30),
            "template": {
                "metadata": {
                    "labels": {
                        "app.kubernetes.io/name": "e08-workload",
                        "hooke.io/e08-job": name,
                        "hooke.io/run-id": run_id,
                    },
                    "annotations": {"hooke.io/run-id": run_id},
                },
                "spec": {
                    "restartPolicy": "Never",
                    "securityContext": {
                        "runAsNonRoot": True,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "affinity": {
                        "nodeAffinity": {
                            "requiredDuringSchedulingIgnoredDuringExecution": {
                                "nodeSelectorTerms": [
                                    {
                                        "matchExpressions": [
                                            {
                                                "key": "kubernetes.io/hostname",
                                                "operator": "In",
                                                "values": target_nodes,
                                            }
                                        ]
                                    }
                                ]
                            }
                        },
                    },
                    "topologySpreadConstraints": [
                        {
                            "maxSkew": 1,
                            "minDomains": 2,
                            "topologyKey": "kubernetes.io/hostname",
                            "whenUnsatisfiable": "DoNotSchedule",
                            "labelSelector": {
                                "matchLabels": {"hooke.io/e08-job": name}
                            },
                        }
                    ],
                    "containers": [
                        {
                            "name": "worker",
                            "image": image,
                            "imagePullPolicy": "IfNotPresent",
                            "command": ["/e06-stage-worker"],
                            "env": environment,
                            "resources": {
                                "requests": {
                                    "cpu": cpu_request,
                                    "memory": memory_request,
                                },
                                "limits": {
                                    "cpu": cpu_request,
                                    "memory": memory_request,
                                },
                            },
                            "securityContext": {
                                "allowPrivilegeEscalation": False,
                                "capabilities": {"drop": ["ALL"]},
                            },
                        }
                    ],
                },
            },
        },
    }


def parse_prometheus(path: Path) -> dict[tuple[str, tuple[tuple[str, str], ...]], float]:
    output: dict[tuple[str, tuple[tuple[str, str], ...]], float] = {}
    if not path.exists():
        return output
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        match = PROM_SAMPLE_RE.fullmatch(line)
        if not match:
            raise ValidationError(f"{path}:{line_number} is not a Prometheus sample")
        labels: dict[str, str] = {}
        raw_labels = match.group("labels") or ""
        for label_match in PROM_LABEL_RE.finditer(raw_labels):
            labels[label_match.group(1)] = json.loads(
                '"' + label_match.group(2) + '"'
            )
        output[(match.group("name"), tuple(sorted(labels.items())))] = float(
            match.group("value")
        )
    return output


def prom_value(
    samples: dict[tuple[str, tuple[tuple[str, str], ...]], float],
    name: str,
    labels: dict[str, str] | None = None,
) -> float:
    expected = labels or {}
    total = 0.0
    for (sample_name, sample_labels), value in samples.items():
        actual = dict(sample_labels)
        if sample_name == name and all(actual.get(key) == item for key, item in expected.items()):
            total += value
    return total


def prom_delta(
    before: dict[tuple[str, tuple[tuple[str, str], ...]], float],
    after: dict[tuple[str, tuple[tuple[str, str], ...]], float],
    name: str,
    labels: dict[str, str] | None = None,
) -> float:
    delta = prom_value(after, name, labels) - prom_value(before, name, labels)
    if delta < -1e-9:
        raise ValidationError(f"Prometheus counter {name} moved backwards")
    return max(0.0, delta)


def pod_startup_seconds(pod: dict[str, Any]) -> float:
    metadata = pod.get("metadata") or {}
    created = timestamp_ns(str(metadata.get("creationTimestamp") or ""))
    statuses = (pod.get("status") or {}).get("containerStatuses") or []
    if len(statuses) != 1:
        raise ValidationError(f"Pod {metadata.get('name')} must have one container")
    state = statuses[0].get("state") or {}
    terminated = state.get("terminated") or {}
    started_at = terminated.get("startedAt")
    if not started_at:
        raise ValidationError(f"Pod {metadata.get('name')} lacks terminated.startedAt")
    duration = (timestamp_ns(str(started_at)) - created) / 1_000_000_000
    if duration < 0:
        raise ValidationError(f"Pod {metadata.get('name')} has negative startup")
    return duration


def validate_workload_pods(
    pods_payload: dict[str, Any],
    target_nodes: list[str],
    expected_image: str,
    expected_count: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    pods = list(pods_payload.get("items") or [])
    if len(pods) != expected_count:
        raise ValidationError(
            f"expected {expected_count} workload Pods, found {len(pods)}"
        )
    allowed = set(target_nodes)
    used: set[str] = set()
    image_digest = expected_image.split("@", 1)[1].lower()
    startups: list[float] = []
    for pod in pods:
        metadata = pod.get("metadata") or {}
        status = pod.get("status") or {}
        if status.get("phase") != "Succeeded":
            raise ValidationError(f"Pod {metadata.get('name')} did not succeed")
        node = str((pod.get("spec") or {}).get("nodeName") or "")
        if node not in allowed:
            raise ValidationError(f"Pod {metadata.get('name')} used unexpected node {node}")
        used.add(node)
        statuses = status.get("containerStatuses") or []
        if len(statuses) != 1 or int(statuses[0].get("restartCount") or 0) != 0:
            raise ValidationError(f"Pod {metadata.get('name')} restarted")
        image_id = str(statuses[0].get("imageID") or "").lower()
        if image_digest not in image_id:
            raise ValidationError(
                f"Pod {metadata.get('name')} imageID is not {image_digest}"
            )
        startups.append(pod_startup_seconds(pod))
    if used != allowed:
        raise ValidationError("the workload did not exercise both target nodes")
    return pods, {
        "pod_count": len(pods),
        "nodes_used": sorted(used),
        "startup_seconds": distribution(startups),
    }


def resource_summary(
    samples: list[dict[str, Any]],
    system_pods_payload: dict[str, Any],
    target_nodes: list[str],
) -> dict[str, Any]:
    component_by_pod: dict[tuple[str, str], tuple[str, str]] = {}
    for pod in system_pods_payload.get("items") or []:
        metadata = pod.get("metadata") or {}
        labels = metadata.get("labels") or {}
        name = str(labels.get("app.kubernetes.io/name") or "")
        component = {
            "hooke-node-agent": "node_agent",
            "hooke-controller": "controller",
            "hooke-ingester": "ingester",
        }.get(name)
        if component:
            component_by_pod[
                (str(metadata.get("namespace") or ""), str(metadata.get("name") or ""))
            ] = (component, str((pod.get("spec") or {}).get("nodeName") or ""))

    measurements: dict[str, list[tuple[float, float]]] = defaultdict(list)
    node_agent_measurements: dict[str, list[tuple[float, float]]] = defaultdict(list)
    node_agent_nodes: set[str] = set()
    for sample in samples:
        for item in (sample.get("items") or []):
            metadata = item.get("metadata") or {}
            key = (
                str(metadata.get("namespace") or ""),
                str(metadata.get("name") or ""),
            )
            match = component_by_pod.get(key)
            if not match:
                continue
            component, node = match
            if component == "node_agent":
                if node not in set(target_nodes):
                    continue
                node_agent_nodes.add(node)
            cpu = Decimal(0)
            memory = Decimal(0)
            for container in item.get("containers") or []:
                usage = container.get("usage") or {}
                cpu += quantity(str(usage.get("cpu") or "0"))
                memory += quantity(str(usage.get("memory") or "0"))
            measurement = (float(cpu), float(memory))
            measurements[component].append(measurement)
            if component == "node_agent":
                node_agent_measurements[node].append(measurement)

    result: dict[str, Any] = {}
    for component in ("node_agent", "controller", "ingester"):
        values = measurements.get(component, [])
        cpu_values = [value[0] for value in values]
        memory_values = [value[1] for value in values]
        result[component] = {
            "sample_count": len(values),
            "cpu_cores": {
                "mean": sum(cpu_values) / len(cpu_values) if cpu_values else None,
                "maximum": max(cpu_values) if cpu_values else None,
            },
            "memory_bytes": {
                "mean": (
                    sum(memory_values) / len(memory_values) if memory_values else None
                ),
                "maximum": max(memory_values) if memory_values else None,
            },
        }
    result["node_agent"]["nodes_observed"] = sorted(node_agent_nodes)
    result["node_agent"]["per_node"] = {
        node: {
            "sample_count": len(values),
            "cpu_cores": {
                "mean": sum(value[0] for value in values) / len(values),
                "maximum": max(value[0] for value in values),
            },
            "memory_bytes": {
                "mean": sum(value[1] for value in values) / len(values),
                "maximum": max(value[1] for value in values),
            },
        }
        for node, values in sorted(node_agent_measurements.items())
    }
    return result


def summarize_cell(
    *,
    cell: dict[str, Any],
    run_id: str,
    workload_namespace: str,
    target_nodes: list[str],
    image: str,
    expected_pods: int,
    job_payload: dict[str, Any],
    pods_payload: dict[str, Any],
    events: list[dict[str, Any]],
    metrics_samples: list[dict[str, Any]],
    system_pods_payload: dict[str, Any],
    metrics_before: dict[tuple[str, tuple[tuple[str, str], ...]], float],
    metrics_after: dict[tuple[str, tuple[tuple[str, str], ...]], float],
) -> dict[str, Any]:
    if (job_payload.get("status") or {}).get("succeeded") != expected_pods:
        raise ValidationError("E08 Indexed Job did not reach the expected completions")
    pods, workload = validate_workload_pods(
        pods_payload, target_nodes, image, expected_pods
    )
    pod_uids = {
        str((pod.get("metadata") or {}).get("uid") or "") for pod in pods
    }
    relevant = [
        item
        for item in events
        if item.get("run_id") == run_id
        and item.get("namespace") == workload_namespace
        and item.get("pod_uid") in pod_uids
    ]
    by_pod: dict[str, set[str]] = defaultdict(set)
    controller_events: list[dict[str, Any]] = []
    for item in relevant:
        event_type = str(item.get("event_type") or "")
        source = str(item.get("source_component") or "")
        if source == "kubernetes-pod-watch":
            controller_events.append(item)
            if event_type in CONTROLLER_EVENT_TYPES:
                by_pod[str(item.get("pod_uid"))].add(event_type)

    app_by_pod: dict[str, set[str]] = defaultdict(set)
    for item in relevant:
        if (
            item.get("source_component") == "e08-workload"
            and item.get("event_type") in APPLICATION_EVENT_TYPES
        ):
            app_by_pod[str(item.get("pod_uid"))].add(str(item.get("event_type")))
    missing_application = sorted(
        uid for uid in pod_uids if app_by_pod[uid] != APPLICATION_EVENT_TYPES
    )
    if missing_application:
        raise ValidationError(
            f"application events are incomplete for {len(missing_application)} Pods"
        )

    complete_uids = sorted(
        uid for uid in pod_uids if CONTROLLER_EVENT_TYPES.issubset(by_pod[uid])
    )
    trace_complete_rate = len(complete_uids) / len(pod_uids)
    enabled = bool(cell["collector_enabled"])
    sample_percent = int(cell["sample_percent"])
    if enabled:
        gauge = prom_value(
            metrics_after, "hooke_collector_sample_percent"
        )
        if gauge != float(sample_percent):
            raise ValidationError(
                f"collector sample gauge is {gauge}, expected {sample_percent}"
            )
        kept = prom_delta(
            metrics_before,
            metrics_after,
            "hooke_collector_sampling_events_total",
            {"decision": "kept"},
        )
        sampled_out = prom_delta(
            metrics_before,
            metrics_after,
            "hooke_collector_sampling_events_total",
            {"decision": "sampled_out"},
        )
        enqueued = prom_delta(
            metrics_before,
            metrics_after,
            "hooke_collector_queue_events_total",
            {"result": "enqueued"},
        )
        queue_full = prom_delta(
            metrics_before,
            metrics_after,
            "hooke_collector_queue_events_total",
            {"result": "full"},
        )
        queue_invalid = prom_delta(
            metrics_before,
            metrics_after,
            "hooke_collector_queue_events_total",
            {"result": "invalid"},
        )
        delivery_sent = prom_delta(
            metrics_before,
            metrics_after,
            "hooke_collector_delivery_events_total",
            {"result": "sent"},
        )
        delivery_error = prom_delta(
            metrics_before,
            metrics_after,
            "hooke_collector_delivery_events_total",
            {"result": "error"},
        )
        queue_depth = prom_value(metrics_after, "hooke_collector_queue_depth")
        if kept <= 0 or enqueued <= 0:
            raise ValidationError("collector kept/enqueued no events")
        if (
            queue_full != 0
            or queue_invalid != 0
            or delivery_error != 0
            or queue_depth != 0
        ):
            raise ValidationError("collector queue or delivery loss was observed")
        if kept != enqueued:
            raise ValidationError("not every retained collector event was enqueued")
        if delivery_sent != enqueued:
            raise ValidationError("not every enqueued collector event was persisted")
        if sample_percent == 10:
            if sampled_out <= 0:
                raise ValidationError("10-percent mode sampled out no events")
            if not (0 < trace_complete_rate < 1):
                raise ValidationError(
                    "10-percent mode did not produce a partial Pod trace population"
                )
        elif sample_percent == 100:
            if sampled_out != 0 or trace_complete_rate != 1.0:
                raise ValidationError("100-percent mode did not retain complete traces")
    else:
        kept = sampled_out = enqueued = queue_full = queue_invalid = 0.0
        delivery_sent = delivery_error = 0.0
        queue_depth = 0.0
        if controller_events or trace_complete_rate != 0:
            raise ValidationError("collector-off persisted controller events")

    resources = resource_summary(
        metrics_samples, system_pods_payload, target_nodes
    )
    if enabled:
        if resources["controller"]["sample_count"] <= 0:
            raise ValidationError("controller resource samples are missing")
        if set(resources["node_agent"]["nodes_observed"]) != set(target_nodes):
            raise ValidationError("node-agent resources were not sampled on both nodes")
    else:
        if (
            resources["controller"]["sample_count"] != 0
            or resources["node_agent"]["sample_count"] != 0
        ):
            raise ValidationError("collector-off still ran collector Pods")

    persistence_seconds = [
        (int(item["ingest_time_ns"]) - int(item["observed_time_ns"]))
        / 1_000_000_000
        for item in relevant
        if int(item.get("ingest_time_ns") or 0) > 0
        and int(item.get("observed_time_ns") or 0) > 0
    ]
    if any(value < 0 for value in persistence_seconds):
        raise ValidationError("negative event persistence latency")

    return {
        **cell,
        "gate": "PASS",
        "run_id": run_id,
        "workload_namespace": workload_namespace,
        "target_nodes": target_nodes,
        "image": image,
        "workload": workload,
        "application_event_count": sum(len(value) for value in app_by_pod.values()),
        "controller_event_count": len(controller_events),
        "complete_trace_count": len(complete_uids),
        "trace_complete_rate": trace_complete_rate,
        "persistence_latency_seconds": distribution(persistence_seconds),
        "collector_metrics": {
            "sample_percent": sample_percent,
            "sampling_kept": kept,
            "sampling_sampled_out": sampled_out,
            "queue_enqueued": enqueued,
            "queue_full": queue_full,
            "queue_invalid": queue_invalid,
            "delivery_sent": delivery_sent,
            "delivery_error": delivery_error,
            "queue_depth_final": queue_depth,
            "ring_buffer_supported": False,
            "ring_buffer_note": (
                "The current collector is informer-based; no eBPF ring buffer "
                "exists, so ring-buffer counters are intentionally not fabricated."
            ),
        },
        "resources": resources,
    }


def aggregate(
    schedule: list[dict[str, Any]], cells: list[dict[str, Any]]
) -> dict[str, Any]:
    expected_ids = [item["cell_id"] for item in schedule]
    if [item.get("cell_id") for item in cells] != expected_ids:
        raise ValidationError("cell summaries do not match the frozen E08 order")
    if any(item.get("gate") != "PASS" for item in cells):
        raise ValidationError("at least one E08 cell failed")
    target_nodes = [tuple(item.get("target_nodes") or []) for item in cells]
    if len(set(target_nodes)) != 1 or len(target_nodes[0]) != 2:
        raise ValidationError("all E08 cells must use the same two target nodes")
    images = {str(item.get("image") or "") for item in cells}
    if len(images) != 1:
        raise ValidationError("all E08 cells must use one immutable image")
    return {
        "experiment": "E08",
        "scope": "two-worker-low-rate-smoke",
        "gate": "PASS",
        "formal_statistics_executed": False,
        "formal_statistics_note": (
            "KS tests and confidence intervals are intentionally deferred until "
            "the 8/16-node formal experiment."
        ),
        "target_nodes": list(target_nodes[0]),
        "image": next(iter(images)),
        "cells": cells,
    }


def render_report(summary: dict[str, Any]) -> str:
    lines = [
        "# E08 collector overhead smoke",
        "",
        f"- Gate: **{summary['gate']}**",
        f"- Scope: `{summary['scope']}`",
        f"- Target nodes: `{', '.join(summary['target_nodes'])}`",
        f"- Immutable image: `{summary['image']}`",
        "- Formal KS/CI: not executed (smoke only)",
        "- eBPF ring buffer: unsupported in this collector; no synthetic values reported",
        "",
        "| mode | sample | Pods | controller events | trace complete | controller CPU max | node-agent CPU max | persistence p50 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for cell in summary["cells"]:
        resources = cell["resources"]
        persistence = cell["persistence_latency_seconds"]["p50"]
        lines.append(
            "| {mode} | {sample}% | {pods} | {events} | {rate:.1%} | {controller} | {agent} | {latency} |".format(
                mode=cell["mode"],
                sample=cell["sample_percent"],
                pods=cell["workload"]["pod_count"],
                events=cell["controller_event_count"],
                rate=cell["trace_complete_rate"],
                controller=_format_number(
                    resources["controller"]["cpu_cores"]["maximum"]
                ),
                agent=_format_number(
                    resources["node_agent"]["cpu_cores"]["maximum"]
                ),
                latency=_format_number(persistence),
            )
        )
    lines.extend(
        [
            "",
            "This PASS proves activation, collection, persistence, loss counters, "
            "and two-node placement at low rate. It does not prove production "
            "overhead or statistical equivalence.",
            "",
        ]
    )
    return "\n".join(lines)


def _format_number(value: Any) -> str:
    return "n/a" if value is None else f"{float(value):.6f}"


def command_schedule(args: argparse.Namespace) -> None:
    rows = generate_schedule()
    write_tsv(Path(args.output), SCHEDULE_FIELDS, rows)
    if args.json_output:
        atomic_json(Path(args.json_output), rows)


def command_render_workload(args: argparse.Namespace) -> None:
    manifest = workload_manifest(
        namespace=args.namespace,
        name=args.name,
        run_id=args.run_id,
        cluster_id=args.cluster_id,
        image=args.image,
        ingester_url=args.ingester_url,
        target_nodes=args.target_node,
        completions=args.completions,
        parallelism=args.parallelism,
        work_duration=args.work_duration,
        cpu_request=args.cpu_request,
        memory_request=args.memory_request,
    )
    atomic_json(Path(args.output), manifest)


def command_summarize_cell(args: argparse.Namespace) -> None:
    schedule = generate_schedule()
    match = next(
        (item for item in schedule if item["cell_id"] == args.cell_id), None
    )
    if match is None:
        raise ValidationError(f"unknown E08 cell {args.cell_id}")
    summary = summarize_cell(
        cell=match,
        run_id=args.run_id,
        workload_namespace=args.workload_namespace,
        target_nodes=args.target_node,
        image=args.image,
        expected_pods=args.expected_pods,
        job_payload=load_json(Path(args.job)),
        pods_payload=load_json(Path(args.pods)),
        events=load_ndjson(Path(args.events)),
        metrics_samples=load_ndjson(Path(args.resource_samples)),
        system_pods_payload=load_json(Path(args.system_pods)),
        metrics_before=parse_prometheus(Path(args.metrics_before)),
        metrics_after=parse_prometheus(Path(args.metrics_after)),
    )
    atomic_json(Path(args.output), summary)


def command_aggregate(args: argparse.Namespace) -> None:
    schedule = generate_schedule()
    cells = [load_json(Path(path)) for path in args.cell]
    summary = aggregate(schedule, cells)
    atomic_json(Path(args.output), summary)
    atomic_text(Path(args.report), render_report(summary))


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    subparsers = value.add_subparsers(dest="command", required=True)

    schedule = subparsers.add_parser("schedule")
    schedule.add_argument("--output", required=True)
    schedule.add_argument("--json-output")
    schedule.set_defaults(function=command_schedule)

    workload = subparsers.add_parser("render-workload")
    workload.add_argument("--namespace", required=True)
    workload.add_argument("--name", required=True)
    workload.add_argument("--run-id", required=True)
    workload.add_argument("--cluster-id", required=True)
    workload.add_argument("--image", required=True)
    workload.add_argument("--ingester-url", required=True)
    workload.add_argument("--target-node", action="append", required=True)
    workload.add_argument("--completions", type=int, default=20)
    workload.add_argument("--parallelism", type=int, default=2)
    workload.add_argument("--work-duration", default="5s")
    workload.add_argument("--cpu-request", default="25m")
    workload.add_argument("--memory-request", default="32Mi")
    workload.add_argument("--output", required=True)
    workload.set_defaults(function=command_render_workload)

    cell = subparsers.add_parser("summarize-cell")
    cell.add_argument("--cell-id", required=True)
    cell.add_argument("--run-id", required=True)
    cell.add_argument("--workload-namespace", required=True)
    cell.add_argument("--target-node", action="append", required=True)
    cell.add_argument("--image", required=True)
    cell.add_argument("--expected-pods", type=int, required=True)
    cell.add_argument("--job", required=True)
    cell.add_argument("--pods", required=True)
    cell.add_argument("--events", required=True)
    cell.add_argument("--resource-samples", required=True)
    cell.add_argument("--system-pods", required=True)
    cell.add_argument("--metrics-before", required=True)
    cell.add_argument("--metrics-after", required=True)
    cell.add_argument("--output", required=True)
    cell.set_defaults(function=command_summarize_cell)

    combined = subparsers.add_parser("aggregate")
    combined.add_argument("--cell", action="append", required=True)
    combined.add_argument("--output", required=True)
    combined.add_argument("--report", required=True)
    combined.set_defaults(function=command_aggregate)
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        args.function(args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"E08 validation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
