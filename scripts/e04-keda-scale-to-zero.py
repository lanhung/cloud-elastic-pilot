#!/usr/bin/env python3
"""Schedule, sample, validate, and summarize the E04 KEDA pilot."""

from __future__ import annotations

import argparse
import calendar
import csv
import json
import math
import os
import random
import re
import statistics
import subprocess
import sys
import time
import urllib.parse
import uuid
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable


CROCKFORD_BASE32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
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


class ValidationError(ValueError):
    pass


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(path)


def write_json(path: Path, payload: Any) -> None:
    atomic_write(path, json.dumps(payload, indent=2, sort_keys=True) + "\n")


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def read_ndjson(path: Path) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValidationError(
                f"invalid NDJSON in {path}:{line_number}"
            ) from exc
        if not isinstance(item, dict):
            raise ValidationError(f"{path}:{line_number} is not a JSON object")
        output.append(item)
    return output


def format_tsv(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return f"{value:.9f}".rstrip("0").rstrip(".")
    return str(value)


def write_tsv(path: Path, fields: list[str], rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(
            stream, fieldnames=fields, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        for row in rows:
            writer.writerow({field: format_tsv(row.get(field)) for field in fields})
    temporary.replace(path)


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def generate_schedule(
    repetitions: int, seed: int, cooldowns: tuple[int, ...] = (60, 300)
) -> list[dict[str, Any]]:
    if repetitions <= 0:
        raise ValidationError("repetitions must be positive")
    if len(cooldowns) < 2 or len(set(cooldowns)) != len(cooldowns):
        raise ValidationError("at least two distinct cooldown levels are required")
    if any(value <= 0 for value in cooldowns):
        raise ValidationError("cooldown levels must be positive")
    rng = random.Random(seed)
    rows: list[dict[str, Any]] = []
    sequence = 0
    for block in range(1, repetitions + 1):
        levels = list(cooldowns)
        rng.shuffle(levels)
        for cooldown in levels:
            sequence += 1
            rows.append(
                {
                    "sequence": sequence,
                    "block": block,
                    "cell_id": f"cooldown-{cooldown}s",
                    "cooldown_seconds": cooldown,
                }
            )
    return rows


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


def parse_quantity(value: str) -> float:
    match = QUANTITY_RE.fullmatch(value.strip())
    if not match:
        raise ValidationError(f"unsupported Kubernetes quantity: {value!r}")
    try:
        number = Decimal(match.group("number"))
    except InvalidOperation as exc:
        raise ValidationError(f"invalid Kubernetes quantity: {value!r}") from exc
    return float(number * DECIMAL_MULTIPLIERS[match.group("suffix") or ""])


def kube_command(kubeconfig: str, context: str, args: list[str]) -> list[str]:
    command = ["kubectl"]
    if kubeconfig:
        command.extend(("--kubeconfig", kubeconfig))
    if context:
        command.extend(("--context", context))
    return command + args


def run_kubectl_json(
    kubeconfig: str, context: str, args: list[str], timeout_seconds: float
) -> dict[str, Any]:
    result = subprocess.run(
        kube_command(kubeconfig, context, args),
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"kubectl {' '.join(args)} failed: {message}")
    payload = json.loads(result.stdout)
    if not isinstance(payload, dict):
        raise RuntimeError("kubectl response is not a JSON object")
    return payload


def append_capture(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(payload, separators=(",", ":"), sort_keys=True))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    path.chmod(0o600)


def external_metric_names(
    kubeconfig: str,
    context: str,
    namespace: str,
    scaled_object: str,
    timeout_seconds: float,
) -> list[str]:
    payload = run_kubectl_json(
        kubeconfig,
        context,
        [
            "-n",
            namespace,
            "get",
            "scaledobject.keda.sh",
            scaled_object,
            "-o",
            "json",
        ],
        timeout_seconds,
    )
    names = payload.get("status", {}).get("externalMetricNames", [])
    if not isinstance(names, list):
        return []
    return sorted({str(value) for value in names if str(value)})


def capture_external_metrics(args: argparse.Namespace) -> int:
    output = Path(args.output)
    stop_file = Path(args.stop_file)
    consecutive_errors = 0
    captured = 0
    while True:
        observed_ns = time.time_ns()
        try:
            names = external_metric_names(
                args.kubeconfig,
                args.context,
                args.namespace,
                args.scaled_object,
                args.request_timeout_seconds,
            )
            if not names:
                raise RuntimeError("ScaledObject has no status.externalMetricNames")
            selector = urllib.parse.quote(
                f"scaledobject.keda.sh/name={args.scaled_object}", safe=""
            )
            namespace = urllib.parse.quote(args.namespace, safe="")
            for name in names:
                metric = urllib.parse.quote(name, safe="")
                raw_path = (
                    "/apis/external.metrics.k8s.io/v1beta1/namespaces/"
                    f"{namespace}/{metric}?labelSelector={selector}"
                )
                payload = run_kubectl_json(
                    args.kubeconfig,
                    args.context,
                    ["get", "--raw", raw_path],
                    args.request_timeout_seconds,
                )
                append_capture(
                    output,
                    {
                        "observed_time_ns": observed_ns,
                        "namespace": args.namespace,
                        "scaled_object": args.scaled_object,
                        "metric_name": name,
                        "payload": payload,
                    },
                )
                captured += 1
            consecutive_errors = 0
        except (
            OSError,
            RuntimeError,
            ValueError,
            json.JSONDecodeError,
            subprocess.TimeoutExpired,
        ) as exc:
            consecutive_errors += 1
            append_capture(
                output,
                {
                    "observed_time_ns": observed_ns,
                    "namespace": args.namespace,
                    "scaled_object": args.scaled_object,
                    "error": str(exc),
                    "consecutive_errors": consecutive_errors,
                },
            )
            if consecutive_errors >= args.max_consecutive_errors:
                raise RuntimeError(
                    f"KEDA metric sampling failed {consecutive_errors} times in a row"
                ) from exc
        if stop_file.exists():
            break
        deadline = time.monotonic() + args.interval_seconds
        while time.monotonic() < deadline and not stop_file.exists():
            time.sleep(min(0.2, max(0.01, deadline - time.monotonic())))
    if captured == 0:
        raise RuntimeError("KEDA metric sampler captured no successful response")
    return 0


def deterministic_event_id(canonical: str) -> str:
    value = uuid.uuid5(uuid.NAMESPACE_URL, canonical).int
    encoded = ["0"] * 26
    for index in range(25, -1, -1):
        encoded[index] = CROCKFORD_BASE32[value & 31]
        value >>= 5
    return "".join(encoded)


def normalize_metric_samples(
    captures: list[dict[str, Any]],
    cluster_id: str,
    run_id: str,
    start_ns: int,
    end_ns: int,
) -> list[dict[str, Any]]:
    if start_ns <= 0 or end_ns <= start_ns:
        raise ValidationError("metric sample window is invalid")
    errors = [item for item in captures if item.get("error")]
    if errors:
        raise ValidationError(
            f"KEDA metric capture contains {len(errors)} failed request(s): "
            f"{errors[0].get('error')}"
        )
    output: list[dict[str, Any]] = []
    for capture_index, capture in enumerate(captures, 1):
        observed_ns = capture.get("observed_time_ns")
        if not isinstance(observed_ns, int) or not start_ns <= observed_ns <= end_ns:
            raise ValidationError(
                f"KEDA capture {capture_index} has an invalid observation time"
            )
        namespace = str(capture.get("namespace") or "")
        scaled_object = str(capture.get("scaled_object") or "")
        expected_metric = str(capture.get("metric_name") or "")
        payload = capture.get("payload") or {}
        items = payload.get("items", [])
        if not namespace or not scaled_object or not isinstance(items, list):
            raise ValidationError(f"KEDA capture {capture_index} is malformed")
        if len(items) != 1:
            raise ValidationError(
                f"KEDA capture {capture_index} returned {len(items)} metric items"
            )
        item = items[0]
        if not isinstance(item, dict):
            raise ValidationError(f"KEDA capture {capture_index} item is malformed")
        metric_name = str(item.get("metricName") or "")
        timestamp = str(item.get("timestamp") or "")
        value = str(item.get("value") or "")
        if metric_name != expected_metric:
            raise ValidationError(
                f"KEDA capture metric {metric_name!r} does not match {expected_metric!r}"
            )
        source_ns = timestamp_ns(timestamp)
        numeric_value = parse_quantity(value)
        attributes = {
            "scaled_object": scaled_object,
            "metric_name": metric_name,
            "metric_value": value,
            "metric_value_float": numeric_value,
            "metric_labels": item.get("metricLabels"),
            "api_version": payload.get("apiVersion"),
            "sample_index": capture_index,
            "precision": "keda-external-metrics-api-observation",
        }
        event: dict[str, Any] = {
            "cluster_id": cluster_id,
            "run_id": run_id,
            "event_type": "KEDA_SCALER_SAMPLE",
            "source_time_ns": source_ns,
            "event_time_ns": source_ns,
            "observed_time_ns": observed_ns,
            "clock_type": "source",
            "source_component": "keda-external-metrics-api",
            "namespace": namespace,
            "workload_kind": "ScaledObject",
            "workload_name": scaled_object,
            "approximate": True,
            "attributes": attributes,
        }
        canonical = json.dumps(event, separators=(",", ":"), sort_keys=True)
        event["event_id"] = deterministic_event_id(canonical)
        output.append(event)
    if not output:
        raise ValidationError("no KEDA metric samples were normalized")
    return output


def write_ndjson(path: Path, records: Iterable[dict[str, Any]]) -> None:
    content = "".join(
        json.dumps(item, separators=(",", ":"), sort_keys=True) + "\n"
        for item in records
    )
    atomic_write(path, content)


def required_int(payload: dict[str, Any], key: str, minimum: int = 0) -> int:
    value = payload.get(key)
    if isinstance(value, bool):
        raise ValidationError(f"{key} must be an integer")
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"{key} must be an integer") from exc
    if parsed < minimum:
        raise ValidationError(f"{key} must be at least {minimum}")
    return parsed


def required_float(
    payload: dict[str, Any], key: str, minimum: float = 0, strict: bool = False
) -> float:
    try:
        value = float(payload.get(key))
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"{key} must be numeric") from exc
    if (strict and value <= minimum) or (not strict and value < minimum):
        comparator = "greater than" if strict else "at least"
        raise ValidationError(f"{key} must be {comparator} {minimum}")
    if not math.isfinite(value):
        raise ValidationError(f"{key} must be finite")
    return value


def event_time(item: dict[str, Any]) -> int:
    value = item.get("event_time_ns")
    if not isinstance(value, int) or value <= 0:
        raise ValidationError("event has no positive integer event_time_ns")
    return value


def observed_time(item: dict[str, Any]) -> int:
    value = item.get("observed_time_ns")
    if isinstance(value, int) and value > 0:
        return value
    return event_time(item)


def attributes(item: dict[str, Any]) -> dict[str, Any]:
    value = item.get("attributes")
    return value if isinstance(value, dict) else {}


def events_of(
    events: list[dict[str, Any]], event_type: str
) -> list[dict[str, Any]]:
    return sorted(
        [item for item in events if item.get("event_type") == event_type],
        key=event_time,
    )


def exact_application_events(
    events: list[dict[str, Any]], event_type: str
) -> list[dict[str, Any]]:
    result = [
        item
        for item in events_of(events, event_type)
        if item.get("source_component") == "application-event-log"
    ]
    for item in result:
        if item.get("approximate") is True:
            raise ValidationError(f"{event_type} application evidence is approximate")
        if attributes(item).get("persistence") != "container-stdout":
            raise ValidationError(f"{event_type} lacks frozen stdout persistence")
    return result


def one_event(items: list[dict[str, Any]], name: str) -> dict[str, Any]:
    if len(items) != 1:
        raise ValidationError(f"{name} count is {len(items)}, expected exactly 1")
    return items[0]


def message_map(
    items: list[dict[str, Any]], event_type: str, expected_count: int
) -> dict[str, dict[str, Any]]:
    if len(items) != expected_count:
        raise ValidationError(
            f"{event_type} count is {len(items)}, expected {expected_count}"
        )
    output: dict[str, dict[str, Any]] = {}
    for item in items:
        message_id = str(attributes(item).get("message_id") or "")
        if not message_id or message_id in output:
            raise ValidationError(f"{event_type} has missing or duplicate message_id")
        output[message_id] = item
    return output


def condition_status(
    scaled_object: dict[str, Any], condition_type: str
) -> str:
    for condition in scaled_object.get("status", {}).get("conditions", []):
        if (
            isinstance(condition, dict)
            and condition.get("type") == condition_type
        ):
            return str(condition.get("status") or "")
    return ""


def validate_frozen_objects(
    initial: dict[str, Any],
    scaled_object: dict[str, Any],
    config: dict[str, Any],
) -> None:
    deployment = initial.get("deployment")
    initial_scaled_object = initial.get("scaled_object")
    if not isinstance(deployment, dict) or not isinstance(initial_scaled_object, dict):
        raise ValidationError(
            "initial-state.json must contain deployment and scaled_object snapshots"
        )
    spec_replicas = deployment.get("spec", {}).get("replicas")
    status = deployment.get("status", {})
    if spec_replicas != 0:
        raise ValidationError("worker Deployment did not start with spec.replicas=0")
    for field_name in ("replicas", "readyReplicas", "availableReplicas"):
        if int(status.get(field_name) or 0) != 0:
            raise ValidationError(
                f"worker Deployment initial status.{field_name} is not zero"
            )
    active = condition_status(initial_scaled_object, "Active")
    if active not in {"", "False"}:
        raise ValidationError("ScaledObject was active before the producer started")

    spec = scaled_object.get("spec", {})
    expected = {
        "pollingInterval": required_int(config, "polling_interval_seconds", 1),
        "cooldownPeriod": required_int(config, "cooldown_seconds", 1),
        "minReplicaCount": required_int(config, "min_replicas", 0),
        "maxReplicaCount": required_int(config, "max_replicas", 1),
    }
    for key, value in expected.items():
        if spec.get(key) != value:
            raise ValidationError(
                f"ScaledObject spec.{key}={spec.get(key)!r}, expected {value!r}"
            )
    worker_name = str(config.get("worker_name") or "")
    scaled_object_name = str(config.get("scaled_object_name") or "")
    if scaled_object.get("metadata", {}).get("name") != scaled_object_name:
        raise ValidationError("ScaledObject snapshot name does not match run config")
    if spec.get("scaleTargetRef", {}).get("name") != worker_name:
        raise ValidationError("ScaledObject scaleTargetRef does not match worker")
    triggers = spec.get("triggers", [])
    redis_triggers = [
        trigger
        for trigger in triggers
        if isinstance(trigger, dict) and trigger.get("type") == "redis"
    ]
    if len(redis_triggers) != 1:
        raise ValidationError("ScaledObject must contain exactly one Redis trigger")
    metadata = redis_triggers[0].get("metadata", {})
    if metadata.get("listName") != config.get("queue_key"):
        raise ValidationError("Redis trigger listName does not match the frozen queue")
    if str(metadata.get("listLength")) != str(config.get("list_length")):
        raise ValidationError("Redis trigger listLength drifted")
    if str(metadata.get("activationListLength")) != str(
        config.get("activation_list_length")
    ):
        raise ValidationError("Redis trigger activationListLength drifted")
    expected_trigger_metadata = {
        "addressFromEnv": "E04_REDIS_ADDRESS",
        "passwordFromEnv": "E04_REDIS_PASSWORD",
        "databaseIndex": "0",
        "enableTLS": "false",
    }
    for key, value in expected_trigger_metadata.items():
        if str(metadata.get(key)) != value:
            raise ValidationError(f"Redis trigger {key} drifted")


def render_manifests(
    config: dict[str, Any],
    namespace: str,
    run_id: str,
    redis_secret: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if not namespace or not run_id or not redis_secret:
        raise ValidationError("namespace, run ID, and Redis Secret are required")
    redis_name = str(config.get("redis_name") or "redis")
    worker_name = str(config.get("worker_name") or "worker")
    producer_name = str(config.get("producer_name") or "producer")
    scaled_object_name = str(config.get("scaled_object_name") or "")
    app_image = str(config.get("app_image") or "")
    redis_image = str(config.get("redis_image") or "")
    queue_key = str(config.get("queue_key") or "")
    completion_key = str(config.get("completion_key") or "")
    if not all(
        (
            redis_name,
            worker_name,
            producer_name,
            scaled_object_name,
            app_image,
            redis_image,
            queue_key,
            completion_key,
        )
    ):
        raise ValidationError("run config is missing manifest identity fields")

    annotations = {"hooke.io/run-id": run_id}
    node_selector = {
        str(config.get("node_selector_key") or ""): str(
            config.get("node_selector_value") or ""
        )
    }
    if "" in node_selector or not next(iter(node_selector.values())):
        raise ValidationError("E04 fixed node selector is incomplete")
    tolerations: list[dict[str, Any]] = []
    taint_key = str(config.get("taint_key") or "")
    taint_value = str(config.get("taint_value") or "")
    if taint_key or taint_value:
        if not taint_key or not taint_value:
            raise ValidationError("E04 taint key and value must be set together")
        tolerations.append(
            {
                "key": taint_key,
                "operator": "Equal",
                "value": taint_value,
                "effect": str(config.get("taint_effect") or "NoSchedule"),
            }
        )

    def pod_metadata(role: str) -> dict[str, Any]:
        return {
            "labels": {
                "hooke.io/experiment": "E04",
                "hooke.io/e04-role": role,
            },
            "annotations": dict(annotations),
        }

    def scheduling() -> dict[str, Any]:
        result: dict[str, Any] = {"nodeSelector": dict(node_selector)}
        if tolerations:
            result["tolerations"] = copy_json(tolerations)
        return result

    def secret_password_env() -> dict[str, Any]:
        return {
            "name": "E04_REDIS_PASSWORD",
            "valueFrom": {
                "secretKeyRef": {"name": redis_secret, "key": "password"}
            },
        }

    def field_env(name: str, field_path: str) -> dict[str, Any]:
        return {
            "name": name,
            "valueFrom": {"fieldRef": {"fieldPath": field_path}},
        }

    def application_env(mode: str, workload_kind: str, workload_name: str) -> list[dict[str, Any]]:
        values = {
            "E04_MODE": mode,
            "E04_REDIS_ADDRESS": (
                f"{redis_name}.{namespace}.svc.cluster.local:6379"
            ),
            "E04_QUEUE_KEY": queue_key,
            "E04_COMPLETION_KEY": completion_key,
            "E04_PROCESSING_DURATION": str(config.get("processing_duration")),
            "E04_QUEUE_SAMPLE_INTERVAL": str(
                config.get("queue_sample_interval")
            ),
            "E04_BLPOP_TIMEOUT": "1s",
            "HOOKE_SDK_DISABLED": "true",
            "HOOKE_CLUSTER_ID": str(config.get("cluster_id") or ""),
            "HOOKE_RUN_ID": run_id,
            "HOOKE_WORKLOAD_KIND": workload_kind,
            "HOOKE_WORKLOAD_NAME": workload_name,
            "HOOKE_CONTAINER_NAME": mode,
        }
        env = [{"name": key, "value": value} for key, value in values.items()]
        env.append(secret_password_env())
        env.extend(
            [
                field_env("POD_NAMESPACE", "metadata.namespace"),
                field_env("POD_NAME", "metadata.name"),
                field_env("POD_UID", "metadata.uid"),
                field_env("NODE_NAME", "spec.nodeName"),
            ]
        )
        return env

    def resources(prefix: str) -> dict[str, Any]:
        result = {
            "requests": {
                "cpu": str(config.get(f"{prefix}_cpu_request") or ""),
                "memory": str(config.get(f"{prefix}_memory_request") or ""),
            },
            "limits": {
                "cpu": str(config.get(f"{prefix}_cpu_limit") or ""),
                "memory": str(config.get(f"{prefix}_memory_limit") or ""),
            },
        }
        parsed: dict[tuple[str, str], float] = {}
        for bound, values in result.items():
            for resource_name, value in values.items():
                try:
                    quantity = parse_quantity(value)
                except ValidationError as exc:
                    raise ValidationError(
                        f"{prefix} {bound}.{resource_name} is invalid"
                    ) from exc
                if quantity <= 0:
                    raise ValidationError(
                        f"{prefix} {bound}.{resource_name} must be positive"
                    )
                parsed[(bound, resource_name)] = quantity
        for resource_name in ("cpu", "memory"):
            if parsed[("requests", resource_name)] > parsed[("limits", resource_name)]:
                raise ValidationError(
                    f"{prefix} requests.{resource_name} exceeds its limit"
                )
        return result

    application_security = {
        "allowPrivilegeEscalation": False,
        "readOnlyRootFilesystem": True,
        "runAsNonRoot": True,
        "capabilities": {"drop": ["ALL"]},
    }
    redis_labels = {
        "hooke.io/experiment": "E04",
        "hooke.io/e04-role": "redis",
    }
    worker_labels = {
        "hooke.io/experiment": "E04",
        "hooke.io/e04-role": "worker",
    }

    redis_pod_spec: dict[str, Any] = {
        "automountServiceAccountToken": False,
        "terminationGracePeriodSeconds": 10,
        "securityContext": {
            "runAsNonRoot": True,
            "runAsUser": 999,
            "runAsGroup": 999,
            "fsGroup": 999,
        },
        "containers": [
            {
                "name": "redis",
                "image": redis_image,
                "imagePullPolicy": "IfNotPresent",
                "command": [
                    "sh",
                    "-c",
                    'exec redis-server --appendonly no --save "" '
                    '--requirepass "$E04_REDIS_PASSWORD"',
                ],
                "env": [secret_password_env()],
                "ports": [{"name": "redis", "containerPort": 6379}],
                "readinessProbe": {
                    "exec": {
                        "command": [
                            "sh",
                            "-c",
                            'test "$(REDISCLI_AUTH="$E04_REDIS_PASSWORD" '
                            'redis-cli -h 127.0.0.1 ping)" = PONG',
                        ]
                    },
                    "periodSeconds": 1,
                    "timeoutSeconds": 1,
                    "failureThreshold": 60,
                },
                "resources": resources("redis"),
                "securityContext": {
                    "allowPrivilegeEscalation": False,
                    "runAsNonRoot": True,
                    "runAsUser": 999,
                    "runAsGroup": 999,
                    "capabilities": {"drop": ["ALL"]},
                },
                "volumeMounts": [{"name": "data", "mountPath": "/data"}],
            }
        ],
        "volumes": [{"name": "data", "emptyDir": {}}],
    }
    redis_pod_spec.update(scheduling())

    worker_pod_spec: dict[str, Any] = {
        "automountServiceAccountToken": False,
        "terminationGracePeriodSeconds": 5,
        "securityContext": {
            "runAsNonRoot": True,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "containers": [
            {
                "name": "worker",
                "image": app_image,
                "imagePullPolicy": "IfNotPresent",
                "env": application_env("worker", "Deployment", worker_name),
                "ports": [{"name": "http", "containerPort": 8080}],
                "readinessProbe": {
                    "httpGet": {"path": "/readyz", "port": "http"},
                    "periodSeconds": 1,
                    "timeoutSeconds": 1,
                    "failureThreshold": 60,
                },
                "resources": resources("worker"),
                "securityContext": application_security,
            }
        ],
    }
    worker_pod_spec.update(scheduling())

    base = {
        "apiVersion": "v1",
        "kind": "List",
        "items": [
            {
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {
                    "name": redis_name,
                    "namespace": namespace,
                    "labels": redis_labels,
                    "annotations": dict(annotations),
                },
                "spec": {
                    "replicas": 1,
                    "selector": {"matchLabels": redis_labels},
                    "template": {
                        "metadata": pod_metadata("redis"),
                        "spec": redis_pod_spec,
                    },
                },
            },
            {
                "apiVersion": "v1",
                "kind": "Service",
                "metadata": {
                    "name": redis_name,
                    "namespace": namespace,
                    "labels": redis_labels,
                    "annotations": dict(annotations),
                },
                "spec": {
                    "selector": redis_labels,
                    "ports": [
                        {"name": "redis", "port": 6379, "targetPort": "redis"}
                    ],
                },
            },
            {
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {
                    "name": worker_name,
                    "namespace": namespace,
                    "labels": worker_labels,
                    "annotations": {
                        **annotations,
                        "hooke.io/keda-scaled-object": scaled_object_name,
                    },
                },
                "spec": {
                    "replicas": 0,
                    "selector": {"matchLabels": worker_labels},
                    "template": {
                        "metadata": pod_metadata("worker"),
                        "spec": worker_pod_spec,
                    },
                },
            },
            {
                "apiVersion": "keda.sh/v1alpha1",
                "kind": "ScaledObject",
                "metadata": {
                    "name": scaled_object_name,
                    "namespace": namespace,
                    "labels": {
                        "hooke.io/experiment": "E04",
                        "hooke.io/e04-role": "scaler",
                    },
                    "annotations": dict(annotations),
                },
                "spec": {
                    "scaleTargetRef": {"name": worker_name},
                    "pollingInterval": required_int(
                        config, "polling_interval_seconds", 1
                    ),
                    "cooldownPeriod": required_int(
                        config, "cooldown_seconds", 1
                    ),
                    "initialCooldownPeriod": 0,
                    "minReplicaCount": required_int(config, "min_replicas", 0),
                    "maxReplicaCount": required_int(config, "max_replicas", 1),
                    "triggers": [
                        {
                            "type": "redis",
                            "metadata": {
                                "addressFromEnv": "E04_REDIS_ADDRESS",
                                "passwordFromEnv": "E04_REDIS_PASSWORD",
                                "listName": queue_key,
                                "listLength": str(config.get("list_length")),
                                "activationListLength": str(
                                    config.get("activation_list_length")
                                ),
                                "databaseIndex": "0",
                                "enableTLS": "false",
                            },
                        }
                    ],
                },
            },
        ],
    }

    producer_pod_spec: dict[str, Any] = {
        "automountServiceAccountToken": False,
        "restartPolicy": "Never",
        "terminationGracePeriodSeconds": 5,
        "securityContext": {
            "runAsNonRoot": True,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "containers": [
            {
                "name": "producer",
                "image": app_image,
                "imagePullPolicy": "IfNotPresent",
                "env": application_env("producer", "Job", producer_name)
                + [
                    {
                        "name": "E04_MESSAGE_COUNT",
                        "value": str(required_int(config, "message_count", 1)),
                    },
                    {
                        "name": "E04_ARRIVAL_RATE",
                        "value": str(
                            required_float(
                                config, "lambda_per_second", 0, strict=True
                            )
                        ),
                    },
                    {
                        "name": "E04_COMPLETION_TIMEOUT",
                        "value": f"{required_int(config, 'producer_timeout_seconds', 1)}s",
                    },
                ],
                "resources": resources("producer"),
                "securityContext": application_security,
            }
        ],
    }
    producer_pod_spec.update(scheduling())
    producer = {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": producer_name,
            "namespace": namespace,
            "labels": {
                "hooke.io/experiment": "E04",
                "hooke.io/e04-role": "producer",
            },
            "annotations": dict(annotations),
        },
        "spec": {
            "backoffLimit": 0,
            "activeDeadlineSeconds": required_int(
                config, "producer_timeout_seconds", 1
            ),
            "template": {
                "metadata": pod_metadata("producer"),
                "spec": producer_pod_spec,
            },
        },
    }
    return base, producer


def copy_json(value: Any) -> Any:
    return json.loads(json.dumps(value))


def validate_run(
    events: list[dict[str, Any]],
    initial: dict[str, Any],
    scaled_object: dict[str, Any],
    config: dict[str, Any],
) -> dict[str, Any]:
    if not events:
        raise ValidationError("run has no events")
    expected_count = required_int(config, "message_count", 1)
    configured_lambda = required_float(
        config, "lambda_per_second", 0, strict=True
    )
    cooldown = required_int(config, "cooldown_seconds", 1)
    polling = required_int(config, "polling_interval_seconds", 1)
    arrival_tolerance = required_float(
        config, "arrival_rate_relative_tolerance", 0
    )
    validate_frozen_objects(initial, scaled_object, config)

    clusters = {str(item.get("cluster_id") or "") for item in events}
    runs = {str(item.get("run_id") or "") for item in events}
    if len(clusters) != 1 or "" in clusters or len(runs) != 1 or "" in runs:
        raise ValidationError("events do not belong to exactly one cluster/run")

    enqueued = message_map(
        exact_application_events(events, "MESSAGE_ENQUEUED"),
        "MESSAGE_ENQUEUED",
        expected_count,
    )
    dequeued = message_map(
        exact_application_events(events, "MESSAGE_DEQUEUED"),
        "MESSAGE_DEQUEUED",
        expected_count,
    )
    processing = message_map(
        exact_application_events(events, "MESSAGE_PROCESSING_STARTED"),
        "MESSAGE_PROCESSING_STARTED",
        expected_count,
    )
    processed = message_map(
        exact_application_events(events, "MESSAGE_PROCESSED"),
        "MESSAGE_PROCESSED",
        expected_count,
    )
    if not (set(enqueued) == set(dequeued) == set(processing) == set(processed)):
        raise ValidationError("message lifecycle ID sets do not match")
    sequences = sorted(
        int(attributes(item).get("sequence") or 0) for item in enqueued.values()
    )
    if sequences != list(range(1, expected_count + 1)):
        raise ValidationError("MESSAGE_ENQUEUED sequences are not exact 1..N")
    for message_id in enqueued:
        times = [
            event_time(enqueued[message_id]),
            event_time(dequeued[message_id]),
            event_time(processing[message_id]),
            event_time(processed[message_id]),
        ]
        if times != sorted(times):
            raise ValidationError(
                f"message {message_id} lifecycle timestamps are out of order"
            )

    busy_start = one_event(
        exact_application_events(events, "BUSY_PERIOD_STARTED"),
        "BUSY_PERIOD_STARTED",
    )
    busy_end = one_event(
        exact_application_events(events, "BUSY_PERIOD_ENDED"),
        "BUSY_PERIOD_ENDED",
    )
    first_enqueue_ns = min(event_time(item) for item in enqueued.values())
    last_enqueue_ns = max(event_time(item) for item in enqueued.values())
    last_processed_ns = max(event_time(item) for item in processed.values())
    busy_start_ns = event_time(busy_start)
    busy_end_ns = event_time(busy_end)
    if busy_start_ns > first_enqueue_ns or busy_end_ns < last_processed_ns:
        raise ValidationError("busy-period boundaries do not enclose message work")

    queue_samples = exact_application_events(events, "QUEUE_DEPTH_SAMPLE")
    if len(queue_samples) < expected_count + 2:
        raise ValidationError("insufficient exact Redis queue-depth samples")
    depths: list[float] = []
    for item in queue_samples:
        try:
            depth = float(attributes(item).get("queue_depth"))
        except (TypeError, ValueError) as exc:
            raise ValidationError("queue-depth sample is not numeric") from exc
        if depth < 0:
            raise ValidationError("queue-depth sample is negative")
        depths.append(depth)
    if not any(depth > 0 for depth in depths):
        raise ValidationError("queue depth never became positive")
    final_producer_samples = [
        item
        for item in queue_samples
        if attributes(item).get("observer") == "producer"
        and event_time(item) <= busy_end_ns
    ]
    if not final_producer_samples:
        raise ValidationError("producer emitted no final queue sample")
    final_sample = max(final_producer_samples, key=event_time)
    if float(attributes(final_sample).get("queue_depth", -1)) != 0:
        raise ValidationError("final producer queue sample is not zero")
    if int(attributes(final_sample).get("completed_count") or -1) != expected_count:
        raise ValidationError("final producer completion count is not exact")

    created = [
        item
        for item in events_of(events, "KEDA_SCALEDOBJECT_CREATED")
        if item.get("workload_name") == config.get("scaled_object_name")
    ]
    ready = [
        item
        for item in events_of(events, "KEDA_SCALEDOBJECT_READY")
        if item.get("workload_name") == config.get("scaled_object_name")
    ]
    active = [
        item
        for item in events_of(events, "KEDA_SCALEDOBJECT_ACTIVE")
        if item.get("workload_name") == config.get("scaled_object_name")
        and event_time(item) >= first_enqueue_ns
    ]
    if not created or not ready or not active:
        raise ValidationError("missing ScaledObject created/ready/active evidence")
    active_event = active[-1]
    active_ns = event_time(active_event)
    inactive = [
        item
        for item in events_of(events, "KEDA_SCALEDOBJECT_INACTIVE")
        if item.get("workload_name") == config.get("scaled_object_name")
        and event_time(item) > active_ns
    ]
    if not inactive:
        raise ValidationError("missing ScaledObject inactive transition after activation")
    inactive_event = inactive[0]
    inactive_ns = event_time(inactive_event)
    if active_event.get("approximate") or inactive_event.get("approximate"):
        raise ValidationError(
            "ScaledObject Active/Inactive transition timestamps are approximate"
        )

    scaler_samples = [
        item
        for item in events_of(events, "KEDA_SCALER_SAMPLE")
        if item.get("source_component") == "keda-external-metrics-api"
        and attributes(item).get("scaled_object") == config.get("scaled_object_name")
    ]
    if len(scaler_samples) < 3:
        raise ValidationError("insufficient external-metrics KEDA samples")
    metric_names = {
        str(attributes(item).get("metric_name") or "")
        for item in scaler_samples
    }
    if len(metric_names) != 1 or "" in metric_names:
        raise ValidationError(
            "E04 Redis ScaledObject must expose exactly one external metric"
        )
    sample_values: list[tuple[int, float]] = []
    for item in scaler_samples:
        try:
            value = float(attributes(item).get("metric_value_float"))
        except (TypeError, ValueError) as exc:
            raise ValidationError("KEDA metric sample value is not numeric") from exc
        if value < 0:
            raise ValidationError("KEDA metric sample value is negative")
        sample_values.append((observed_time(item), value))
    sample_values.sort()
    positive = [sample for sample in sample_values if sample[1] > 0]
    if not positive:
        raise ValidationError("KEDA external metric never became positive")
    first_positive_observed = positive[0][0]
    if not any(
        value == 0 and observed <= first_positive_observed
        for observed, value in sample_values
    ):
        raise ValidationError("KEDA samples have no initial zero observation")
    if not any(
        value == 0 and observed > first_positive_observed
        for observed, value in sample_values
    ):
        raise ValidationError("KEDA samples have no post-active zero observation")
    max_gap_seconds = required_float(
        config, "metric_sample_max_gap_seconds", 0, strict=True
    )
    observed_gaps = [
        (right[0] - left[0]) / 1e9
        for left, right in zip(sample_values, sample_values[1:])
    ]
    if observed_gaps and max(observed_gaps) > max_gap_seconds:
        raise ValidationError(
            f"KEDA metric sample gap {max(observed_gaps):.3f}s exceeds "
            f"{max_gap_seconds:.3f}s"
        )

    hpa_scale_out = [
        item
        for item in events_of(events, "HPA_DESIRED_REPLICAS_CHANGED")
        if attributes(item).get("scaled_object") == config.get("scaled_object_name")
        and int(attributes(item).get("desired_replicas") or 0) > 0
        and event_time(item) >= first_enqueue_ns
    ]
    if not hpa_scale_out:
        raise ValidationError("HPA never recorded a positive desired replica count")
    first_hpa_ns = event_time(hpa_scale_out[0])

    worker_name = str(config.get("worker_name") or "")
    pod_ready = [
        item
        for item in events_of(events, "POD_READY")
        if str(item.get("pod_name") or "").startswith(worker_name + "-")
        and event_time(item) >= first_enqueue_ns
    ]
    if not pod_ready:
        raise ValidationError("no worker Pod Ready event followed the first message")
    first_ready_ns = event_time(pod_ready[0])
    first_processed_ns = min(event_time(item) for item in processed.values())

    scale_zero = [
        item
        for item in events_of(events, "KEDA_SCALE_TO_ZERO")
        if item.get("workload_name") == worker_name
        and attributes(item).get("scaled_object")
        == config.get("scaled_object_name")
        and event_time(item) > busy_end_ns
    ]
    if not scale_zero:
        raise ValidationError("missing post-busy KEDA scale-to-zero event")
    scale_zero_ns = event_time(scale_zero[0])
    observed_cooldown = (scale_zero_ns - inactive_ns) / 1e9
    lower = max(0.0, cooldown - 2 * polling - 5)
    upper = cooldown + 3 * polling + 30
    if not lower <= observed_cooldown <= upper:
        raise ValidationError(
            f"observed scale-to-zero delay {observed_cooldown:.3f}s is outside "
            f"[{lower:.3f}, {upper:.3f}]"
        )

    if expected_count == 1:
        observed_lambda = configured_lambda
    else:
        arrival_window = (last_enqueue_ns - first_enqueue_ns) / 1e9
        if arrival_window <= 0:
            raise ValidationError("message arrival window is not positive")
        observed_lambda = (expected_count - 1) / arrival_window
    relative_error = abs(observed_lambda - configured_lambda) / configured_lambda
    if relative_error > arrival_tolerance:
        raise ValidationError(
            f"observed lambda {observed_lambda:.6f} differs from configured "
            f"{configured_lambda:.6f} by {relative_error:.2%}"
        )

    cold_start_seconds = (first_ready_ns - first_enqueue_ns) / 1e9
    first_processed_seconds = (first_processed_ns - first_enqueue_ns) / 1e9
    busy_period_seconds = (busy_end_ns - busy_start_ns) / 1e9
    if min(cold_start_seconds, first_processed_seconds, busy_period_seconds) < 0:
        raise ValidationError("derived E04 duration is negative")
    predicted = keda_elasticity_bound(
        observed_lambda, cold_start_seconds, busy_period_seconds, cooldown
    )
    return {
        "result": "PASS",
        "sequence": required_int(config, "sequence", 1),
        "block": required_int(config, "block", 1),
        "cell_id": str(config.get("cell_id") or ""),
        "cluster_id": next(iter(clusters)),
        "run_id": next(iter(runs)),
        "cooldown_seconds": cooldown,
        "configured_lambda_per_second": configured_lambda,
        "observed_lambda_per_second": observed_lambda,
        "arrival_rate_relative_error": relative_error,
        "cold_start_seconds": cold_start_seconds,
        "first_message_processed_seconds": first_processed_seconds,
        "busy_period_seconds": busy_period_seconds,
        "hpa_reaction_seconds": (first_hpa_ns - first_enqueue_ns) / 1e9,
        "active_reaction_seconds": (active_ns - first_enqueue_ns) / 1e9,
        "observed_scale_to_zero_seconds": observed_cooldown,
        "predicted_elasticity": predicted,
        "message_count": expected_count,
        "queue_sample_count": len(queue_samples),
        "keda_sample_count": len(scaler_samples),
        "worker_pod_count": len(
            {
                str(item.get("pod_uid") or "")
                for item in pod_ready
                if item.get("pod_uid")
            }
        ),
        "times_ns": {
            "first_enqueue": first_enqueue_ns,
            "first_keda_active": active_ns,
            "first_hpa_positive_desired": first_hpa_ns,
            "first_worker_ready": first_ready_ns,
            "first_message_processed": first_processed_ns,
            "busy_start": busy_start_ns,
            "busy_end": busy_end_ns,
            "keda_inactive": inactive_ns,
            "scale_to_zero": scale_zero_ns,
        },
    }


def keda_elasticity_bound(
    arrival_rate: float,
    cold_start_seconds: float,
    busy_period_seconds: float,
    cooldown_seconds: float,
) -> float:
    if (
        arrival_rate <= 0
        or cold_start_seconds < 0
        or busy_period_seconds < 0
        or cooldown_seconds < 0
    ):
        raise ValidationError("invalid KEDA model parameters")
    exponential = math.exp(-arrival_rate * cooldown_seconds)
    denominator = (
        exponential
        + arrival_rate * cold_start_seconds
        + arrival_rate * busy_period_seconds
    )
    if denominator <= 0:
        raise ValidationError("invalid KEDA model denominator")
    dormant_probability = exponential / denominator
    return 1 - dormant_probability * cold_start_seconds / (
        cold_start_seconds + 1 / arrival_rate
    )


def solve_keda_cooldown(
    arrival_rate: float,
    cold_start_seconds: float,
    busy_period_seconds: float,
    target: float,
    maximum_seconds: float,
) -> float:
    if not 0 < target <= 1:
        raise ValidationError("target elasticity must be in (0,1]")
    if maximum_seconds <= 0:
        raise ValidationError("maximum cooldown must be positive")
    if (
        keda_elasticity_bound(
            arrival_rate, cold_start_seconds, busy_period_seconds, 0
        )
        >= target
    ):
        return 0
    if (
        keda_elasticity_bound(
            arrival_rate,
            cold_start_seconds,
            busy_period_seconds,
            maximum_seconds,
        )
        < target
    ):
        raise ValidationError("target cannot be reached within maximum cooldown")
    low, high = 0.0, maximum_seconds
    for _ in range(80):
        middle = (low + high) / 2
        value = keda_elasticity_bound(
            arrival_rate, cold_start_seconds, busy_period_seconds, middle
        )
        if value >= target:
            high = middle
        else:
            low = middle
    return high


def quantile(values: list[float], probability: float) -> float:
    if not values:
        raise ValidationError("cannot calculate a quantile without values")
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def describe(values: list[float]) -> dict[str, float | int]:
    if not values:
        raise ValidationError("cannot describe an empty sample")
    return {
        "count": len(values),
        "mean": statistics.fmean(values),
        "p50": quantile(values, 0.5),
        "p95": quantile(values, 0.95),
        "minimum": min(values),
        "maximum": max(values),
    }


def summarize(
    schedule: list[dict[str, str]],
    observations: list[dict[str, Any]],
    target: float,
    maximum_cooldown: float,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if len(schedule) != len(observations):
        raise ValidationError(
            f"schedule has {len(schedule)} rows but {len(observations)} observations"
        )
    by_sequence: dict[int, dict[str, Any]] = {}
    for observation in observations:
        if observation.get("result") != "PASS":
            raise ValidationError("summary only accepts PASS observations")
        sequence = required_int(observation, "sequence", 1)
        if sequence in by_sequence:
            raise ValidationError(f"duplicate observation sequence {sequence}")
        by_sequence[sequence] = observation
    ordered: list[dict[str, Any]] = []
    for row in schedule:
        sequence = int(row["sequence"])
        observation = by_sequence.get(sequence)
        if observation is None:
            raise ValidationError(f"missing observation sequence {sequence}")
        if int(row["cooldown_seconds"]) != int(observation["cooldown_seconds"]):
            raise ValidationError(f"cooldown mismatch at sequence {sequence}")
        ordered.append(observation)

    arrival_rate = statistics.fmean(
        float(item["observed_lambda_per_second"]) for item in ordered
    )
    cold_start = statistics.fmean(
        float(item["cold_start_seconds"]) for item in ordered
    )
    busy_period = statistics.fmean(
        float(item["busy_period_seconds"]) for item in ordered
    )
    tau_star = solve_keda_cooldown(
        arrival_rate, cold_start, busy_period, target, maximum_cooldown
    )
    grouped: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for item in ordered:
        grouped[int(item["cooldown_seconds"])].append(item)
    cells: list[dict[str, Any]] = []
    for cooldown, items in sorted(grouped.items()):
        cells.append(
            {
                "cooldown_seconds": cooldown,
                "runs": len(items),
                "cold_start_seconds": describe(
                    [float(item["cold_start_seconds"]) for item in items]
                ),
                "busy_period_seconds": describe(
                    [float(item["busy_period_seconds"]) for item in items]
                ),
                "scale_to_zero_seconds": describe(
                    [
                        float(item["observed_scale_to_zero_seconds"])
                        for item in items
                    ]
                ),
                "predicted_elasticity_from_pooled_inputs": keda_elasticity_bound(
                    arrival_rate, cold_start, busy_period, cooldown
                ),
            }
        )
    summary = {
        "result": "PASS",
        "run_count": len(ordered),
        "model": "hooke-keda-rule-2/v1",
        "arrival_rate_lambda": arrival_rate,
        "cold_start_mean_mu_s": cold_start,
        "busy_period_mean_E_V": busy_period,
        "target_elasticity": target,
        "recommended_cooldown_tau_star_seconds": tau_star,
        "cells": cells,
    }
    rows = [
        {
            key: item.get(key)
            for key in (
                "sequence",
                "block",
                "cell_id",
                "run_id",
                "cooldown_seconds",
                "configured_lambda_per_second",
                "observed_lambda_per_second",
                "cold_start_seconds",
                "first_message_processed_seconds",
                "busy_period_seconds",
                "hpa_reaction_seconds",
                "active_reaction_seconds",
                "observed_scale_to_zero_seconds",
                "predicted_elasticity",
                "message_count",
                "queue_sample_count",
                "keda_sample_count",
                "worker_pod_count",
            )
        }
        for item in ordered
    ]
    return summary, rows


def command_schedule(args: argparse.Namespace) -> int:
    cooldowns = tuple(int(value) for value in args.cooldowns.split(","))
    rows = generate_schedule(args.repetitions, args.seed, cooldowns)
    write_tsv(
        Path(args.output),
        ["sequence", "block", "cell_id", "cooldown_seconds"],
        rows,
    )
    return 0


def command_normalize_samples(args: argparse.Namespace) -> int:
    captures = read_ndjson(Path(args.input))
    events = normalize_metric_samples(
        captures,
        args.cluster_id,
        args.run_id,
        args.start_ns,
        args.end_ns,
    )
    write_ndjson(Path(args.output), events)
    return 0


def command_validate_run(args: argparse.Namespace) -> int:
    observation = validate_run(
        read_ndjson(Path(args.events)),
        read_json(Path(args.initial_state)),
        read_json(Path(args.scaled_object)),
        read_json(Path(args.config)),
    )
    write_json(Path(args.output), observation)
    return 0


def command_render(args: argparse.Namespace) -> int:
    base, producer = render_manifests(
        read_json(Path(args.config)),
        args.namespace,
        args.run_id,
        args.redis_secret,
    )
    write_json(Path(args.base_output), base)
    write_json(Path(args.producer_output), producer)
    return 0


def command_summarize(args: argparse.Namespace) -> int:
    observations = [read_json(Path(path)) for path in args.observation]
    summary, rows = summarize(
        read_tsv(Path(args.schedule)),
        observations,
        args.target_elasticity,
        args.maximum_cooldown_seconds,
    )
    write_json(Path(args.output_json), summary)
    fields = list(rows[0]) if rows else []
    write_tsv(Path(args.output_tsv), fields, rows)
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    schedule = commands.add_parser("schedule")
    schedule.add_argument("--repetitions", type=int, default=5)
    schedule.add_argument("--seed", type=int, default=20260724)
    schedule.add_argument("--cooldowns", default="60,300")
    schedule.add_argument("--output", required=True)
    schedule.set_defaults(handler=command_schedule)

    sample = commands.add_parser("sample-keda")
    sample.add_argument("--kubeconfig", default=os.getenv("KUBECONFIG_PATH", ""))
    sample.add_argument("--context", default=os.getenv("KUBE_CONTEXT", ""))
    sample.add_argument("--namespace", required=True)
    sample.add_argument("--scaled-object", required=True)
    sample.add_argument("--output", required=True)
    sample.add_argument("--stop-file", required=True)
    sample.add_argument("--interval-seconds", type=float, default=1)
    sample.add_argument("--request-timeout-seconds", type=float, default=15)
    sample.add_argument("--max-consecutive-errors", type=int, default=10)
    sample.set_defaults(handler=capture_external_metrics)

    normalize = commands.add_parser("normalize-samples")
    normalize.add_argument("--input", required=True)
    normalize.add_argument("--cluster-id", required=True)
    normalize.add_argument("--run-id", required=True)
    normalize.add_argument("--start-ns", required=True, type=int)
    normalize.add_argument("--end-ns", required=True, type=int)
    normalize.add_argument("--output", required=True)
    normalize.set_defaults(handler=command_normalize_samples)

    validate = commands.add_parser("validate-run")
    validate.add_argument("--events", required=True)
    validate.add_argument("--initial-state", required=True)
    validate.add_argument("--scaled-object", required=True)
    validate.add_argument("--config", required=True)
    validate.add_argument("--output", required=True)
    validate.set_defaults(handler=command_validate_run)

    render = commands.add_parser("render")
    render.add_argument("--config", required=True)
    render.add_argument("--namespace", required=True)
    render.add_argument("--run-id", required=True)
    render.add_argument("--redis-secret", required=True)
    render.add_argument("--base-output", required=True)
    render.add_argument("--producer-output", required=True)
    render.set_defaults(handler=command_render)

    summary = commands.add_parser("summarize")
    summary.add_argument("--schedule", required=True)
    summary.add_argument("--observation", action="append", required=True)
    summary.add_argument("--target-elasticity", type=float, default=0.99)
    summary.add_argument("--maximum-cooldown-seconds", type=float, default=86400)
    summary.add_argument("--output-json", required=True)
    summary.add_argument("--output-tsv", required=True)
    summary.set_defaults(handler=command_summarize)
    return root


def main() -> int:
    args = parser().parse_args()
    if getattr(args, "interval_seconds", 1) <= 0:
        raise ValidationError("sample interval must be positive")
    if getattr(args, "request_timeout_seconds", 1) <= 0:
        raise ValidationError("request timeout must be positive")
    if getattr(args, "max_consecutive_errors", 1) <= 0:
        raise ValidationError("max consecutive errors must be positive")
    return int(args.handler(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        OSError,
        RuntimeError,
        ValidationError,
        ValueError,
        json.JSONDecodeError,
        subprocess.TimeoutExpired,
    ) as exc:
        print(f"e04-keda-scale-to-zero: {exc}", file=sys.stderr)
        raise SystemExit(1)
