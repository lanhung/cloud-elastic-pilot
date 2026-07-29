import argparse
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "e09-gpu-dra-mig.py"
SPEC = importlib.util.spec_from_file_location("e09_gpu_dra_mig", SCRIPT)
assert SPEC and SPEC.loader
e09 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = e09
SPEC.loader.exec_module(e09)

RUN_ID = "01J00000000000000000000000"
CLAIM_UID = "11111111-1111-1111-1111-111111111111"
POD_UID = "22222222-2222-2222-2222-222222222222"
CUDA_UUID = "12345678-1234-1234-1234-1234567890ab"
DEVICE_NAME = "mig-" + CUDA_UUID
IMAGE = "registry.example.com/hooke/e09-probe@sha256:" + "a" * 64


def write_json(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def node(profile):
    return {
        "metadata": {
            "name": "gpu-node",
            "labels": {
                "nvidia.com/mig.capable": "true",
                "nvidia.com/mig.config": profile,
                "nvidia.com/mig.config.state": "success",
                "nvidia.com/mig.strategy": "single",
                "nvidia.com/gpu.product": "NVIDIA A100-SXM4-40GB",
                "nvidia.com/dra-kubelet-plugin": "true",
            },
        },
        "spec": {
            "providerID": "aliyun:///i-gpu",
            "nodeName": "gpu-node",
        },
        "status": {
            "conditions": [{"type": "Ready", "status": "True"}],
            "allocatable": {},
        },
    }


def resource_slices():
    return {
        "items": [
            {
                "metadata": {"name": "gpu-node-slice"},
                "spec": {
                    "driver": "gpu.nvidia.com",
                    "nodeName": "gpu-node",
                    "pool": {
                        "name": "gpu-node",
                        "generation": 1,
                        "resourceSliceCount": 1,
                    },
                    "devices": [
                        {
                            "name": DEVICE_NAME,
                            "attributes": {
                                "uuid": {"string": "MIG-" + CUDA_UUID},
                                "type": {"string": "mig"},
                                "profile": {"string": "1g.5gb"},
                            },
                        }
                    ],
                },
            }
        ]
    }


def final_claim():
    return {
        "apiVersion": "resource.k8s.io/v1",
        "kind": "ResourceClaim",
        "metadata": {
            "namespace": "e09",
            "name": "mig",
            "uid": CLAIM_UID,
        },
        "spec": {
            "devices": {
                "requests": [
                    {
                        "name": "gpu",
                        "exactly": {"deviceClassName": "mig.nvidia.com"},
                    }
                ]
            }
        },
        "status": {
            "allocation": {
                "devices": {
                    "results": [
                        {
                            "request": "gpu",
                            "driver": "gpu.nvidia.com",
                            "pool": "gpu-node",
                            "device": DEVICE_NAME,
                        }
                    ]
                }
            },
            "reservedFor": [
                {
                    "resource": "pods",
                    "name": "probe",
                    "uid": POD_UID,
                }
            ],
        },
    }


def final_pod():
    return {
        "metadata": {
            "namespace": "e09",
            "name": "probe",
            "uid": POD_UID,
        },
        "spec": {
            "nodeName": "gpu-node",
            "resourceClaims": [
                {"name": "gpu", "resourceClaimName": "mig"}
            ],
            "containers": [
                {
                    "name": "cuda-probe",
                    "resources": {"claims": [{"name": "gpu"}]},
                }
            ],
        },
        "status": {
            "phase": "Succeeded",
            "containerStatuses": [{"name": "cuda-probe", "restartCount": 0}],
        },
    }


def event(event_type, at, **values):
    item = {
        "run_id": RUN_ID,
        "event_type": event_type,
        "event_time_ns": at,
        "attributes": {},
    }
    item.update(values)
    return item


def passing_events():
    claim_attributes = {"claim_uid": CLAIM_UID}
    return [
        event(
            "DRA_DEVICECLASS_AVAILABLE",
            500_000_000,
            attributes={"device_class_name": "mig.nvidia.com"},
        ),
        event(
            "MIG_RESHAPE_REQUESTED",
            1_000_000_000,
            node_name="gpu-node",
            attributes={
                "precision": "runner-request-annotation",
                "previous_mig_profile": "all-disabled",
                "requested_mig_profile": "all-1g.5gb",
                "mig_request_id": "request-1",
            },
        ),
        event(
            "MIG_RESHAPE_STARTED",
            2_000_000_000,
            node_name="gpu-node",
            attributes={
                "precision": "mig-manager-node-label-observation",
                "mig_profile": "all-1g.5gb",
                "mig_config_state": "pending",
                "mig_request_id": "request-1",
            },
        ),
        event(
            "MIG_RESHAPE_FINISHED",
            3_000_000_000,
            node_name="gpu-node",
            attributes={
                "precision": "mig-manager-node-label-observation",
                "mig_profile": "all-1g.5gb",
                "mig_config_state": "success",
                "mig_request_id": "request-1",
            },
        ),
        event(
            "DRA_RESOURCESLICE_PUBLISHED",
            3_500_000_000,
            attributes={
                "driver": "gpu.nvidia.com",
                "node_name": "gpu-node",
                "device_count": 7,
            },
        ),
        event(
            "RESOURCE_CLAIM_CREATED",
            4_000_000_000,
            attributes=claim_attributes,
        ),
        event(
            "RESOURCE_CLAIM_ALLOCATED",
            5_000_000_000,
            attributes={
                **claim_attributes,
                "precision": "resourceclaim-status-allocationTimestamp",
            },
        ),
        event(
            "RESOURCE_CLAIM_RESERVED",
            5_500_000_000,
            pod_uid=POD_UID,
            attributes=claim_attributes,
        ),
        event("POD_SCHEDULED", 6_000_000_000, pod_uid=POD_UID),
        event("CONTAINER_STARTED", 7_000_000_000, pod_uid=POD_UID),
        event(
            "FIRST_CUDA_SUCCESS",
            8_000_000_000,
            pod_uid=POD_UID,
            attributes={
                "resource_claim_uid": CLAIM_UID,
                "resource_claim_name": "mig",
                "device_class": "mig.nvidia.com",
                "cuda_visible_device_count": 1,
                "cuda_device_uuid": CUDA_UUID,
                "verified_allocation_bytes": 4096,
                "precision": "cuda-device-synchronize-source-timestamp",
            },
        ),
    ]


class E09GPUDRAMIGTest(unittest.TestCase):
    def test_render_claim_uses_stable_v1_exactly_request(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "claim.json"
            e09.render_claim(
                argparse.Namespace(
                    namespace="e09",
                    name="mig",
                    run_id=RUN_ID,
                    device_class="mig.nvidia.com",
                    output=str(output),
                )
            )
            manifest = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(manifest["apiVersion"], "resource.k8s.io/v1")
        request = manifest["spec"]["devices"]["requests"][0]
        self.assertEqual(
            request["exactly"]["deviceClassName"], "mig.nvidia.com"
        )
        self.assertEqual(
            manifest["metadata"]["annotations"]["hooke.io/run-id"], RUN_ID
        )

    def test_render_probe_links_container_claim_and_downward_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "pod.json"
            e09.render_probe(
                argparse.Namespace(
                    namespace="e09",
                    name="probe",
                    cluster_id="cluster",
                    run_id=RUN_ID,
                    image=IMAGE,
                    target_node="gpu-node",
                    claim_name="mig",
                    claim_uid=CLAIM_UID,
                    device_class="mig.nvidia.com",
                    taint_key="nvidia.com/gpu",
                    taint_value="",
                    taint_effect="NoSchedule",
                    output=str(output),
                )
            )
            manifest = json.loads(output.read_text(encoding="utf-8"))
        spec = manifest["spec"]
        self.assertEqual(
            spec["resourceClaims"][0]["resourceClaimName"], "mig"
        )
        self.assertEqual(
            spec["containers"][0]["resources"]["claims"][0]["name"], "gpu"
        )
        env = {
            value["name"]: value for value in spec["containers"][0]["env"]
        }
        self.assertEqual(env["HOOKE_RESOURCE_CLAIM_UID"]["value"], CLAIM_UID)
        self.assertEqual(
            env["POD_UID"]["valueFrom"]["fieldRef"]["fieldPath"],
            "metadata.uid",
        )
        self.assertTrue(
            spec["containers"][0]["securityContext"]["readOnlyRootFilesystem"]
        )

    def test_preflight_accepts_dedicated_physical_a100(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_json(root / "nodes.json", {"items": [node("all-disabled")]})
            write_json(
                root / "pods.json",
                {
                    "items": [
                        {
                            "metadata": {
                                "namespace": "gpu-operator",
                                "name": "mig-manager",
                                "ownerReferences": [
                                    {
                                        "kind": "DaemonSet",
                                        "name": "mig-manager",
                                        "controller": True,
                                    }
                                ],
                            },
                            "spec": {"nodeName": "gpu-node"},
                            "status": {"phase": "Running"},
                        }
                    ]
                },
            )
            write_json(
                root / "classes.json",
                {"items": [{"metadata": {"name": "mig.nvidia.com"}}]},
            )
            write_json(root / "slices.json", resource_slices())
            output = root / "summary.json"
            e09.check_preflight(
                argparse.Namespace(
                    nodes=str(root / "nodes.json"),
                    pods=str(root / "pods.json"),
                    device_classes=str(root / "classes.json"),
                    resource_slices=str(root / "slices.json"),
                    target_node="gpu-node",
                    source_profile="all-disabled",
                    device_class="mig.nvidia.com",
                    driver="gpu.nvidia.com",
                    dra_node_label_key="nvidia.com/dra-kubelet-plugin",
                    dra_node_label_value="true",
                    product_regex=r"\bA100\b",
                    output=str(output),
                )
            )
            summary = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(summary["status"], "PASS")
        self.assertEqual(summary["advertised_device_count"], 1)

    def test_preflight_rejects_active_tenant_pod(self):
        nodes = {"items": [node("all-disabled")]}
        pods = {
            "items": [
                {
                    "metadata": {"namespace": "tenant", "name": "training"},
                    "spec": {"nodeName": "gpu-node"},
                    "status": {"phase": "Running"},
                }
            ]
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in (
                ("nodes.json", nodes),
                ("pods.json", pods),
                (
                    "classes.json",
                    {"items": [{"metadata": {"name": "mig.nvidia.com"}}]},
                ),
                ("slices.json", resource_slices()),
            ):
                write_json(root / name, value)
            with self.assertRaisesRegex(e09.ValidationError, "not dedicated"):
                e09.check_preflight(
                    argparse.Namespace(
                        nodes=str(root / "nodes.json"),
                        pods=str(root / "pods.json"),
                        device_classes=str(root / "classes.json"),
                        resource_slices=str(root / "slices.json"),
                        target_node="gpu-node",
                        source_profile="all-disabled",
                        device_class="mig.nvidia.com",
                        driver="gpu.nvidia.com",
                        dra_node_label_key="nvidia.com/dra-kubelet-plugin",
                        dra_node_label_value="true",
                        product_regex=r"\bA100\b",
                        output=str(root / "summary.json"),
                    )
                )

    def test_preflight_rejects_legacy_device_plugin_resources(self):
        target = node("all-disabled")
        target["status"]["allocatable"]["nvidia.com/gpu"] = "1"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in (
                ("nodes.json", {"items": [target]}),
                ("pods.json", {"items": []}),
                (
                    "classes.json",
                    {"items": [{"metadata": {"name": "mig.nvidia.com"}}]},
                ),
                ("slices.json", resource_slices()),
            ):
                write_json(root / name, value)
            with self.assertRaisesRegex(
                e09.ValidationError, "Device Plugin resources"
            ):
                e09.check_preflight(
                    argparse.Namespace(
                        nodes=str(root / "nodes.json"),
                        pods=str(root / "pods.json"),
                        device_classes=str(root / "classes.json"),
                        resource_slices=str(root / "slices.json"),
                        target_node="gpu-node",
                        source_profile="all-disabled",
                        device_class="mig.nvidia.com",
                        driver="gpu.nvidia.com",
                        dra_node_label_key="nvidia.com/dra-kubelet-plugin",
                        dra_node_label_value="true",
                        product_regex=r"\bA100\b",
                        output=str(root / "summary.json"),
                    )
                )

    def test_summary_requires_and_correlates_real_lifecycle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            events = root / "events.ndjson"
            events.write_text(
                "".join(json.dumps(item) + "\n" for item in passing_events()),
                encoding="utf-8",
            )
            for name, value in (
                ("claim.json", final_claim()),
                ("pod.json", final_pod()),
                ("before.json", node("all-disabled")),
                ("after.json", node("all-1g.5gb")),
                ("slices.json", resource_slices()),
            ):
                write_json(root / name, value)
            output = root / "summary.json"
            report = root / "report.md"
            e09.summarize(
                argparse.Namespace(
                    events=str(events),
                    claim=str(root / "claim.json"),
                    pod=str(root / "pod.json"),
                    node_before=str(root / "before.json"),
                    node_after=str(root / "after.json"),
                    resource_slices=str(root / "slices.json"),
                    run_id=RUN_ID,
                    claim_uid=CLAIM_UID,
                    pod_uid=POD_UID,
                    target_node="gpu-node",
                    source_profile="all-disabled",
                    target_profile="all-1g.5gb",
                    device_class="mig.nvidia.com",
                    driver="gpu.nvidia.com",
                    max_clock_skew_ns=0,
                    output=str(output),
                    report=str(report),
                )
            )
            summary = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(summary["status"], "PASS")
        self.assertTrue(summary["claim_to_pod_to_cuda_uuid_correlated"])
        self.assertTrue(summary["allocation_device_uuid_matches_cuda_uuid"])
        self.assertEqual(
            summary["prepared_boundary"], "first-cuda-success-upper-bound"
        )
        self.assertEqual(
            summary["durations_seconds"]["reshape_request_to_first_cuda"], 7.0
        )

    def test_summary_fails_without_cuda_success(self):
        events = [
            item
            for item in passing_events()
            if item["event_type"] != "FIRST_CUDA_SUCCESS"
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "events.ndjson").write_text(
                "".join(json.dumps(item) + "\n" for item in events),
                encoding="utf-8",
            )
            for name, value in (
                ("claim.json", final_claim()),
                ("pod.json", final_pod()),
                ("before.json", node("all-disabled")),
                ("after.json", node("all-1g.5gb")),
                ("slices.json", resource_slices()),
            ):
                write_json(root / name, value)
            with self.assertRaisesRegex(
                e09.ValidationError, "FIRST_CUDA_SUCCESS"
            ):
                e09.summarize(
                    argparse.Namespace(
                        events=str(root / "events.ndjson"),
                        claim=str(root / "claim.json"),
                        pod=str(root / "pod.json"),
                        node_before=str(root / "before.json"),
                        node_after=str(root / "after.json"),
                        resource_slices=str(root / "slices.json"),
                        run_id=RUN_ID,
                        claim_uid=CLAIM_UID,
                        pod_uid=POD_UID,
                        target_node="gpu-node",
                        source_profile="all-disabled",
                        target_profile="all-1g.5gb",
                        device_class="mig.nvidia.com",
                        driver="gpu.nvidia.com",
                        max_clock_skew_ns=0,
                        output=str(root / "summary.json"),
                        report=str(root / "report.md"),
                    )
                )


if __name__ == "__main__":
    unittest.main()
