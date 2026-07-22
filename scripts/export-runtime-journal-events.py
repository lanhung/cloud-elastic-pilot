#!/usr/bin/env python3
"""Export exact per-Pod runtime events from ACK node journals.

Alibaba Cloud Linux ACK nodes log the CRI boundaries used here with embedded
RFC3339Nano timestamps.  The exporter joins those records to the Pod UID,
sandbox ID and container ID frozen in the run artifacts.  It deliberately does
not manufacture a CNI interval: the stock info-level journal does not expose a
separate, UID-addressable CNI start/end pair.
"""

from __future__ import annotations

import argparse
import calendar
import json
import os
import re
import subprocess
import sys
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


RFC3339_RE = re.compile(
    r"^(?P<base>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})"
    r"(?P<fraction>\.\d+)?(?P<zone>Z|[+-]\d{2}:\d{2})$"
)
EMBEDDED_TIME_RE = re.compile(r'\btime="(?P<time>[^"]+)"')
RUN_START_RE = re.compile(
    r"RunPodSandbox for &PodSandboxMetadata\{Name:(?P<name>[^,]+),"
    r"Uid:(?P<uid>[^,]+),Namespace:(?P<namespace>[^,]+),"
    r"Attempt:(?P<attempt>\d+),\}"
)
RUN_END_RE = re.compile(
    r"RunPodSandbox for &PodSandboxMetadata\{Name:(?P<name>[^,]+),"
    r"Uid:(?P<uid>[^,]+),Namespace:(?P<namespace>[^,]+),"
    r"Attempt:(?P<attempt>\d+),\} returns sandbox id "
    r'"(?P<sandbox>[0-9a-f]+)"'
)
CREATE_START_RE = re.compile(
    r'CreateContainer within sandbox "(?P<sandbox>[0-9a-f]+)" for (?:container )?'
    r"&ContainerMetadata\{Name:(?P<name>[^,]+),Attempt:(?P<attempt>\d+),\}"
)
CREATE_END_RE = re.compile(
    r'CreateContainer within sandbox "(?P<sandbox>[0-9a-f]+)" for '
    r"&ContainerMetadata\{Name:(?P<name>[^,]+),Attempt:(?P<attempt>\d+),\} "
    r'returns container id "(?P<container>[0-9a-f]+)"'
)
START_CONTAINER_END_RE = re.compile(
    r'StartContainer for "(?P<container>[0-9a-f]+)" returns successfully'
)
PULL_END_RE = re.compile(
    r'PullImage "(?P<image>.+?)" returns image reference "(?P<reference>[^"]+)"'
)
PULL_START_RE = re.compile(r'PullImage "(?P<image>[^"]+)"')
PULL_BYTES_RE = re.compile(r"PullImageInfo: DownloadBytes=(?P<bytes>\d+)")
IMAGE_NAME_RE = re.compile(r'image\.name="(?P<image>[^"]+)"')
SHA256_RE = re.compile(r"sha256:[0-9a-fA-F]{64}")
DNS_SAFE_RE = re.compile(r"[^a-z0-9-]+")
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
    node_uid: str = ""
    containers: dict[str, ContainerTarget] = field(default_factory=dict)


@dataclass(frozen=True)
class JournalRecord:
    time_ns: int
    message: str


@dataclass(frozen=True)
class SandboxStart:
    time_ns: int
    uid: str
    namespace: str
    name: str
    attempt: int


@dataclass(frozen=True)
class SandboxEnd:
    time_ns: int
    uid: str
    namespace: str
    name: str
    attempt: int
    sandbox_id: str


@dataclass(frozen=True)
class ContainerCreate:
    start_ns: int
    end_ns: int
    sandbox_id: str
    name: str
    container_id: str


@dataclass(frozen=True)
class PullPair:
    image: str
    start_ns: int
    end_ns: int
    reference: str
    download_bytes: int | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export exact ACK containerd/kubelet journal events as NDJSON"
    )
    parser.add_argument("--cluster-id", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--start-file", required=True)
    parser.add_argument("--end-file", required=True)
    parser.add_argument("--artifact-dir", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--helper-image", default=os.getenv("E01_HOST_HELPER_IMAGE", "")
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=int(os.getenv("E01_RUNTIME_HOOK_TIMEOUT_SECONDS", "120")),
    )
    return parser.parse_args()


def timestamp_ns(value: str) -> int:
    match = RFC3339_RE.fullmatch(value.strip())
    if not match:
        raise ValueError(f"invalid RFC3339 timestamp: {value!r}")
    zone = match.group("zone")
    zone_text = "+00:00" if zone == "Z" else zone
    parsed = datetime.fromisoformat(match.group("base") + zone_text)
    seconds = calendar.timegm(parsed.astimezone(timezone.utc).timetuple())
    fraction = (match.group("fraction") or "")[1:]
    nanos = int((fraction + "000000000")[:9]) if fraction else 0
    return seconds * 1_000_000_000 + nanos


def read_time_ns(path: str) -> int:
    value = Path(path).read_text(encoding="utf-8").strip()
    return timestamp_ns(value)


def datetime_from_ns(nanos: int) -> datetime:
    seconds, remainder = divmod(nanos, 1_000_000_000)
    return datetime.fromtimestamp(seconds, tz=timezone.utc) + timedelta(
        microseconds=remainder // 1000
    )


def kube_base() -> list[str]:
    command = ["kubectl"]
    kubeconfig = os.getenv("KUBECONFIG_PATH", "")
    context = os.getenv("KUBE_CONTEXT", "")
    if kubeconfig:
        command.extend(("--kubeconfig", kubeconfig))
    if context:
        command.extend(("--context", context))
    return command


def run(
    command: list[str],
    *,
    input_text: str | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"command failed ({completed.returncode}): {detail}")
    return completed


def run_json(command: list[str]) -> Any:
    completed = run(command)
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("command returned invalid JSON") from exc


def safe_name(value: str, limit: int = 63) -> str:
    value = DNS_SAFE_RE.sub("-", value.lower()).strip("-")
    return (value or "node")[:limit].rstrip("-")


def node_uid_map(artifact_dir: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(artifact_dir.glob("nodes*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for item in payload.get("items", []):
            metadata = item.get("metadata") or {}
            name = str(metadata.get("name") or "")
            uid = str(metadata.get("uid") or "")
            if name and uid:
                result[name] = uid
    return result


def load_targets(artifact_dir: Path) -> list[PodTarget]:
    nodes = node_uid_map(artifact_dir)
    targets: dict[str, PodTarget] = {}
    for path in sorted(artifact_dir.glob("pods-*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        for item in payload.get("items", []):
            metadata = item.get("metadata") or {}
            spec = item.get("spec") or {}
            status = item.get("status") or {}
            uid = str(metadata.get("uid") or "")
            node_name = str(spec.get("nodeName") or "")
            if not uid or not node_name:
                continue
            target = targets.setdefault(
                uid,
                PodTarget(
                    uid=uid,
                    namespace=str(metadata.get("namespace") or ""),
                    name=str(metadata.get("name") or ""),
                    node_name=node_name,
                    node_uid=nodes.get(node_name, ""),
                ),
            )
            statuses = {
                str(value.get("name") or ""): value
                for value in status.get("containerStatuses", [])
                if isinstance(value, dict)
            }
            for container in spec.get("containers", []):
                if not isinstance(container, dict):
                    continue
                name = str(container.get("name") or "")
                image = str(container.get("image") or "")
                state = statuses.get(name, {})
                container_id = str(state.get("containerID") or "")
                if container_id.startswith("containerd://"):
                    container_id = container_id[len("containerd://") :]
                if name and image and container_id:
                    target.containers[name] = ContainerTarget(
                        name=name, image=image, container_id=container_id
                    )
    result = sorted(targets.values(), key=lambda item: (item.node_name, item.uid))
    if not result:
        raise RuntimeError("no Pod targets found in pods-*.json artifacts")
    missing = [f"{pod.namespace}/{pod.name}" for pod in result if not pod.containers]
    if missing:
        raise RuntimeError("Pod artifacts have no container IDs: " + ", ".join(missing))
    return result


def helper_manifest(namespace: str, node: str, pod: str, image: str) -> dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": pod,
            "namespace": namespace,
            "labels": {"hooke.io/component": "runtime-journal-exporter"},
        },
        "spec": {
            "nodeName": node,
            "hostPID": True,
            "automountServiceAccountToken": False,
            "restartPolicy": "Never",
            "terminationGracePeriodSeconds": 0,
            "tolerations": [{"operator": "Exists"}],
            "containers": [
                {
                    "name": "helper",
                    "image": image,
                    "imagePullPolicy": "IfNotPresent",
                    "command": ["/bin/sh", "-c", "sleep 600"],
                    "securityContext": {
                        "privileged": True,
                        "readOnlyRootFilesystem": True,
                    },
                    "resources": {
                        "requests": {"cpu": "1m", "memory": "4Mi"},
                        "limits": {"cpu": "100m", "memory": "64Mi"},
                    },
                }
            ],
        },
    }


def create_helpers(nodes: list[str], helper_image: str, timeout: int) -> tuple[str, dict[str, str]]:
    namespace = f"hooke-runtime-{uuid.uuid4().hex[:10]}"
    run(kube_base() + ["create", "namespace", namespace])
    pods: dict[str, str] = {}
    try:
        for index, node in enumerate(nodes):
            pod = safe_name(f"journal-{index}-{node}")
            run(
                kube_base() + ["apply", "-f", "-"],
                input_text=json.dumps(helper_manifest(namespace, node, pod, helper_image)),
            )
            pods[node] = pod
        for pod in pods.values():
            run(
                kube_base()
                + [
                    "-n",
                    namespace,
                    "wait",
                    "--for=condition=Ready",
                    f"pod/{pod}",
                    f"--timeout={timeout}s",
                ]
            )
        return namespace, pods
    except Exception:
        run(
            kube_base()
            + ["delete", "namespace", namespace, "--wait=false", "--ignore-not-found"],
            check=False,
        )
        raise


def host_journal(
    namespace: str,
    pod: str,
    unit: str,
    start: datetime,
    end: datetime,
    pattern: str,
) -> str:
    padded_start = int((start - timedelta(seconds=2)).timestamp())
    padded_end = int((end + timedelta(seconds=2)).timestamp())
    command = kube_base() + [
        "-n",
        namespace,
        "exec",
        pod,
        "--",
        "nsenter",
        "-t",
        "1",
        "-m",
        "-u",
        "-i",
        "-n",
        "-p",
        "--",
        "journalctl",
        "-u",
        unit,
        "--since",
        f"@{padded_start}",
        "--until",
        f"@{padded_end}",
        "--no-pager",
        "-o",
        "json",
        "--grep",
        pattern,
    ]
    return run(command).stdout


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text(content, encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def parse_journal(content: str) -> list[JournalRecord]:
    records: list[JournalRecord] = []
    for line_number, line in enumerate(content.splitlines(), 1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"invalid journal JSON at line {line_number}") from exc
        message = str(item.get("MESSAGE") or "")
        embedded = EMBEDDED_TIME_RE.search(message)
        if embedded:
            at_ns = timestamp_ns(embedded.group("time"))
        else:
            realtime = str(item.get("__REALTIME_TIMESTAMP") or "")
            if not realtime.isdigit():
                continue
            at_ns = int(realtime) * 1000
        records.append(JournalRecord(time_ns=at_ns, message=message.replace('\\"', '"')))
    return sorted(records, key=lambda item: item.time_ns)


def parse_runtime(
    containerd: list[JournalRecord],
) -> tuple[
    list[SandboxStart],
    dict[str, SandboxEnd],
    dict[str, ContainerCreate],
    dict[str, int],
    list[PullPair],
]:
    sandbox_starts: list[SandboxStart] = []
    sandbox_ends: dict[str, SandboxEnd] = {}
    create_starts: dict[tuple[str, str, int], int] = {}
    creates: dict[str, ContainerCreate] = {}
    started: dict[str, int] = {}
    pull_starts: dict[str, list[int]] = {}
    pull_pairs: list[PullPair] = []
    download_samples: list[tuple[int, str, int]] = []

    for record in containerd:
        message = record.message
        if match := RUN_END_RE.search(message):
            end = SandboxEnd(
                time_ns=record.time_ns,
                uid=match.group("uid"),
                namespace=match.group("namespace"),
                name=match.group("name"),
                attempt=int(match.group("attempt")),
                sandbox_id=match.group("sandbox"),
            )
            sandbox_ends[end.sandbox_id] = end
            continue
        if match := RUN_START_RE.search(message):
            sandbox_starts.append(
                SandboxStart(
                    time_ns=record.time_ns,
                    uid=match.group("uid"),
                    namespace=match.group("namespace"),
                    name=match.group("name"),
                    attempt=int(match.group("attempt")),
                )
            )
            continue
        if match := CREATE_END_RE.search(message):
            key = (match.group("sandbox"), match.group("name"), int(match.group("attempt")))
            creates[match.group("container")] = ContainerCreate(
                start_ns=create_starts.get(key, record.time_ns),
                end_ns=record.time_ns,
                sandbox_id=match.group("sandbox"),
                name=match.group("name"),
                container_id=match.group("container"),
            )
            continue
        if match := CREATE_START_RE.search(message):
            key = (match.group("sandbox"), match.group("name"), int(match.group("attempt")))
            create_starts[key] = record.time_ns
            continue
        if match := START_CONTAINER_END_RE.search(message):
            started[match.group("container")] = record.time_ns
            continue
        if match := PULL_END_RE.search(message):
            image = match.group("image")
            starts = pull_starts.get(image, [])
            if not starts:
                raise RuntimeError(f"PullImage end has no start for {image}")
            start_ns = starts.pop(0)
            bytes_value: int | None = None
            candidates = [
                sample
                for sample in download_samples
                if sample[1] == image and start_ns <= sample[0] <= record.time_ns
            ]
            if candidates:
                bytes_value = candidates[-1][2]
            pull_pairs.append(
                PullPair(
                    image=image,
                    start_ns=start_ns,
                    end_ns=record.time_ns,
                    reference=match.group("reference"),
                    download_bytes=bytes_value,
                )
            )
            continue
        if match := PULL_START_RE.search(message):
            pull_starts.setdefault(match.group("image"), []).append(record.time_ns)
            continue
        if bytes_match := PULL_BYTES_RE.search(message):
            image_match = IMAGE_NAME_RE.search(message)
            if image_match:
                download_samples.append(
                    (record.time_ns, image_match.group("image"), int(bytes_match.group("bytes")))
                )
    return sandbox_starts, sandbox_ends, creates, started, pull_pairs


def nearest_sandbox_start(
    pod: PodTarget, end: SandboxEnd, starts: list[SandboxStart]
) -> SandboxStart:
    matches = [
        item
        for item in starts
        if item.uid == pod.uid
        and item.namespace == pod.namespace
        and item.name == pod.name
        and item.attempt == end.attempt
        and item.time_ns <= end.time_ns
    ]
    if not matches:
        raise RuntimeError(f"no RunPodSandbox start for {pod.namespace}/{pod.name}")
    return max(matches, key=lambda item: item.time_ns)


def image_digest(image: str) -> str:
    matches = SHA256_RE.findall(image)
    return matches[-1].lower() if matches else ""


def base_event(
    cluster_id: str,
    run_id: str,
    pod: PodTarget,
    event_type: str,
    at_ns: int,
    component: str,
    attributes: dict[str, Any],
) -> dict[str, Any]:
    event: dict[str, Any] = {
        "cluster_id": cluster_id,
        "run_id": run_id,
        "event_type": event_type,
        "source_time_ns": at_ns,
        "event_time_ns": at_ns,
        "clock_type": "realtime",
        "source_component": component,
        "source_instance": pod.node_name,
        "namespace": pod.namespace,
        "pod_name": pod.name,
        "pod_uid": pod.uid,
        "node_name": pod.node_name,
        "approximate": False,
        "attributes": attributes,
    }
    if pod.node_uid:
        event["node_uid"] = pod.node_uid
    return event


def cache_hit_time(
    pod: PodTarget,
    container: ContainerTarget,
    kubelet: list[JournalRecord],
    lower_ns: int,
    upper_ns: int,
) -> int:
    object_marker = f'object="{pod.namespace}/{pod.name}"'
    field_marker = f'fieldPath="spec.containers{{{container.name}}}"'
    matches = [
        record.time_ns
        for record in kubelet
        if lower_ns <= record.time_ns <= upper_ns
        and object_marker in record.message
        and field_marker in record.message
        and 'reason="Pulled"' in record.message
        and "already present on machine" in record.message
        and container.image in record.message
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"expected one cache-hit journal record for {pod.namespace}/{pod.name}/"
            f"{container.name}, found {len(matches)}"
        )
    return matches[0]


def normalize_events(
    cluster_id: str,
    run_id: str,
    targets: list[PodTarget],
    journals: dict[str, tuple[list[JournalRecord], list[JournalRecord]]],
) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for pod in targets:
        containerd, kubelet = journals[pod.node_name]
        starts, ends, creates, started, pulls = parse_runtime(containerd)

        pod_creates = [
            creates[container.container_id]
            for container in pod.containers.values()
            if container.container_id in creates
        ]
        if len(pod_creates) != len(pod.containers):
            missing = [
                container.container_id
                for container in pod.containers.values()
                if container.container_id not in creates
            ]
            raise RuntimeError(
                f"missing CreateContainer journal record for {pod.namespace}/{pod.name}: "
                + ",".join(missing)
            )
        sandbox_ids = {item.sandbox_id for item in pod_creates}
        if len(sandbox_ids) != 1:
            raise RuntimeError(f"containers for {pod.namespace}/{pod.name} use multiple sandboxes")
        sandbox_id = next(iter(sandbox_ids))
        sandbox_end = ends.get(sandbox_id)
        if not sandbox_end or sandbox_end.uid != pod.uid:
            raise RuntimeError(f"missing UID-linked sandbox end for {pod.namespace}/{pod.name}")
        sandbox_start = nearest_sandbox_start(pod, sandbox_end, starts)
        sandbox_attributes = {
            "precision": "containerd-cri-journal",
            "runtime_operation": "RunPodSandbox",
            "sandbox_id": sandbox_id,
            "association": "pod-uid+sandbox-id",
        }
        output.append(
            base_event(
                cluster_id,
                run_id,
                pod,
                "POD_SANDBOX_START",
                sandbox_start.time_ns,
                "containerd-cri-journal",
                sandbox_attributes,
            )
        )
        output.append(
            base_event(
                cluster_id,
                run_id,
                pod,
                "POD_SANDBOX_END",
                sandbox_end.time_ns,
                "containerd-cri-journal",
                sandbox_attributes,
            )
        )

        for container in sorted(pod.containers.values(), key=lambda item: item.name):
            create = creates[container.container_id]
            start_ns = started.get(container.container_id)
            if not start_ns:
                raise RuntimeError(
                    f"missing successful StartContainer for {pod.namespace}/{pod.name}/"
                    f"{container.name}"
                )
            candidates = [
                pair
                for pair in pulls
                if pair.image == container.image
                and sandbox_end.time_ns <= pair.start_ns
                and pair.end_ns <= create.start_ns
            ]
            common = {
                "precision": "containerd-cri-journal",
                "association": "pod-uid+sandbox-id+container-id",
                "sandbox_id": sandbox_id,
            }
            if len(candidates) == 1:
                pull = candidates[0]
                start_attributes = dict(common, runtime_operation="PullImage")
                end_attributes = dict(common, runtime_operation="PullImage")
                if pull.download_bytes is not None:
                    end_attributes["download_bytes"] = pull.download_bytes
                for event_type, at_ns, attributes in (
                    ("IMAGE_PULL_START", pull.start_ns, start_attributes),
                    ("IMAGE_PULL_END", pull.end_ns, end_attributes),
                ):
                    event = base_event(
                        cluster_id,
                        run_id,
                        pod,
                        event_type,
                        at_ns,
                        "containerd-cri-journal",
                        attributes,
                    )
                    event.update(
                        {
                            "container_name": container.name,
                            "container_id": container.container_id,
                            "image_ref": container.image,
                            "image_digest": image_digest(container.image),
                            "result": "success" if event_type.endswith("END") else "started",
                        }
                    )
                    output.append(event)
            elif not candidates:
                hit_ns = cache_hit_time(
                    pod, container, kubelet, sandbox_end.time_ns, create.start_ns
                )
                event = base_event(
                    cluster_id,
                    run_id,
                    pod,
                    "IMAGE_CACHE_HIT",
                    hit_ns,
                    "kubelet-journal",
                    {
                        "precision": "kubelet-runtime-manager-journal",
                        "runtime_operation": "image-present-check",
                        "association": "pod-uid+pod-name+container-name+image-digest",
                        "sandbox_id": sandbox_id,
                    },
                )
                event.update(
                    {
                        "container_name": container.name,
                        "container_id": container.container_id,
                        "image_ref": container.image,
                        "image_digest": image_digest(container.image),
                        "result": "cache-hit",
                    }
                )
                output.append(event)
            else:
                raise RuntimeError(
                    f"ambiguous PullImage pairs for {pod.namespace}/{pod.name}/"
                    f"{container.name}: {len(candidates)}"
                )

            event = base_event(
                cluster_id,
                run_id,
                pod,
                "CONTAINER_STARTED",
                start_ns,
                "containerd-cri-journal",
                dict(common, runtime_operation="StartContainer"),
            )
            event.update(
                {
                    "container_name": container.name,
                    "container_id": container.container_id,
                    "image_ref": container.image,
                    "image_digest": image_digest(container.image),
                    "result": "success",
                }
            )
            output.append(event)
    return sorted(
        output,
        key=lambda item: (
            int(item["event_time_ns"]),
            str(item["pod_uid"]),
            str(item["event_type"]),
        ),
    )


def application_events(
    artifact_dir: Path,
    cluster_id: str,
    run_id: str,
    targets: list[PodTarget],
    start_ns: int,
    end_ns: int,
) -> list[dict[str, Any]]:
    by_uid = {pod.uid: pod for pod in targets}
    seen: set[tuple[str, str, int]] = set()
    output: list[dict[str, Any]] = []
    for path in sorted(artifact_dir.glob("pod-logs-*.ndjson")):
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            marker = line.find("{")
            if marker < 0:
                continue
            try:
                record = json.loads(line[marker:])
            except json.JSONDecodeError as exc:
                raise RuntimeError(
                    f"invalid application log JSON in {path.name}:{line_number}"
                ) from exc
            event_type = str(record.get("hooke_event_type") or "")
            if not event_type:
                continue
            pod_uid = str(record.get("pod_uid") or "")
            pod = by_uid.get(pod_uid)
            if not pod:
                raise RuntimeError(
                    f"application event in {path.name}:{line_number} has unknown Pod UID {pod_uid!r}"
                )
            logged_cluster = str(record.get("hooke_cluster_id") or "")
            logged_run = str(record.get("hooke_run_id") or "")
            if logged_cluster != cluster_id:
                raise RuntimeError("application event cluster_id does not match hook input")
            if logged_run != run_id:
                raise RuntimeError("application event run_id does not match hook input")
            expected_identity = {
                "pod_namespace": pod.namespace,
                "pod_name": pod.name,
                "node_name": pod.node_name,
            }
            for field_name, expected in expected_identity.items():
                if str(record.get(field_name) or "") != expected:
                    raise RuntimeError(
                        f"application event {field_name} does not match Pod artifact"
                    )
            at_ns = record.get("source_time_ns")
            if not isinstance(at_ns, int) or at_ns <= 0:
                raise RuntimeError(
                    f"application event in {path.name}:{line_number} has no integer source_time_ns"
                )
            if at_ns < start_ns or at_ns > end_ns:
                raise RuntimeError(
                    f"application event in {path.name}:{line_number} is outside the run window"
                )
            identity = (pod_uid, event_type, at_ns)
            if identity in seen:
                continue
            seen.add(identity)
            attributes = record.get("hooke_attributes")
            if not isinstance(attributes, dict):
                attributes = {}
            attributes = dict(attributes)
            attributes.update(
                {
                    "precision": "application-source-timestamp",
                    "persistence": "container-stdout",
                }
            )
            event = base_event(
                cluster_id,
                run_id,
                pod,
                event_type,
                at_ns,
                "application-event-log",
                attributes,
            )
            container_name = str(record.get("container_name") or "")
            target = pod.containers.get(container_name)
            if not target:
                raise RuntimeError(
                    f"application event container {container_name!r} does not match Pod artifact"
                )
            event["container_name"] = container_name
            event["container_id"] = target.container_id
            event["image_ref"] = target.image
            event["image_digest"] = image_digest(target.image)
            workload_kind = str(record.get("workload_kind") or "")
            workload_name = str(record.get("workload_name") or "")
            if workload_kind:
                event["workload_kind"] = workload_kind
            if workload_name:
                event["workload_name"] = workload_name
            output.append(event)
    return output


def deterministic_event_id(canonical: str) -> str:
    """Return a stable 26-character ID compatible with raw_events.event_id."""
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
        identity = dict(item)
        identity.pop("event_id", None)
        canonical = json.dumps(identity, separators=(",", ":"), sort_keys=True)
        event_id = deterministic_event_id(canonical)
        if event_id in seen_ids:
            raise RuntimeError("runtime export produced duplicate canonical event evidence")
        seen_ids.add(event_id)
        item["event_id"] = event_id
        prepared.append(item)
    content = "".join(
        json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n"
        for record in prepared
    )
    atomic_write(path, content)


def main() -> int:
    args = parse_args()
    if not args.helper_image:
        raise ValueError("E01_HOST_HELPER_IMAGE (or --helper-image) is required")
    if args.timeout_seconds < 1 or args.timeout_seconds > 600:
        raise ValueError("--timeout-seconds must be between 1 and 600")
    start_ns = read_time_ns(args.start_file)
    end_ns = read_time_ns(args.end_file)
    if end_ns <= start_ns:
        raise ValueError("end timestamp must be after start timestamp")
    start = datetime_from_ns(start_ns)
    end = datetime_from_ns(end_ns)
    artifact_dir = Path(args.artifact_dir)
    targets = load_targets(artifact_dir)
    nodes = sorted({pod.node_name for pod in targets})

    current_nodes = run_json(kube_base() + ["get", "nodes", "-o", "json"])
    current_names = {
        str(item.get("metadata", {}).get("name") or "")
        for item in current_nodes.get("items", [])
    }
    missing_nodes = [node for node in nodes if node not in current_names]
    if missing_nodes:
        raise RuntimeError(
            "runtime source node disappeared before journal export: "
            + ",".join(missing_nodes)
        )

    namespace = ""
    journals: dict[str, tuple[list[JournalRecord], list[JournalRecord]]] = {}
    raw_dir = artifact_dir / "runtime-journal"
    try:
        namespace, pods = create_helpers(nodes, args.helper_image, args.timeout_seconds)
        for node in nodes:
            containerd_raw = host_journal(
                namespace,
                pods[node],
                "containerd",
                start,
                end,
                "RunPodSandbox|PullImage|CreateContainer|StartContainer",
            )
            kubelet_raw = host_journal(
                namespace,
                pods[node],
                "kubelet",
                start,
                end,
                'reason="Pulled"',
            )
            stem = safe_name(node)
            atomic_write(raw_dir / f"{stem}.containerd.ndjson", containerd_raw)
            atomic_write(raw_dir / f"{stem}.kubelet.ndjson", kubelet_raw)
            journals[node] = (
                parse_journal(containerd_raw),
                parse_journal(kubelet_raw),
            )
    finally:
        if namespace:
            run(
                kube_base()
                + [
                    "delete",
                    "namespace",
                    namespace,
                    "--wait=false",
                    "--ignore-not-found",
                ],
                check=False,
            )

    events = normalize_events(args.cluster_id, args.run_id, targets, journals)
    events.extend(
        application_events(
            artifact_dir,
            args.cluster_id,
            args.run_id,
            targets,
            start_ns,
            end_ns,
        )
    )
    events.sort(
        key=lambda item: (
            int(item["event_time_ns"]),
            str(item["pod_uid"]),
            str(item["event_type"]),
        )
    )
    expected_minimum = sum(2 + len(pod.containers) * 2 for pod in targets)
    if len(events) < expected_minimum:
        raise RuntimeError(
            f"runtime export produced {len(events)} events, expected at least {expected_minimum}"
        )
    write_ndjson(Path(args.output), events)
    print(
        f"exported {len(events)} exact runtime/application event(s) for "
        f"{len(targets)} Pod(s) "
        f"from {len(nodes)} node journal(s) to {args.output}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"export-runtime-journal-events: {exc}", file=sys.stderr)
        raise SystemExit(1)
