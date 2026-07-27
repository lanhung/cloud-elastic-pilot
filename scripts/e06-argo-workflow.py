#!/usr/bin/env python3
"""Generate, validate, and summarize E06 Argo Workflow smoke assets."""

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
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable


STAGES = ("a", "b", "c", "d", "e", "f")
CONTROL_DEPENDENCIES = {
    "baseline": {
        "a": (),
        "b": ("a",),
        "c": ("b",),
        "d": ("c",),
        "e": ("d",),
        "f": ("e",),
    },
    "tuned": {
        "a": (),
        "b": ("a",),
        "c": ("a",),
        "d": ("b", "c"),
        "e": ("d",),
        "f": ("e",),
    },
}
# Business-reviewed data dependencies are identical in both variants. The
# baseline deliberately serializes B and C even though neither consumes the
# other's output; the tuned DAG removes only that artificial control edge.
TRUE_DEPENDENCIES = CONTROL_DEPENDENCIES["tuned"]
EXPECTED_CRITICAL_PATH = {
    "baseline": ("a", "b", "c", "d", "e", "f"),
    "tuned": ("a", "b", "d", "e", "f"),
}
RFC3339_RE = re.compile(
    r"^(?P<base>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})"
    r"(?P<fraction>\.\d+)?(?P<zone>Z|[+-]\d{2}:\d{2})$"
)
DURATION_RE = re.compile(r"^(?P<number>[1-9][0-9]*)(?P<unit>ms|s|m|h)$")
QUANTITY_RE = re.compile(
    r"^(?P<number>[+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)"
    r"(?P<suffix>n|u|m|k|K|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?$"
)
QUANTITY_MULTIPLIERS = {
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


def duration_seconds(value: str) -> Decimal:
    match = DURATION_RE.fullmatch(value)
    if not match:
        raise ValidationError(f"invalid positive duration: {value!r}")
    number = Decimal(match.group("number"))
    multiplier = {
        "ms": Decimal("0.001"),
        "s": Decimal(1),
        "m": Decimal(60),
        "h": Decimal(3600),
    }[match.group("unit")]
    return number * multiplier


def quantity(value: str) -> Decimal:
    match = QUANTITY_RE.fullmatch(str(value))
    if not match:
        raise ValidationError(f"invalid Kubernetes quantity: {value!r}")
    try:
        result = Decimal(match.group("number")) * QUANTITY_MULTIPLIERS[
            match.group("suffix") or ""
        ]
    except InvalidOperation as exc:
        raise ValidationError(f"invalid Kubernetes quantity: {value!r}") from exc
    if result < 0:
        raise ValidationError(f"negative Kubernetes quantity: {value!r}")
    return result


def parse_stage_durations(raw: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for part in raw.split(","):
        if not part.strip():
            continue
        if "=" not in part:
            raise ValidationError(f"invalid stage duration entry: {part!r}")
        stage, value = (item.strip() for item in part.split("=", 1))
        if stage not in STAGES or stage in result:
            raise ValidationError(f"invalid or duplicate stage: {stage!r}")
        duration_seconds(value)
        result[stage] = value
    if set(result) != set(STAGES):
        raise ValidationError(
            f"stage durations must define exactly {','.join(STAGES)}"
        )
    if duration_seconds(result["b"]) <= duration_seconds(result["c"]):
        raise ValidationError(
            "stage b must be longer than c so the tuned critical path is deterministic"
        )
    return result


def compact_dependencies(value: dict[str, tuple[str, ...]]) -> str:
    return json.dumps(
        {stage: list(value[stage]) for stage in STAGES},
        separators=(",", ":"),
        sort_keys=True,
    )


def edge_set(dependencies: dict[str, Iterable[str]]) -> set[tuple[str, str]]:
    return {
        (predecessor, stage)
        for stage, predecessors in dependencies.items()
        for predecessor in predecessors
    }


def generate_schedule(repetitions: int, seed: int) -> list[dict[str, Any]]:
    if repetitions <= 0:
        raise ValidationError("repetitions must be positive")
    rng = random.Random(seed)
    rows: list[dict[str, Any]] = []
    sequence = 0
    for block in range(1, repetitions + 1):
        variants = ["baseline", "tuned"]
        rng.shuffle(variants)
        for variant in variants:
            sequence += 1
            rows.append(
                {
                    "sequence": sequence,
                    "block": block,
                    "cell_id": variant,
                    "variant": variant,
                }
            )
    return rows


def write_schedule(path: Path, rows: list[dict[str, Any]]) -> None:
    atomic_text(
        path,
        render_tsv(rows, ("sequence", "block", "cell_id", "variant")),
    )


def render_tsv(rows: list[dict[str, Any]], fields: tuple[str, ...]) -> str:
    from io import StringIO

    stream = StringIO()
    writer = csv.DictWriter(
        stream, fieldnames=fields, delimiter="\t", lineterminator="\n"
    )
    writer.writeheader()
    writer.writerows(rows)
    return stream.getvalue()


def rbac_manifest(namespace: str, service_account: str) -> dict[str, Any]:
    labels = {
        "app.kubernetes.io/name": "e06-argo-workflow",
        "app.kubernetes.io/managed-by": "hooke-e06-runner",
    }
    role_name = f"{service_account}-executor"
    return {
        "apiVersion": "v1",
        "kind": "List",
        "items": [
            {
                "apiVersion": "v1",
                "kind": "ServiceAccount",
                "metadata": {
                    "name": service_account,
                    "namespace": namespace,
                    "labels": labels,
                },
            },
            {
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "Role",
                "metadata": {
                    "name": role_name,
                    "namespace": namespace,
                    "labels": labels,
                },
                "rules": [
                    {
                        "apiGroups": ["argoproj.io"],
                        "resources": ["workflowtaskresults"],
                        "verbs": ["create", "patch"],
                    }
                ],
            },
            {
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "RoleBinding",
                "metadata": {
                    "name": role_name,
                    "namespace": namespace,
                    "labels": labels,
                },
                "roleRef": {
                    "apiGroup": "rbac.authorization.k8s.io",
                    "kind": "Role",
                    "name": role_name,
                },
                "subjects": [
                    {
                        "kind": "ServiceAccount",
                        "name": service_account,
                        "namespace": namespace,
                    }
                ],
            },
        ],
    }


def pod_placement(args: argparse.Namespace) -> dict[str, Any]:
    placement: dict[str, Any] = {}
    if args.node_selector_key:
        if not args.node_selector_value:
            raise ValidationError("node selector value is required with its key")
        placement["nodeSelector"] = {
            args.node_selector_key: args.node_selector_value
        }
    if args.taint_key:
        if not args.taint_value:
            raise ValidationError("taint value is required with its key")
        placement["tolerations"] = [
            {
                "key": args.taint_key,
                "operator": "Equal",
                "value": args.taint_value,
                "effect": args.taint_effect,
            }
        ]
    return placement


def stage_env(
    *,
    stage: str,
    variant: str,
    duration: str,
    run_id: str,
    cluster_id: str,
    predecessors: tuple[str, ...],
    proof: str,
    workload_name: str,
) -> list[dict[str, Any]]:
    return [
        {"name": "E06_STAGE_NAME", "value": stage},
        {"name": "E06_VARIANT", "value": variant},
        {"name": "E06_WORK_DURATION", "value": duration},
        {"name": "E06_PREDECESSORS", "value": ",".join(predecessors)},
        {"name": "E06_DEPENDENCY_PROOF", "value": proof},
        {"name": "HOOKE_SDK_DISABLED", "value": "true"},
        {"name": "HOOKE_CLUSTER_ID", "value": cluster_id},
        {"name": "HOOKE_RUN_ID", "value": run_id},
        {"name": "HOOKE_CONTAINER_NAME", "value": "main"},
        {"name": "HOOKE_WORKLOAD_KIND", "value": "Workflow"},
        {"name": "HOOKE_WORKLOAD_NAME", "value": workload_name},
        {
            "name": "POD_NAMESPACE",
            "valueFrom": {"fieldRef": {"fieldPath": "metadata.namespace"}},
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
    ]


def container_security() -> dict[str, Any]:
    return {
        "allowPrivilegeEscalation": False,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": True,
        "runAsNonRoot": True,
        "runAsUser": 65532,
        "runAsGroup": 65532,
    }


def workflow_manifest(args: argparse.Namespace) -> dict[str, Any]:
    if args.variant not in CONTROL_DEPENDENCIES:
        raise ValidationError("variant must be baseline or tuned")
    durations = parse_stage_durations(args.stage_durations)
    for value in (
        args.cpu_request,
        args.cpu_limit,
        args.memory_request,
        args.memory_limit,
    ):
        if quantity(value) <= 0:
            raise ValidationError("worker resources must be positive")
    dependencies = CONTROL_DEPENDENCIES[args.variant]
    tasks: list[dict[str, Any]] = []
    for stage in STAGES:
        predecessors = dependencies[stage]
        true_predecessors = TRUE_DEPENDENCIES[stage]
        proof = (
            "root-trigger"
            if not true_predecessors
            else "business-inputs-from:" + ",".join(true_predecessors)
        )
        task: dict[str, Any] = {
            "name": stage,
            "template": "e06-stage",
            "arguments": {
                "parameters": [
                    {"name": "stage", "value": stage},
                    {"name": "duration", "value": durations[stage]},
                    {
                        "name": "true-predecessors",
                        "value": ",".join(true_predecessors),
                    },
                    {"name": "dependency-proof", "value": proof},
                ]
            },
        }
        if predecessors:
            task["dependencies"] = list(predecessors)
        tasks.append(task)
    stage_template: dict[str, Any] = {
        "name": "e06-stage",
        "inputs": {
            "parameters": [
                {"name": "stage"},
                {"name": "duration"},
                {"name": "true-predecessors"},
                {"name": "dependency-proof"},
            ]
        },
        "metadata": {
            "labels": {
                "app.kubernetes.io/name": "e06-stage-worker",
                "app.kubernetes.io/managed-by": "hooke-e06-runner",
                "hooke.io/run-id": args.run_id,
                "hooke.io/e06-variant": args.variant,
            },
            "annotations": {"hooke.io/run-id": args.run_id},
        },
        "container": {
            "name": "main",
            "image": args.image,
            "imagePullPolicy": "IfNotPresent",
            "env": stage_env(
                stage="{{inputs.parameters.stage}}",
                variant=args.variant,
                duration="{{inputs.parameters.duration}}",
                run_id=args.run_id,
                cluster_id=args.cluster_id,
                predecessors=(
                    "{{inputs.parameters.true-predecessors}}",
                ),
                proof="{{inputs.parameters.dependency-proof}}",
                workload_name="{{workflow.name}}",
            ),
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
            "securityContext": container_security(),
        },
        "securityContext": {
            "runAsNonRoot": True,
            "runAsUser": 65532,
            "runAsGroup": 65532,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "activeDeadlineSeconds": args.stage_timeout_seconds,
    }
    stage_template.update(pod_placement(args))
    annotations = {
        "hooke.io/run-id": args.run_id,
        "hooke.io/e06-variant": args.variant,
        "hooke.io/true-dependencies": compact_dependencies(TRUE_DEPENDENCIES),
        "hooke.io/control-dependencies": compact_dependencies(dependencies),
        "hooke.io/e06-protocol": "serial-vs-parallel-v1",
    }
    return {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "Workflow",
        "metadata": {
            "name": args.name,
            "namespace": args.namespace,
            "labels": {
                "app.kubernetes.io/name": "e06-argo-workflow",
                "app.kubernetes.io/managed-by": "hooke-e06-runner",
                "hooke.io/run-id": args.run_id,
                "hooke.io/e06-variant": args.variant,
            },
            "annotations": annotations,
        },
        "spec": {
            "entrypoint": "experiment-dag",
            "serviceAccountName": args.service_account,
            "parallelism": 2,
            "activeDeadlineSeconds": args.workflow_timeout_seconds,
            "templates": [
                {"name": "experiment-dag", "dag": {"tasks": tasks}},
                stage_template,
            ],
        },
    }


def warmup_manifest(args: argparse.Namespace) -> dict[str, Any]:
    for value in (
        args.cpu_request,
        args.cpu_limit,
        args.memory_request,
        args.memory_limit,
    ):
        if quantity(value) <= 0:
            raise ValidationError("warmup resources must be positive")
    spec: dict[str, Any] = {
        "restartPolicy": "Never",
        "terminationGracePeriodSeconds": 10,
        "automountServiceAccountToken": False,
        "enableServiceLinks": False,
        "containers": [
            {
                "name": "main",
                "image": args.image,
                "imagePullPolicy": "IfNotPresent",
                "env": stage_env(
                    stage="warmup",
                    variant="warmup",
                    duration="100ms",
                    run_id=args.run_id,
                    cluster_id=args.cluster_id,
                    predecessors=(),
                    proof="image-preload-only",
                    workload_name=args.name,
                ),
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
                "securityContext": container_security(),
            }
        ],
        "securityContext": {
            "runAsNonRoot": True,
            "runAsUser": 65532,
            "runAsGroup": 65532,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
    }
    spec.update(pod_placement(args))
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": args.name,
            "namespace": args.namespace,
            "labels": {
                "app.kubernetes.io/name": "e06-image-warmup",
                "app.kubernetes.io/managed-by": "hooke-e06-runner",
                "hooke.io/run-id": args.run_id,
            },
            "annotations": {"hooke.io/run-id": args.run_id},
        },
        "spec": spec,
    }


def pod_effective_request(pod: dict[str, Any], resource: str) -> Decimal:
    spec = pod.get("spec") or {}
    regular = sum(
        (
            quantity(
                str(
                    ((container.get("resources") or {}).get("requests") or {}).get(
                        resource, "0"
                    )
                )
            )
            for container in spec.get("containers", [])
        ),
        Decimal(0),
    )
    init_max = max(
        (
            quantity(
                str(
                    ((container.get("resources") or {}).get("requests") or {}).get(
                        resource, "0"
                    )
                )
            )
            for container in spec.get("initContainers", [])
        ),
        default=Decimal(0),
    )
    overhead = quantity(str((spec.get("overhead") or {}).get(resource, "0")))
    return max(regular, init_max) + overhead


def node_headroom(node: dict[str, Any], pods: dict[str, Any]) -> dict[str, Any]:
    node_name = str((node.get("metadata") or {}).get("name") or "")
    if not node_name:
        raise ValidationError("node payload has no metadata.name")
    allocatable = (node.get("status") or {}).get("allocatable") or {}
    cpu_alloc = quantity(str(allocatable.get("cpu") or "0"))
    memory_alloc = quantity(str(allocatable.get("memory") or "0"))
    cpu_requested = Decimal(0)
    memory_requested = Decimal(0)
    counted = 0
    for pod in pods.get("items", []):
        if (pod.get("spec") or {}).get("nodeName") != node_name:
            continue
        if (pod.get("status") or {}).get("phase") in {"Succeeded", "Failed"}:
            continue
        cpu_requested += pod_effective_request(pod, "cpu")
        memory_requested += pod_effective_request(pod, "memory")
        counted += 1
    return {
        "node_name": node_name,
        "active_pod_count": counted,
        "allocatable_cpu_millicores": int(cpu_alloc * 1000),
        "requested_cpu_millicores": int(cpu_requested * 1000),
        "available_cpu_millicores": int((cpu_alloc - cpu_requested) * 1000),
        "allocatable_memory_bytes": int(memory_alloc),
        "requested_memory_bytes": int(memory_requested),
        "available_memory_bytes": int(memory_alloc - memory_requested),
    }


def workflow_control_dependencies(workflow: dict[str, Any]) -> dict[str, tuple[str, ...]]:
    spec = workflow.get("spec") or {}
    entrypoint = str(spec.get("entrypoint") or "")
    templates = {
        str(template.get("name") or ""): template
        for template in spec.get("templates", [])
        if isinstance(template, dict)
    }
    entry = templates.get(entrypoint) or {}
    tasks = ((entry.get("dag") or {}).get("tasks") or [])
    dependencies: dict[str, tuple[str, ...]] = {}
    for task in tasks:
        name = str(task.get("name") or "")
        if name not in STAGES or name in dependencies:
            raise ValidationError(f"unexpected or duplicate DAG task {name!r}")
        if task.get("depends"):
            raise ValidationError("E06 manifest must use explicit dependencies lists")
        dependencies[name] = tuple(str(value) for value in task.get("dependencies", []))
    if set(dependencies) != set(STAGES):
        raise ValidationError("Workflow DAG does not contain exactly stages a..f")
    return dependencies


def logical_stage_nodes(workflow: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for node_id, raw in ((workflow.get("status") or {}).get("nodes") or {}).items():
        if not isinstance(raw, dict) or raw.get("type") != "Pod":
            continue
        stage = str(raw.get("displayName") or "")
        if stage not in STAGES:
            continue
        if stage in result:
            raise ValidationError(f"Workflow retried or duplicated stage {stage}")
        value = dict(raw)
        value["id"] = node_id
        result[stage] = value
    if set(result) != set(STAGES):
        raise ValidationError(
            f"Workflow stage nodes are {sorted(result)}, expected {list(STAGES)}"
        )
    return result


def longest_path(
    durations: dict[str, float],
    dependencies: dict[str, tuple[str, ...]],
) -> tuple[list[str], float]:
    incoming = {stage: set(dependencies[stage]) for stage in STAGES}
    outgoing = {stage: set() for stage in STAGES}
    for stage, predecessors in incoming.items():
        for predecessor in predecessors:
            if predecessor not in outgoing:
                raise ValidationError(f"unknown predecessor {predecessor!r}")
            outgoing[predecessor].add(stage)
    queue = sorted(stage for stage in STAGES if not incoming[stage])
    distance = {stage: durations[stage] for stage in STAGES}
    paths = {stage: [stage] for stage in STAGES}
    visited = 0
    while queue:
        stage = queue.pop(0)
        visited += 1
        for target in sorted(outgoing[stage]):
            candidate = distance[stage] + durations[target]
            candidate_path = paths[stage] + [target]
            if candidate > distance[target] or (
                candidate == distance[target]
                and tuple(candidate_path) < tuple(paths[target])
            ):
                distance[target] = candidate
                paths[target] = candidate_path
            incoming[target].remove(stage)
            if not incoming[target]:
                queue.append(target)
                queue.sort()
    if visited != len(STAGES):
        raise ValidationError("Workflow DAG contains a cycle")
    end = min(STAGES, key=lambda stage: (-distance[stage], tuple(paths[stage])))
    return paths[end], distance[end]


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValidationError(f"{path} does not contain a JSON object")
    return value


def load_ndjson(path: Path) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValidationError(f"{path}:{line_number} is not an object")
        result.append(value)
    return result


def summarize_cell(args: argparse.Namespace) -> dict[str, Any]:
    workflow = load_json(Path(args.workflow))
    pods = load_json(Path(args.pods))
    events = load_ndjson(Path(args.application_events))
    metadata = workflow.get("metadata") or {}
    status = workflow.get("status") or {}
    workflow_uid = str(metadata.get("uid") or "")
    workflow_name = str(metadata.get("name") or "")
    annotations = metadata.get("annotations") or {}
    if not workflow_uid or not workflow_name:
        raise ValidationError("Workflow identity is incomplete")
    if status.get("phase") != "Succeeded":
        raise ValidationError(f"Workflow phase is {status.get('phase')!r}")
    if annotations.get("hooke.io/e06-variant") != args.variant:
        raise ValidationError("Workflow variant annotation does not match")
    dependencies = workflow_control_dependencies(workflow)
    if dependencies != CONTROL_DEPENDENCIES[args.variant]:
        raise ValidationError("Workflow control DAG differs from frozen protocol")
    try:
        true_dependencies = json.loads(
            str(annotations.get("hooke.io/true-dependencies") or "")
        )
    except json.JSONDecodeError as exc:
        raise ValidationError("true dependency annotation is invalid") from exc
    expected_true = {stage: list(TRUE_DEPENDENCIES[stage]) for stage in STAGES}
    if true_dependencies != expected_true:
        raise ValidationError("business-reviewed true dependencies changed")
    if (
        "b" in TRUE_DEPENDENCIES["c"]
        or "c" in TRUE_DEPENDENCIES["b"]
    ):
        raise ValidationError("B and C dependency proof is internally inconsistent")
    nodes = logical_stage_nodes(workflow)
    node_times: dict[str, tuple[int, int]] = {}
    durations: dict[str, float] = {}
    for stage, node in nodes.items():
        if node.get("phase") != "Succeeded":
            raise ValidationError(f"stage {stage} phase is {node.get('phase')!r}")
        started = timestamp_ns(str(node.get("startedAt") or ""))
        finished = timestamp_ns(str(node.get("finishedAt") or ""))
        if finished < started:
            raise ValidationError(f"stage {stage} has negative duration")
        node_times[stage] = (started, finished)
        durations[stage] = (finished - started) / 1e9

    expected_digest = args.expected_image.rsplit("@sha256:", 1)[-1].lower()
    pod_items = pods.get("items", [])
    if len(pod_items) != len(STAGES):
        raise ValidationError(
            f"Workflow has {len(pod_items)} Pods, expected {len(STAGES)}"
        )
    pod_uids: set[str] = set()
    for pod in pod_items:
        pod_metadata = pod.get("metadata") or {}
        pod_uid = str(pod_metadata.get("uid") or "")
        if not pod_uid or pod_uid in pod_uids:
            raise ValidationError("Workflow Pod UID is empty or duplicated")
        pod_uids.add(pod_uid)
        owner_uids = {
            str(owner.get("uid") or "")
            for owner in pod_metadata.get("ownerReferences", [])
            if owner.get("kind") == "Workflow"
        }
        if owner_uids != {workflow_uid}:
            raise ValidationError("Workflow Pod owner UID is not exact")
        if (pod.get("status") or {}).get("phase") != "Succeeded":
            raise ValidationError(
                f"Pod {pod_metadata.get('name')} did not succeed"
            )
        if args.expected_node and (pod.get("spec") or {}).get("nodeName") != args.expected_node:
            raise ValidationError(
                f"Pod {pod_metadata.get('name')} escaped fixed node"
            )
        statuses = {
            str(item.get("name") or ""): item
            for item in (pod.get("status") or {}).get("containerStatuses", [])
        }
        main = statuses.get("main")
        if main is None:
            raise ValidationError("Workflow Pod has no main container status")
        image_id = str(main.get("imageID") or "").lower()
        if expected_digest not in image_id:
            raise ValidationError(
                f"Pod {pod_metadata.get('name')} imageID does not match immutable image"
            )

    relevant = [
        item
        for item in events
        if item.get("workload_uid") == workflow_uid
        and item.get("event_type")
        in {"USEFUL_WORK_STARTED", "USEFUL_WORK_FINISHED"}
    ]
    by_stage_type: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for item in relevant:
        attributes = item.get("attributes") or {}
        stage = str(attributes.get("stage_name") or "")
        event_type = str(item.get("event_type") or "")
        if stage not in STAGES:
            raise ValidationError(f"application event has unknown stage {stage!r}")
        if attributes.get("variant") != args.variant:
            raise ValidationError(f"stage {stage} event variant changed")
        if (
            item.get("workload_kind") != "Workflow"
            or item.get("workload_name") != workflow_name
        ):
            raise ValidationError(f"stage {stage} event Workflow identity changed")
        if str(item.get("pod_uid") or "") not in pod_uids:
            raise ValidationError(f"stage {stage} event Pod UID is not frozen")
        if item.get("approximate") is True:
            raise ValidationError(f"stage {stage} application event is approximate")
        if item.get("source_component") != "application-event-log":
            raise ValidationError(f"stage {stage} event is not log-derived")
        if expected_digest not in str(item.get("image_digest") or "").lower():
            raise ValidationError(f"stage {stage} event image digest changed")
        by_stage_type.setdefault((stage, event_type), []).append(item)
    app_times: dict[str, tuple[int, int]] = {}
    stage_pod_uids: set[str] = set()
    tolerance_ns = int(args.clock_tolerance_seconds * 1e9)
    for stage in STAGES:
        starts = by_stage_type.get((stage, "USEFUL_WORK_STARTED"), [])
        finishes = by_stage_type.get((stage, "USEFUL_WORK_FINISHED"), [])
        if len(starts) != 1 or len(finishes) != 1:
            raise ValidationError(
                f"stage {stage} application events are start={len(starts)}, finish={len(finishes)}"
            )
        start = int(starts[0].get("event_time_ns") or 0)
        finish = int(finishes[0].get("event_time_ns") or 0)
        start_pod_uid = str(starts[0].get("pod_uid") or "")
        finish_pod_uid = str(finishes[0].get("pod_uid") or "")
        if start_pod_uid != finish_pod_uid:
            raise ValidationError(f"stage {stage} events span multiple Pods")
        if start_pod_uid in stage_pod_uids:
            raise ValidationError("multiple logical stages reused one Pod")
        stage_pod_uids.add(start_pod_uid)
        if start <= 0 or finish < start:
            raise ValidationError(f"stage {stage} application event order is invalid")
        node_start, node_finish = node_times[stage]
        if start < node_start - tolerance_ns or finish > node_finish + tolerance_ns:
            raise ValidationError(
                f"stage {stage} application events escape Argo node interval"
            )
        app_times[stage] = (start, finish)
    if stage_pod_uids != pod_uids:
        raise ValidationError("application events do not cover every Workflow Pod")

    critical_path, critical_seconds = longest_path(durations, dependencies)
    if tuple(critical_path) != EXPECTED_CRITICAL_PATH[args.variant]:
        raise ValidationError(
            f"{args.variant} critical path is {critical_path}, "
            f"expected {list(EXPECTED_CRITICAL_PATH[args.variant])}"
        )
    b_start, b_finish = node_times["b"]
    c_start, c_finish = node_times["c"]
    bc_overlap_seconds = max(
        0.0, (min(b_finish, c_finish) - max(b_start, c_start)) / 1e9
    )
    if args.variant == "baseline" and bc_overlap_seconds > args.clock_tolerance_seconds:
        raise ValidationError("baseline B/C unexpectedly overlap")
    if args.variant == "tuned" and bc_overlap_seconds <= 0:
        raise ValidationError("tuned B/C did not overlap")

    workflow_started = timestamp_ns(str(status.get("startedAt") or ""))
    workflow_finished = timestamp_ns(str(status.get("finishedAt") or ""))
    if workflow_finished < workflow_started:
        raise ValidationError("Workflow duration is negative")
    workflow_seconds = (workflow_finished - workflow_started) / 1e9
    startup_delays: dict[str, float] = {}
    for stage in STAGES:
        predecessors = dependencies[stage]
        eligible = (
            max(node_times[value][1] for value in predecessors)
            if predecessors
            else workflow_started
        )
        raw_delay = (app_times[stage][0] - eligible) / 1e9
        if raw_delay < -args.clock_tolerance_seconds:
            raise ValidationError(f"stage {stage} useful work predates eligibility")
        startup_delays[stage] = max(0.0, raw_delay)
    predicted = math.prod(
        math.exp(-durations[stage] / args.slo_seconds)
        for stage in critical_path
    )
    measured = math.exp(-workflow_seconds / args.slo_seconds)
    return {
        "sequence": args.sequence,
        "block": args.block,
        "variant": args.variant,
        "workflow_name": workflow_name,
        "workflow_uid": workflow_uid,
        "workflow_phase": status.get("phase"),
        "control_dependencies": {
            stage: list(dependencies[stage]) for stage in STAGES
        },
        "true_dependencies": expected_true,
        "stage_durations_seconds": durations,
        "stage_startup_delays_seconds": startup_delays,
        "critical_path": critical_path,
        "critical_path_length": len(critical_path),
        "critical_path_seconds": critical_seconds,
        "workflow_duration_seconds": workflow_seconds,
        "workflow_overhead_seconds": workflow_seconds - critical_seconds,
        "bc_overlap_seconds": bc_overlap_seconds,
        "elasticity_slo_seconds": args.slo_seconds,
        "workflow_elasticity_predicted": predicted,
        "workflow_elasticity_measured": measured,
        "workflow_model_absolute_error": abs(predicted - measured),
        "required_application_events": len(relevant),
        "expected_application_events": len(STAGES) * 2,
        "application_event_completeness": len(relevant) / (len(STAGES) * 2),
        "fixed_node": args.expected_node,
        "image": args.expected_image,
        "gate": "PASS",
    }


def aggregate_summaries(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    if not summaries:
        raise ValidationError("no E06 cell summaries")
    by_block: dict[int, dict[str, dict[str, Any]]] = {}
    for summary in summaries:
        block = int(summary.get("block") or 0)
        variant = str(summary.get("variant") or "")
        if block <= 0 or variant not in CONTROL_DEPENDENCIES:
            raise ValidationError("cell summary has invalid block or variant")
        if summary.get("gate") != "PASS":
            raise ValidationError("cannot aggregate a failed E06 cell")
        if variant in by_block.setdefault(block, {}):
            raise ValidationError(f"block {block} repeats variant {variant}")
        by_block[block][variant] = summary
    comparisons: list[dict[str, Any]] = []
    for block in sorted(by_block):
        cells = by_block[block]
        if set(cells) != {"baseline", "tuned"}:
            raise ValidationError(f"block {block} is not a complete pair")
        baseline = cells["baseline"]
        tuned = cells["tuned"]
        baseline_seconds = float(baseline["workflow_duration_seconds"])
        tuned_seconds = float(tuned["workflow_duration_seconds"])
        if tuned_seconds >= baseline_seconds:
            raise ValidationError(
                f"block {block} tuned Workflow was not faster than baseline"
            )
        comparisons.append(
            {
                "block": block,
                "baseline_workflow_seconds": baseline_seconds,
                "tuned_workflow_seconds": tuned_seconds,
                "duration_reduction_seconds": baseline_seconds - tuned_seconds,
                "duration_reduction_ratio": (
                    baseline_seconds - tuned_seconds
                )
                / baseline_seconds,
                "baseline_critical_path_length": int(
                    baseline["critical_path_length"]
                ),
                "tuned_critical_path_length": int(tuned["critical_path_length"]),
                "baseline_measured_elasticity": float(
                    baseline["workflow_elasticity_measured"]
                ),
                "tuned_measured_elasticity": float(
                    tuned["workflow_elasticity_measured"]
                ),
                "elasticity_gain_ratio": float(
                    tuned["workflow_elasticity_measured"]
                )
                / float(baseline["workflow_elasticity_measured"]),
                "tuned_bc_overlap_seconds": float(tuned["bc_overlap_seconds"]),
            }
        )
    return {
        "experiment": "E06 Argo Workflow critical-path smoke",
        "scope": "smoke" if len(comparisons) == 1 else "pilot",
        "pair_count": len(comparisons),
        "cell_count": len(summaries),
        "passed_cells": len(summaries),
        "comparisons": comparisons,
        "cells": sorted(
            summaries, key=lambda item: (int(item["block"]), int(item["sequence"]))
        ),
        "gate": "PASS",
    }


def report_markdown(summary: dict[str, Any]) -> str:
    lines = [
        "# E06 Argo Workflow critical-path smoke summary",
        "",
        f"- Gate: **{summary['gate']}**",
        f"- Scope: `{summary['scope']}`",
        f"- Paired blocks: {summary['pair_count']}",
        f"- Cells: {summary['passed_cells']}/{summary['cell_count']} PASS",
        "",
        "| Block | Baseline (s) | Tuned (s) | Reduction | CP length | B/C overlap (s) |",
        "|---:|---:|---:|---:|---:|---:|",
    ]
    for item in summary["comparisons"]:
        lines.append(
            "| {block} | {baseline_workflow_seconds:.3f} | "
            "{tuned_workflow_seconds:.3f} | {duration_reduction_ratio:.2%} | "
            "{baseline_critical_path_length}→{tuned_critical_path_length} | "
            "{tuned_bc_overlap_seconds:.3f} |".format(**item)
        )
    lines.extend(
        [
            "",
            "This is a smoke Gate result. It validates the Argo CR/event path, "
            "business-reviewed dependencies, application events, and critical-path "
            "calculation; it is not a 30-repeat statistical conclusion.",
            "",
        ]
    )
    return "\n".join(lines)


def atomic_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def atomic_json(path: Path, value: Any) -> None:
    atomic_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n")


def add_placement_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--node-selector-key", default="")
    parser.add_argument("--node-selector-value", default="")
    parser.add_argument("--taint-key", default="")
    parser.add_argument("--taint-value", default="")
    parser.add_argument("--taint-effect", default="NoSchedule")


def add_resource_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--cpu-request", default="50m")
    parser.add_argument("--cpu-limit", default="100m")
    parser.add_argument("--memory-request", default="32Mi")
    parser.add_argument("--memory-limit", default="64Mi")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    schedule = subparsers.add_parser("schedule")
    schedule.add_argument("--repetitions", type=int, required=True)
    schedule.add_argument("--seed", type=int, required=True)
    schedule.add_argument("--output", required=True)

    rbac = subparsers.add_parser("rbac")
    rbac.add_argument("--namespace", required=True)
    rbac.add_argument("--service-account", required=True)

    workflow = subparsers.add_parser("workflow")
    workflow.add_argument("--namespace", required=True)
    workflow.add_argument("--name", required=True)
    workflow.add_argument("--run-id", required=True)
    workflow.add_argument("--cluster-id", required=True)
    workflow.add_argument("--variant", choices=("baseline", "tuned"), required=True)
    workflow.add_argument("--image", required=True)
    workflow.add_argument("--service-account", required=True)
    workflow.add_argument("--stage-durations", required=True)
    workflow.add_argument("--stage-timeout-seconds", type=int, default=120)
    workflow.add_argument("--workflow-timeout-seconds", type=int, default=600)
    add_placement_arguments(workflow)
    add_resource_arguments(workflow)

    warmup = subparsers.add_parser("warmup")
    warmup.add_argument("--namespace", required=True)
    warmup.add_argument("--name", required=True)
    warmup.add_argument("--run-id", required=True)
    warmup.add_argument("--cluster-id", required=True)
    warmup.add_argument("--image", required=True)
    add_placement_arguments(warmup)
    add_resource_arguments(warmup)

    headroom = subparsers.add_parser("node-headroom")
    headroom.add_argument("--node", required=True)
    headroom.add_argument("--pods", required=True)
    headroom.add_argument("--output", required=True)

    cell = subparsers.add_parser("summarize-cell")
    cell.add_argument("--workflow", required=True)
    cell.add_argument("--pods", required=True)
    cell.add_argument("--application-events", required=True)
    cell.add_argument("--variant", choices=("baseline", "tuned"), required=True)
    cell.add_argument("--sequence", type=int, required=True)
    cell.add_argument("--block", type=int, required=True)
    cell.add_argument("--slo-seconds", type=float, required=True)
    cell.add_argument("--clock-tolerance-seconds", type=float, default=2)
    cell.add_argument("--expected-image", required=True)
    cell.add_argument("--expected-node", default="")
    cell.add_argument("--output", required=True)

    aggregate = subparsers.add_parser("aggregate")
    aggregate.add_argument("--summary", action="append", required=True)
    aggregate.add_argument("--output", required=True)
    aggregate.add_argument("--tsv", required=True)
    aggregate.add_argument("--report", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "schedule":
        write_schedule(
            Path(args.output), generate_schedule(args.repetitions, args.seed)
        )
    elif args.command == "rbac":
        print(
            json.dumps(
                rbac_manifest(args.namespace, args.service_account),
                separators=(",", ":"),
            )
        )
    elif args.command == "workflow":
        print(json.dumps(workflow_manifest(args), separators=(",", ":")))
    elif args.command == "warmup":
        print(json.dumps(warmup_manifest(args), separators=(",", ":")))
    elif args.command == "node-headroom":
        result = node_headroom(
            load_json(Path(args.node)), load_json(Path(args.pods))
        )
        atomic_json(Path(args.output), result)
    elif args.command == "summarize-cell":
        atomic_json(Path(args.output), summarize_cell(args))
    elif args.command == "aggregate":
        result = aggregate_summaries(
            [load_json(Path(path)) for path in args.summary]
        )
        atomic_json(Path(args.output), result)
        rows = [
            {
                "block": item["block"],
                "baseline_workflow_seconds": item[
                    "baseline_workflow_seconds"
                ],
                "tuned_workflow_seconds": item["tuned_workflow_seconds"],
                "duration_reduction_seconds": item[
                    "duration_reduction_seconds"
                ],
                "duration_reduction_ratio": item["duration_reduction_ratio"],
                "baseline_critical_path_length": item[
                    "baseline_critical_path_length"
                ],
                "tuned_critical_path_length": item[
                    "tuned_critical_path_length"
                ],
                "tuned_bc_overlap_seconds": item[
                    "tuned_bc_overlap_seconds"
                ],
            }
            for item in result["comparisons"]
        ]
        fields = (
            "block",
            "baseline_workflow_seconds",
            "tuned_workflow_seconds",
            "duration_reduction_seconds",
            "duration_reduction_ratio",
            "baseline_critical_path_length",
            "tuned_critical_path_length",
            "tuned_bc_overlap_seconds",
        )
        atomic_text(Path(args.tsv), render_tsv(rows, fields))
        atomic_text(Path(args.report), report_markdown(result))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        OSError,
        ValidationError,
        ValueError,
        json.JSONDecodeError,
    ) as exc:
        print(f"e06-argo-workflow: {exc}", file=sys.stderr)
        raise SystemExit(1)
