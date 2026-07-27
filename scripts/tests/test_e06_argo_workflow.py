import argparse
import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "e06-argo-workflow.py"
SPEC = importlib.util.spec_from_file_location("e06_argo_workflow", SCRIPT)
assert SPEC and SPEC.loader
e06 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = e06
SPEC.loader.exec_module(e06)


def manifest_args(variant: str = "tuned") -> argparse.Namespace:
    return argparse.Namespace(
        namespace="e06-run",
        name=f"e06-{variant}",
        run_id="run-1",
        cluster_id="cluster-1",
        variant=variant,
        image="registry.example/e06@sha256:" + "a" * 64,
        service_account="e06-workflow",
        stage_durations="a=2s,b=6s,c=4s,d=2s,e=1s,f=1s",
        stage_timeout_seconds=120,
        workflow_timeout_seconds=600,
        node_selector_key="kubernetes.io/hostname",
        node_selector_value="node-a",
        taint_key="",
        taint_value="",
        taint_effect="NoSchedule",
        cpu_request="50m",
        cpu_limit="100m",
        memory_request="32Mi",
        memory_limit="64Mi",
    )


def rfc3339(ns: int) -> str:
    seconds, nanos = divmod(ns, 1_000_000_000)
    base = datetime.fromtimestamp(seconds, timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%S"
    )
    return f"{base}.{nanos:09d}Z"


class E06ArgoWorkflowTest(unittest.TestCase):
    def test_schedule_is_paired_randomized_and_deterministic(self):
        first = e06.generate_schedule(3, 20260727)
        second = e06.generate_schedule(3, 20260727)
        self.assertEqual(first, second)
        self.assertEqual(len(first), 6)
        for block in range(1, 4):
            self.assertEqual(
                {
                    row["variant"]
                    for row in first
                    if row["block"] == block
                },
                {"baseline", "tuned"},
            )

    def test_manifest_freezes_control_and_true_dependencies(self):
        baseline = e06.workflow_manifest(manifest_args("baseline"))
        tuned = e06.workflow_manifest(manifest_args("tuned"))
        self.assertEqual(
            e06.workflow_control_dependencies(baseline),
            e06.CONTROL_DEPENDENCIES["baseline"],
        )
        self.assertEqual(
            e06.workflow_control_dependencies(tuned),
            e06.CONTROL_DEPENDENCIES["tuned"],
        )
        baseline_true = json.loads(
            baseline["metadata"]["annotations"][
                "hooke.io/true-dependencies"
            ]
        )
        tuned_true = json.loads(
            tuned["metadata"]["annotations"][
                "hooke.io/true-dependencies"
            ]
        )
        self.assertEqual(baseline_true, tuned_true)
        self.assertNotIn("b", tuned_true["c"])
        self.assertNotIn("c", tuned_true["b"])
        self.assertEqual(tuned["spec"]["serviceAccountName"], "e06-workflow")
        stage = tuned["spec"]["templates"][1]
        self.assertEqual(
            stage["nodeSelector"], {"kubernetes.io/hostname": "node-a"}
        )
        self.assertTrue(
            stage["container"]["securityContext"]["readOnlyRootFilesystem"]
        )

    def test_executor_rbac_is_minimal(self):
        manifest = e06.rbac_manifest("e06-run", "e06-workflow")
        _, role, binding = manifest["items"]
        self.assertEqual(
            role["rules"],
            [
                {
                    "apiGroups": ["argoproj.io"],
                    "resources": ["workflowtaskresults"],
                    "verbs": ["create", "patch"],
                }
            ],
        )
        self.assertEqual(
            binding["subjects"][0]["name"], "e06-workflow"
        )

    def test_node_headroom_uses_effective_requests(self):
        node = {
            "metadata": {"name": "node-a"},
            "status": {"allocatable": {"cpu": "2", "memory": "1Gi"}},
        }
        pods = {
            "items": [
                {
                    "spec": {
                        "nodeName": "node-a",
                        "containers": [
                            {
                                "resources": {
                                    "requests": {
                                        "cpu": "100m",
                                        "memory": "128Mi",
                                    }
                                }
                            }
                        ],
                    },
                    "status": {"phase": "Running"},
                },
                {
                    "spec": {
                        "nodeName": "node-a",
                        "containers": [
                            {
                                "resources": {
                                    "requests": {
                                        "cpu": "1",
                                        "memory": "512Mi",
                                    }
                                }
                            }
                        ],
                    },
                    "status": {"phase": "Succeeded"},
                },
            ]
        }
        result = e06.node_headroom(node, pods)
        self.assertEqual(result["requested_cpu_millicores"], 100)
        self.assertEqual(
            result["available_memory_bytes"], 896 * 1024 * 1024
        )

    def test_summarize_tuned_cell_validates_events_and_critical_path(self):
        workflow = e06.workflow_manifest(manifest_args("tuned"))
        workflow["metadata"]["uid"] = "workflow-uid"
        workflow["status"] = {
            "phase": "Succeeded",
            "startedAt": rfc3339(1_000_000_000),
            "finishedAt": rfc3339(13_000_000_000),
            "nodes": {},
        }
        intervals = {
            "a": (1_000_000_000, 3_000_000_000),
            "b": (3_000_000_000, 9_000_000_000),
            "c": (3_000_000_000, 7_000_000_000),
            "d": (9_000_000_000, 11_000_000_000),
            "e": (11_000_000_000, 12_000_000_000),
            "f": (12_000_000_000, 13_000_000_000),
        }
        pods = {"items": []}
        events = []
        for stage, (started, finished) in intervals.items():
            workflow["status"]["nodes"][f"node-{stage}"] = {
                "displayName": stage,
                "name": f"e06-tuned.{stage}",
                "type": "Pod",
                "templateName": "e06-stage",
                "phase": "Succeeded",
                "startedAt": rfc3339(started),
                "finishedAt": rfc3339(finished),
            }
            pod_uid = f"pod-{stage}"
            pods["items"].append(
                {
                    "metadata": {
                        "name": f"e06-tuned-{stage}",
                        "uid": pod_uid,
                        "ownerReferences": [
                            {
                                "kind": "Workflow",
                                "name": "e06-tuned",
                                "uid": "workflow-uid",
                            }
                        ],
                    },
                    "spec": {"nodeName": "node-a"},
                    "status": {
                        "phase": "Succeeded",
                        "containerStatuses": [
                            {
                                "name": "main",
                                "imageID": (
                                    "registry.example/e06@sha256:"
                                    + "a" * 64
                                ),
                            }
                        ],
                    },
                }
            )
            for event_type, at in (
                ("USEFUL_WORK_STARTED", started + 100_000_000),
                ("USEFUL_WORK_FINISHED", finished - 100_000_000),
            ):
                events.append(
                    {
                        "workload_uid": "workflow-uid",
                        "workload_kind": "Workflow",
                        "workload_name": "e06-tuned",
                        "pod_uid": pod_uid,
                        "event_type": event_type,
                        "event_time_ns": at,
                        "source_component": "application-event-log",
                        "image_digest": "sha256:" + "a" * 64,
                        "approximate": False,
                        "attributes": {
                            "stage_name": stage,
                            "variant": "tuned",
                        },
                    }
                )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "workflow.json").write_text(
                json.dumps(workflow), encoding="utf-8"
            )
            (root / "pods.json").write_text(
                json.dumps(pods), encoding="utf-8"
            )
            (root / "events.ndjson").write_text(
                "".join(json.dumps(item) + "\n" for item in events),
                encoding="utf-8",
            )
            args = argparse.Namespace(
                workflow=str(root / "workflow.json"),
                pods=str(root / "pods.json"),
                application_events=str(root / "events.ndjson"),
                variant="tuned",
                sequence=1,
                block=1,
                slo_seconds=30.0,
                clock_tolerance_seconds=2.0,
                expected_image="registry.example/e06@sha256:" + "a" * 64,
                expected_node="node-a",
            )
            summary = e06.summarize_cell(args)
        self.assertEqual(
            summary["critical_path"], ["a", "b", "d", "e", "f"]
        )
        self.assertEqual(summary["critical_path_length"], 5)
        self.assertEqual(summary["required_application_events"], 12)
        self.assertEqual(summary["gate"], "PASS")

    def test_aggregate_requires_tuned_to_improve(self):
        baseline = {
            "sequence": 1,
            "block": 1,
            "variant": "baseline",
            "gate": "PASS",
            "workflow_duration_seconds": 20.0,
            "critical_path_length": 6,
            "workflow_elasticity_measured": 0.5,
            "bc_overlap_seconds": 0.0,
        }
        tuned = {
            "sequence": 2,
            "block": 1,
            "variant": "tuned",
            "gate": "PASS",
            "workflow_duration_seconds": 14.0,
            "critical_path_length": 5,
            "workflow_elasticity_measured": 0.7,
            "bc_overlap_seconds": 4.0,
        }
        result = e06.aggregate_summaries([baseline, tuned])
        self.assertEqual(result["gate"], "PASS")
        self.assertEqual(result["pair_count"], 1)
        tuned["workflow_duration_seconds"] = 21.0
        with self.assertRaisesRegex(e06.ValidationError, "not faster"):
            e06.aggregate_summaries([baseline, tuned])


if __name__ == "__main__":
    unittest.main()
