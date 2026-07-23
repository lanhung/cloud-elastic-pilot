#!/usr/bin/env python3
"""Pure validation and summarization helpers for the E03 ACK pilot.

The shell orchestrator owns cluster mutations.  This module deliberately keeps
all schedule generation and artifact validation side-effect free so the
scientific gates can be unit tested without an ACK cluster.
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlsplit


SIZE_LEVELS_MIB = (100, 500, 1024)
CONCURRENCY_LEVELS = (1, 2, 4)
NODE_STATES = ("existing", "new")
CACHE_STATES = ("cold", "warm")


class ValidationError(ValueError):
    pass


def read_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot read JSON {path}: {exc}") from exc


def write_json(path: Path | None, payload: Any) -> None:
    content = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if path is None:
        sys.stdout.write(content)
        return
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def write_tsv(path: Path, fields: list[str], rows: Iterable[dict[str, Any]]) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(
            stream, fieldnames=fields, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        for row in rows:
            writer.writerow({field: format_tsv(row.get(field)) for field in fields})
    temporary.chmod(0o600)
    temporary.replace(path)


def format_tsv(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (dict, list)):
        return json.dumps(value, separators=(",", ":"), sort_keys=True)
    return str(value)


def read_tsv(path: Path) -> list[dict[str, str]]:
    try:
        with path.open(encoding="utf-8", newline="") as stream:
            return list(csv.DictReader(stream, delimiter="\t"))
    except OSError as exc:
        raise ValidationError(f"cannot read TSV {path}: {exc}") from exc


def experiment_cells() -> list[dict[str, Any]]:
    """Return the frozen E03 pilot matrix.

    Warm cache requires an already-existing node.  A "new+warm" cell would no
    longer be a new-node observation after prewarming, so it is excluded rather
    than mislabeled.  The resulting matrix has 27 cells per repetition:
    18 existing-node cells and 9 fresh-node cold-cache cells.
    """

    cells: list[dict[str, Any]] = []
    for node_state in NODE_STATES:
        cache_states = CACHE_STATES if node_state == "existing" else ("cold",)
        for cache_state in cache_states:
            for size_mib in SIZE_LEVELS_MIB:
                for concurrency in CONCURRENCY_LEVELS:
                    cell = (
                        f"{node_state}-{cache_state}-"
                        f"{size_mib}mib-c{concurrency}"
                    )
                    cells.append(
                        {
                            "cell": cell,
                            "node_state": node_state,
                            "cache_state": cache_state,
                            "size_mib": size_mib,
                            "requested_concurrency": concurrency,
                        }
                    )
    return cells


def generate_schedule(repetitions: int, seed: int) -> list[dict[str, Any]]:
    if repetitions < 1:
        raise ValidationError("repetitions must be positive")
    if seed < 0:
        raise ValidationError("seed must be non-negative")
    rng = random.Random(seed)
    schedule: list[dict[str, Any]] = []
    sequence = 0
    frozen_cells = experiment_cells()
    for block in range(1, repetitions + 1):
        block_cells = [dict(item) for item in frozen_cells]
        rng.shuffle(block_cells)
        for item in block_cells:
            sequence += 1
            item.update(
                {
                    "sequence": sequence,
                    "block": block,
                    "repetition": block,
                }
            )
            schedule.append(item)
    return schedule


def parse_summary(path: Path) -> tuple[str, dict[str, str]]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ValidationError(f"cannot read summary {path}: {exc}") from exc
    result = ""
    for line in lines:
        if not line.startswith("- ") or ": " not in line:
            continue
        key, value = line[2:].split(": ", 1)
        value = value.strip().strip("`")
        if key == "result":
            result = value.replace("**", "")
        values[key] = value
    if not result:
        raise ValidationError("child summary has no result")
    return result, values


def read_ndjson(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ValidationError(f"cannot read NDJSON {path}: {exc}") from exc
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValidationError(
                f"invalid NDJSON at {path}:{line_number}"
            ) from exc
        if not isinstance(item, dict):
            raise ValidationError(f"non-object NDJSON at {path}:{line_number}")
        records.append(item)
    return records


def immutable_digest(image: str) -> str:
    marker = "@sha256:"
    if marker not in image:
        raise ValidationError(f"image is not immutable: {image}")
    digest = image.rsplit(marker, 1)[1]
    if len(digest) != 64 or any(ch not in "0123456789abcdefABCDEF" for ch in digest):
        raise ValidationError(f"image has invalid sha256 digest: {image}")
    return f"sha256:{digest.lower()}"


def registry_host(image: str) -> str:
    repository = image.split("@", 1)[0]
    host = urlsplit(f"//{repository}").hostname
    if not host:
        raise ValidationError(f"cannot derive registry host from {image}")
    return host


def load_run_pods(
    artifact_dir: Path, run_id: str
) -> dict[str, dict[str, Any]]:
    selected: dict[str, dict[str, Any]] = {}
    for path in sorted(artifact_dir.glob("pods-*.json")):
        payload = read_json(path)
        items = payload.get("items") if isinstance(payload, dict) else None
        if not isinstance(items, list):
            raise ValidationError(f"{path} has no items array")
        for item in items:
            if not isinstance(item, dict):
                continue
            metadata = item.get("metadata") or {}
            annotations = metadata.get("annotations") or {}
            labels = metadata.get("labels") or {}
            if (
                annotations.get("hooke.io/run-id") != run_id
                or labels.get("hooke.io/experiment") != "true"
            ):
                continue
            uid = str(metadata.get("uid") or "")
            if not uid:
                raise ValidationError(f"run-owned Pod in {path} has no UID")
            previous = selected.get(uid)
            if previous is not None:
                previous_identity = (
                    (previous.get("metadata") or {}).get("name"),
                    (previous.get("spec") or {}).get("nodeName"),
                )
                current_identity = (
                    metadata.get("name"),
                    (item.get("spec") or {}).get("nodeName"),
                )
                if previous_identity != current_identity:
                    raise ValidationError(f"Pod UID {uid} changed identity in artifacts")
                continue
            selected[uid] = item
    if not selected:
        raise ValidationError("no run-owned Pod snapshots found")
    return selected


def pod_container(pod: dict[str, Any]) -> dict[str, Any]:
    containers = (pod.get("spec") or {}).get("containers") or []
    selected = [
        item
        for item in containers
        if isinstance(item, dict) and item.get("name") == "app"
    ]
    if len(selected) != 1:
        raise ValidationError("each E03 Pod must contain exactly one app container")
    return selected[0]


def selected_nodes(
    payload: dict[str, Any], selector_key: str, selector_value: str
) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    items = payload.get("items")
    if not isinstance(items, list):
        raise ValidationError("Node payload has no items array")
    for item in items:
        metadata = item.get("metadata") or {}
        labels = metadata.get("labels") or {}
        if labels.get(selector_key) != selector_value:
            continue
        uid = str(metadata.get("uid") or "")
        name = str(metadata.get("name") or "")
        if not uid or not name:
            raise ValidationError("selected Node has no name/UID")
        if uid in result:
            raise ValidationError(f"duplicate selected Node UID: {uid}")
        result[uid] = item
    return result


def node_ready(node: dict[str, Any]) -> bool:
    return any(
        item.get("type") == "Ready" and item.get("status") == "True"
        for item in (node.get("status") or {}).get("conditions") or []
    )


def exact_events(
    events: Iterable[dict[str, Any]], pod_uid: str, event_type: str
) -> list[dict[str, Any]]:
    selected = [
        item
        for item in events
        if item.get("pod_uid") == pod_uid and item.get("event_type") == event_type
    ]
    for item in selected:
        if item.get("approximate") is not False:
            raise ValidationError(
                f"{event_type} for Pod {pod_uid} is not exact evidence"
            )
        if not isinstance(item.get("event_time_ns"), int):
            raise ValidationError(
                f"{event_type} for Pod {pod_uid} has no integer timestamp"
            )
    return selected


def require_single_event(
    events: Iterable[dict[str, Any]], pod_uid: str, event_type: str
) -> dict[str, Any]:
    selected = exact_events(events, pod_uid, event_type)
    if len(selected) != 1:
        raise ValidationError(
            f"Pod {pod_uid} has {len(selected)} {event_type} events; expected 1"
        )
    return selected[0]


def event_image(event: dict[str, Any]) -> str:
    image = str(event.get("image_ref") or "")
    if not image:
        raise ValidationError(f"{event.get('event_type')} has no image_ref")
    immutable_digest(image)
    return image


def require_event_target(
    event: dict[str, Any],
    *,
    pod_uid: str,
    pod_name: str,
    namespace: str,
    node_name: str,
    image: str,
) -> None:
    expected = {
        "pod_uid": pod_uid,
        "pod_name": pod_name,
        "namespace": namespace,
        "node_name": node_name,
    }
    for key, value in expected.items():
        if event.get(key) != value:
            raise ValidationError(
                f"{event.get('event_type')} {key}={event.get(key)!r}, "
                f"expected {value!r}"
            )
    if event_image(event) != image:
        raise ValidationError(
            f"{event.get('event_type')} image does not match its Pod"
        )
    digest = str(event.get("image_digest") or "").lower()
    if digest != immutable_digest(image):
        raise ValidationError(
            f"{event.get('event_type')} digest does not match its Pod image"
        )


def overlap_metrics(intervals: list[tuple[int, int]]) -> tuple[int, int]:
    """Return maximum positive-duration concurrency and all-active overlap."""

    if not intervals:
        return 0, 0
    points: list[tuple[int, int]] = []
    for start, end in intervals:
        if start <= 0 or end <= start:
            raise ValidationError("image pull interval is non-positive")
        points.append((start, 1))
        points.append((end, -1))
    # End before start at equal timestamps: touching intervals are not overlap.
    points.sort(key=lambda item: (item[0], item[1]))
    active = 0
    maximum = 0
    previous_time: int | None = None
    duration_at_max = 0
    for at_ns, delta in points:
        if previous_time is not None and at_ns > previous_time:
            if active > maximum:
                maximum = active
                duration_at_max = at_ns - previous_time
            elif active == maximum:
                duration_at_max += at_ns - previous_time
        active += delta
        if active < 0:
            raise ValidationError("image pull interval sweep became negative")
        previous_time = at_ns
    if active != 0:
        raise ValidationError("image pull interval sweep did not close")
    return maximum, duration_at_max


def label_value(node: dict[str, Any], keys: tuple[str, ...]) -> str:
    labels = (node.get("metadata") or {}).get("labels") or {}
    for key in keys:
        value = labels.get(key)
        if value:
            return str(value)
    return ""


def validate_run(
    *,
    artifact_dir: Path,
    node_state: str,
    cache_state: str,
    size_mib: int,
    requested_concurrency: int,
    images: list[str],
    cluster_id: str,
    selector_key: str,
    selector_value: str,
    expected_instance_type: str,
    expected_zone: str,
    expected_registry: str,
    disk_type: str,
    min_download_bytes: int,
    max_trigger_spread_ms: float,
    existing_node_name: str,
    require_unpack: bool,
) -> dict[str, Any]:
    if node_state not in NODE_STATES:
        raise ValidationError(f"unsupported node_state: {node_state}")
    if cache_state not in CACHE_STATES:
        raise ValidationError(f"unsupported cache_state: {cache_state}")
    if node_state == "new" and cache_state != "cold":
        raise ValidationError("new-node runs must use cold cache")
    if size_mib not in SIZE_LEVELS_MIB:
        raise ValidationError(f"unsupported size level: {size_mib}")
    if requested_concurrency not in CONCURRENCY_LEVELS:
        raise ValidationError(
            f"unsupported concurrency level: {requested_concurrency}"
        )
    if len(images) != requested_concurrency:
        raise ValidationError("image count must equal requested concurrency")
    if len(set(images)) != len(images):
        raise ValidationError("E03 concurrent images must use distinct references")
    digests = [immutable_digest(image) for image in images]
    if len(set(digests)) != len(digests):
        raise ValidationError("E03 concurrent images must use distinct digests")
    registries = {registry_host(image) for image in images}
    if registries != {expected_registry}:
        raise ValidationError(
            f"image registry {sorted(registries)} does not equal {expected_registry}"
        )
    if min_download_bytes < 1:
        raise ValidationError("min_download_bytes must be positive")
    if max_trigger_spread_ms <= 0:
        raise ValidationError("max_trigger_spread_ms must be positive")
    required_strings = {
        "cluster_id": cluster_id,
        "selector_key": selector_key,
        "selector_value": selector_value,
        "expected_instance_type": expected_instance_type,
        "expected_zone": expected_zone,
        "expected_registry": expected_registry,
        "disk_type": disk_type,
    }
    for key, value in required_strings.items():
        if not value:
            raise ValidationError(f"{key} must be non-empty")
    if node_state == "existing" and not existing_node_name:
        raise ValidationError("existing_node_name is required for existing-node runs")

    run = read_json(artifact_dir / "run.json")
    run_id = str(run.get("run_id") or "")
    if not run_id or run.get("cluster_id") != cluster_id:
        raise ValidationError("child run identity does not match E03 input")
    labels = run.get("labels") or {}
    expected_cell = (
        f"{node_state}-{cache_state}-{size_mib}mib-c{requested_concurrency}"
    )
    expected_labels = {
        "experiment": "E03-image-cache-concurrency",
        "phase": "pilot",
        "cell": expected_cell,
        "node_state": node_state,
        "cache_state": cache_state,
        "size_mib": size_mib,
        "requested_concurrency": requested_concurrency,
    }
    for key, expected in expected_labels.items():
        if labels.get(key) != expected:
            raise ValidationError(
                f"run label {key}={labels.get(key)!r}, expected {expected!r}"
            )
    numeric_labels: dict[str, int] = {}
    for key in ("sequence", "block", "repetition", "random_seed"):
        value = labels.get(key)
        if not isinstance(value, int) or isinstance(value, bool):
            raise ValidationError(f"run label {key} is not an integer")
        numeric_labels[key] = value
    if any(numeric_labels[key] < 1 for key in ("sequence", "block", "repetition")):
        raise ValidationError("run sequence/block/repetition labels must be positive")
    if numeric_labels["random_seed"] < 0:
        raise ValidationError("run random_seed label must be non-negative")
    expected_digests_csv = ",".join(digests)
    if labels.get("image_digests_csv") != expected_digests_csv:
        raise ValidationError("run image digest labels do not match the E03 images")

    result, summary = parse_summary(artifact_dir / "summary.md")
    if result != "PASS":
        raise ValidationError(f"child Gate-S did not pass: {result}")
    for key in (
        "traces",
        "expected_traces",
        "complete_traces",
        "image_layer_samples",
        "exact_image_samples",
        "exact_pod_samples",
        "exact_app_samples",
    ):
        try:
            value = int(summary[key])
        except (KeyError, ValueError) as exc:
            raise ValidationError(f"child summary has invalid {key}") from exc
        if value != requested_concurrency:
            raise ValidationError(
                f"child summary {key}={value}, expected {requested_concurrency}"
            )
    if int(summary.get("invalid_order_count", "-1")) != 0:
        raise ValidationError("child trace contains invalid event ordering")
    if int(summary.get("untraceable_primary_samples", "-1")) != 0:
        raise ValidationError("child trace contains untraceable primary samples")
    try:
        exact_node_samples = int(summary["exact_node_samples"])
    except (KeyError, ValueError) as exc:
        raise ValidationError("child summary has invalid exact_node_samples") from exc
    expected_node_samples = requested_concurrency if node_state == "new" else 0
    if exact_node_samples != expected_node_samples:
        raise ValidationError(
            f"exact_node_samples={exact_node_samples}, "
            f"expected {expected_node_samples}"
        )
    if summary.get("image_batch_enabled") != "true":
        raise ValidationError("child did not run in image batch mode")
    if int(summary.get("image_batch_size", "0")) != requested_concurrency:
        raise ValidationError("child image batch size does not match the cell")

    batch_timing = read_json(artifact_dir / "image-batch-timing.json")
    expected_path = "fixed" if node_state == "existing" else "node-scale"
    if (
        batch_timing.get("run_id") != run_id
        or batch_timing.get("cluster_id") != cluster_id
        or batch_timing.get("requested_concurrency") != requested_concurrency
        or batch_timing.get("path") != expected_path
        or batch_timing.get("clock_type") != "CLOCK_MONOTONIC"
    ):
        raise ValidationError("image batch timing identity does not match the run")
    namespace_evidence = read_json(artifact_dir / "experiment-namespace.json")
    if (
        namespace_evidence.get("run_id") != run_id
        or namespace_evidence.get("name") != batch_timing.get("namespace")
        or namespace_evidence.get("uid") != batch_timing.get("namespace_uid")
        or namespace_evidence.get("created_by_run") is not True
    ):
        raise ValidationError("image batch namespace identity is not exact")
    deployments = batch_timing.get("deployments")
    if not isinstance(deployments, list) or len(deployments) != requested_concurrency:
        raise ValidationError("image batch timing has an invalid Deployment set")
    try:
        batch_start_ns = int(batch_timing["batch_start_monotonic_ns"])
        batch_end_ns = int(batch_timing["batch_end_monotonic_ns"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValidationError("image batch timing has invalid batch bounds") from exc
    if batch_start_ns <= 0 or batch_end_ns <= batch_start_ns:
        raise ValidationError("image batch timing bounds are non-positive")
    timing_workloads: set[str] = set()
    timing_pods: dict[str, str] = {}
    patch_starts: list[int] = []
    for deployment in deployments:
        if not isinstance(deployment, dict):
            raise ValidationError("image batch Deployment evidence is not an object")
        workload = str(deployment.get("workload") or "")
        deployment_uid = str(deployment.get("deployment_uid") or "")
        pod_uid = str(deployment.get("pod_uid") or "")
        pod_name = str(deployment.get("pod_name") or "")
        if not all((workload, deployment_uid, pod_uid, pod_name)):
            raise ValidationError("image batch Deployment evidence is incomplete")
        if workload in timing_workloads or pod_uid in timing_pods:
            raise ValidationError("image batch Deployment/Pod evidence is duplicated")
        timing_workloads.add(workload)
        timing_pods[pod_uid] = pod_name
        for phase in ("scale", "rollout"):
            timing = deployment.get(phase)
            if not isinstance(timing, dict) or timing.get("returncode") != 0:
                raise ValidationError(
                    f"image batch {phase} evidence did not succeed for {workload}"
                )
            try:
                started_ns = int(timing["started_monotonic_ns"])
                ended_ns = int(timing["ended_monotonic_ns"])
            except (KeyError, TypeError, ValueError) as exc:
                raise ValidationError(
                    f"image batch {phase} timing is invalid for {workload}"
                ) from exc
            if not (
                batch_start_ns <= started_ns <= ended_ns <= batch_end_ns
            ):
                raise ValidationError(
                    f"image batch {phase} timing is outside batch bounds"
                )
            if phase == "scale":
                patch_starts.append(started_ns)
    try:
        trigger_spread_ns = int(batch_timing["trigger_spread_ns"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValidationError("image batch timing has no trigger_spread_ns") from exc
    if trigger_spread_ns < 0:
        raise ValidationError("image batch trigger spread is negative")
    if trigger_spread_ns != max(patch_starts) - min(patch_starts):
        raise ValidationError("image batch trigger spread does not match patch timings")
    trigger_spread_ms = trigger_spread_ns / 1_000_000
    if trigger_spread_ms > max_trigger_spread_ms:
        raise ValidationError(
            f"batch trigger spread {trigger_spread_ms:.3f} ms exceeds "
            f"{max_trigger_spread_ms:.3f} ms"
        )

    pods = load_run_pods(artifact_dir, run_id)
    if len(pods) != requested_concurrency:
        raise ValidationError(
            f"observed {len(pods)} run Pods, expected {requested_concurrency}"
        )
    pod_namespaces = {
        str((pod.get("metadata") or {}).get("namespace") or "")
        for pod in pods.values()
    }
    if pod_namespaces != {str(batch_timing.get("namespace") or "")}:
        raise ValidationError("run Pods do not match the measured batch namespace")
    pod_workloads = {
        str(((pod.get("metadata") or {}).get("labels") or {}).get("app") or "")
        for pod in pods.values()
    }
    if "" in pod_workloads or pod_workloads != timing_workloads:
        raise ValidationError("run Pods do not match the measured Deployment set")
    artifact_pod_names = {
        uid: str((pod.get("metadata") or {}).get("name") or "")
        for uid, pod in pods.items()
    }
    if artifact_pod_names != timing_pods:
        raise ValidationError("run Pods do not match batch timing Pod identities")
    scheduled_nodes = {
        str((pod.get("spec") or {}).get("nodeName") or "") for pod in pods.values()
    }
    if "" in scheduled_nodes or len(scheduled_nodes) != 1:
        raise ValidationError(
            f"E03 Pods were not all scheduled on one Node: {sorted(scheduled_nodes)}"
        )
    scheduled_node = next(iter(scheduled_nodes))
    if node_state == "existing" and scheduled_node != existing_node_name:
        raise ValidationError(
            f"existing-node run used {scheduled_node}, expected {existing_node_name}"
        )

    pod_images: dict[str, str] = {}
    for uid, pod in pods.items():
        container = pod_container(pod)
        image = str(container.get("image") or "")
        immutable_digest(image)
        pod_images[uid] = image
        if container.get("imagePullPolicy") != "IfNotPresent":
            raise ValidationError("E03 app container must use IfNotPresent")
    if set(pod_images.values()) != set(images):
        raise ValidationError("Pod image set does not match the E03 cell")

    nodes_after = read_json(artifact_dir / "nodes-after.json")
    after_selected = selected_nodes(nodes_after, selector_key, selector_value)
    matching_nodes = [
        node
        for node in after_selected.values()
        if (node.get("metadata") or {}).get("name") == scheduled_node
    ]
    if len(matching_nodes) != 1:
        raise ValidationError("scheduled Node is not uniquely in the selected pool")
    target_node = matching_nodes[0]
    if not node_ready(target_node):
        raise ValidationError("scheduled E03 Node is not Ready")
    if (target_node.get("spec") or {}).get("unschedulable") is True:
        raise ValidationError("scheduled E03 Node is unschedulable")

    instance_type = label_value(
        target_node,
        (
            "node.kubernetes.io/instance-type",
            "beta.kubernetes.io/instance-type",
        ),
    )
    zone = label_value(
        target_node,
        ("topology.kubernetes.io/zone", "failure-domain.beta.kubernetes.io/zone"),
    )
    if instance_type != expected_instance_type:
        raise ValidationError(
            f"instance type {instance_type!r} != {expected_instance_type!r}"
        )
    if zone != expected_zone:
        raise ValidationError(f"zone {zone!r} != {expected_zone!r}")

    new_node_uid = ""
    if node_state == "new":
        before_selected = selected_nodes(
            read_json(artifact_dir / "nodes-before.json"),
            selector_key,
            selector_value,
        )
        new_uids = set(after_selected) - set(before_selected)
        if len(before_selected) != 0 or len(new_uids) != 1:
            raise ValidationError(
                "new-node E03 run requires an empty pool and exactly one new Node"
            )
        new_node_uid = next(iter(new_uids))
        if (after_selected[new_node_uid].get("metadata") or {}).get(
            "name"
        ) != scheduled_node:
            raise ValidationError("Pods did not land on the unique new Node")

    events = read_ndjson(artifact_dir / "runtime-events.ndjson")
    for event in events:
        if event.get("run_id") != run_id or event.get("cluster_id") != cluster_id:
            raise ValidationError("runtime event has foreign run/cluster identity")

    pull_intervals: list[tuple[int, int]] = []
    pull_latencies_ms: list[float] = []
    image_total_latencies_ms: list[float] = []
    download_latencies_ms: list[float] = []
    download_bytes: list[int] = []
    unpack_latencies_ms: list[float] = []
    for pod_uid, image in pod_images.items():
        metadata = pods[pod_uid].get("metadata") or {}
        pod_name = str(metadata.get("name") or "")
        namespace = str(metadata.get("namespace") or "")
        pull_start_ns: int | None = None
        pull_end_ns: int | None = None
        if cache_state == "cold":
            if exact_events(events, pod_uid, "IMAGE_CACHE_HIT"):
                raise ValidationError("cold-cache run contains IMAGE_CACHE_HIT")
            start = require_single_event(events, pod_uid, "IMAGE_PULL_START")
            end = require_single_event(events, pod_uid, "IMAGE_PULL_END")
            for event in (start, end):
                require_event_target(
                    event,
                    pod_uid=pod_uid,
                    pod_name=pod_name,
                    namespace=namespace,
                    node_name=scheduled_node,
                    image=image,
                )
            pull_start_ns = int(start["event_time_ns"])
            pull_end_ns = int(end["event_time_ns"])
            if pull_end_ns <= pull_start_ns:
                raise ValidationError("IMAGE_PULL_END is not after start")
            attributes = end.get("attributes") or {}
            try:
                transferred = int(attributes["download_bytes"])
            except (KeyError, TypeError, ValueError) as exc:
                raise ValidationError("cold pull has no integer download_bytes") from exc
            if transferred < min_download_bytes:
                raise ValidationError(
                    f"download_bytes {transferred} below floor {min_download_bytes}"
                )
            pull_intervals.append((pull_start_ns, pull_end_ns))
            pull_latencies_ms.append(
                (pull_end_ns - pull_start_ns) / 1_000_000
            )
            download_bytes.append(transferred)
        else:
            if exact_events(events, pod_uid, "IMAGE_PULL_START") or exact_events(
                events, pod_uid, "IMAGE_PULL_END"
            ):
                raise ValidationError("warm-cache run contains an image pull")
            hit = require_single_event(events, pod_uid, "IMAGE_CACHE_HIT")
            require_event_target(
                hit,
                pod_uid=pod_uid,
                pod_name=pod_name,
                namespace=namespace,
                node_name=scheduled_node,
                image=image,
            )
            pull_latencies_ms.append(0.0)
            image_total_latencies_ms.append(0.0)
            download_bytes.append(0)

        unpack_starts = exact_events(events, pod_uid, "IMAGE_UNPACK_START")
        unpack_ends = exact_events(events, pod_uid, "IMAGE_UNPACK_END")
        if cache_state == "warm" and (unpack_starts or unpack_ends):
            raise ValidationError("warm-cache run contains image unpack evidence")
        if require_unpack and cache_state == "cold":
            if len(unpack_starts) != 1 or len(unpack_ends) != 1:
                raise ValidationError(
                    "unpack substage is required but exact endpoints are missing"
                )
            unpack_start_ns = int(unpack_starts[0]["event_time_ns"])
            unpack_end_ns = int(unpack_ends[0]["event_time_ns"])
            if unpack_end_ns <= unpack_start_ns:
                raise ValidationError("image unpack interval is non-positive")
            unpack_latencies_ms.append(
                (unpack_end_ns - unpack_start_ns) / 1_000_000
            )
        elif unpack_starts or unpack_ends:
            if len(unpack_starts) != 1 or len(unpack_ends) != 1:
                raise ValidationError("partial unpack evidence is not accepted")
            unpack_start_ns = int(unpack_starts[0]["event_time_ns"])
            unpack_end_ns = int(unpack_ends[0]["event_time_ns"])
            if unpack_end_ns <= unpack_start_ns:
                raise ValidationError("image unpack interval is non-positive")
            unpack_latencies_ms.append(
                (unpack_end_ns - unpack_start_ns) / 1_000_000
            )
        if unpack_starts and unpack_ends:
            for event in (unpack_starts[0], unpack_ends[0]):
                require_event_target(
                    event,
                    pod_uid=pod_uid,
                    pod_name=pod_name,
                    namespace=namespace,
                    node_name=scheduled_node,
                    image=image,
                )
            unpack_start_ns = int(unpack_starts[0]["event_time_ns"])
            unpack_end_ns = int(unpack_ends[0]["event_time_ns"])
            if (
                pull_start_ns is None
                or pull_end_ns is None
                or not (
                    pull_start_ns
                    <= unpack_start_ns
                    < unpack_end_ns
                    and pull_start_ns < pull_end_ns <= unpack_end_ns
                )
            ):
                raise ValidationError(
                    "download/unpack intervals do not form one image operation"
                )
            download_latencies_ms.append(
                (pull_end_ns - pull_start_ns) / 1_000_000
            )
            image_total_latencies_ms.append(
                (unpack_end_ns - pull_start_ns) / 1_000_000
            )
        elif cache_state == "cold":
            if pull_start_ns is None or pull_end_ns is None:
                raise ValidationError("cold image operation has no pull interval")
            image_total_latencies_ms.append(
                (pull_end_ns - pull_start_ns) / 1_000_000
            )

    actual_pull_concurrency, max_overlap_ns = overlap_metrics(pull_intervals)
    if cache_state == "cold" and actual_pull_concurrency != requested_concurrency:
        raise ValidationError(
            "actual positive-duration pull concurrency "
            f"{actual_pull_concurrency} != requested {requested_concurrency}"
        )
    if cache_state == "warm" and actual_pull_concurrency != 0:
        raise ValidationError("warm-cache run unexpectedly has active pulls")

    return {
        "status": "PASS",
        "run_id": run_id,
        "artifact_dir": str(artifact_dir),
        "sequence": numeric_labels["sequence"],
        "block": numeric_labels["block"],
        "repetition": numeric_labels["repetition"],
        "random_seed": numeric_labels["random_seed"],
        "cell": expected_cell,
        "node_state": node_state,
        "cache_state": cache_state,
        "size_mib": size_mib,
        "requested_concurrency": requested_concurrency,
        "actual_pull_concurrency": actual_pull_concurrency,
        "trigger_spread_ms": trigger_spread_ms,
        "max_concurrency_overlap_ms": max_overlap_ns / 1_000_000,
        "pod_count": len(pods),
        "images": images,
        "image_digests": digests,
        "registry": expected_registry,
        "scheduled_node": scheduled_node,
        "scheduled_node_uid": str(
            (target_node.get("metadata") or {}).get("uid") or ""
        ),
        "new_node_uid": new_node_uid,
        "instance_type": instance_type,
        "zone": zone,
        "disk_type": disk_type,
        "download_bytes": download_bytes,
        "download_bytes_total": sum(download_bytes),
        "pull_latency_ms": pull_latencies_ms,
        "pull_latency_ms_max": max(pull_latencies_ms),
        "pull_latency_ms_mean": statistics.fmean(pull_latencies_ms),
        "image_total_latency_ms": image_total_latencies_ms,
        "image_total_latency_ms_max": max(image_total_latencies_ms),
        "image_total_latency_ms_mean": statistics.fmean(
            image_total_latencies_ms
        ),
        "download_latency_ms": download_latencies_ms,
        "download_latency_ms_max": (
            max(download_latencies_ms) if download_latencies_ms else None
        ),
        "download_latency_ms_mean": (
            statistics.fmean(download_latencies_ms)
            if download_latencies_ms
            else None
        ),
        "unpack_required": require_unpack and cache_state == "cold",
        "unpack_sample_count": len(unpack_latencies_ms),
        "unpack_latency_ms": unpack_latencies_ms,
        "unpack_latency_ms_max": (
            max(unpack_latencies_ms) if unpack_latencies_ms else None
        ),
        "unpack_latency_ms_mean": (
            statistics.fmean(unpack_latencies_ms)
            if unpack_latencies_ms
            else None
        ),
    }


def describe(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "min": None, "p50": None, "mean": None, "max": None}
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "min": ordered[0],
        "p50": statistics.median(ordered),
        "mean": statistics.fmean(ordered),
        "max": ordered[-1],
    }


def summarize_runs(
    *,
    run_index: Path,
    schedule_path: Path,
    expected_repetitions: int,
    expected_seed: int,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    schedule = read_tsv(schedule_path)
    index = read_tsv(run_index)
    generated_schedule = generate_schedule(expected_repetitions, expected_seed)
    expected_count = len(generated_schedule)
    if len(schedule) != expected_count or len(index) != expected_count:
        raise ValidationError(
            f"expected {expected_count} scheduled/indexed runs, got "
            f"{len(schedule)}/{len(index)}"
        )
    schedule_fields = (
        "sequence",
        "block",
        "repetition",
        "cell",
        "node_state",
        "cache_state",
        "size_mib",
        "requested_concurrency",
    )
    for position, (actual, expected) in enumerate(
        zip(schedule, generated_schedule), 1
    ):
        for key in schedule_fields:
            if actual.get(key) != format_tsv(expected.get(key)):
                raise ValidationError(
                    f"schedule does not match seed at row {position}: {key}"
                )
    schedule_by_sequence: dict[int, dict[str, str]] = {}
    for row in schedule:
        sequence = int(row["sequence"])
        if sequence in schedule_by_sequence:
            raise ValidationError(f"duplicate schedule sequence: {sequence}")
        schedule_by_sequence[sequence] = row
    if set(schedule_by_sequence) != set(range(1, expected_count + 1)):
        raise ValidationError("schedule sequence is not contiguous")

    observations: list[dict[str, Any]] = []
    seen_sequences: set[int] = set()
    seen_artifact_dirs: set[str] = set()
    seen_validation_files: set[str] = set()
    seen_run_ids: set[str] = set()
    for row in index:
        sequence = int(row["sequence"])
        if sequence in seen_sequences:
            raise ValidationError(f"duplicate run-index sequence: {sequence}")
        seen_sequences.add(sequence)
        expected = schedule_by_sequence.get(sequence)
        if expected is None:
            raise ValidationError(f"run index has unknown sequence: {sequence}")
        for key in (
            "cell",
            "block",
            "repetition",
            "node_state",
            "cache_state",
            "size_mib",
            "requested_concurrency",
        ):
            if row.get(key) != expected.get(key):
                raise ValidationError(
                    f"run-index {key} differs from schedule at sequence {sequence}"
                )
        artifact_dir = row.get("artifact_dir") or ""
        validation_file = row.get("validation") or ""
        if not artifact_dir or artifact_dir in seen_artifact_dirs:
            raise ValidationError(
                f"sequence {sequence} has a missing or duplicate artifact directory"
            )
        if not validation_file or validation_file in seen_validation_files:
            raise ValidationError(
                f"sequence {sequence} has a missing or duplicate validation file"
            )
        seen_artifact_dirs.add(artifact_dir)
        seen_validation_files.add(validation_file)
        validation = read_json(Path(validation_file))
        if validation.get("status") != "PASS":
            raise ValidationError(f"sequence {sequence} validation did not pass")
        if validation.get("artifact_dir") != artifact_dir:
            raise ValidationError(
                f"sequence {sequence} artifact identity does not match validation"
            )
        validation_identity = {
            "sequence": sequence,
            "block": int(row["block"]),
            "repetition": int(row["repetition"]),
            "random_seed": expected_seed,
            "cell": row["cell"],
            "node_state": row["node_state"],
            "cache_state": row["cache_state"],
            "size_mib": int(row["size_mib"]),
            "requested_concurrency": int(row["requested_concurrency"]),
        }
        for key, expected in validation_identity.items():
            if validation.get(key) != expected:
                raise ValidationError(
                    f"sequence {sequence} validation {key} identity differs"
                )
        run_id = str(validation.get("run_id") or "")
        if not run_id or run_id in seen_run_ids:
            raise ValidationError(
                f"sequence {sequence} has a missing or duplicate run_id"
            )
        seen_run_ids.add(run_id)
        expected_actual_concurrency = (
            int(row["requested_concurrency"])
            if row["cache_state"] == "cold"
            else 0
        )
        if validation.get("actual_pull_concurrency") != expected_actual_concurrency:
            raise ValidationError(
                f"sequence {sequence} actual pull concurrency is inconsistent"
            )
        observation = {
            "sequence": sequence,
            "block": int(row["block"]),
            "repetition": int(row["repetition"]),
            "cell": row["cell"],
            "node_state": row["node_state"],
            "cache_state": row["cache_state"],
            "size_mib": int(row["size_mib"]),
            "requested_concurrency": int(row["requested_concurrency"]),
            "actual_pull_concurrency": int(
                validation["actual_pull_concurrency"]
            ),
            "trigger_spread_ms": float(validation["trigger_spread_ms"]),
            "max_concurrency_overlap_ms": float(
                validation["max_concurrency_overlap_ms"]
            ),
            "download_bytes_total": int(validation["download_bytes_total"]),
            "pull_latency_ms_mean": float(validation["pull_latency_ms_mean"]),
            "pull_latency_ms_max": float(validation["pull_latency_ms_max"]),
            "image_total_latency_ms_mean": float(
                validation["image_total_latency_ms_mean"]
            ),
            "image_total_latency_ms_max": float(
                validation["image_total_latency_ms_max"]
            ),
            "download_latency_ms_mean": (
                float(validation["download_latency_ms_mean"])
                if validation.get("download_latency_ms_mean") is not None
                else None
            ),
            "download_latency_ms_max": (
                float(validation["download_latency_ms_max"])
                if validation.get("download_latency_ms_max") is not None
                else None
            ),
            "unpack_sample_count": int(validation["unpack_sample_count"]),
            "unpack_latency_ms_mean": (
                float(validation["unpack_latency_ms_mean"])
                if validation.get("unpack_latency_ms_mean") is not None
                else None
            ),
            "unpack_latency_ms_max": (
                float(validation["unpack_latency_ms_max"])
                if validation.get("unpack_latency_ms_max") is not None
                else None
            ),
            "scheduled_node": validation["scheduled_node"],
            "instance_type": validation["instance_type"],
            "zone": validation["zone"],
            "disk_type": validation["disk_type"],
            "run_id": run_id,
            "artifact_dir": artifact_dir,
            "validation": validation_file,
        }
        observations.append(observation)

    by_cell: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in observations:
        by_cell[item["cell"]].append(item)
    expected_cells = {item["cell"] for item in experiment_cells()}
    if set(by_cell) != expected_cells:
        raise ValidationError("summary does not contain the frozen E03 cell set")
    cell_summaries: dict[str, Any] = {}
    for cell in sorted(by_cell):
        selected = by_cell[cell]
        if len(selected) != expected_repetitions:
            raise ValidationError(
                f"cell {cell} has {len(selected)} runs, expected {expected_repetitions}"
            )
        first = selected[0]
        cell_summaries[cell] = {
            "node_state": first["node_state"],
            "cache_state": first["cache_state"],
            "size_mib": first["size_mib"],
            "requested_concurrency": first["requested_concurrency"],
            "runs": len(selected),
            "pull_latency_ms_mean": describe(
                [float(item["pull_latency_ms_mean"]) for item in selected]
            ),
            "pull_latency_ms_max": describe(
                [float(item["pull_latency_ms_max"]) for item in selected]
            ),
            "image_total_latency_ms_mean": describe(
                [
                    float(item["image_total_latency_ms_mean"])
                    for item in selected
                ]
            ),
            "image_total_latency_ms_max": describe(
                [
                    float(item["image_total_latency_ms_max"])
                    for item in selected
                ]
            ),
            "download_latency_ms_mean": describe(
                [
                    float(item["download_latency_ms_mean"])
                    for item in selected
                    if item["download_latency_ms_mean"] is not None
                ]
            ),
            "download_latency_ms_max": describe(
                [
                    float(item["download_latency_ms_max"])
                    for item in selected
                    if item["download_latency_ms_max"] is not None
                ]
            ),
            "unpack_latency_ms_mean": describe(
                [
                    float(item["unpack_latency_ms_mean"])
                    for item in selected
                    if item["unpack_latency_ms_mean"] is not None
                ]
            ),
            "unpack_latency_ms_max": describe(
                [
                    float(item["unpack_latency_ms_max"])
                    for item in selected
                    if item["unpack_latency_ms_max"] is not None
                ]
            ),
            "download_bytes_total": describe(
                [float(item["download_bytes_total"]) for item in selected]
            ),
            "max_concurrency_overlap_ms": describe(
                [float(item["max_concurrency_overlap_ms"]) for item in selected]
            ),
            "trigger_spread_ms": describe(
                [float(item["trigger_spread_ms"]) for item in selected]
            ),
            "actual_pull_concurrency": sorted(
                {int(item["actual_pull_concurrency"]) for item in selected}
            ),
        }

    summary = {
        "status": "PASS",
        "experiment": "E03-image-cache-concurrency",
        "random_seed": expected_seed,
        "repetitions_per_cell": expected_repetitions,
        "cell_count": len(expected_cells),
        "run_count": len(observations),
        "matrix": {
            "size_mib": list(SIZE_LEVELS_MIB),
            "cache": list(CACHE_STATES),
            "requested_concurrency": list(CONCURRENCY_LEVELS),
            "node": list(NODE_STATES),
            "excluded": ["new-warm (prewarming makes the node non-new)"],
        },
        "cells": cell_summaries,
    }
    return summary, sorted(observations, key=lambda item: item["sequence"])


def command_schedule(args: argparse.Namespace) -> int:
    rows = generate_schedule(args.repetitions, args.seed)
    fields = [
        "sequence",
        "block",
        "repetition",
        "cell",
        "node_state",
        "cache_state",
        "size_mib",
        "requested_concurrency",
    ]
    write_tsv(args.output, fields, rows)
    return 0


def parse_images(value: str) -> list[str]:
    try:
        images = json.loads(value)
    except json.JSONDecodeError as exc:
        raise ValidationError("--images-json must be valid JSON") from exc
    if not isinstance(images, list) or not all(
        isinstance(item, str) and item for item in images
    ):
        raise ValidationError("--images-json must be a non-empty string array")
    return images


def command_validate_run(args: argparse.Namespace) -> int:
    result = validate_run(
        artifact_dir=args.artifact_dir,
        node_state=args.node_state,
        cache_state=args.cache_state,
        size_mib=args.size_mib,
        requested_concurrency=args.requested_concurrency,
        images=parse_images(args.images_json),
        cluster_id=args.cluster_id,
        selector_key=args.selector_key,
        selector_value=args.selector_value,
        expected_instance_type=args.instance_type,
        expected_zone=args.zone,
        expected_registry=args.registry,
        disk_type=args.disk_type,
        min_download_bytes=args.min_download_bytes,
        max_trigger_spread_ms=args.max_trigger_spread_ms,
        existing_node_name=args.existing_node_name,
        require_unpack=args.require_unpack,
    )
    write_json(args.output, result)
    return 0


def command_summarize(args: argparse.Namespace) -> int:
    summary, observations = summarize_runs(
        run_index=args.run_index,
        schedule_path=args.schedule,
        expected_repetitions=args.expected_repetitions,
        expected_seed=args.expected_seed,
    )
    fields = [
        "sequence",
        "block",
        "repetition",
        "cell",
        "node_state",
        "cache_state",
        "size_mib",
        "requested_concurrency",
        "actual_pull_concurrency",
        "trigger_spread_ms",
        "max_concurrency_overlap_ms",
        "download_bytes_total",
        "pull_latency_ms_mean",
        "pull_latency_ms_max",
        "image_total_latency_ms_mean",
        "image_total_latency_ms_max",
        "download_latency_ms_mean",
        "download_latency_ms_max",
        "unpack_sample_count",
        "unpack_latency_ms_mean",
        "unpack_latency_ms_max",
        "scheduled_node",
        "instance_type",
        "zone",
        "disk_type",
        "run_id",
        "artifact_dir",
        "validation",
    ]
    write_tsv(args.observations, fields, observations)
    write_json(args.output, summary)
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="E03 pilot artifact helper")
    commands = root.add_subparsers(dest="command", required=True)

    schedule = commands.add_parser("schedule")
    schedule.add_argument("--repetitions", type=int, required=True)
    schedule.add_argument("--seed", type=int, required=True)
    schedule.add_argument("--output", type=Path, required=True)
    schedule.set_defaults(handler=command_schedule)

    validate = commands.add_parser("validate-run")
    validate.add_argument("--artifact-dir", type=Path, required=True)
    validate.add_argument("--node-state", choices=NODE_STATES, required=True)
    validate.add_argument("--cache-state", choices=CACHE_STATES, required=True)
    validate.add_argument("--size-mib", type=int, required=True)
    validate.add_argument("--requested-concurrency", type=int, required=True)
    validate.add_argument("--images-json", required=True)
    validate.add_argument("--cluster-id", required=True)
    validate.add_argument("--selector-key", required=True)
    validate.add_argument("--selector-value", required=True)
    validate.add_argument("--instance-type", required=True)
    validate.add_argument("--zone", required=True)
    validate.add_argument("--registry", required=True)
    validate.add_argument("--disk-type", required=True)
    validate.add_argument("--min-download-bytes", type=int, required=True)
    validate.add_argument("--max-trigger-spread-ms", type=float, required=True)
    validate.add_argument("--existing-node-name", default="")
    validate.add_argument("--require-unpack", action="store_true")
    validate.add_argument("--output", type=Path)
    validate.set_defaults(handler=command_validate_run)

    summarize = commands.add_parser("summarize")
    summarize.add_argument("--run-index", type=Path, required=True)
    summarize.add_argument("--schedule", type=Path, required=True)
    summarize.add_argument("--expected-repetitions", type=int, required=True)
    summarize.add_argument("--expected-seed", type=int, required=True)
    summarize.add_argument("--observations", type=Path, required=True)
    summarize.add_argument("--output", type=Path, required=True)
    summarize.set_defaults(handler=command_summarize)
    return root


def main() -> int:
    args = parser().parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError, ValueError, KeyError, TypeError) as exc:
        print(f"e03-image-cache-concurrency: {exc}", file=sys.stderr)
        raise SystemExit(1)
