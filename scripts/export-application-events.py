#!/usr/bin/env python3
"""Normalize exact Hooke application events persisted in Kubernetes Pod logs."""

from __future__ import annotations

import argparse
import json
import re
import sys
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


SHA256_RE = re.compile(r"sha256:[0-9a-fA-F]{64}")
CROCKFORD_BASE32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


@dataclass(frozen=True)
class ContainerTarget:
    name: str
    image: str
    container_id: str


@dataclass
class PodTarget:
    uid: str
    namespace: str
    name: str
    node_name: str
    containers: dict[str, ContainerTarget] = field(default_factory=dict)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export Hooke source-timestamped Pod log events as NDJSON"
    )
    parser.add_argument("--cluster-id", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--pods", required=True, help="kubectl PodList JSON snapshot")
    parser.add_argument("--logs-dir", required=True)
    parser.add_argument("--start-ns", required=True, type=int)
    parser.add_argument("--end-ns", required=True, type=int)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def load_targets(path: Path) -> list[PodTarget]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    targets: dict[str, PodTarget] = {}
    for item in payload.get("items", []):
        if not isinstance(item, dict):
            continue
        metadata = item.get("metadata") or {}
        spec = item.get("spec") or {}
        status = item.get("status") or {}
        uid = str(metadata.get("uid") or "")
        namespace = str(metadata.get("namespace") or "")
        name = str(metadata.get("name") or "")
        node_name = str(spec.get("nodeName") or "")
        if not uid or not namespace or not name or not node_name:
            continue
        target = targets.setdefault(
            uid,
            PodTarget(
                uid=uid,
                namespace=namespace,
                name=name,
                node_name=node_name,
            ),
        )
        statuses: dict[str, dict[str, Any]] = {}
        for field_name in (
            "initContainerStatuses",
            "containerStatuses",
            "ephemeralContainerStatuses",
        ):
            for value in status.get(field_name, []):
                if isinstance(value, dict):
                    statuses[str(value.get("name") or "")] = value
        specs: list[dict[str, Any]] = []
        for field_name in ("initContainers", "containers", "ephemeralContainers"):
            specs.extend(
                value
                for value in spec.get(field_name, [])
                if isinstance(value, dict)
            )
        for container in specs:
            container_name = str(container.get("name") or "")
            image = str(container.get("image") or "")
            container_id = str(
                statuses.get(container_name, {}).get("containerID") or ""
            )
            if "://" in container_id:
                container_id = container_id.split("://", 1)[1]
            if container_name and image and container_id:
                target.containers[container_name] = ContainerTarget(
                    name=container_name,
                    image=image,
                    container_id=container_id,
                )
    if not targets:
        raise RuntimeError("Pod snapshot contains no scheduled Pod identities")
    return sorted(targets.values(), key=lambda item: (item.namespace, item.name))


def image_digest(image: str) -> str:
    matches = SHA256_RE.findall(image)
    return matches[-1].lower() if matches else ""


def log_paths(directory: Path) -> Iterable[Path]:
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.suffix.lower() in {".log", ".json", ".ndjson"}:
            yield path


def normalize_events(
    cluster_id: str,
    run_id: str,
    targets: list[PodTarget],
    logs_dir: Path,
    start_ns: int,
    end_ns: int,
) -> list[dict[str, Any]]:
    if start_ns <= 0 or end_ns <= start_ns:
        raise ValueError("event window must contain positive increasing nanoseconds")
    by_uid = {pod.uid: pod for pod in targets}
    output: list[dict[str, Any]] = []
    seen: set[str] = set()
    for path in log_paths(logs_dir):
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), 1
        ):
            marker = line.find("{")
            if marker < 0:
                continue
            try:
                record = json.loads(line[marker:])
            except json.JSONDecodeError as exc:
                raise RuntimeError(
                    f"invalid JSON in {path.name}:{line_number}"
                ) from exc
            event_type = str(record.get("hooke_event_type") or "")
            if not event_type:
                continue
            pod_uid = str(record.get("pod_uid") or "")
            pod = by_uid.get(pod_uid)
            if pod is None:
                raise RuntimeError(
                    f"{path.name}:{line_number} references unknown Pod UID {pod_uid!r}"
                )
            expected = {
                "hooke_cluster_id": cluster_id,
                "hooke_run_id": run_id,
                "pod_namespace": pod.namespace,
                "pod_name": pod.name,
                "pod_uid": pod.uid,
                "node_name": pod.node_name,
            }
            for field_name, value in expected.items():
                if str(record.get(field_name) or "") != value:
                    raise RuntimeError(
                        f"{path.name}:{line_number} field {field_name} does not "
                        "match the frozen Pod/run identity"
                    )
            source_time_ns = record.get("source_time_ns")
            if not isinstance(source_time_ns, int) or source_time_ns <= 0:
                raise RuntimeError(
                    f"{path.name}:{line_number} has no positive integer source_time_ns"
                )
            if source_time_ns < start_ns or source_time_ns > end_ns:
                raise RuntimeError(
                    f"{path.name}:{line_number} event is outside the run window"
                )
            container_name = str(record.get("container_name") or "")
            container = pod.containers.get(container_name)
            if container is None:
                raise RuntimeError(
                    f"{path.name}:{line_number} container {container_name!r} "
                    "does not match the frozen Pod status"
                )
            attributes = record.get("hooke_attributes")
            if not isinstance(attributes, dict):
                attributes = {}
            attributes = dict(attributes)
            attributes.update(
                {
                    "precision": attributes.get(
                        "precision", "application-source-timestamp"
                    ),
                    "persistence": "container-stdout",
                }
            )
            item: dict[str, Any] = {
                "cluster_id": cluster_id,
                "run_id": run_id,
                "event_type": event_type,
                "source_time_ns": source_time_ns,
                "event_time_ns": source_time_ns,
                "clock_type": "realtime",
                "source_component": "application-event-log",
                "source_instance": pod.node_name,
                "namespace": pod.namespace,
                "pod_name": pod.name,
                "pod_uid": pod.uid,
                "container_name": container.name,
                "container_id": container.container_id,
                "node_name": pod.node_name,
                "image_ref": container.image,
                "image_digest": image_digest(container.image),
                "approximate": False,
                "attributes": attributes,
            }
            for source_name, target_name in (
                ("workload_kind", "workload_kind"),
                ("workload_name", "workload_name"),
                ("workload_uid", "workload_uid"),
            ):
                value = str(record.get(source_name) or "")
                if value:
                    item[target_name] = value
            identity = json.dumps(item, separators=(",", ":"), sort_keys=True)
            if identity in seen:
                continue
            seen.add(identity)
            output.append(item)
    if not output:
        raise RuntimeError("no Hooke application events found in Pod logs")
    return sorted(
        output,
        key=lambda item: (
            int(item["event_time_ns"]),
            str(item["pod_uid"]),
            str(item["event_type"]),
            json.dumps(item["attributes"], separators=(",", ":"), sort_keys=True),
        ),
    )


def deterministic_event_id(canonical: str) -> str:
    value = uuid.uuid5(uuid.NAMESPACE_URL, canonical).int
    encoded = ["0"] * 26
    for index in range(25, -1, -1):
        encoded[index] = CROCKFORD_BASE32[value & 31]
        value >>= 5
    return "".join(encoded)


def write_ndjson(path: Path, records: list[dict[str, Any]]) -> None:
    prepared: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for record in records:
        item = dict(record)
        canonical = json.dumps(item, separators=(",", ":"), sort_keys=True)
        event_id = deterministic_event_id(canonical)
        if event_id in seen_ids:
            raise RuntimeError("application export produced a duplicate event identity")
        seen_ids.add(event_id)
        item["event_id"] = event_id
        prepared.append(item)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        "".join(
            json.dumps(item, separators=(",", ":"), sort_keys=True) + "\n"
            for item in prepared
        ),
        encoding="utf-8",
    )
    temporary.replace(path)


def main() -> int:
    args = parse_args()
    targets = load_targets(Path(args.pods))
    events = normalize_events(
        args.cluster_id,
        args.run_id,
        targets,
        Path(args.logs_dir),
        args.start_ns,
        args.end_ns,
    )
    write_ndjson(Path(args.output), events)
    print(
        f"exported {len(events)} exact application event(s) from "
        f"{len(targets)} Pod identity snapshot(s)",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"export-application-events: {exc}", file=sys.stderr)
        raise SystemExit(1)
