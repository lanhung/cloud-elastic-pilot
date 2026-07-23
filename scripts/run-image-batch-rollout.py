#!/usr/bin/env python3
"""Trigger one replica across multiple owned Deployments as a measured batch."""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


class RolloutError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Scale an E03 Deployment batch")
    parser.add_argument("--kubeconfig", required=True)
    parser.add_argument("--context", default="")
    parser.add_argument("--cluster-id", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--namespace-uid", required=True)
    parser.add_argument("--path", choices=("fixed", "node-scale"), required=True)
    parser.add_argument("--workloads-json", required=True)
    parser.add_argument("--timeout", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def parse_workloads(value: str) -> list[str]:
    try:
        workloads = json.loads(value)
    except json.JSONDecodeError as exc:
        raise RolloutError("--workloads-json is invalid") from exc
    if not isinstance(workloads, list) or not workloads:
        raise RolloutError("--workloads-json must be a non-empty array")
    if not all(isinstance(item, str) and item for item in workloads):
        raise RolloutError("workload names must be non-empty strings")
    if len(workloads) != len(set(workloads)):
        raise RolloutError("workload names must be unique")
    return workloads


def kube_base(args: argparse.Namespace) -> list[str]:
    command = ["kubectl", "--kubeconfig", args.kubeconfig]
    if args.context:
        command.extend(("--context", args.context))
    return command


def run(
    base: list[str],
    command: list[str],
    *,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        base + command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RolloutError(f"kubectl failed ({completed.returncode}): {detail}")
    return completed


def get_json(base: list[str], command: list[str]) -> dict[str, Any]:
    completed = run(base, command + ["-o", "json"])
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RolloutError("kubectl returned invalid JSON") from exc
    if not isinstance(value, dict):
        raise RolloutError("kubectl JSON is not an object")
    return value


def deployment_evidence(
    base: list[str], namespace: str, run_id: str, workload: str
) -> dict[str, Any]:
    deployment = get_json(
        base, ["-n", namespace, "get", "deployment", workload]
    )
    metadata = deployment.get("metadata") or {}
    uid = str(metadata.get("uid") or "")
    annotations = metadata.get("annotations") or {}
    if not uid or annotations.get("hooke.io/run-id") != run_id:
        raise RolloutError(
            f"deployment/{workload} is not owned by run {run_id}"
        )
    if int((deployment.get("spec") or {}).get("replicas") or 0) != 0:
        raise RolloutError(f"deployment/{workload} does not start at replicas=0")
    return {
        "workload": workload,
        "deployment_uid": uid,
        "generation_before": int(metadata.get("generation") or 0),
    }


def scale_patch(uid: str, run_id: str) -> str:
    return json.dumps(
        [
            {"op": "test", "path": "/metadata/uid", "value": uid},
            {
                "op": "test",
                "path": "/metadata/annotations/hooke.io~1run-id",
                "value": run_id,
            },
            {"op": "replace", "path": "/spec/replicas", "value": 1},
        ],
        separators=(",", ":"),
    )


def start_process(command: list[str]) -> tuple[subprocess.Popen[str], int]:
    started = time.monotonic_ns()
    process = subprocess.Popen(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return process, started


def collect_process(
    process: subprocess.Popen[str], started_ns: int
) -> dict[str, Any]:
    output, _ = process.communicate()
    return {
        "started_monotonic_ns": started_ns,
        "ended_monotonic_ns": time.monotonic_ns(),
        "returncode": process.returncode,
        "output": output,
    }


def ready_pod_evidence(
    base: list[str],
    namespace: str,
    run_id: str,
    deployment_uid: str,
    workload: str,
) -> dict[str, str]:
    deployment = get_json(
        base, ["-n", namespace, "get", "deployment", workload]
    )
    metadata = deployment.get("metadata") or {}
    if (
        metadata.get("uid") != deployment_uid
        or (metadata.get("annotations") or {}).get("hooke.io/run-id") != run_id
    ):
        raise RolloutError(f"deployment/{workload} identity changed")
    generation = int(metadata.get("generation") or 0)
    observed = int((deployment.get("status") or {}).get("observedGeneration") or 0)
    if observed < generation:
        raise RolloutError(f"deployment/{workload} generation was not observed")

    pods = get_json(
        base,
        ["-n", namespace, "get", "pods", "-l", f"app={workload}"],
    )
    ready: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for pod in pods.get("items") or []:
        pod_metadata = pod.get("metadata") or {}
        if (
            (pod_metadata.get("annotations") or {}).get("hooke.io/run-id")
            != run_id
            or pod_metadata.get("deletionTimestamp")
        ):
            continue
        owners = [
            item
            for item in pod_metadata.get("ownerReferences") or []
            if item.get("kind") == "ReplicaSet"
            and item.get("controller") is True
            and item.get("uid")
            and item.get("name")
        ]
        conditions = (pod.get("status") or {}).get("conditions") or []
        is_ready = any(
            item.get("type") == "Ready" and item.get("status") == "True"
            for item in conditions
        )
        if len(owners) != 1 or not is_ready:
            continue
        owner = owners[0]
        replica_set = get_json(
            base,
            [
                "-n",
                namespace,
                "get",
                "replicaset",
                str(owner["name"]),
            ],
        )
        rs_metadata = replica_set.get("metadata") or {}
        parents = rs_metadata.get("ownerReferences") or []
        if (
            rs_metadata.get("uid") == owner["uid"]
            and any(
                item.get("kind") == "Deployment"
                and item.get("controller") is True
                and item.get("uid") == deployment_uid
                for item in parents
            )
        ):
            ready.append((pod_metadata, rs_metadata))
    if len(ready) != 1:
        raise RolloutError(
            f"deployment/{workload} has {len(ready)} Ready owned Pods; expected 1"
        )
    pod_metadata, rs_metadata = ready[0]
    return {
        "deployment_generation_after": str(generation),
        "observed_generation": str(observed),
        "replica_set_uid": str(rs_metadata.get("uid") or ""),
        "replica_set_name": str(rs_metadata.get("name") or ""),
        "pod_uid": str(pod_metadata.get("uid") or ""),
        "pod_name": str(pod_metadata.get("name") or ""),
    }


def atomic_write(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.chmod(0o600)
    temporary.replace(path)


def execute(args: argparse.Namespace) -> dict[str, Any]:
    workloads = parse_workloads(args.workloads_json)
    base = kube_base(args)
    namespace = get_json(base, ["get", "namespace", args.namespace])
    metadata = namespace.get("metadata") or {}
    if (
        metadata.get("uid") != args.namespace_uid
        or (metadata.get("annotations") or {}).get("hooke.io/run-id")
        != args.run_id
    ):
        raise RolloutError("experiment namespace ownership changed")

    deployments = [
        deployment_evidence(base, args.namespace, args.run_id, workload)
        for workload in workloads
    ]
    batch_start = time.monotonic_ns()
    patch_processes: list[tuple[dict[str, Any], subprocess.Popen[str], int]] = []
    for item in deployments:
        process, started = start_process(
            base
            + [
                "-n",
                args.namespace,
                "patch",
                "deployment",
                item["workload"],
                "--type=json",
                "-p",
                scale_patch(item["deployment_uid"], args.run_id),
            ]
        )
        patch_processes.append((item, process, started))
    for item, process, started in patch_processes:
        item["scale"] = collect_process(process, started)
    failed_scales = [
        item["workload"]
        for item in deployments
        if item["scale"]["returncode"] != 0
    ]
    if failed_scales:
        raise RolloutError(
            "batch scale failed for: " + ",".join(failed_scales)
        )

    rollout_processes: list[
        tuple[dict[str, Any], subprocess.Popen[str], int]
    ] = []
    for item in deployments:
        process, started = start_process(
            base
            + [
                "-n",
                args.namespace,
                "rollout",
                "status",
                f"deployment/{item['workload']}",
                f"--timeout={args.timeout}",
            ]
        )
        rollout_processes.append((item, process, started))
    for item, process, started in rollout_processes:
        item["rollout"] = collect_process(process, started)
    failed_rollouts = [
        item["workload"]
        for item in deployments
        if item["rollout"]["returncode"] != 0
    ]
    if failed_rollouts:
        raise RolloutError(
            "batch rollout failed for: " + ",".join(failed_rollouts)
        )

    for item in deployments:
        item.update(
            ready_pod_evidence(
                base,
                args.namespace,
                args.run_id,
                item["deployment_uid"],
                item["workload"],
            )
        )
    batch_end = time.monotonic_ns()
    patch_starts = [
        int(item["scale"]["started_monotonic_ns"]) for item in deployments
    ]
    try:
        boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(
            encoding="utf-8"
        ).strip()
    except OSError:
        boot_id = ""
    return {
        "cluster_id": args.cluster_id,
        "run_id": args.run_id,
        "namespace": args.namespace,
        "namespace_uid": args.namespace_uid,
        "path": args.path,
        "requested_concurrency": len(workloads),
        "clock_type": "CLOCK_MONOTONIC",
        "clock_source": "python-time.monotonic_ns",
        "source_host": socket.gethostname(),
        "boot_id": boot_id,
        "batch_start_monotonic_ns": batch_start,
        "batch_end_monotonic_ns": batch_end,
        "trigger_spread_ns": max(patch_starts) - min(patch_starts),
        "deployments": deployments,
    }


def main() -> int:
    args = parse_args()
    result = execute(args)
    atomic_write(args.output, result)
    print(
        f"scaled {result['requested_concurrency']} E03 workload(s); "
        f"trigger spread {result['trigger_spread_ns'] / 1_000_000:.3f} ms",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RolloutError, ValueError, TypeError) as exc:
        print(f"run-image-batch-rollout: {exc}", file=sys.stderr)
        raise SystemExit(1)
