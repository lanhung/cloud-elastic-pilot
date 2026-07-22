#!/usr/bin/env python3
"""Reset or verify the exact E01 image cache entry on selected ACK nodes.

The same executable implements both hook contracts used by
ack-four-layer-baseline.sh:

* CACHE_RESET_HOOK passes --reason.
* CACHE_VERIFY_HOOK passes --state warm|cold.

All runtime inspection happens through short-lived, explicitly privileged Pods.
The helper enters the host namespaces and uses the node's own crictl/ctr tools;
it never uploads credentials or removes an image other than the requested
immutable digest.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


IMAGE_RE = re.compile(r"^\S+@(?P<digest>sha256:[0-9a-fA-F]{64})$")
DNS_SAFE_RE = re.compile(r"[^a-z0-9-]+")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Reset or verify an immutable image on selected ACK nodes"
    )
    parser.add_argument("--image", required=True)
    parser.add_argument("--selector-key", required=True)
    parser.add_argument("--selector-value", required=True)
    parser.add_argument("--reason", default="")
    parser.add_argument("--state", choices=("warm", "cold"))
    parser.add_argument("--evidence", default="")
    parser.add_argument(
        "--helper-image", default=os.getenv("E01_HOST_HELPER_IMAGE", "")
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=int(os.getenv("E01_CACHE_HOOK_TIMEOUT_SECONDS", "120")),
    )
    parser.add_argument(
        "--gc-wait-seconds",
        type=int,
        default=int(os.getenv("E01_CACHE_GC_WAIT_SECONDS", "30")),
    )
    args = parser.parse_args()
    if bool(args.reason) == bool(args.state):
        parser.error("pass exactly one of --reason (reset) or --state (verify)")
    return args


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


def selected_nodes(selector_key: str, selector_value: str) -> list[str]:
    payload = run_json(
        kube_base()
        + [
            "get",
            "nodes",
            "-l",
            f"{selector_key}={selector_value}",
            "-o",
            "json",
        ]
    )
    nodes = sorted(
        str(item.get("metadata", {}).get("name", ""))
        for item in payload.get("items", [])
    )
    return [node for node in nodes if node]


def helper_manifest(namespace: str, node: str, pod: str, image: str) -> dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": pod,
            "namespace": namespace,
            "labels": {"hooke.io/component": "e01-cache-helper"},
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
    namespace = f"hooke-cache-{uuid.uuid4().hex[:10]}"
    run(kube_base() + ["create", "namespace", namespace])
    pods: dict[str, str] = {}
    try:
        for index, node in enumerate(nodes):
            pod = safe_name(f"cache-{index}-{node}")
            manifest = helper_manifest(namespace, node, pod, helper_image)
            run(
                kube_base() + ["apply", "-f", "-"],
                input_text=json.dumps(manifest),
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


def host_command(namespace: str, pod: str, command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(
        kube_base()
        + [
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
        ]
        + command,
        check=check,
    )


def strings(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        result: list[str] = []
        for item in value:
            result.extend(strings(item))
        return result
    if isinstance(value, dict):
        result = []
        for item in value.values():
            result.extend(strings(item))
        return result
    return []


def image_records(namespace: str, pod: str) -> list[dict[str, Any]]:
    completed = host_command(namespace, pod, ["crictl", "images", "-o", "json"])
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("crictl images returned invalid JSON") from exc
    return [item for item in payload.get("images", []) if isinstance(item, dict)]


def matching_records(records: list[dict[str, Any]], image: str, digest: str) -> list[dict[str, Any]]:
    matches: list[dict[str, Any]] = []
    for record in records:
        values = strings(record)
        if image in values or digest in values:
            matches.append(record)
    return matches


def content_digests(namespace: str, pod: str) -> set[str]:
    completed = host_command(
        namespace, pod, ["ctr", "-n", "k8s.io", "content", "ls", "-q"]
    )
    return {line.strip() for line in completed.stdout.splitlines() if line.strip()}


def running_target_containers(namespace: str, pod: str, image: str, digest: str) -> list[str]:
    completed = host_command(namespace, pod, ["crictl", "ps", "-o", "json"])
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("crictl ps returned invalid JSON") from exc
    result: list[str] = []
    for item in payload.get("containers", []):
        if not isinstance(item, dict):
            continue
        values = strings(item)
        if image in values or digest in values:
            result.append(str(item.get("id") or item.get("metadata", {}).get("name") or "unknown"))
    return result


def inspect_node(namespace: str, pod: str, image: str, digest: str) -> dict[str, Any]:
    matches = matching_records(image_records(namespace, pod), image, digest)
    contents = content_digests(namespace, pod)
    return {
        "image_present": bool(matches),
        "manifest_blob_present": digest in contents,
        "matching_image_ids": sorted(
            str(item.get("id", "")) for item in matches if item.get("id")
        ),
        "matching_repo_digests": sorted(
            {
                value
                for item in matches
                for value in item.get("repoDigests", [])
                if isinstance(value, str)
            }
        ),
    }


def reset_node(
    namespace: str,
    pod: str,
    image: str,
    digest: str,
    gc_wait_seconds: int,
) -> dict[str, Any]:
    before = inspect_node(namespace, pod, image, digest)
    running = running_target_containers(namespace, pod, image, digest)
    if running:
        raise RuntimeError(
            "refusing to remove an image used by running container(s): "
            + ",".join(running)
        )
    if before["image_present"]:
        host_command(namespace, pod, ["crictl", "rmi", image])

    deadline = time.monotonic() + gc_wait_seconds
    while True:
        after = inspect_node(namespace, pod, image, digest)
        if not after["image_present"] and not after["manifest_blob_present"]:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(
                "target image or manifest blob remained after cache reset: "
                + json.dumps(after, sort_keys=True)
            )
        time.sleep(2)
    return {"before": before, "after": after, "removed": before["image_present"]}


def write_evidence(path: str, payload: dict[str, Any]) -> None:
    serialized = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if not path:
        sys.stdout.write(serialized)
        return
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp-{os.getpid()}")
    temporary.write_text(serialized, encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, output)


def main() -> int:
    args = parse_args()
    match = IMAGE_RE.fullmatch(args.image)
    if not match:
        raise ValueError("--image must be an immutable repository@sha256 reference")
    if not args.helper_image or "@" in args.helper_image and "@sha256:" not in args.helper_image:
        raise ValueError("E01_HOST_HELPER_IMAGE (or --helper-image) is required")
    if args.timeout_seconds < 1 or args.timeout_seconds > 600:
        raise ValueError("--timeout-seconds must be between 1 and 600")
    if args.gc_wait_seconds < 0 or args.gc_wait_seconds > 300:
        raise ValueError("--gc-wait-seconds must be between 0 and 300")

    nodes = selected_nodes(args.selector_key, args.selector_value)
    if not nodes:
        raise RuntimeError(
            f"no nodes match {args.selector_key}={args.selector_value}"
        )

    digest = match.group("digest").lower()
    namespace = ""
    pods: dict[str, str] = {}
    results: dict[str, Any] = {}
    try:
        namespace, pods = create_helpers(nodes, args.helper_image, args.timeout_seconds)
        for node in nodes:
            if args.reason:
                results[node] = reset_node(
                    namespace,
                    pods[node],
                    args.image,
                    digest,
                    args.gc_wait_seconds,
                )
            else:
                observed = inspect_node(namespace, pods[node], args.image, digest)
                expected_present = args.state == "warm"
                valid = (
                    observed["image_present"] == expected_present
                    and observed["manifest_blob_present"] == expected_present
                )
                results[node] = {"observed": observed, "valid": valid}
                if not valid:
                    raise RuntimeError(
                        f"node {node} is not {args.state}: "
                        + json.dumps(observed, sort_keys=True)
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

    payload = {
        "action": "reset" if args.reason else "verify",
        "expected_state": "cold" if args.reason else args.state,
        "image": args.image,
        "manifest_digest": digest,
        "selector": f"{args.selector_key}={args.selector_value}",
        "reason": args.reason or None,
        "observed_at": datetime.now(timezone.utc).isoformat(),
        "nodes": results,
    }
    write_evidence(args.evidence, payload)
    print(
        f"E01 cache {'reset' if args.reason else args.state} verified on "
        f"{len(nodes)} node(s)",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"e01-cache-hook: {exc}", file=sys.stderr)
        raise SystemExit(1)
