#!/usr/bin/env python3
"""Plan and fail-closed validate the two-A100 E09 MIG/DRA pilot."""

from __future__ import annotations

import argparse
import json
import math
import re
import secrets
import statistics
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


MIG_PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9.+-]{0,62}$")
ULID_RE = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")


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


def ready_node(node: dict[str, Any]) -> bool:
    return any(
        condition.get("type") == "Ready" and condition.get("status") == "True"
        for condition in (node.get("status") or {}).get("conditions") or []
    )


def owner_kind(pod: dict[str, Any]) -> str:
    references = (pod.get("metadata") or {}).get("ownerReferences") or []
    controller = next(
        (
            reference
            for reference in references
            if reference.get("controller") is True
        ),
        references[0] if references else {},
    )
    return str(controller.get("kind") or "")


def device_attribute_string(device: dict[str, Any], name: str) -> str:
    basic = device.get("basic")
    attributes = (
        (basic.get("attributes") if isinstance(basic, dict) else None)
        or device.get("attributes")
        or {}
    )
    if not isinstance(attributes, dict):
        return ""
    for candidate in (
        attributes.get(name),
        attributes.get(f"gpu.nvidia.com/{name}"),
    ):
        if isinstance(candidate, dict) and candidate.get("string"):
            return str(candidate["string"])
    domain = attributes.get("gpu.nvidia.com")
    if isinstance(domain, dict):
        candidate = domain.get(name)
        if isinstance(candidate, dict) and candidate.get("string"):
            return str(candidate["string"])
    return ""


def resource_slice_device_records(
    resource_slice: dict[str, Any],
) -> list[dict[str, str]]:
    spec = resource_slice.get("spec") or {}
    pool = str((spec.get("pool") or {}).get("name") or "")
    output: list[dict[str, str]] = []
    for device in spec.get("devices") or []:
        if not isinstance(device, dict) or not device.get("name"):
            continue
        output.append(
            {
                "driver": str(spec.get("driver") or ""),
                "pool": pool,
                "name": str(device["name"]),
                "type": device_attribute_string(device, "type"),
                "profile": device_attribute_string(device, "profile"),
                "uuid": device_attribute_string(device, "uuid"),
                "parent_uuid": device_attribute_string(device, "parentUUID"),
            }
        )
    return sorted(output, key=lambda item: item["name"])


def parse_csv(value: str) -> list[str]:
    output = [item.strip() for item in value.split(",") if item.strip()]
    if not output:
        raise ValidationError("comma-separated value must not be empty")
    return output


def parse_profile_map(value: str) -> dict[str, str]:
    output: dict[str, str] = {}
    for item in parse_csv(value):
        profile, separator, config = item.partition("=")
        profile = profile.strip()
        config = config.strip()
        if not separator or not profile or not config:
            raise ValidationError(
                "profile map entries must use requested-profile=mig-config"
            )
        if not MIG_PROFILE_RE.fullmatch(profile):
            raise ValidationError(f"invalid requested MIG profile: {profile}")
        if not MIG_PROFILE_RE.fullmatch(config):
            raise ValidationError(f"invalid MIG config name: {config}")
        if profile in output:
            raise ValidationError(f"duplicate requested profile: {profile}")
        output[profile] = config
    return output


def new_run_id(args: argparse.Namespace) -> None:
    alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    value = (int(time.time_ns() // 1_000_000) << 80) | secrets.randbits(80)
    encoded = []
    for _ in range(26):
        encoded.append(alphabet[value & 31])
        value >>= 5
    run_id = "".join(reversed(encoded))
    if not ULID_RE.fullmatch(run_id):
        raise ValidationError("generated run ID is not a canonical ULID")
    print(run_id)


def make_plan(args: argparse.Namespace) -> None:
    if args.node_a == args.node_b:
        raise ValidationError("the crossover pilot requires two distinct nodes")
    profile_map = parse_profile_map(args.profile_map)
    sequence = parse_csv(args.sequence)
    if len(profile_map) != 2:
        raise ValidationError("the small pilot requires exactly two profiles")
    if any(profile not in profile_map for profile in sequence):
        raise ValidationError("sequence contains a profile absent from profile map")
    counts = Counter(sequence)
    if any(counts[profile] < 3 for profile in profile_map):
        raise ValidationError(
            "each profile needs at least three repetitions per period"
        )
    if len(sequence) < 6:
        raise ValidationError("each crossover period needs at least six trials")
    if not MIG_PROFILE_RE.fullmatch(args.static_config):
        raise ValidationError("invalid static MIG config name")
    if args.static_config in profile_map.values():
        raise ValidationError(
            "static balanced config must differ from dynamic homogeneous configs"
        )
    if args.batch_size < 1 or args.batch_size > 32:
        raise ValidationError("batch size must be between 1 and 32")
    if args.admission_window_seconds < 5:
        raise ValidationError("admission window must be at least five seconds")
    if args.hold_seconds <= args.admission_window_seconds + 5:
        raise ValidationError(
            "hold time must exceed the admission window by more than five seconds"
        )

    mismatch_pattern: list[bool] = []
    current = sequence[0]
    for profile in sequence:
        mismatch = profile != current
        mismatch_pattern.append(mismatch)
        current = profile
    if sum(mismatch_pattern) < 2:
        raise ValidationError(
            "sequence needs at least two measured dynamic profile transitions"
        )
    if all(mismatch_pattern) or not any(mismatch_pattern):
        raise ValidationError(
            "sequence must include both matching and mismatching demand epochs"
        )

    periods = []
    assignments = (
        (1, args.node_a, args.node_b),
        (2, args.node_b, args.node_a),
    )
    for period, static_node, dynamic_node in assignments:
        trials = []
        current = sequence[0]
        for index, profile in enumerate(sequence, 1):
            mismatch = profile != current
            trials.append(
                {
                    "period": period,
                    "trial": index,
                    "trial_id": f"p{period}-t{index:02d}",
                    "requested_profile": profile,
                    "dynamic_mig_config": profile_map[profile],
                    "planned_dynamic_mismatch": mismatch,
                }
            )
            current = profile
        periods.append(
            {
                "period": period,
                "static_node": static_node,
                "dynamic_node": dynamic_node,
                "dynamic_initial_profile": sequence[0],
                "dynamic_initial_mig_config": profile_map[sequence[0]],
                "trials": trials,
            }
        )

    plan = {
        "schema_version": 1,
        "scope": "two-A100 crossover small-scale pilot",
        "nodes": [args.node_a, args.node_b],
        "strategies": {
            "static-balanced": {
                "mig_config": args.static_config,
                "description": "one fixed mixed-profile geometry per period",
            },
            "dynamic-homogeneous": {
                "profile_map": profile_map,
                "description": (
                    "reshape only when the demand epoch profile mismatches "
                    "the current homogeneous geometry"
                ),
            },
        },
        "sequence": sequence,
        "repetitions_per_profile_per_period": {
            profile: counts[profile] for profile in sorted(profile_map)
        },
        "batch_size": args.batch_size,
        "hold_seconds": args.hold_seconds,
        "admission_window_seconds": args.admission_window_seconds,
        "periods": periods,
    }
    atomic_json(Path(args.output), plan)


def check_preflight(args: argparse.Namespace) -> None:
    nodes = load_json(Path(args.nodes))
    pods = load_json(Path(args.pods))
    device_classes = load_json(Path(args.device_classes))
    resource_slices = load_json(Path(args.resource_slices))
    targets = [args.node_a, args.node_b]
    if len(set(targets)) != 2:
        raise ValidationError("preflight requires two distinct target nodes")

    class_names = {
        str((item.get("metadata") or {}).get("name") or "")
        for item in device_classes.get("items") or []
    }
    if args.device_class not in class_names:
        raise ValidationError(
            f"required DeviceClass {args.device_class!r} is unavailable"
        )

    node_by_name = {
        str((item.get("metadata") or {}).get("name") or ""): item
        for item in nodes.get("items") or []
    }
    summaries = []
    products: set[str] = set()
    architectures: set[str] = set()
    driver_versions: set[str] = set()
    provider_ids: set[str] = set()
    for name in targets:
        if name not in node_by_name:
            raise ValidationError(f"target node {name!r} was not found")
        node = node_by_name[name]
        metadata = node.get("metadata") or {}
        labels = metadata.get("labels") or {}
        spec = node.get("spec") or {}
        if spec.get("unschedulable") is True or not ready_node(node):
            raise ValidationError(f"target node {name} is not Ready and schedulable")
        provider_id = str(spec.get("providerID") or "")
        if not provider_id:
            raise ValidationError(f"target node {name} has no providerID")
        if provider_id in provider_ids:
            raise ValidationError("target nodes do not have distinct providerIDs")
        provider_ids.add(provider_id)
        if labels.get("nvidia.com/mig.capable") != "true":
            raise ValidationError(f"target node {name} is not MIG-capable")
        product = str(labels.get("nvidia.com/gpu.product") or "")
        if not re.search(args.product_regex, product, re.IGNORECASE):
            raise ValidationError(
                f"GPU product {product!r} does not match {args.product_regex!r}"
            )
        if any(
            str(labels.get(key) or "").lower() == "true"
            for key in (
                "nvidia.com/vgpu.present",
                "nvidia.com/vgpu.host-driver-ready",
            )
        ):
            raise ValidationError(f"target node {name} is a vGPU host/guest")
        if labels.get("nvidia.com/mig.config") != args.source_profile:
            raise ValidationError(
                f"target node {name} does not use the frozen source profile"
            )
        if labels.get("nvidia.com/mig.config.state") != "success":
            raise ValidationError(
                f"target node {name} MIG manager state is not success"
            )
        if labels.get("nvidia.com/mig.strategy") != args.mig_strategy:
            raise ValidationError(
                f"target node {name} does not use required MIG strategy "
                f"{args.mig_strategy}"
            )
        if labels.get(args.dra_node_label_key) != args.dra_node_label_value:
            raise ValidationError(
                f"target node {name} lacks the frozen DRA selector label"
            )
        legacy = sorted(
            key
            for key, value in (
                (node.get("status") or {}).get("allocatable") or {}
            ).items()
            if re.fullmatch(r"nvidia\.com/(?:gpu|mig-.+)", str(key))
            and str(value or "") not in {"", "0"}
        )
        if legacy:
            raise ValidationError(
                f"target node {name} exposes legacy Device Plugin resources"
            )
        blocking = []
        for pod in pods.get("items") or []:
            if (pod.get("spec") or {}).get("nodeName") != name:
                continue
            phase = str((pod.get("status") or {}).get("phase") or "")
            if phase in {"Succeeded", "Failed"}:
                continue
            annotations = (pod.get("metadata") or {}).get("annotations") or {}
            if (
                owner_kind(pod) == "DaemonSet"
                or "kubernetes.io/config.mirror" in annotations
            ):
                continue
            pod_metadata = pod.get("metadata") or {}
            blocking.append(
                f"{pod_metadata.get('namespace', '')}/"
                f"{pod_metadata.get('name', '')}"
            )
        if blocking:
            raise ValidationError(
                f"target node {name} has active tenant Pods: "
                + ",".join(sorted(blocking))
            )

        matching_slices = [
            item
            for item in resource_slices.get("items") or []
            if (item.get("spec") or {}).get("driver") == args.driver
            and (item.get("spec") or {}).get("nodeName") == name
            and resource_slice_device_records(item)
        ]
        if len(matching_slices) != 1:
            raise ValidationError(
                f"target node {name} needs one non-empty NVIDIA ResourceSlice"
            )
        pool = (matching_slices[0].get("spec") or {}).get("pool") or {}
        devices = resource_slice_device_records(matching_slices[0])
        if int(pool.get("resourceSliceCount") or 0) != 1:
            raise ValidationError(f"target node {name} ResourceSlice is split")
        if len(devices) != 1 or devices[0]["type"] != "gpu":
            raise ValidationError(
                f"source profile on {name} must publish exactly one full GPU"
            )

        architecture = str(labels.get("kubernetes.io/arch") or "")
        driver_version = str(
            labels.get("nvidia.com/cuda.driver-version.full") or ""
        )
        products.add(product)
        architectures.add(architecture)
        driver_versions.add(driver_version)
        summaries.append(
            {
                "node": name,
                "provider_id": provider_id,
                "gpu_product": product,
                "architecture": architecture,
                "driver_version": driver_version,
                "source_profile": args.source_profile,
                "source_device_count": 1,
                "blocking_pods": [],
            }
        )

    if len(products) != 1:
        raise ValidationError("the two GPU nodes do not use the same GPU product")
    if len(architectures) != 1 or "" in architectures:
        raise ValidationError("the two GPU nodes do not use one known architecture")
    if len(driver_versions) != 1 or "" in driver_versions:
        raise ValidationError("the two GPU nodes do not use one known driver")

    cpu_nodes = [
        name
        for name, node in node_by_name.items()
        if name not in targets
        and ((node.get("metadata") or {}).get("labels") or {}).get(
            args.control_selector_key
        )
        == args.control_selector_value
        and ready_node(node)
        and (node.get("spec") or {}).get("unschedulable") is not True
    ]
    if not cpu_nodes:
        raise ValidationError("no Ready fixed CPU control node was found")

    atomic_json(
        Path(args.output),
        {
            "status": "PASS",
            "scope": "two-A100 crossover preflight",
            "nodes": summaries,
            "gpu_product": next(iter(products)),
            "architecture": next(iter(architectures)),
            "driver_version": next(iter(driver_versions)),
            "device_class": args.device_class,
            "dra_driver": args.driver,
            "cpu_control_nodes": sorted(cpu_nodes),
        },
    )


def identifier_compact(value: str) -> str:
    lowered = value.lower()
    for prefix in ("mig-", "gpu-"):
        if lowered.startswith(prefix):
            lowered = lowered[len(prefix) :]
    return re.sub(r"[^0-9a-f]", "", lowered)


def claim_allocations(claim: dict[str, Any]) -> list[dict[str, str]]:
    results = (
        (((claim.get("status") or {}).get("allocation") or {}).get("devices") or {})
        .get("results")
        or []
    )
    output = []
    for result in results:
        if not isinstance(result, dict):
            continue
        output.append(
            {
                "driver": str(result.get("driver") or ""),
                "pool": str(result.get("pool") or ""),
                "device": str(result.get("device") or ""),
            }
        )
    return output


def percentile(values: Iterable[float], fraction: float) -> float | None:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return None
    if len(ordered) == 1:
        return round(ordered[0], 9)
    position = fraction * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return round(ordered[lower], 9)
    weight = position - lower
    return round(
        ordered[lower] * (1 - weight) + ordered[upper] * weight, 9
    )


def cuda_events_from_log(path: Path) -> list[dict[str, Any]]:
    output = []
    if not path.exists():
        return output
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8", errors="replace").splitlines(), 1
    ):
        if not line.strip().startswith("{"):
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValidationError(
                f"{path}:{line_number} contains malformed JSON"
            ) from exc
        if value.get("hooke_event_type") == "FIRST_CUDA_SUCCESS":
            output.append(value)
    return output


def summarize_batch(args: argparse.Namespace) -> None:
    metadata = load_json(Path(args.metadata))
    pods = load_json(Path(args.pods))
    claims = load_json(Path(args.claims))
    resource_slices = load_json(Path(args.resource_slices))
    logs_dir = Path(args.logs_dir)

    required = (
        "run_id",
        "period",
        "trial",
        "strategy",
        "node",
        "requested_profile",
        "request_time_ns",
        "profile_ready_time_ns",
        "batch_apply_start_ns",
        "admission_deadline_ns",
        "batch_size",
        "hold_seconds",
        "admission_window_seconds",
        "profile_mismatch",
    )
    missing = [key for key in required if key not in metadata]
    if missing:
        raise ValidationError("batch metadata is missing: " + ",".join(missing))
    if not ULID_RE.fullmatch(str(metadata["run_id"])):
        raise ValidationError("batch run_id is not a canonical ULID")
    if metadata["strategy"] not in {
        "static-balanced",
        "dynamic-homogeneous",
    }:
        raise ValidationError("unknown pilot strategy")
    profile = str(metadata["requested_profile"])
    if not MIG_PROFILE_RE.fullmatch(profile):
        raise ValidationError("invalid requested profile in batch metadata")
    batch_size = int(metadata["batch_size"])
    hold_seconds = int(metadata["hold_seconds"])
    window_seconds = int(metadata["admission_window_seconds"])
    if hold_seconds <= window_seconds + 5:
        raise ValidationError("batch hold time does not protect the first wave")

    device_records: dict[tuple[str, str, str], dict[str, str]] = {}
    target_profile_records = []
    for resource_slice in resource_slices.get("items") or []:
        spec = resource_slice.get("spec") or {}
        if (
            spec.get("nodeName") != metadata["node"]
            or spec.get("driver") != args.driver
        ):
            continue
        for record in resource_slice_device_records(resource_slice):
            key = (record["driver"], record["pool"], record["name"])
            device_records[key] = record
            if record["type"] == "mig" and record["profile"] == profile:
                target_profile_records.append(record)
    capacity = len(target_profile_records)
    if capacity < 1:
        raise ValidationError("target ResourceSlice publishes no requested profile")
    if batch_size < capacity:
        raise ValidationError("batch size is smaller than published capacity")

    pod_items = pods.get("items") or []
    claim_items = claims.get("items") or []
    if len(pod_items) != batch_size or len(claim_items) != batch_size:
        raise ValidationError("batch snapshot does not contain every Pod and Claim")
    claims_by_name = {
        str((claim.get("metadata") or {}).get("name") or ""): claim
        for claim in claim_items
    }

    successes = []
    all_cuda_events = 0
    for pod in pod_items:
        pod_metadata = pod.get("metadata") or {}
        pod_spec = pod.get("spec") or {}
        pod_status = pod.get("status") or {}
        pod_name = str(pod_metadata.get("name") or "")
        pod_uid = str(pod_metadata.get("uid") or "")
        if pod_spec.get("nodeName") not in {None, "", metadata["node"]}:
            raise ValidationError(f"Pod {pod_name} ran on the wrong node")
        references = pod_spec.get("resourceClaims") or []
        if len(references) != 1:
            raise ValidationError(f"Pod {pod_name} has an invalid Claim link")
        claim_name = str(references[0].get("resourceClaimName") or "")
        claim = claims_by_name.get(claim_name)
        if claim is None:
            raise ValidationError(f"Pod {pod_name} Claim is absent from snapshot")
        events = cuda_events_from_log(logs_dir / f"{pod_name}.log")
        all_cuda_events += len(events)
        if len(events) > 1:
            raise ValidationError(f"Pod {pod_name} emitted duplicate CUDA success")
        if not events:
            continue
        event = events[0]
        event_time = int(event.get("source_time_ns") or 0)
        if event_time > int(metadata["admission_deadline_ns"]):
            continue
        if event_time < int(metadata["batch_apply_start_ns"]):
            raise ValidationError("CUDA event predates its batch creation")
        if pod_status.get("phase") != "Running":
            raise ValidationError(
                "first-wave CUDA Pod was not still holding its allocation"
            )
        attributes = event.get("hooke_attributes") or {}
        claim_metadata = claim.get("metadata") or {}
        if (
            event.get("pod_uid") != pod_uid
            or event.get("node_name") != metadata["node"]
            or attributes.get("resource_claim_name") != claim_name
            or attributes.get("resource_claim_uid")
            != str(claim_metadata.get("uid") or "")
        ):
            raise ValidationError("CUDA event does not match Pod/Claim identity")
        if attributes.get("device_class") != args.device_class:
            raise ValidationError("CUDA event carries a different DeviceClass")
        if int(attributes.get("cuda_visible_device_count") or 0) != 1:
            raise ValidationError("CUDA probe did not see exactly one device")
        if int(attributes.get("verified_allocation_bytes") or 0) <= 0:
            raise ValidationError("CUDA probe did not verify memory")
        if int(attributes.get("cuda_hold_seconds") or 0) != hold_seconds:
            raise ValidationError("CUDA probe did not use the frozen hold time")
        device_name = str(attributes.get("cuda_device_name") or "")
        if "mig" not in device_name.lower() or profile not in device_name.lower():
            raise ValidationError("CUDA-visible device has the wrong MIG profile")

        allocations = claim_allocations(claim)
        if len(allocations) != 1:
            raise ValidationError(
                "first-wave Claim does not preserve one exact allocation"
            )
        allocation = allocations[0]
        key = (
            allocation["driver"],
            allocation["pool"],
            allocation["device"],
        )
        record = device_records.get(key)
        if record is None:
            raise ValidationError("allocated device is absent from ResourceSlice")
        if record["type"] != "mig" or record["profile"] != profile:
            raise ValidationError("allocated device has the wrong MIG profile")
        reservations = (claim.get("status") or {}).get("reservedFor") or []
        if not any(
            reservation.get("resource") == "pods"
            and reservation.get("uid") == pod_uid
            for reservation in reservations
        ):
            raise ValidationError("Claim is not reserved for the exact Pod UID")

        cuda_uuid = str(attributes.get("cuda_device_uuid") or "")
        cuda_compact = identifier_compact(cuda_uuid)
        exact_uuid = (
            cuda_compact
            and cuda_compact == identifier_compact(record["uuid"])
        )
        parent_uuid = (
            cuda_compact
            and cuda_compact == identifier_compact(record["parent_uuid"])
        )
        if not exact_uuid and not parent_uuid:
            raise ValidationError("allocated device identity does not match CUDA")

        successes.append(
            {
                "pod_name": pod_name,
                "pod_uid": pod_uid,
                "claim_name": claim_name,
                "claim_uid": str(claim_metadata.get("uid") or ""),
                "allocation": allocation,
                "cuda_device_uuid": cuda_uuid,
                "identity_match": (
                    "allocated-device-uuid"
                    if exact_uuid
                    else "allocated-mig-parent-uuid-and-profile"
                ),
                "first_cuda_time_ns": event_time,
                "request_to_cuda_seconds": round(
                    (event_time - int(metadata["request_time_ns"]))
                    / 1_000_000_000,
                    9,
                ),
                "profile_ready_to_cuda_seconds": round(
                    (event_time - int(metadata["profile_ready_time_ns"]))
                    / 1_000_000_000,
                    9,
                ),
                "batch_apply_to_cuda_seconds": round(
                    (event_time - int(metadata["batch_apply_start_ns"]))
                    / 1_000_000_000,
                    9,
                ),
            }
        )

    if len(successes) != capacity:
        raise ValidationError(
            "first-wave CUDA successes do not equal published profile capacity: "
            f"successes={len(successes)} capacity={capacity}"
        )
    if all_cuda_events != len(successes):
        raise ValidationError(
            "a Pod outside the frozen admission window emitted CUDA success"
        )

    request_latencies = [
        item["request_to_cuda_seconds"] for item in successes
    ]
    ready_latencies = [
        item["profile_ready_to_cuda_seconds"] for item in successes
    ]
    summary = {
        "status": "PASS",
        "scope": "one demand epoch in the two-A100 crossover pilot",
        **metadata,
        "published_profile_capacity": capacity,
        "first_wave_cuda_successes": len(successes),
        "pending_after_first_wave": batch_size - len(successes),
        "capacity_gate": "first_wave_cuda_successes == published_profile_capacity",
        "request_to_cuda_seconds": {
            "min": percentile(request_latencies, 0),
            "p50": percentile(request_latencies, 0.5),
            "max": percentile(request_latencies, 1),
        },
        "profile_ready_to_cuda_seconds": {
            "min": percentile(ready_latencies, 0),
            "p50": percentile(ready_latencies, 0.5),
            "max": percentile(ready_latencies, 1),
        },
        "successes": successes,
    }
    atomic_json(Path(args.output), summary)


def mean_or_none(values: Iterable[float]) -> float | None:
    items = [float(value) for value in values]
    if not items:
        return None
    return round(statistics.fmean(items), 9)


def aggregate(args: argparse.Namespace) -> None:
    plan = load_json(Path(args.plan))
    summaries = [
        load_json(path)
        for path in sorted(Path(args.root).glob("**/batch-summary.json"))
    ]
    expected = sum(len(period["trials"]) for period in plan["periods"]) * 2
    if len(summaries) != expected:
        raise ValidationError(
            f"expected {expected} batch summaries, found {len(summaries)}"
        )
    if any(item.get("status") != "PASS" for item in summaries):
        raise ValidationError("not every batch summary passed")

    paired: dict[tuple[int, int], dict[str, dict[str, Any]]] = defaultdict(dict)
    for item in summaries:
        key = (int(item["period"]), int(item["trial"]))
        strategy = str(item["strategy"])
        if strategy in paired[key]:
            raise ValidationError("duplicate strategy result for one trial")
        paired[key][strategy] = item
    if any(
        set(value) != {"static-balanced", "dynamic-homogeneous"}
        for value in paired.values()
    ):
        raise ValidationError("every demand epoch needs both strategy results")
    for pair in paired.values():
        if (
            pair["static-balanced"]["requested_profile"]
            != pair["dynamic-homogeneous"]["requested_profile"]
        ):
            raise ValidationError("paired strategies saw different demand profiles")
        if (
            pair["static-balanced"]["request_time_ns"]
            != pair["dynamic-homogeneous"]["request_time_ns"]
        ):
            raise ValidationError("paired strategies do not share request time")

    nodes_by_strategy: dict[str, set[str]] = defaultdict(set)
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for item in summaries:
        nodes_by_strategy[str(item["strategy"])].add(str(item["node"]))
        grouped[
            (str(item["strategy"]), str(item["requested_profile"]))
        ].append(item)
    expected_nodes = set(plan["nodes"])
    if any(nodes != expected_nodes for nodes in nodes_by_strategy.values()):
        raise ValidationError("crossover did not run each strategy on both nodes")

    cells: dict[str, Any] = {}
    for (strategy, profile), items in sorted(grouped.items()):
        request_latencies = [
            float(success["request_to_cuda_seconds"])
            for item in items
            for success in item["successes"]
        ]
        ready_latencies = [
            float(success["profile_ready_to_cuda_seconds"])
            for item in items
            for success in item["successes"]
        ]
        capacities = [int(item["published_profile_capacity"]) for item in items]
        if len(set(capacities)) != 1:
            raise ValidationError(
                f"published capacity changed within {strategy}/{profile}"
            )
        key = f"{strategy}/{profile}"
        cells[key] = {
            "strategy": strategy,
            "requested_profile": profile,
            "batches": len(items),
            "nodes": sorted({str(item["node"]) for item in items}),
            "published_profile_capacity": capacities[0],
            "first_wave_cuda_successes": sum(
                int(item["first_wave_cuda_successes"]) for item in items
            ),
            "request_to_cuda_seconds": {
                "mean": mean_or_none(request_latencies),
                "p50": percentile(request_latencies, 0.5),
                "p95": percentile(request_latencies, 0.95),
                "max": percentile(request_latencies, 1),
            },
            "profile_ready_to_cuda_seconds": {
                "mean": mean_or_none(ready_latencies),
                "p50": percentile(ready_latencies, 0.5),
                "p95": percentile(ready_latencies, 0.95),
                "max": percentile(ready_latencies, 1),
            },
        }

    dynamic = [
        item
        for item in summaries
        if item["strategy"] == "dynamic-homogeneous"
    ]
    mismatches = [item for item in dynamic if item["profile_mismatch"] is True]
    if not mismatches:
        raise ValidationError("dynamic strategy recorded no profile mismatch")
    reshape_durations = []
    mismatch_cuda_durations = []
    for item in mismatches:
        requested = item.get("reshape_requested_time_ns")
        finished = item.get("reshape_finished_time_ns")
        if not requested or not finished or int(finished) <= int(requested):
            raise ValidationError("dynamic mismatch lacks a valid reshape interval")
        reshape_durations.append(
            (int(finished) - int(requested)) / 1_000_000_000
        )
        first_cuda = min(
            int(success["first_cuda_time_ns"]) for success in item["successes"]
        )
        mismatch_cuda_durations.append(
            (first_cuda - int(item["request_time_ns"])) / 1_000_000_000
        )
    for item in dynamic:
        if item["profile_mismatch"] is not True and (
            item.get("reshape_requested_time_ns")
            or item.get("reshape_finished_time_ns")
        ):
            raise ValidationError("matching dynamic epoch unexpectedly reshaped")

    intervals = []
    by_period: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for item in mismatches:
        by_period[int(item["period"])].append(item)
    for items in by_period.values():
        ordered = sorted(items, key=lambda item: int(item["trial"]))
        intervals.extend(
            (
                int(current["reshape_requested_time_ns"])
                - int(previous["reshape_requested_time_ns"])
            )
            / 1_000_000_000
            for previous, current in zip(ordered, ordered[1:])
        )
    if not intervals or any(value <= 0 for value in intervals):
        raise ValidationError("not enough valid within-period reshape intervals")

    rho = len(mismatches) / len(dynamic)
    mean_d = statistics.fmean(reshape_durations)
    mean_t = statistics.fmean(intervals)
    bound = max(0.0, 1.0 - rho * mean_d / mean_t)
    mean_d_cuda = statistics.fmean(mismatch_cuda_durations)
    cuda_bound = max(0.0, 1.0 - rho * mean_d_cuda / mean_t)

    capacity_comparisons = {}
    profiles = sorted(plan["strategies"]["dynamic-homogeneous"]["profile_map"])
    for profile in profiles:
        static_capacity = cells[
            f"static-balanced/{profile}"
        ]["published_profile_capacity"]
        dynamic_capacity = cells[
            f"dynamic-homogeneous/{profile}"
        ]["published_profile_capacity"]
        capacity_comparisons[profile] = {
            "static_balanced": static_capacity,
            "dynamic_homogeneous": dynamic_capacity,
            "dynamic_over_static_ratio": round(
                dynamic_capacity / static_capacity, 9
            ),
        }

    summary = {
        "status": "PASS",
        "scope": "two-A100 crossover small-scale pilot",
        "batch_count": len(summaries),
        "demand_epoch_count": len(paired),
        "nodes": sorted(expected_nodes),
        "cells": cells,
        "capacity_comparisons": capacity_comparisons,
        "dynamic_policy": {
            "demand_epochs": len(dynamic),
            "profile_mismatch_epochs": len(mismatches),
            "rho_epoch": round(rho, 9),
            "rho_request": round(rho, 9),
            "rho_request_note": (
                "identical to epoch rho because every epoch has the same "
                "batch size"
            ),
            "reshape_d_seconds": {
                "mean": round(mean_d, 9),
                "p50": percentile(reshape_durations, 0.5),
                "p95": percentile(reshape_durations, 0.95),
                "max": percentile(reshape_durations, 1),
            },
            "reshape_request_to_first_cuda_seconds": {
                "mean": round(mean_d_cuda, 9),
                "p50": percentile(mismatch_cuda_durations, 0.5),
                "p95": percentile(mismatch_cuda_durations, 0.95),
                "max": percentile(mismatch_cuda_durations, 1),
            },
            "mean_reshape_interval_t_avg_seconds": round(mean_t, 9),
            "reshape_interval_count": len(intervals),
            "gpu_elasticity_bound_reshape_finish": round(bound, 9),
            "gpu_elasticity_bound_first_cuda": round(cuda_bound, 9),
            "bound_formula": "max(0, 1 - rho * D / T_avg)",
        },
        "crossover_gate": {
            strategy: sorted(nodes)
            for strategy, nodes in sorted(nodes_by_strategy.items())
        },
        "limitations": [
            "two A100 GPUs and six repetitions per strategy/profile are pilot scale",
            "demand epochs are synthetic and use a fixed seven-Claim burst",
            "the bound is descriptive for this controlled sequence, not a production forecast",
            "MIG Manager reshapes geometry; DRA allocates the published devices",
        ],
    }
    atomic_json(Path(args.output), summary)

    rows = []
    for profile, comparison in capacity_comparisons.items():
        rows.append(
            f"| `{profile}` | {comparison['static_balanced']} | "
            f"{comparison['dynamic_homogeneous']} | "
            f"{comparison['dynamic_over_static_ratio']:.3f}× |"
        )
    report = f"""# E09 two-A100 MIG/DRA small-scale pilot

Status: **PASS**

- Demand epochs: `{summary['demand_epoch_count']}`
- Strategy batches: `{summary['batch_count']}`
- Physical A100 nodes: `{len(summary['nodes'])}`
- Dynamic mismatch probability ρ: `{rho:.6f}`
- Mean reshape cost D: `{mean_d:.6f}` s
- Mean reshape interval T_avg: `{mean_t:.6f}` s
- Elasticity bound (reshape finish): `{bound:.6f}`
- Elasticity bound (first CUDA): `{cuda_bound:.6f}`

| Requested profile | Static balanced capacity | Dynamic homogeneous capacity | Ratio |
|---|---:|---:|---:|
{chr(10).join(rows)}

Each strategy ran on both physical nodes. Every first-wave CUDA count matched
the exact profile inventory published by NVIDIA DRA, and every successful
Claim was correlated to its Pod UID, allocated ResourceSlice device, and CUDA
identity.

This is a small crossover pilot, not the final statistical experiment. The
controlled demand sequence, seven-Claim burst size, and two-node scope limit
external validity. MIG Manager performs geometry changes; DRA allocates the
devices published after those changes.
"""
    atomic_text(Path(args.report), report)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subparsers = root.add_subparsers(dest="command", required=True)

    run_id = subparsers.add_parser("new-run-id")
    run_id.set_defaults(function=new_run_id)

    plan = subparsers.add_parser("make-plan")
    plan.add_argument("--node-a", required=True)
    plan.add_argument("--node-b", required=True)
    plan.add_argument("--static-config", default="all-balanced")
    plan.add_argument(
        "--profile-map",
        default="1g.10gb=all-1g.10gb,3g.40gb=all-3g.40gb",
    )
    plan.add_argument(
        "--sequence",
        default="1g.10gb,1g.10gb,3g.40gb,3g.40gb,1g.10gb,3g.40gb",
    )
    plan.add_argument("--batch-size", type=int, default=7)
    plan.add_argument("--hold-seconds", type=int, default=45)
    plan.add_argument("--admission-window-seconds", type=int, default=25)
    plan.add_argument("--output", required=True)
    plan.set_defaults(function=make_plan)

    preflight = subparsers.add_parser("check-preflight")
    preflight.add_argument("--nodes", required=True)
    preflight.add_argument("--pods", required=True)
    preflight.add_argument("--device-classes", required=True)
    preflight.add_argument("--resource-slices", required=True)
    preflight.add_argument("--node-a", required=True)
    preflight.add_argument("--node-b", required=True)
    preflight.add_argument("--source-profile", default="all-disabled")
    preflight.add_argument("--mig-strategy", default="mixed")
    preflight.add_argument("--device-class", default="mig.nvidia.com")
    preflight.add_argument("--driver", default="gpu.nvidia.com")
    preflight.add_argument(
        "--dra-node-label-key", default="nvidia.com/dra-kubelet-plugin"
    )
    preflight.add_argument("--dra-node-label-value", default="true")
    preflight.add_argument("--product-regex", default=r"\bA100\b")
    preflight.add_argument("--control-selector-key", default="hooke.io/pool")
    preflight.add_argument("--control-selector-value", default="fixed-cpu")
    preflight.add_argument("--output", required=True)
    preflight.set_defaults(function=check_preflight)

    batch = subparsers.add_parser("summarize-batch")
    batch.add_argument("--metadata", required=True)
    batch.add_argument("--pods", required=True)
    batch.add_argument("--claims", required=True)
    batch.add_argument("--resource-slices", required=True)
    batch.add_argument("--logs-dir", required=True)
    batch.add_argument("--device-class", default="mig.nvidia.com")
    batch.add_argument("--driver", default="gpu.nvidia.com")
    batch.add_argument("--output", required=True)
    batch.set_defaults(function=summarize_batch)

    final = subparsers.add_parser("aggregate")
    final.add_argument("--plan", required=True)
    final.add_argument("--root", required=True)
    final.add_argument("--output", required=True)
    final.add_argument("--report", required=True)
    final.set_defaults(function=aggregate)
    return root


def main() -> int:
    args = parser().parse_args()
    args.function(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError, json.JSONDecodeError) as exc:
        print(f"e09-gpu-dra-mig-pilot: {exc}", file=sys.stderr)
        raise SystemExit(1)
