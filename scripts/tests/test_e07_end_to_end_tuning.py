import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "e07-end-to-end-tuning.py"
SPEC = importlib.util.spec_from_file_location("e07_end_to_end_tuning", SCRIPT)
assert SPEC and SPEC.loader
e07 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = e07
SPEC.loader.exec_module(e07)


class E07EndToEndTuningTest(unittest.TestCase):
    def test_schedule_is_exact_cumulative_one_by_five(self):
        rows = e07.generate_schedule(30, 5, 2, 2, 1)
        self.assertEqual([row["cell_id"] for row in rows], ["B0", "B1", "B2", "B3", "B4"])
        self.assertEqual(
            [
                (
                    row["node_mode"],
                    row["cooldown_seconds"],
                    row["queue_mode"],
                    row["k"],
                    row["argo_variant"],
                )
                for row in rows
            ],
            [
                ("cold", 30, "direct", 2, "baseline"),
                ("warm", 30, "direct", 2, "baseline"),
                ("warm", 5, "direct", 2, "baseline"),
                ("warm", 5, "ack", 1, "baseline"),
                ("warm", 5, "ack", 1, "tuned"),
            ],
        )
        self.assertTrue(all(row["n"] == 2 for row in rows))

    def test_headroom_requires_scale_out_and_fits_fresh_node(self):
        nodes = {
            "items": [
                {
                    "metadata": {
                        "name": name,
                        "uid": f"uid-{name}",
                        "labels": {"alibabacloud.com/nodepool-id": "pool-a"},
                    },
                    "spec": {},
                    "status": {
                        "allocatable": {"memory": "1500Mi"},
                        "conditions": [{"type": "Ready", "status": "True"}],
                    },
                }
                for name in ("node-a", "node-b")
            ]
        }
        pods = {
            "items": [
                {
                    "metadata": {
                        "name": f"daemon-{node}",
                        "ownerReferences": [{"kind": "DaemonSet"}],
                    },
                    "spec": {
                        "nodeName": node,
                        "containers": [
                            {
                                "resources": {
                                    "requests": {"memory": "100Mi"}
                                }
                            }
                        ],
                    },
                    "status": {"phase": "Running"},
                }
                for node in ("node-a", "node-b")
            ]
            + [
                {
                    "metadata": {"name": f"load-{node}"},
                    "spec": {
                        "nodeName": node,
                        "containers": [
                            {
                                "resources": {
                                    "requests": {"memory": "450Mi"}
                                }
                            }
                        ],
                    },
                    "status": {"phase": "Running"},
                }
                for node in ("node-a", "node-b")
            ]
        }
        result = e07.headroom_evidence(
            nodes,
            pods,
            "alibabacloud.com/nodepool-id",
            "pool-a",
            5,
            "1024Mi",
            "200Mi",
            "100Mi",
        )
        self.assertEqual(result["gate"], "PASS")
        self.assertEqual(result["baseline_node_count"], 2)
        self.assertEqual(result["max_current_available_memory_mib"], 950)
        self.assertEqual(result["conservative_fresh_memory_headroom_mib"], 1400)
        self.assertEqual(result["required_fresh_memory_mib"], 1324)

    def test_headroom_rejects_anchor_that_can_fit_current_node(self):
        nodes = {
            "items": [
                {
                    "metadata": {
                        "name": "node-a",
                        "uid": "uid-a",
                        "labels": {"pool": "one"},
                    },
                    "spec": {},
                    "status": {
                        "allocatable": {"memory": "2Gi"},
                        "conditions": [{"type": "Ready", "status": "True"}],
                    },
                }
            ]
        }
        with self.assertRaisesRegex(e07.ValidationError, "must exceed"):
            e07.headroom_evidence(
                nodes, {"items": []}, "pool", "one", 2, "1Gi", "128Mi", "64Mi"
            )

    def test_aggregate_checks_cumulative_activation_without_monotonic_gate(self):
        schedule = e07.generate_schedule(30, 5, 2, 2, 1)
        cells = []
        e2e = {"B0": 100.0, "B1": 50.0, "B2": 55.0, "B3": 54.0, "B4": 57.0}
        for row in schedule:
            cells.append(
                {
                    **row,
                    "gate": "PASS",
                    "target_node": "node-new",
                    "node_provision_seconds": 40.0 if row["cell_id"] == "B0" else 0.0,
                    "e2e_seconds": e2e[row["cell_id"]],
                    "gang": {
                        "queue_admission_members": row["n"],
                        "application_barrier_minimum": row["k"],
                    },
                    "argo": {
                        "critical_path_length": 5 if row["argo_variant"] == "tuned" else 6,
                        "bc_overlap_seconds": 2.0 if row["argo_variant"] == "tuned" else 0.0,
                    },
                }
            )
        provisioning = {
            "gate": "PASS",
            "baseline_node_count": 4,
            "baseline_nodes": [{"name": "node-old", "uid": "old-uid"}],
            "target_node": "node-new",
            "anchor_node": "node-new",
            "anchor_created_ns": 1,
            "node_ready_ns": 2,
        }
        result = e07.aggregate(schedule, cells, provisioning)
        self.assertEqual(result["gate"], "PASS")
        self.assertTrue(result["activation_checks"]["parallel_argo_dag_from_b4"])
        self.assertGreater(cells[2]["e2e_seconds"], cells[1]["e2e_seconds"])

    def test_aggregate_rejects_reused_baseline_node(self):
        schedule = e07.generate_schedule(30, 5, 2, 2, 1)
        cells = []
        for index, row in enumerate(schedule):
            cells.append(
                {
                    **row,
                    "gate": "PASS",
                    "target_node": "node-old",
                    "node_provision_seconds": 1.0 if index == 0 else 0.0,
                    "e2e_seconds": 100.0 if index == 0 else 50.0,
                    "gang": {
                        "queue_admission_members": row["n"],
                        "application_barrier_minimum": row["k"],
                    },
                    "argo": {
                        "critical_path_length": 5 if index == 4 else 6,
                        "bc_overlap_seconds": 1.0 if index == 4 else 0.0,
                    },
                }
            )
        provisioning = {
            "gate": "PASS",
            "baseline_node_count": 1,
            "baseline_nodes": [{"name": "node-old", "uid": "uid-old"}],
            "target_node": "node-old",
            "anchor_node": "node-old",
            "anchor_created_ns": 1,
            "node_ready_ns": 2,
        }
        with self.assertRaisesRegex(e07.ValidationError, "already present"):
            e07.aggregate(schedule, cells, provisioning)

    def test_ack_queue_running_phase_is_post_admission_evidence(self):
        cell = {"queue_mode": "ack", "n": 2, "k": 1}
        gang = {
            "n": 2,
            "k": 1,
            "queue_admission_members": 2,
            "application_barrier_minimum": 1,
            "queue_admission_policy": "whole-job",
            "queueunit_name": "e07-b3-gang",
            "queueunit_phase": "Running",
        }
        with mock.patch.object(e07, "validate_gang_pods"):
            e07.validate_common_gang(cell, gang, {}, "node-new", "image@sha256:1")

        gang["queueunit_phase"] = "Enqueued"
        with mock.patch.object(e07, "validate_gang_pods"):
            with self.assertRaisesRegex(
                e07.ValidationError, "admitted or post-admission"
            ):
                e07.validate_common_gang(
                    cell, gang, {}, "node-new", "image@sha256:1"
                )


if __name__ == "__main__":
    unittest.main()
