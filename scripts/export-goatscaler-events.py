#!/usr/bin/env python3
"""Export exact ACK GOATScaler provision events from Alibaba Cloud SLS.

The E01 runner invokes this file as a hook.  It deliberately keeps the SLS
query outside the Go adapter: the raw GOATScaler format is version-specific,
while the adapter consumes a small, stable NDJSON record contract.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


START_BATCH_RE = re.compile(
    r"start provision batch (?P<batch>\S+): "
    r"nodepool=(?P<nodepool>\S+) zone=(?P<zone>\S+) "
    r"instanceTypes=\[(?P<types>[^]]+)] size=(?P<size>\d+)"
)
TRIGGER_BATCH_RE = re.compile(
    r"succeed to trigger batch (?P<batch>\S+): .*?activity=(?P<task>asa-[A-Za-z0-9-]+)"
)
PREBIND_RE = re.compile(
    r"PreBind pod (?P<pod>[^\s]+) to vNode (?P<task>asa-[A-Za-z0-9-]+) "
    r"in batch (?P<batch>\S+) successfully"
)
PROVISION_EVENT_RE = re.compile(
    r"Provision node (?P<task>asa-[A-Za-z0-9-]+) in Zone: (?P<zone>[^\s]+) "
    r"with InstanceType: (?P<instance_type>[^,]+), Triggered time (?P<triggered>[^\t]+)"
)
TASK_ID_RE = re.compile(r"\b(asa-[A-Za-z0-9-]+)\b")
SAFE_REGION_RE = re.compile(r"^[a-z0-9-]+$")


@dataclass
class Batch:
    batch_id: str
    event_time: str
    event_datetime: datetime
    nodepool_id: str
    zone_id: str
    instance_types: list[str]
    size: int
    task_id: str = ""
    pod_names: set[str] = field(default_factory=set)
    pod_uids: set[str] = field(default_factory=set)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export GOATScaler provision events as adapter NDJSON"
    )
    parser.add_argument("--cluster-id", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--start-file", required=True)
    parser.add_argument("--end-file", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--region", default=os.getenv("ACK_SLS_REGION", ""))
    parser.add_argument("--project", default=os.getenv("ACK_SLS_PROJECT", ""))
    parser.add_argument("--logstore", default=os.getenv("ACK_SLS_LOGSTORE", ""))
    parser.add_argument(
        "--max-wait-seconds",
        type=int,
        default=int(os.getenv("ACK_SLS_MAX_WAIT_SECONDS", "30")),
    )
    return parser.parse_args()


def parse_timestamp(value: str) -> datetime:
    text = value.strip()
    if not text:
        raise ValueError("empty timestamp")
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def read_timestamp(path: str) -> datetime:
    return parse_timestamp(Path(path).read_text(encoding="utf-8"))


def run_json(command: list[str]) -> Any:
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"command failed ({completed.returncode}): {detail}")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("command returned invalid JSON") from exc


def query_sls(
    region: str,
    project: str,
    logstore: str,
    start: datetime,
    end: datetime,
) -> list[dict[str, Any]]:
    endpoint = f"{region}.log.aliyuncs.com"
    from_epoch = int((start - timedelta(seconds=60)).timestamp())
    to_epoch = int((end + timedelta(seconds=60)).timestamp()) + 1
    records: list[dict[str, Any]] = []
    for offset in range(0, 5000, 100):
        page = run_json(
            [
                "aliyun",
                "--endpoint",
                endpoint,
                "sls",
                "GetLogs",
                "--project",
                project,
                "--logstore",
                logstore,
                "--from",
                str(from_epoch),
                "--to",
                str(to_epoch),
                "--query",
                "*",
                "--line",
                "100",
                "--offset",
                str(offset),
                "--reverse",
                "false",
            ]
        )
        if not isinstance(page, list):
            raise RuntimeError("SLS GetLogs did not return a JSON array")
        records.extend(item for item in page if isinstance(item, dict))
        if len(page) < 100:
            break
    else:
        raise RuntimeError("SLS result exceeded the 5,000-record safety limit")
    return records


def event_scope(output: Path) -> tuple[set[str], dict[str, set[str]], dict[str, set[str]]]:
    """Return task IDs and their Pod UIDs/names from this run's K8s Events."""
    event_path = output.parent / "kubernetes-events.json"
    if not event_path.is_file():
        return set(), {}, {}
    payload = json.loads(event_path.read_text(encoding="utf-8"))
    tasks: set[str] = set()
    task_uids: dict[str, set[str]] = {}
    task_names: dict[str, set[str]] = {}
    for item in payload.get("items", []):
        if item.get("reason") != "ProvisionNode":
            continue
        match = TASK_ID_RE.search(str(item.get("message", "")))
        if not match:
            continue
        task_id = match.group(1)
        tasks.add(task_id)
        involved = item.get("involvedObject") or {}
        uid = str(involved.get("uid") or "")
        name = str(involved.get("name") or "")
        if uid:
            task_uids.setdefault(task_id, set()).add(uid)
        if name:
            namespace = str(involved.get("namespace") or "")
            task_names.setdefault(task_id, set()).add(
                f"{namespace}/{name}" if namespace else name
            )
    return tasks, task_uids, task_names


def parse_embedded_event(content: str) -> dict[str, Any] | None:
    marker = content.find('{"type"')
    if marker < 0:
        return None
    try:
        value = json.loads(content[marker:])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def parse_batches(
    records: list[dict[str, Any]],
    window_start: datetime,
    window_end: datetime,
) -> dict[str, Batch]:
    batches: dict[str, Batch] = {}
    task_to_batch: dict[str, str] = {}
    for record in sorted(records, key=lambda item: str(item.get("_time_", ""))):
        content = str(record.get("content", ""))
        source_time = str(record.get("_time_", ""))
        if not source_time:
            continue
        try:
            source_datetime = parse_timestamp(source_time)
        except (TypeError, ValueError):
            continue

        start_match = START_BATCH_RE.search(content)
        if start_match and window_start <= source_datetime <= window_end:
            types = [value for value in start_match.group("types").split() if value]
            batches[start_match.group("batch")] = Batch(
                batch_id=start_match.group("batch"),
                event_time=source_time,
                event_datetime=source_datetime,
                nodepool_id=start_match.group("nodepool"),
                zone_id=start_match.group("zone"),
                instance_types=types,
                size=int(start_match.group("size")),
            )
            continue

        trigger_match = TRIGGER_BATCH_RE.search(content)
        if trigger_match:
            batch = batches.get(trigger_match.group("batch"))
            if batch:
                batch.task_id = trigger_match.group("task")
                task_to_batch[batch.task_id] = batch.batch_id
            continue

        prebind_match = PREBIND_RE.search(content)
        if prebind_match:
            batch = batches.get(prebind_match.group("batch"))
            if batch:
                batch.task_id = prebind_match.group("task")
                task_to_batch[batch.task_id] = batch.batch_id
                batch.pod_names.add(prebind_match.group("pod"))
            continue

        provision_match = PROVISION_EVENT_RE.search(content)
        if not provision_match:
            continue
        task_id = provision_match.group("task")
        batch_id = task_to_batch.get(task_id)
        if not batch_id:
            continue
        batch = batches[batch_id]
        embedded = parse_embedded_event(content)
        if embedded:
            involved = embedded.get("object") or {}
            uid = str(involved.get("uid") or "")
            name = str(involved.get("name") or "")
            namespace = str(involved.get("namespace") or "")
            if uid:
                batch.pod_uids.add(uid)
            if name:
                batch.pod_names.add(f"{namespace}/{name}" if namespace else name)
    return batches


def node_tasks() -> dict[str, dict[str, str]]:
    command = ["kubectl"]
    kubeconfig = os.getenv("KUBECONFIG_PATH", "")
    context = os.getenv("KUBE_CONTEXT", "")
    if kubeconfig:
        command.extend(["--kubeconfig", kubeconfig])
    if context:
        command.extend(["--context", context])
    command.extend(["get", "nodes", "-o", "json"])
    try:
        payload = run_json(command)
    except (FileNotFoundError, RuntimeError):
        return {}
    result: dict[str, dict[str, str]] = {}
    for item in payload.get("items", []):
        metadata = item.get("metadata") or {}
        labels = metadata.get("labels") or {}
        task_id = str(labels.get("goatscaler.io/provision-task-id") or "")
        if not task_id:
            continue
        provider_id = str((item.get("spec") or {}).get("providerID") or "")
        instance_id = str(labels.get("alibabacloud.com/ecs-instance-id") or "")
        if not instance_id and ".i-" in provider_id:
            instance_id = provider_id.rsplit(".", 1)[-1]
        result[task_id] = {
            "node_name": str(metadata.get("name") or ""),
            "node_uid": str(metadata.get("uid") or ""),
            "instance_id": instance_id,
            "provider_id": provider_id,
            "nodepool_id": str(
                labels.get("node.alibabacloud.com/nodepool-id")
                or labels.get("alibabacloud.com/nodepool-id")
                or ""
            ),
            "instance_type": str(labels.get("node.kubernetes.io/instance-type") or ""),
        }
    return result


def normalize(
    batches: dict[str, Batch],
    cluster_id: str,
    run_id: str,
    allowed_tasks: set[str],
    event_uids: dict[str, set[str]],
    event_names: dict[str, set[str]],
) -> list[dict[str, Any]]:
    nodes = node_tasks()
    output: list[dict[str, Any]] = []
    for batch in sorted(batches.values(), key=lambda item: item.event_datetime):
        if not batch.task_id:
            continue
        if allowed_tasks and batch.task_id not in allowed_tasks:
            continue
        batch.pod_uids.update(event_uids.get(batch.task_id, set()))
        batch.pod_names.update(event_names.get(batch.task_id, set()))
        node = nodes.get(batch.task_id, {})
        instance_type = node.get("instance_type") or (
            batch.instance_types[0] if batch.instance_types else ""
        )
        record: dict[str, Any] = {
            "action": "CreateNode",
            "cluster_id": cluster_id,
            "run_id": run_id,
            "event_time": batch.event_time,
            "task_id": batch.task_id,
            "reason": "goatscaler_start_provision_batch",
            "status": "started",
            "zone_id": batch.zone_id,
            "instance_type": instance_type,
            "nodepool_id": node.get("nodepool_id") or batch.nodepool_id,
            "batch_id": batch.batch_id,
            "requested_nodes": batch.size,
            "pending_pod_uids": sorted(batch.pod_uids),
            "pending_pods": sorted(batch.pod_names),
            "source_component": "ack-goatscaler-sls",
        }
        for field_name in ("node_name", "node_uid", "instance_id", "provider_id"):
            if node.get(field_name):
                record[field_name] = node[field_name]
        output.append(record)
    return output


def write_ndjson(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as stream:
        for record in records:
            stream.write(json.dumps(record, separators=(",", ":"), sort_keys=True))
            stream.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def main() -> int:
    args = parse_args()
    if not SAFE_REGION_RE.fullmatch(args.region):
        raise ValueError("ACK_SLS_REGION is required and must be a region ID")
    if not args.project:
        raise ValueError("ACK_SLS_PROJECT is required")
    if not args.logstore:
        raise ValueError("ACK_SLS_LOGSTORE is required")
    if args.max_wait_seconds < 0 or args.max_wait_seconds > 300:
        raise ValueError("--max-wait-seconds must be between 0 and 300")

    window_start = read_timestamp(args.start_file)
    window_end = read_timestamp(args.end_file)
    if window_end <= window_start:
        raise ValueError("end timestamp must be after start timestamp")
    output_path = Path(args.output)
    allowed_tasks, event_uids, event_names = event_scope(output_path)

    deadline = time.monotonic() + args.max_wait_seconds
    normalized: list[dict[str, Any]] = []
    record_count = 0
    while True:
        raw = query_sls(
            args.region,
            args.project,
            args.logstore,
            window_start,
            window_end,
        )
        record_count = len(raw)
        batches = parse_batches(raw, window_start, window_end)
        normalized = normalize(
            batches,
            args.cluster_id,
            args.run_id,
            allowed_tasks,
            event_uids,
            event_names,
        )
        if normalized or time.monotonic() >= deadline:
            break
        time.sleep(min(5, max(0, deadline - time.monotonic())))

    if not normalized:
        scope = ",".join(sorted(allowed_tasks)) if allowed_tasks else "window"
        raise RuntimeError(
            f"no GOATScaler provision batches matched {scope}; queried {record_count} records"
        )
    write_ndjson(output_path, normalized)
    print(
        f"exported {len(normalized)} GOATScaler provision event(s) "
        f"from {record_count} SLS record(s) to {output_path}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"export-goatscaler-events: {exc}", file=sys.stderr)
        raise SystemExit(1)
