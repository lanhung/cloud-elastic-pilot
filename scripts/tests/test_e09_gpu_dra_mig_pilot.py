import argparse
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "e09-gpu-dra-mig-pilot.py"
SPEC = importlib.util.spec_from_file_location("e09_gpu_dra_mig_pilot", SCRIPT)
assert SPEC and SPEC.loader
pilot = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = pilot
SPEC.loader.exec_module(pilot)

RUN_ID = "01J00000000000000000000000"


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def node(name):
    return {
        "metadata": {
            "name": name,
            "labels": {
                "kubernetes.io/arch": "amd64",
                "hooke.io/pool": "gpu",
                "nvidia.com/mig.capable": "true",
                "nvidia.com/mig.config": "all-disabled",
                "nvidia.com/mig.config.state": "success",
                "nvidia.com/mig.strategy": "mixed",
                "nvidia.com/gpu.product": "NVIDIA A100-SXM4-80GB",
                "nvidia.com/dra-kubelet-plugin": "true",
                "nvidia.com/cuda.driver-version.full": "580.126.09",
            },
        },
        "spec": {"providerID": f"aliyun:///{name}"},
        "status": {
            "conditions": [{"type": "Ready", "status": "True"}],
            "allocatable": {},
        },
    }


def cpu_node():
    return {
        "metadata": {
            "name": "cpu",
            "labels": {
                "kubernetes.io/arch": "amd64",
                "hooke.io/pool": "fixed-cpu",
            },
        },
        "spec": {"providerID": "aliyun:///cpu"},
        "status": {
            "conditions": [{"type": "Ready", "status": "True"}],
        },
    }


def resource_slice(node_name, records):
    return {
        "metadata": {"name": f"{node_name}-slice"},
        "spec": {
            "driver": "gpu.nvidia.com",
            "nodeName": node_name,
            "pool": {
                "name": node_name,
                "generation": 1,
                "resourceSliceCount": 1,
            },
            "devices": [
                {
                    "name": record["name"],
                    "attributes": {
                        "type": {"string": record["type"]},
                        "profile": {"string": record.get("profile", "")},
                        "uuid": {"string": record["uuid"]},
                        "parentUUID": {
                            "string": record.get(
                                "parent_uuid",
                                "GPU-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                            )
                        },
                    },
                }
                for record in records
            ],
        },
    }


def source_slice(node_name):
    return resource_slice(
        node_name,
        [
            {
                "name": "gpu-0",
                "type": "gpu",
                "uuid": "GPU-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            }
        ],
    )


class E09GPUDRAMIGPilotTest(unittest.TestCase):
    def plan(self, root):
        output = root / "plan.json"
        pilot.make_plan(
            argparse.Namespace(
                node_a="gpu-a",
                node_b="gpu-b",
                static_config="all-balanced",
                profile_map=(
                    "1g.10gb=all-1g.10gb,3g.40gb=all-3g.40gb"
                ),
                sequence=(
                    "1g.10gb,1g.10gb,3g.40gb,"
                    "3g.40gb,1g.10gb,3g.40gb"
                ),
                batch_size=7,
                hold_seconds=45,
                admission_window_seconds=25,
                output=str(output),
            )
        )
        return json.loads(output.read_text(encoding="utf-8"))

    def test_plan_is_balanced_crossover_with_match_and_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = self.plan(Path(directory))
        self.assertEqual(len(plan["periods"]), 2)
        self.assertEqual(plan["periods"][0]["static_node"], "gpu-a")
        self.assertEqual(plan["periods"][1]["static_node"], "gpu-b")
        self.assertEqual(
            plan["repetitions_per_profile_per_period"]["1g.10gb"], 3
        )
        pattern = [
            trial["planned_dynamic_mismatch"]
            for trial in plan["periods"][0]["trials"]
        ]
        self.assertEqual(pattern, [False, False, True, False, True, True])

    def test_generated_run_id_is_canonical_ulid(self):
        import contextlib
        import io

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            pilot.new_run_id(argparse.Namespace())
        self.assertRegex(output.getvalue().strip(), pilot.ULID_RE)

    def test_preflight_requires_two_equivalent_physical_a100_nodes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_json(
                root / "nodes.json",
                {"items": [node("gpu-a"), node("gpu-b"), cpu_node()]},
            )
            write_json(
                root / "pods.json",
                {
                    "items": [
                        {
                            "metadata": {
                                "namespace": "gpu-operator",
                                "name": f"mig-manager-{name}",
                                "ownerReferences": [
                                    {
                                        "kind": "DaemonSet",
                                        "controller": True,
                                    }
                                ],
                            },
                            "spec": {"nodeName": name},
                            "status": {"phase": "Running"},
                        }
                        for name in ("gpu-a", "gpu-b")
                    ]
                },
            )
            write_json(
                root / "classes.json",
                {"items": [{"metadata": {"name": "mig.nvidia.com"}}]},
            )
            write_json(
                root / "slices.json",
                {"items": [source_slice("gpu-a"), source_slice("gpu-b")]},
            )
            output = root / "summary.json"
            pilot.check_preflight(
                argparse.Namespace(
                    nodes=str(root / "nodes.json"),
                    pods=str(root / "pods.json"),
                    device_classes=str(root / "classes.json"),
                    resource_slices=str(root / "slices.json"),
                    node_a="gpu-a",
                    node_b="gpu-b",
                    source_profile="all-disabled",
                    mig_strategy="mixed",
                    device_class="mig.nvidia.com",
                    driver="gpu.nvidia.com",
                    dra_node_label_key="nvidia.com/dra-kubelet-plugin",
                    dra_node_label_value="true",
                    product_regex=r"\bA100\b",
                    control_selector_key="hooke.io/pool",
                    control_selector_value="fixed-cpu",
                    output=str(output),
                )
            )
            summary = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(summary["status"], "PASS")
        self.assertEqual(len(summary["nodes"]), 2)
        self.assertEqual(summary["cpu_control_nodes"], ["cpu"])

    def test_preflight_rejects_single_strategy_for_balanced_control(self):
        gpu_a = node("gpu-a")
        gpu_b = node("gpu-b")
        gpu_a["metadata"]["labels"]["nvidia.com/mig.strategy"] = "single"
        gpu_b["metadata"]["labels"]["nvidia.com/mig.strategy"] = "single"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_json(
                root / "nodes.json",
                {"items": [gpu_a, gpu_b, cpu_node()]},
            )
            write_json(root / "pods.json", {"items": []})
            write_json(
                root / "classes.json",
                {"items": [{"metadata": {"name": "mig.nvidia.com"}}]},
            )
            write_json(
                root / "slices.json",
                {"items": [source_slice("gpu-a"), source_slice("gpu-b")]},
            )
            with self.assertRaisesRegex(
                pilot.ValidationError, "required MIG strategy mixed"
            ):
                pilot.check_preflight(
                    argparse.Namespace(
                        nodes=str(root / "nodes.json"),
                        pods=str(root / "pods.json"),
                        device_classes=str(root / "classes.json"),
                        resource_slices=str(root / "slices.json"),
                        node_a="gpu-a",
                        node_b="gpu-b",
                        source_profile="all-disabled",
                        mig_strategy="mixed",
                        device_class="mig.nvidia.com",
                        driver="gpu.nvidia.com",
                        dra_node_label_key=(
                            "nvidia.com/dra-kubelet-plugin"
                        ),
                        dra_node_label_value="true",
                        product_regex=r"\bA100\b",
                        control_selector_key="hooke.io/pool",
                        control_selector_value="fixed-cpu",
                        output=str(root / "summary.json"),
                    )
                )

    def batch_fixture(self, root):
        records = [
            {
                "name": f"mig-{index}",
                "type": "mig",
                "profile": "1g.10gb",
                "uuid": (
                    f"MIG-0000000{index}-0000-0000-0000-00000000000{index}"
                ),
                "parent_uuid": (
                    "GPU-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                ),
            }
            for index in range(2)
        ]
        write_json(
            root / "slices.json",
            {"items": [resource_slice("gpu-a", records)]},
        )
        pods = []
        claims = []
        logs = root / "logs"
        logs.mkdir()
        for index in range(7):
            pod_name = f"probe-{index}"
            pod_uid = f"pod-{index}"
            claim_name = f"claim-{index}"
            claim_uid = f"claim-uid-{index}"
            succeeded = index < 2
            pods.append(
                {
                    "metadata": {"name": pod_name, "uid": pod_uid},
                    "spec": {
                        "nodeName": "gpu-a" if succeeded else None,
                        "resourceClaims": [
                            {
                                "name": "gpu",
                                "resourceClaimName": claim_name,
                            }
                        ],
                    },
                    "status": {"phase": "Running" if succeeded else "Pending"},
                }
            )
            status = {}
            if succeeded:
                status = {
                    "allocation": {
                        "devices": {
                            "results": [
                                {
                                    "request": "gpu",
                                    "driver": "gpu.nvidia.com",
                                    "pool": "gpu-a",
                                    "device": f"mig-{index}",
                                }
                            ]
                        }
                    },
                    "reservedFor": [
                        {
                            "resource": "pods",
                            "name": pod_name,
                            "uid": pod_uid,
                        }
                    ],
                }
            claims.append(
                {
                    "metadata": {"name": claim_name, "uid": claim_uid},
                    "status": status,
                }
            )
            if succeeded:
                event = {
                    "hooke_event_type": "FIRST_CUDA_SUCCESS",
                    "source_time_ns": 10_000_000_000 + index,
                    "pod_uid": pod_uid,
                    "node_name": "gpu-a",
                    "hooke_attributes": {
                        "resource_claim_name": claim_name,
                        "resource_claim_uid": claim_uid,
                        "device_class": "mig.nvidia.com",
                        "cuda_visible_device_count": 1,
                        "cuda_device_name": (
                            "NVIDIA A100-SXM4-80GB MIG 1g.10gb"
                        ),
                        "cuda_device_uuid": (
                            f"0000000{index}-0000-0000-0000-00000000000{index}"
                        ),
                        "verified_allocation_bytes": 4096,
                        "cuda_hold_seconds": 45,
                    },
                }
                (logs / f"{pod_name}.log").write_text(
                    json.dumps(event) + "\n", encoding="utf-8"
                )
            else:
                (logs / f"{pod_name}.log").write_text("", encoding="utf-8")
        write_json(root / "pods.json", {"items": pods})
        write_json(root / "claims.json", {"items": claims})
        metadata = {
            "run_id": RUN_ID,
            "period": 1,
            "trial": 1,
            "strategy": "static-balanced",
            "node": "gpu-a",
            "requested_profile": "1g.10gb",
            "request_time_ns": 1_000_000_000,
            "profile_ready_time_ns": 1_000_000_000,
            "batch_apply_start_ns": 2_000_000_000,
            "admission_deadline_ns": 27_000_000_000,
            "batch_size": 7,
            "hold_seconds": 45,
            "admission_window_seconds": 25,
            "profile_mismatch": False,
            "reshape_requested_time_ns": None,
            "reshape_finished_time_ns": None,
        }
        write_json(root / "metadata.json", metadata)

    def test_batch_summary_proves_exact_first_wave_capacity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.batch_fixture(root)
            output = root / "summary.json"
            pilot.summarize_batch(
                argparse.Namespace(
                    metadata=str(root / "metadata.json"),
                    pods=str(root / "pods.json"),
                    claims=str(root / "claims.json"),
                    resource_slices=str(root / "slices.json"),
                    logs_dir=str(root / "logs"),
                    device_class="mig.nvidia.com",
                    driver="gpu.nvidia.com",
                    output=str(output),
                )
            )
            summary = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(summary["status"], "PASS")
        self.assertEqual(summary["published_profile_capacity"], 2)
        self.assertEqual(summary["first_wave_cuda_successes"], 2)
        self.assertEqual(summary["pending_after_first_wave"], 5)

    def test_aggregate_computes_crossover_capacity_and_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan = self.plan(root)
            plan_path = root / "plan.json"
            counter = 0
            capacities = {
                ("static-balanced", "1g.10gb"): 2,
                ("static-balanced", "3g.40gb"): 1,
                ("dynamic-homogeneous", "1g.10gb"): 7,
                ("dynamic-homogeneous", "3g.40gb"): 2,
            }
            for period in plan["periods"]:
                for trial in period["trials"]:
                    request_ns = (
                        int(period["period"]) * 10_000
                        + int(trial["trial"]) * 100
                    ) * 1_000_000_000
                    for strategy, node_name in (
                        ("static-balanced", period["static_node"]),
                        ("dynamic-homogeneous", period["dynamic_node"]),
                    ):
                        capacity = capacities[
                            (strategy, trial["requested_profile"])
                        ]
                        mismatch = (
                            strategy == "dynamic-homogeneous"
                            and trial["planned_dynamic_mismatch"]
                        )
                        first_cuda_ns = request_ns + (
                            70 if mismatch else 10
                        ) * 1_000_000_000
                        result = {
                            "status": "PASS",
                            "run_id": RUN_ID,
                            "period": period["period"],
                            "trial": trial["trial"],
                            "strategy": strategy,
                            "node": node_name,
                            "requested_profile": trial["requested_profile"],
                            "request_time_ns": request_ns,
                            "profile_mismatch": mismatch,
                            "reshape_requested_time_ns": (
                                request_ns if mismatch else None
                            ),
                            "reshape_finished_time_ns": (
                                request_ns + 60_000_000_000
                                if mismatch
                                else None
                            ),
                            "published_profile_capacity": capacity,
                            "first_wave_cuda_successes": capacity,
                            "successes": [
                                {
                                    "first_cuda_time_ns": first_cuda_ns + index,
                                    "request_to_cuda_seconds": (
                                        70.0 if mismatch else 10.0
                                    ),
                                    "profile_ready_to_cuda_seconds": 10.0,
                                }
                                for index in range(capacity)
                            ],
                        }
                        counter += 1
                        write_json(
                            root
                            / "batches"
                            / f"{counter:02d}"
                            / "batch-summary.json",
                            result,
                        )
            output = root / "summary.json"
            report = root / "report.md"
            pilot.aggregate(
                argparse.Namespace(
                    plan=str(plan_path),
                    root=str(root / "batches"),
                    output=str(output),
                    report=str(report),
                )
            )
            summary = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(summary["status"], "PASS")
        self.assertEqual(summary["demand_epoch_count"], 12)
        self.assertEqual(
            summary["capacity_comparisons"]["1g.10gb"][
                "dynamic_over_static_ratio"
            ],
            3.5,
        )
        self.assertEqual(summary["dynamic_policy"]["rho_epoch"], 0.5)
        self.assertGreater(
            summary["dynamic_policy"]["gpu_elasticity_bound_reshape_finish"],
            0,
        )


if __name__ == "__main__":
    unittest.main()
