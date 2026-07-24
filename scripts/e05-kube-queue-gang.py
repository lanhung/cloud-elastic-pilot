#!/usr/bin/env python3
"""Generate and validate ACK Kube Queue E05 gang pilot assets."""

from __future__ import annotations

import argparse
import calendar
import csv
import json
import math
import random
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


RFC3339_RE = re.compile(
    r"^(?P<base>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})"
    r"(?P<fraction>\.\d+)?(?P<zone>Z|[+-]\d{2}:\d{2})$"
)


class ValidationError(ValueError):
    pass


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


def generate_schedule(
    repetitions: int, seed: int, members: tuple[int, ...] = (2, 4)
) -> list[dict[str, Any]]:
    if repetitions <= 0:
        raise ValidationError("repetitions must be positive")
    if not members or any(value <= 0 for value in members):
        raise ValidationError("member counts must be positive")
    if len(set(members)) != len(members):
        raise ValidationError("member counts must be unique")
    cells: list[tuple[int, int]] = []
    for member_count in members:
        levels = (member_count, math.ceil(member_count / 2))
        if len(set(levels)) != 2:
            raise ValidationError(
                f"n={member_count} does not produce two distinct k levels"
            )
        cells.extend((member_count, minimum) for minimum in levels)
    rng = random.Random(seed)
    rows: list[dict[str, Any]] = []
    sequence = 0
    for block in range(1, repetitions + 1):
        randomized = list(cells)
        rng.shuffle(randomized)
        for member_count, minimum in randomized:
            sequence += 1
            rows.append(
                {
                    "sequence": sequence,
                    "block": block,
                    "cell_id": f"n{member_count}-k{minimum}",
                    "n": member_count,
                    "k": minimum,
                    "queue_admission_members": member_count,
                    "barrier_minimum": minimum,
                }
            )
    return rows


def write_schedule(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = [
        "sequence",
        "block",
        "cell_id",
        "n",
        "k",
        "queue_admission_members",
        "barrier_minimum",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(
            stream, fieldnames=fields, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)


def workload_manifest(args: argparse.Namespace) -> dict[str, Any]:
    if args.n < 1 or args.k < 1 or args.k > args.n:
        raise ValidationError("manifest requires 1 <= k <= n")
    labels = {
        "app.kubernetes.io/name": "e05-gang-worker",
        "app.kubernetes.io/managed-by": "hooke-e05-runner",
        "hooke.io/run-id": args.run_id,
        "hooke.io/e05-job": args.job_name,
    }
    pod_spec: dict[str, Any] = {
        "restartPolicy": "Never",
        "terminationGracePeriodSeconds": 10,
        "enableServiceLinks": False,
        "containers": [
            {
                "name": "gang-worker",
                "image": args.image,
                "imagePullPolicy": "IfNotPresent",
                "env": [
                    {"name": "E05_N", "value": str(args.n)},
                    {"name": "E05_K", "value": str(args.k)},
                    {
                        "name": "E05_RANK",
                        "valueFrom": {
                            "fieldRef": {
                                "fieldPath": (
                                    "metadata.annotations['batch.kubernetes.io/"
                                    "job-completion-index']"
                                )
                            }
                        },
                    },
                    {"name": "E05_HEADLESS_SERVICE", "value": args.service_name},
                    {"name": "E05_SERVICE_PORT", "value": str(args.port)},
                    {"name": "E05_BARRIER_TIMEOUT", "value": args.barrier_timeout},
                    {"name": "E05_WORK_DURATION", "value": args.work_duration},
                    {
                        "name": "E05_LEADER_GRACE_DURATION",
                        "value": args.leader_grace,
                    },
                    {"name": "HOOKE_SDK_DISABLED", "value": "true"},
                    {"name": "HOOKE_CLUSTER_ID", "value": args.cluster_id},
                    {"name": "HOOKE_RUN_ID", "value": args.run_id},
                    {"name": "HOOKE_CONTAINER_NAME", "value": "gang-worker"},
                    {"name": "HOOKE_WORKLOAD_KIND", "value": "Job"},
                    {"name": "HOOKE_WORKLOAD_NAME", "value": args.job_name},
                    {
                        "name": "POD_NAMESPACE",
                        "valueFrom": {
                            "fieldRef": {"fieldPath": "metadata.namespace"}
                        },
                    },
                    {
                        "name": "POD_NAME",
                        "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}},
                    },
                    {
                        "name": "POD_UID",
                        "valueFrom": {"fieldRef": {"fieldPath": "metadata.uid"}},
                    },
                    {
                        "name": "NODE_NAME",
                        "valueFrom": {"fieldRef": {"fieldPath": "spec.nodeName"}},
                    },
                ],
                "ports": [{"name": "http", "containerPort": args.port}],
                "readinessProbe": {
                    "httpGet": {"path": "/readyz", "port": "http"},
                    "periodSeconds": 1,
                    "timeoutSeconds": 1,
                    "failureThreshold": 30,
                },
                "resources": {
                    "requests": {
                        "cpu": args.cpu_request,
                        "memory": args.memory_request,
                    },
                    "limits": {
                        "cpu": args.cpu_limit,
                        "memory": args.memory_limit,
                    },
                },
                "securityContext": {
                    "allowPrivilegeEscalation": False,
                    "capabilities": {"drop": ["ALL"]},
                    "readOnlyRootFilesystem": True,
                    "runAsNonRoot": True,
                    "runAsUser": 65532,
                    "runAsGroup": 65532,
                },
            }
        ],
        "securityContext": {
            "runAsNonRoot": True,
            "runAsUser": 65532,
            "runAsGroup": 65532,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
    }
    if args.node_selector_key:
        if not args.node_selector_value:
            raise ValidationError("node selector value is required with its key")
        pod_spec["nodeSelector"] = {
            args.node_selector_key: args.node_selector_value
        }
    if args.taint_key:
        if not args.taint_value:
            raise ValidationError("taint value is required with its key")
        pod_spec["tolerations"] = [
            {
                "key": args.taint_key,
                "operator": "Equal",
                "value": args.taint_value,
                "effect": args.taint_effect,
            }
        ]
    service = {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": args.service_name,
            "namespace": args.namespace,
            "labels": labels,
        },
        "spec": {
            "clusterIP": "None",
            "publishNotReadyAddresses": True,
            "selector": {"hooke.io/e05-job": args.job_name},
            "ports": [
                {"name": "http", "port": args.port, "targetPort": "http"}
            ],
        },
    }
    job = {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": args.job_name,
            "namespace": args.namespace,
            "labels": labels,
            "annotations": {"hooke.io/run-id": args.run_id},
        },
        "spec": {
            "suspend": True,
            "parallelism": args.n,
            "completions": args.n,
            "completionMode": "Indexed",
            "backoffLimit": 0,
            "template": {
                "metadata": {
                    "labels": labels,
                    "annotations": {"hooke.io/run-id": args.run_id},
                },
                "spec": pod_spec,
            },
        },
    }
    return {
        "apiVersion": "v1",
        "kind": "List",
        "items": [service, job],
    }


def quota_tree_manifest(args: argparse.Namespace) -> dict[str, Any]:
    resources = {
        "cpu": args.cpu,
        "memory": args.memory,
        "kube-queue/max-jobs": str(args.max_jobs),
    }
    return {
        "apiVersion": "scheduling.sigs.k8s.io/v1beta1",
        "kind": "ElasticQuotaTree",
        "metadata": {"name": args.name, "namespace": "kube-system"},
        "spec": {
            "root": {
                "name": "root",
                "min": resources,
                "max": resources,
                "children": [
                    {
                        "name": args.child_name,
                        "namespaces": [args.namespace],
                        "min": resources,
                        "max": resources,
                    }
                ],
            }
        },
    }


def load_ndjson(path: Path) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    if not path.exists():
        return output
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValidationError(
                f"{path}:{line_number} contains invalid JSON"
            ) from exc
        if not isinstance(value, dict):
            raise ValidationError(f"{path}:{line_number} is not a JSON object")
        output.append(value)
    return output


def queueunit_for_job(
    captures: list[dict[str, Any]], job_name: str
) -> tuple[dict[str, Any], dict[str, Any], int, str]:
    matched: list[tuple[dict[str, Any], int]] = []
    for capture in captures:
        observed_ns = int(capture.get("observed_time_ns") or 0)
        for item in capture.get("items", []):
            if not isinstance(item, dict):
                continue
            spec = item.get("spec") or {}
            owner_names = {
                str(owner.get("name") or "")
                for owner in (item.get("metadata") or {}).get(
                    "ownerReferences", []
                )
                if isinstance(owner, dict)
            }
            if (
                str((spec.get("consumerRef") or {}).get("name") or "")
                == job_name
                or job_name in owner_names
            ):
                matched.append((item, observed_ns))
    if not matched:
        raise ValidationError(f"no QueueUnit capture found for Job {job_name}")
    uids = {
        str((item.get("metadata") or {}).get("uid") or "")
        for item, _ in matched
    }
    uids.discard("")
    if len(uids) > 1:
        raise ValidationError(
            f"multiple QueueUnit UIDs found for Job {job_name}: {sorted(uids)}"
        )

    def requested_count(item: dict[str, Any]) -> int:
        return sum(
            int(value.get("count") or 0)
            for value in (item.get("spec") or {}).get("podSet", [])
            if isinstance(value, dict)
        )

    latest, latest_observed_ns = matched[-1]
    # ACK Job Extensions reduce podSet.count to zero after all completions.
    # Preserve the snapshot with the largest request as the admission input.
    admission = max(matched, key=lambda value: requested_count(value[0]))[0]
    allocate_time = ""
    dequeued_observed_ns = 0
    for item, observed_ns in matched:
        status = item.get("status") or {}
        candidate = str(status.get("lastAllocateTime") or "")
        if candidate and not allocate_time:
            allocate_time = candidate
        if (
            not dequeued_observed_ns
            and str(status.get("phase") or "").lower()
            not in {"", "enqueued", "reserved"}
        ):
            dequeued_observed_ns = observed_ns
    if dequeued_observed_ns <= 0:
        dequeued_observed_ns = latest_observed_ns
    return latest, admission, dequeued_observed_ns, allocate_time


def condition_time_ns(item: dict[str, Any], condition_type: str) -> int:
    for condition in (item.get("status") or {}).get("conditions", []):
        if (
            isinstance(condition, dict)
            and condition.get("type") == condition_type
            and condition.get("status") == "True"
        ):
            return timestamp_ns(str(condition.get("lastTransitionTime") or ""))
    return 0


def summarize_cell(args: argparse.Namespace) -> dict[str, Any]:
    captures = load_ndjson(Path(args.queueunit_captures))
    queueunit, admission_queueunit, observed_ns, allocate_time = queueunit_for_job(
        captures, args.job_name
    )
    pod_sets = (admission_queueunit.get("spec") or {}).get("podSet", [])
    requested_members = sum(
        int(value.get("count") or 0)
        for value in pod_sets
        if isinstance(value, dict)
    )
    declared_minimums = [
        int(value["minCount"])
        for value in pod_sets
        if isinstance(value, dict) and value.get("minCount") is not None
    ]
    if requested_members != args.n:
        raise ValidationError(
            f"QueueUnit requested {requested_members} Pods, expected full n={args.n}"
        )
    if declared_minimums:
        raise ValidationError(
            "native Job QueueUnit unexpectedly declared partial admission"
        )
    status = queueunit.get("status") or {}
    dequeued_ns = timestamp_ns(allocate_time) if allocate_time else observed_ns
    if dequeued_ns <= 0:
        raise ValidationError("QueueUnit has no usable Dequeued timestamp")

    ready_by_rank: dict[int, int] = {}
    pod_captures = load_ndjson(Path(args.pod_captures))
    pods_payload = json.loads(Path(args.pods).read_text(encoding="utf-8"))
    pod_snapshots = pod_captures + [pods_payload]
    for capture in pod_snapshots:
        for pod in capture.get("items", []):
            metadata = pod.get("metadata") or {}
            annotations = metadata.get("annotations") or {}
            raw_rank = annotations.get("batch.kubernetes.io/job-completion-index")
            if raw_rank is None:
                continue
            rank = int(raw_rank)
            ready_ns = condition_time_ns(pod, "Ready")
            if ready_ns > 0:
                previous = ready_by_rank.get(rank)
                ready_by_rank[rank] = (
                    ready_ns if previous is None else min(previous, ready_ns)
                )
    if set(ready_by_rank) != set(range(args.n)):
        raise ValidationError(
            f"Ready ranks are {sorted(ready_by_rank)}, expected 0..{args.n - 1}"
        )
    ready_order = sorted(ready_by_rank.items(), key=lambda item: (item[1], item[0]))
    kth_ready_ns = ready_order[args.k - 1][1]
    nth_ready_ns = ready_order[-1][1]

    application_events = load_ndjson(Path(args.application_events))
    event_ranks: dict[str, set[int]] = {}
    event_times: dict[str, list[int]] = {}
    for item in application_events:
        if item.get("workload_name") != args.job_name:
            continue
        event_type = str(item.get("event_type") or "")
        attributes = item.get("attributes") or {}
        if "rank" not in attributes:
            continue
        rank = int(attributes["rank"])
        event_ranks.setdefault(event_type, set()).add(rank)
        event_times.setdefault(event_type, []).append(int(item["event_time_ns"]))
        if attributes.get("admission_members") != args.n:
            raise ValidationError(
                f"{event_type} rank {rank} did not preserve full-n admission"
            )
    required_types = (
        "READINESS_PROBE_FIRST_SUCCESS",
        "GANG_BARRIER_ENTER",
        "GANG_BARRIER_EXIT",
        "USEFUL_WORK_STARTED",
        "USEFUL_WORK_FINISHED",
    )
    for event_type in required_types:
        if event_ranks.get(event_type) != set(range(args.n)):
            raise ValidationError(
                f"{event_type} ranks are {sorted(event_ranks.get(event_type, set()))}, "
                f"expected 0..{args.n - 1}"
            )
    first_useful_ns = min(event_times["USEFUL_WORK_STARTED"])
    summary = {
        "job_name": args.job_name,
        "n": args.n,
        "k": args.k,
        "queue_admission_policy": "whole-job",
        "queue_admission_members": requested_members,
        "application_barrier_policy": "k-of-n",
        "application_barrier_minimum": args.k,
        "queueunit_name": str((queueunit.get("metadata") or {}).get("name") or ""),
        "queueunit_phase": str(status.get("phase") or ""),
        "dequeued_time_ns": dequeued_ns,
        "dequeued_time_approximate": not bool(allocate_time),
        "ready_order": [
            {"ordinal": index + 1, "rank": rank, "time_ns": at}
            for index, (rank, at) in enumerate(ready_order)
        ],
        "kth_ready_time_ns": kth_ready_ns,
        "nth_ready_time_ns": nth_ready_ns,
        "first_useful_work_time_ns": first_useful_ns,
        "kth_ready_delay_seconds": (kth_ready_ns - dequeued_ns) / 1e9,
        "nth_ready_delay_seconds": (nth_ready_ns - dequeued_ns) / 1e9,
        "barrier_after_kth_ready_seconds": (first_useful_ns - kth_ready_ns) / 1e9,
    }
    return summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    schedule = subparsers.add_parser("schedule")
    schedule.add_argument("--repetitions", type=int, required=True)
    schedule.add_argument("--seed", type=int, required=True)
    schedule.add_argument("--members", default="2,4")
    schedule.add_argument("--output", required=True)

    manifest = subparsers.add_parser("manifest")
    manifest.add_argument("--namespace", required=True)
    manifest.add_argument("--job-name", required=True)
    manifest.add_argument("--service-name", required=True)
    manifest.add_argument("--run-id", required=True)
    manifest.add_argument("--cluster-id", required=True)
    manifest.add_argument("--image", required=True)
    manifest.add_argument("--n", type=int, required=True)
    manifest.add_argument("--k", type=int, required=True)
    manifest.add_argument("--port", type=int, default=8080)
    manifest.add_argument("--barrier-timeout", default="10m")
    manifest.add_argument("--work-duration", default="10s")
    manifest.add_argument("--leader-grace", default="60s")
    manifest.add_argument("--cpu-request", default="250m")
    manifest.add_argument("--cpu-limit", default="250m")
    manifest.add_argument("--memory-request", default="64Mi")
    manifest.add_argument("--memory-limit", default="64Mi")
    manifest.add_argument("--node-selector-key", default="")
    manifest.add_argument("--node-selector-value", default="")
    manifest.add_argument("--taint-key", default="")
    manifest.add_argument("--taint-value", default="")
    manifest.add_argument("--taint-effect", default="NoSchedule")

    quota = subparsers.add_parser("quota-tree")
    quota.add_argument("--name", required=True)
    quota.add_argument("--child-name", required=True)
    quota.add_argument("--namespace", required=True)
    quota.add_argument("--cpu", required=True)
    quota.add_argument("--memory", required=True)
    quota.add_argument("--max-jobs", type=int, default=1)

    summary = subparsers.add_parser("summarize-cell")
    summary.add_argument("--job-name", required=True)
    summary.add_argument("--n", type=int, required=True)
    summary.add_argument("--k", type=int, required=True)
    summary.add_argument("--queueunit-captures", required=True)
    summary.add_argument("--pod-captures", required=True)
    summary.add_argument("--pods", required=True)
    summary.add_argument("--application-events", required=True)
    summary.add_argument("--output", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "schedule":
        members = tuple(int(value) for value in args.members.split(",") if value)
        write_schedule(
            Path(args.output),
            generate_schedule(args.repetitions, args.seed, members),
        )
    elif args.command == "manifest":
        print(json.dumps(workload_manifest(args), separators=(",", ":")))
    elif args.command == "quota-tree":
        print(json.dumps(quota_tree_manifest(args), separators=(",", ":")))
    elif args.command == "summarize-cell":
        summary = summarize_cell(args)
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(output.name + ".tmp")
        temporary.write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary.replace(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError, ValueError, json.JSONDecodeError) as exc:
        print(f"e05-kube-queue-gang: {exc}", file=sys.stderr)
        raise SystemExit(1)
