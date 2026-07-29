#!/usr/bin/env python3
"""Render and fail-closed validate the E09 GPU/DRA/MIG smoke."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable


ULID_RE = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")
IMMUTABLE_IMAGE_RE = re.compile(r"^[^\s@]+@sha256:[0-9a-fA-F]{64}$")


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


def load_ndjson(path: Path) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValidationError(
                f"{path}:{line_number} is not valid JSON"
            ) from exc
        if not isinstance(value, dict):
            raise ValidationError(f"{path}:{line_number} is not an object")
        output.append(value)
    return output


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


def resource_slice_devices(resource_slice: dict[str, Any]) -> list[str]:
    return sorted(
        {
            item["name"]
            for item in resource_slice_device_records(resource_slice)
        }
    )


def device_attribute_string(device: dict[str, Any], name: str) -> str:
    basic = device.get("basic")
    attributes = (
        (basic.get("attributes") if isinstance(basic, dict) else None)
        or device.get("attributes")
        or {}
    )
    if not isinstance(attributes, dict):
        return ""
    candidates = (
        attributes.get(name),
        attributes.get(f"gpu.nvidia.com/{name}"),
    )
    for candidate in candidates:
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
    output: list[dict[str, str]] = []
    for device in (resource_slice.get("spec") or {}).get("devices") or []:
        if not isinstance(device, dict) or not device.get("name"):
            continue
        output.append(
            {
                "name": str(device["name"]),
                "uuid": device_attribute_string(device, "uuid"),
                "type": device_attribute_string(device, "type"),
                "profile": device_attribute_string(device, "profile"),
                "parent_uuid": device_attribute_string(device, "parentUUID"),
            }
        )
    return sorted(output, key=lambda item: item["name"])


def check_preflight(args: argparse.Namespace) -> None:
    nodes = load_json(Path(args.nodes))
    pods = load_json(Path(args.pods))
    device_classes = load_json(Path(args.device_classes))
    resource_slices = load_json(Path(args.resource_slices))
    matching_nodes = [
        node
        for node in nodes.get("items") or []
        if (node.get("metadata") or {}).get("name") == args.target_node
    ]
    if len(matching_nodes) != 1:
        raise ValidationError(
            f"target node {args.target_node!r} was not found exactly once"
        )
    node = matching_nodes[0]
    metadata = node.get("metadata") or {}
    labels = metadata.get("labels") or {}
    spec = node.get("spec") or {}
    if spec.get("unschedulable") is True or not ready_node(node):
        raise ValidationError("target GPU node is not Ready and schedulable")
    if not str(spec.get("providerID") or ""):
        raise ValidationError("target GPU node has no physical providerID")
    if labels.get("nvidia.com/mig.capable") != "true":
        raise ValidationError("target GPU node is not labeled MIG-capable")
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
        raise ValidationError("target is labeled as vGPU rather than a full GPU")
    if labels.get("nvidia.com/mig.config") != args.source_profile:
        raise ValidationError(
            "target MIG source profile does not match the frozen configuration"
        )
    if labels.get("nvidia.com/mig.config.state") != "success":
        raise ValidationError("target MIG manager state must be success")
    if labels.get("nvidia.com/mig.strategy") not in {"single", "mixed"}:
        raise ValidationError("target MIG strategy must be single or mixed")
    if labels.get(args.dra_node_label_key) != args.dra_node_label_value:
        raise ValidationError(
            "target GPU node does not carry the frozen NVIDIA DRA selector label"
        )
    legacy_allocatable = sorted(
        key
        for key, value in ((node.get("status") or {}).get("allocatable") or {}).items()
        if re.fullmatch(r"nvidia\.com/(?:gpu|mig-.+)", str(key))
        and str(value or "") not in {"", "0"}
    )
    if legacy_allocatable:
        raise ValidationError(
            "legacy NVIDIA Device Plugin resources are still allocatable: "
            + ",".join(legacy_allocatable)
        )

    blocking_pods: list[str] = []
    for pod in pods.get("items") or []:
        if (pod.get("spec") or {}).get("nodeName") != args.target_node:
            continue
        phase = str((pod.get("status") or {}).get("phase") or "")
        if phase in {"Succeeded", "Failed"}:
            continue
        annotations = (pod.get("metadata") or {}).get("annotations") or {}
        if owner_kind(pod) == "DaemonSet" or "kubernetes.io/config.mirror" in annotations:
            continue
        pod_metadata = pod.get("metadata") or {}
        blocking_pods.append(
            f"{pod_metadata.get('namespace', '')}/{pod_metadata.get('name', '')}"
        )
    if blocking_pods:
        raise ValidationError(
            "target GPU node is not dedicated; active non-DaemonSet Pods: "
            + ",".join(sorted(blocking_pods))
        )

    class_names = {
        str((item.get("metadata") or {}).get("name") or "")
        for item in device_classes.get("items") or []
    }
    if args.device_class not in class_names:
        raise ValidationError(
            f"required DeviceClass {args.device_class!r} is unavailable"
        )
    matching_slices = [
        resource_slice
        for resource_slice in resource_slices.get("items") or []
        if (resource_slice.get("spec") or {}).get("driver") == args.driver
        and (resource_slice.get("spec") or {}).get("nodeName")
        == args.target_node
        and resource_slice_devices(resource_slice)
    ]
    if len(matching_slices) != 1:
        raise ValidationError(
            "NVIDIA DRA driver must publish exactly one non-empty "
            "ResourceSlice for the single-A100 target"
        )
    pool = (matching_slices[0].get("spec") or {}).get("pool") or {}
    if not pool.get("name") or int(pool.get("resourceSliceCount") or 0) != 1:
        raise ValidationError(
            "single-A100 ResourceSlice pool is incomplete or split unexpectedly"
        )

    summary = {
        "status": "PASS",
        "target_node": args.target_node,
        "provider_id": spec.get("providerID"),
        "gpu_product": product,
        "source_profile": args.source_profile,
        "mig_strategy": labels.get("nvidia.com/mig.strategy"),
        "dra_node_selector": {
            "key": args.dra_node_label_key,
            "value": args.dra_node_label_value,
        },
        "device_class": args.device_class,
        "dra_driver": args.driver,
        "legacy_device_plugin_resources": [],
        "resource_slice_names": [
            (item.get("metadata") or {}).get("name") for item in matching_slices
        ],
        "advertised_device_count": sum(
            len(resource_slice_devices(item)) for item in matching_slices
        ),
        "blocking_pods": [],
    }
    atomic_json(Path(args.output), summary)


def render_claim(args: argparse.Namespace) -> None:
    if not ULID_RE.fullmatch(args.run_id):
        raise ValidationError("--run-id must be a canonical ULID")
    manifest = {
        "apiVersion": "resource.k8s.io/v1",
        "kind": "ResourceClaim",
        "metadata": {
            "namespace": args.namespace,
            "name": args.name,
            "annotations": {"hooke.io/run-id": args.run_id},
            "labels": {
                "hooke.io/experiment": "e09",
                "hooke.io/run-id": args.run_id,
            },
        },
        "spec": {
            "devices": {
                "requests": [
                    {
                        "name": "gpu",
                        "exactly": {"deviceClassName": args.device_class},
                    }
                ]
            }
        },
    }
    atomic_json(Path(args.output), manifest)


def downward_env(name: str, field_path: str) -> dict[str, Any]:
    return {
        "name": name,
        "valueFrom": {"fieldRef": {"fieldPath": field_path}},
    }


def render_probe(args: argparse.Namespace) -> None:
    if not ULID_RE.fullmatch(args.run_id):
        raise ValidationError("--run-id must be a canonical ULID")
    if not IMMUTABLE_IMAGE_RE.fullmatch(args.image):
        raise ValidationError("--image must be repository@sha256:...")
    tolerations: list[dict[str, Any]] = []
    if args.taint_key:
        toleration: dict[str, Any] = {
            "key": args.taint_key,
            "operator": "Exists" if not args.taint_value else "Equal",
            "effect": args.taint_effect,
        }
        if args.taint_value:
            toleration["value"] = args.taint_value
        tolerations.append(toleration)
    manifest = {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "namespace": args.namespace,
            "name": args.name,
            "annotations": {"hooke.io/run-id": args.run_id},
            "labels": {
                "hooke.io/experiment": "e09",
                "hooke.io/run-id": args.run_id,
                "hooke.io/e09-role": "cuda-probe",
            },
        },
        "spec": {
            "restartPolicy": "Never",
            "nodeSelector": {"kubernetes.io/hostname": args.target_node},
            "tolerations": tolerations,
            "resourceClaims": [
                {"name": "gpu", "resourceClaimName": args.claim_name}
            ],
            "containers": [
                {
                    "name": "cuda-probe",
                    "image": args.image,
                    "imagePullPolicy": "IfNotPresent",
                    "resources": {"claims": [{"name": "gpu"}]},
                    "env": [
                        {"name": "HOOKE_CLUSTER_ID", "value": args.cluster_id},
                        {"name": "HOOKE_RUN_ID", "value": args.run_id},
                        {"name": "HOOKE_CONTAINER_NAME", "value": "cuda-probe"},
                        {"name": "HOOKE_WORKLOAD_KIND", "value": "Pod"},
                        {"name": "HOOKE_WORKLOAD_NAME", "value": args.name},
                        {
                            "name": "HOOKE_RESOURCE_CLAIM_NAME",
                            "value": args.claim_name,
                        },
                        {
                            "name": "HOOKE_RESOURCE_CLAIM_UID",
                            "value": args.claim_uid,
                        },
                        {
                            "name": "HOOKE_DEVICE_CLASS",
                            "value": args.device_class,
                        },
                        downward_env("POD_NAMESPACE", "metadata.namespace"),
                        downward_env("POD_NAME", "metadata.name"),
                        downward_env("POD_UID", "metadata.uid"),
                        downward_env("NODE_NAME", "spec.nodeName"),
                        downward_env("HOOKE_WORKLOAD_UID", "metadata.uid"),
                    ],
                    "securityContext": {
                        "allowPrivilegeEscalation": False,
                        "capabilities": {"drop": ["ALL"]},
                        "readOnlyRootFilesystem": True,
                    },
                    "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}],
                }
            ],
            "volumes": [{"name": "tmp", "emptyDir": {}}],
        },
    }
    atomic_json(Path(args.output), manifest)


def attributes(item: dict[str, Any]) -> dict[str, Any]:
    value = item.get("attributes")
    return value if isinstance(value, dict) else {}


def select_events(
    events: Iterable[dict[str, Any]],
    event_type: str,
    predicate: Any | None = None,
) -> list[dict[str, Any]]:
    output = [
        item
        for item in events
        if item.get("event_type") == event_type
        and (predicate is None or predicate(item))
    ]
    return sorted(output, key=lambda item: int(item.get("event_time_ns") or 0))


def require_event(
    events: Iterable[dict[str, Any]],
    event_type: str,
    predicate: Any | None = None,
) -> dict[str, Any]:
    matching = select_events(events, event_type, predicate)
    if not matching:
        raise ValidationError(f"missing required event {event_type}")
    return matching[0]


def claim_request_classes(claim: dict[str, Any]) -> list[str]:
    output: set[str] = set()
    requests = (
        (((claim.get("spec") or {}).get("devices") or {}).get("requests")) or []
    )
    for request in requests:
        if not isinstance(request, dict):
            continue
        exactly = request.get("exactly") or {}
        if exactly.get("deviceClassName"):
            output.add(str(exactly["deviceClassName"]))
        if request.get("deviceClassName"):
            output.add(str(request["deviceClassName"]))
    return sorted(output)


def claim_allocations(claim: dict[str, Any]) -> list[dict[str, str]]:
    results = (
        (((claim.get("status") or {}).get("allocation") or {}).get("devices") or {})
        .get("results")
        or []
    )
    output: list[dict[str, str]] = []
    for result in results:
        if not isinstance(result, dict):
            continue
        allocation = {
            key: str(result.get(key) or "")
            for key in ("request", "driver", "pool", "device", "shareID")
        }
        if not all(allocation[key] for key in ("driver", "pool", "device")):
            continue
        output.append(allocation)
    return sorted(
        output,
        key=lambda item: (
            item["driver"],
            item["pool"],
            item["device"],
            item["shareID"],
        ),
    )


def claim_reserved_for_pod(
    claim: dict[str, Any], pod_name: str, pod_uid: str
) -> bool:
    return any(
        str(reference.get("apiGroup") or "") == ""
        and reference.get("resource") == "pods"
        and reference.get("name") == pod_name
        and reference.get("uid") == pod_uid
        for reference in (claim.get("status") or {}).get("reservedFor") or []
        if isinstance(reference, dict)
    )


def pod_claim_link(pod: dict[str, Any], claim_name: str) -> bool:
    pod_claims = (pod.get("spec") or {}).get("resourceClaims") or []
    container_claims = {
        str(claim.get("name") or "")
        for container in (pod.get("spec") or {}).get("containers") or []
        for claim in ((container.get("resources") or {}).get("claims") or [])
        if isinstance(claim, dict)
    }
    return any(
        reference.get("name") in container_claims
        and reference.get("resourceClaimName") == claim_name
        for reference in pod_claims
        if isinstance(reference, dict)
    )


def node_labels(node: dict[str, Any]) -> dict[str, str]:
    labels = (node.get("metadata") or {}).get("labels") or {}
    return {str(key): str(value) for key, value in labels.items()}


def identifier_compact(value: str) -> str:
    return re.sub(r"[^0-9a-f]", "", value.lower())


def summarize(args: argparse.Namespace) -> None:
    events = load_ndjson(Path(args.events))
    claim = load_json(Path(args.claim))
    pod = load_json(Path(args.pod))
    node_before = load_json(Path(args.node_before))
    node_after = load_json(Path(args.node_after))
    resource_slices = load_json(Path(args.resource_slices))
    if not events:
        raise ValidationError("event export is empty")
    if any(item.get("run_id") != args.run_id for item in events):
        raise ValidationError("event export contains another run_id")
    if select_events(events, "MIG_RESHAPE_FAILED"):
        raise ValidationError("MIG_RESHAPE_FAILED was observed")

    claim_metadata = claim.get("metadata") or {}
    pod_metadata = pod.get("metadata") or {}
    pod_status = pod.get("status") or {}
    claim_name = str(claim_metadata.get("name") or "")
    claim_uid = str(claim_metadata.get("uid") or "")
    pod_name = str(pod_metadata.get("name") or "")
    pod_uid = str(pod_metadata.get("uid") or "")
    if claim_uid != args.claim_uid or pod_uid != args.pod_uid:
        raise ValidationError("frozen Claim or Pod UID does not match final object")
    if args.device_class not in claim_request_classes(claim):
        raise ValidationError("ResourceClaim does not request the frozen DeviceClass")
    allocations = claim_allocations(claim)
    if not allocations:
        raise ValidationError("ResourceClaim has no device allocation results")
    if len(allocations) != 1:
        raise ValidationError("E09 must allocate exactly one DRA device")
    if not claim_reserved_for_pod(claim, pod_name, pod_uid):
        raise ValidationError("ResourceClaim is not reserved for the exact probe Pod UID")
    if not pod_claim_link(pod, claim_name):
        raise ValidationError("probe container is not linked to the ResourceClaim")
    if pod_status.get("phase") != "Succeeded":
        raise ValidationError("CUDA probe Pod did not succeed")
    if (pod.get("spec") or {}).get("nodeName") != args.target_node:
        raise ValidationError("CUDA probe Pod ran on an unexpected node")
    if any(
        int(status.get("restartCount") or 0) != 0
        for status in pod_status.get("containerStatuses") or []
    ):
        raise ValidationError("CUDA probe container restarted")

    before_labels = node_labels(node_before)
    after_labels = node_labels(node_after)
    if before_labels.get("nvidia.com/mig.config") != args.source_profile:
        raise ValidationError("node-before does not preserve the source MIG profile")
    if (
        after_labels.get("nvidia.com/mig.config") != args.target_profile
        or after_labels.get("nvidia.com/mig.config.state") != "success"
    ):
        raise ValidationError("node-after does not prove successful target MIG state")

    claim_predicate = lambda item: attributes(item).get("claim_uid") == claim_uid
    pod_predicate = lambda item: item.get("pod_uid") == pod_uid
    requested = require_event(
        events,
        "MIG_RESHAPE_REQUESTED",
        lambda item: item.get("node_name") == args.target_node
        and attributes(item).get("previous_mig_profile") == args.source_profile
        and attributes(item).get("requested_mig_profile") == args.target_profile,
    )
    started = require_event(
        events,
        "MIG_RESHAPE_STARTED",
        lambda item: item.get("node_name") == args.target_node
        and attributes(item).get("mig_profile") == args.target_profile,
    )
    finished = require_event(
        events,
        "MIG_RESHAPE_FINISHED",
        lambda item: item.get("node_name") == args.target_node
        and attributes(item).get("mig_profile") == args.target_profile
        and attributes(item).get("mig_config_state") == "success",
    )
    request_id = str(attributes(requested).get("mig_request_id") or "")
    if not request_id or any(
        str(attributes(item).get("mig_request_id") or "") != request_id
        for item in (started, finished)
    ):
        raise ValidationError("MIG lifecycle does not carry one stable request ID")
    created = require_event(events, "RESOURCE_CLAIM_CREATED", claim_predicate)
    allocated = require_event(events, "RESOURCE_CLAIM_ALLOCATED", claim_predicate)
    reserved = require_event(
        events,
        "RESOURCE_CLAIM_RESERVED",
        lambda item: claim_predicate(item) and item.get("pod_uid") == pod_uid,
    )
    scheduled = require_event(events, "POD_SCHEDULED", pod_predicate)
    container_started = require_event(events, "CONTAINER_STARTED", pod_predicate)
    cuda = require_event(events, "FIRST_CUDA_SUCCESS", pod_predicate)
    require_event(
        events,
        "DRA_DEVICECLASS_AVAILABLE",
        lambda item: attributes(item).get("device_class_name")
        == args.device_class,
    )
    slice_events = select_events(
        events,
        "DRA_RESOURCESLICE_PUBLISHED",
        lambda item: attributes(item).get("driver") == args.driver
        and attributes(item).get("node_name") == args.target_node
        and int(attributes(item).get("device_count") or 0) > 0,
    )
    if not slice_events:
        raise ValidationError(
            "missing target NVIDIA DRA_RESOURCESLICE_PUBLISHED event"
        )

    cuda_attributes = attributes(cuda)
    if (
        cuda_attributes.get("resource_claim_uid") != claim_uid
        or cuda_attributes.get("resource_claim_name") != claim_name
        or cuda_attributes.get("device_class") != args.device_class
    ):
        raise ValidationError("CUDA event does not carry the exact Claim identity")
    if int(cuda_attributes.get("cuda_visible_device_count") or 0) != 1:
        raise ValidationError("CUDA probe did not observe exactly one visible device")
    cuda_uuid = str(cuda_attributes.get("cuda_device_uuid") or "")
    if not re.fullmatch(
        r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}",
        cuda_uuid,
    ):
        raise ValidationError("CUDA probe did not record a valid device UUID")
    if int(cuda_attributes.get("verified_allocation_bytes") or 0) <= 0:
        raise ValidationError("CUDA probe did not verify device memory operations")

    slice_devices_by_key: dict[tuple[str, str, str], dict[str, str]] = {}
    target_slices = [
        resource_slice
        for resource_slice in resource_slices.get("items") or []
        if (resource_slice.get("spec") or {}).get("driver") == args.driver
        and (resource_slice.get("spec") or {}).get("nodeName")
        == args.target_node
    ]
    if len(target_slices) != 1:
        raise ValidationError(
            "post-reshape snapshot must contain one target NVIDIA ResourceSlice"
        )
    target_pool = (target_slices[0].get("spec") or {}).get("pool") or {}
    if (
        not target_pool.get("name")
        or int(target_pool.get("resourceSliceCount") or 0) != 1
    ):
        raise ValidationError("post-reshape ResourceSlice pool is incomplete")
    for resource_slice in target_slices:
        spec = resource_slice.get("spec") or {}
        pool_name = str((spec.get("pool") or {}).get("name") or "")
        for device in resource_slice_device_records(resource_slice):
            slice_devices_by_key[
                (str(spec.get("driver") or ""), pool_name, device["name"])
            ] = device
    allocated_device_keys = {
        (item["driver"], item["pool"], item["device"]) for item in allocations
    }
    if not allocated_device_keys.issubset(slice_devices_by_key):
        raise ValidationError(
            "allocated device is absent from the post-reshape ResourceSlice snapshot"
        )
    allocation_device_records = {
        key: slice_devices_by_key[key] for key in allocated_device_keys
    }
    if any(
        record.get("type") != "mig"
        for record in allocation_device_records.values()
    ):
        raise ValidationError("allocated ResourceSlice device is not a MIG device")
    allocation_device_uuids = {
        key: record.get("uuid", "")
        for key, record in allocation_device_records.items()
    }
    if any(not value for value in allocation_device_uuids.values()):
        raise ValidationError(
            "allocated ResourceSlice device does not publish a UUID attribute"
        )

    event_times = {
        "reshape_requested": int(requested["event_time_ns"]),
        "reshape_started": int(started["event_time_ns"]),
        "reshape_finished": int(finished["event_time_ns"]),
        "claim_created": int(created["event_time_ns"]),
        "claim_allocated": int(allocated["event_time_ns"]),
        "claim_reserved_observed": int(reserved["event_time_ns"]),
        "pod_scheduled": int(scheduled["event_time_ns"]),
        "container_started": int(container_started["event_time_ns"]),
        "first_cuda_success": int(cuda["event_time_ns"]),
    }
    post_reshape_slice = next(
        (
            item
            for item in slice_events
            if int(item.get("event_time_ns") or 0)
            >= event_times["reshape_finished"] - args.max_clock_skew_ns
        ),
        None,
    )
    if post_reshape_slice is None:
        raise ValidationError(
            "no non-empty NVIDIA ResourceSlice was observed after the reshape"
        )
    event_times["post_reshape_resource_slice"] = int(
        post_reshape_slice["event_time_ns"]
    )
    ordered = (
        event_times["reshape_requested"]
        <= event_times["reshape_started"] + args.max_clock_skew_ns
        and event_times["reshape_started"]
        <= event_times["reshape_finished"] + args.max_clock_skew_ns
        and event_times["reshape_finished"]
        <= event_times["claim_created"] + args.max_clock_skew_ns
        and event_times["claim_created"]
        <= event_times["claim_allocated"] + args.max_clock_skew_ns
        and event_times["claim_allocated"]
        <= event_times["first_cuda_success"] + args.max_clock_skew_ns
        and event_times["pod_scheduled"]
        <= event_times["container_started"] + args.max_clock_skew_ns
        and event_times["container_started"]
        <= event_times["first_cuda_success"] + args.max_clock_skew_ns
    )
    if not ordered:
        raise ValidationError("GPU/DRA lifecycle timestamps are not causally ordered")

    prepared_events = select_events(
        events, "RESOURCE_CLAIM_PREPARED", claim_predicate
    )
    prepared_source = (
        "resourceclaim-device-ready-condition"
        if prepared_events
        else "first-cuda-success-upper-bound"
    )
    cuda_compact = identifier_compact(cuda_uuid)
    allocation_uuid_match = any(
        cuda_compact
        and cuda_compact == identifier_compact(resource_slice_uuid)
        for resource_slice_uuid in allocation_device_uuids.values()
    )
    if not allocation_uuid_match:
        raise ValidationError(
            "allocated ResourceSlice UUID does not match the CUDA-visible UUID"
        )
    serialized_allocation_uuids = {
        "/".join(key): value
        for key, value in sorted(allocation_device_uuids.items())
    }
    seconds = lambda end, start: round(
        (event_times[end] - event_times[start]) / 1_000_000_000, 9
    )
    summary = {
        "status": "PASS",
        "scope": "single-A100 functional smoke",
        "run_id": args.run_id,
        "target_node": args.target_node,
        "source_profile": args.source_profile,
        "target_profile": args.target_profile,
        "device_class": args.device_class,
        "claim": {"name": claim_name, "uid": claim_uid},
        "pod": {"name": pod_name, "uid": pod_uid},
        "allocation_results": allocations,
        "allocation_device_uuids": serialized_allocation_uuids,
        "cuda_device_uuid": cuda_uuid,
        "claim_to_pod_to_cuda_uuid_correlated": True,
        "allocation_device_uuid_matches_cuda_uuid": allocation_uuid_match,
        "prepared_boundary": prepared_source,
        "resourceclaim_ready_condition_observed": bool(prepared_events),
        "timestamps_ns": event_times,
        "durations_seconds": {
            "reshape_request_to_finish": seconds(
                "reshape_finished", "reshape_requested"
            ),
            "claim_create_to_allocate": seconds(
                "claim_allocated", "claim_created"
            ),
            "allocation_to_first_cuda": seconds(
                "first_cuda_success", "claim_allocated"
            ),
            "reshape_request_to_first_cuda": seconds(
                "first_cuda_success", "reshape_requested"
            ),
        },
        "precision": {
            "reshape_requested": attributes(requested).get("precision"),
            "reshape_started": attributes(started).get("precision"),
            "reshape_finished": attributes(finished).get("precision"),
            "claim_allocated": attributes(allocated).get("precision"),
            "first_cuda_success": cuda_attributes.get("precision"),
        },
        "limitations": [
            "one physical GPU proves only functional integration",
            "MIG Manager reshape and DRA allocation are separate mechanisms",
            "this smoke does not establish multi-node elasticity or tail latency",
        ],
    }
    atomic_json(Path(args.output), summary)
    report = f"""# E09 GPU/DRA/MIG smoke

Status: **PASS**

- Run: `{args.run_id}`
- Target: `{args.target_node}`
- MIG profile: `{args.source_profile}` → `{args.target_profile}`
- ResourceClaim: `{claim_name}` (`{claim_uid}`)
- Probe Pod: `{pod_name}` (`{pod_uid}`)
- CUDA device UUID: `{cuda_uuid}`
- Preparation boundary: `{prepared_source}`
- Reshape request → finish: `{summary['durations_seconds']['reshape_request_to_finish']}` s
- Claim create → allocation: `{summary['durations_seconds']['claim_create_to_allocate']}` s
- Allocation → first CUDA success: `{summary['durations_seconds']['allocation_to_first_cuda']}` s

This is a single-A100 functional smoke. It proves the real MIG Manager,
`resource.k8s.io/v1` allocation, exact Claim→Pod UID linkage, and a successful
CUDA memory operation. It does not prove multi-node behavior, p95/p99, or that
DRA itself dynamically reshaped MIG.
"""
    atomic_text(Path(args.report), report)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subparsers = root.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser("check-preflight")
    preflight.add_argument("--nodes", required=True)
    preflight.add_argument("--pods", required=True)
    preflight.add_argument("--device-classes", required=True)
    preflight.add_argument("--resource-slices", required=True)
    preflight.add_argument("--target-node", required=True)
    preflight.add_argument("--source-profile", required=True)
    preflight.add_argument("--device-class", default="mig.nvidia.com")
    preflight.add_argument("--driver", default="gpu.nvidia.com")
    preflight.add_argument(
        "--dra-node-label-key", default="nvidia.com/dra-kubelet-plugin"
    )
    preflight.add_argument("--dra-node-label-value", default="true")
    preflight.add_argument("--product-regex", default=r"\bA100\b")
    preflight.add_argument("--output", required=True)
    preflight.set_defaults(function=check_preflight)

    claim = subparsers.add_parser("render-claim")
    claim.add_argument("--namespace", required=True)
    claim.add_argument("--name", required=True)
    claim.add_argument("--run-id", required=True)
    claim.add_argument("--device-class", default="mig.nvidia.com")
    claim.add_argument("--output", required=True)
    claim.set_defaults(function=render_claim)

    probe = subparsers.add_parser("render-probe")
    probe.add_argument("--namespace", required=True)
    probe.add_argument("--name", required=True)
    probe.add_argument("--cluster-id", required=True)
    probe.add_argument("--run-id", required=True)
    probe.add_argument("--image", required=True)
    probe.add_argument("--target-node", required=True)
    probe.add_argument("--claim-name", required=True)
    probe.add_argument("--claim-uid", required=True)
    probe.add_argument("--device-class", default="mig.nvidia.com")
    probe.add_argument("--taint-key", default="nvidia.com/gpu")
    probe.add_argument("--taint-value", default="")
    probe.add_argument("--taint-effect", default="NoSchedule")
    probe.add_argument("--output", required=True)
    probe.set_defaults(function=render_probe)

    summary = subparsers.add_parser("summarize")
    summary.add_argument("--events", required=True)
    summary.add_argument("--claim", required=True)
    summary.add_argument("--pod", required=True)
    summary.add_argument("--node-before", required=True)
    summary.add_argument("--node-after", required=True)
    summary.add_argument("--resource-slices", required=True)
    summary.add_argument("--run-id", required=True)
    summary.add_argument("--claim-uid", required=True)
    summary.add_argument("--pod-uid", required=True)
    summary.add_argument("--target-node", required=True)
    summary.add_argument("--source-profile", required=True)
    summary.add_argument("--target-profile", required=True)
    summary.add_argument("--device-class", default="mig.nvidia.com")
    summary.add_argument("--driver", default="gpu.nvidia.com")
    summary.add_argument("--max-clock-skew-ns", type=int, default=2_000_000_000)
    summary.add_argument("--output", required=True)
    summary.add_argument("--report", required=True)
    summary.set_defaults(function=summarize)
    return root


def main() -> int:
    args = parser().parse_args()
    args.function(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValidationError, json.JSONDecodeError) as exc:
        print(f"e09-gpu-dra-mig: {exc}", file=sys.stderr)
        raise SystemExit(1)
