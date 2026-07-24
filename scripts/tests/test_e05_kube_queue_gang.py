import argparse
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "e05-kube-queue-gang.py"
SPEC = importlib.util.spec_from_file_location("e05_kube_queue_gang", SCRIPT)
assert SPEC and SPEC.loader
e05 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = e05
SPEC.loader.exec_module(e05)


class E05KubeQueueGangTest(unittest.TestCase):
    def test_schedule_is_blocked_randomized_and_deterministic(self):
        first = e05.generate_schedule(3, 20260724)
        second = e05.generate_schedule(3, 20260724)
        self.assertEqual(first, second)
        self.assertEqual(len(first), 12)
        expected = {(2, 2), (2, 1), (4, 4), (4, 2)}
        for block in range(1, 4):
            cells = {
                (row["n"], row["k"])
                for row in first
                if row["block"] == block
            }
            self.assertEqual(cells, expected)
        self.assertTrue(
            all(row["queue_admission_members"] == row["n"] for row in first)
        )

    def test_manifest_separates_whole_job_admission_from_barrier_k(self):
        args = argparse.Namespace(
            namespace="e05-run",
            job_name="e05-001",
            service_name="e05-001",
            run_id="run-1",
            cluster_id="cluster-1",
            image="registry.example/e05@sha256:" + "a" * 64,
            n=4,
            k=2,
            port=8080,
            barrier_timeout="10m",
            work_duration="10s",
            leader_grace="60s",
            cpu_request="250m",
            cpu_limit="250m",
            memory_request="64Mi",
            memory_limit="64Mi",
            node_selector_key="kubernetes.io/hostname",
            node_selector_value="node-a",
            taint_key="",
            taint_value="",
            taint_effect="NoSchedule",
        )
        manifest = e05.workload_manifest(args)
        service, job = manifest["items"]
        self.assertTrue(service["spec"]["publishNotReadyAddresses"])
        self.assertTrue(job["spec"]["suspend"])
        self.assertEqual(job["spec"]["parallelism"], 4)
        self.assertEqual(job["spec"]["completions"], 4)
        self.assertEqual(job["spec"]["completionMode"], "Indexed")
        env = {
            value["name"]: value
            for value in job["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertEqual(env["E05_N"]["value"], "4")
        self.assertEqual(env["E05_K"]["value"], "2")
        self.assertNotIn("minCount", json.dumps(job))
        pod_security = job["spec"]["template"]["spec"]["securityContext"]
        container_security = job["spec"]["template"]["spec"]["containers"][0][
            "securityContext"
        ]
        self.assertEqual(pod_security["runAsUser"], 65532)
        self.assertEqual(pod_security["runAsGroup"], 65532)
        self.assertEqual(container_security["runAsUser"], 65532)

    def test_summary_rejects_native_partial_admission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            captures = root / "queueunits.ndjson"
            captures.write_text(
                json.dumps(
                    {
                        "observed_time_ns": 100,
                        "items": [
                            {
                                "metadata": {"name": "e05-001"},
                                "spec": {
                                    "consumerRef": {
                                        "kind": "Job",
                                        "name": "e05-001",
                                    },
                                    "podSet": [{"count": 4, "minCount": 2}],
                                },
                                "status": {"phase": "Dequeued"},
                            }
                        ],
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            args = argparse.Namespace(
                job_name="e05-001",
                n=4,
                k=2,
                queueunit_captures=str(captures),
                pod_captures=str(root / "pod-captures.ndjson"),
                pods=str(root / "pods.json"),
                application_events=str(root / "events.ndjson"),
            )
            with self.assertRaisesRegex(
                e05.ValidationError, "partial admission"
            ):
                e05.summarize_cell(args)

    def test_queueunit_preserves_initial_request_after_succeed_reclaims_pods(self):
        captures = [
            {
                "observed_time_ns": 100,
                "items": [
                    {
                        "metadata": {"name": "e05-001", "uid": "queueunit-1"},
                        "spec": {
                            "consumerRef": {"kind": "Job", "name": "e05-001"},
                            "podSet": [{"name": "main", "count": 2}],
                        },
                        "status": {
                            "phase": "Dequeued",
                            "lastAllocateTime": "2026-07-24T08:00:00Z",
                        },
                    }
                ],
            },
            {
                "observed_time_ns": 200,
                "items": [
                    {
                        "metadata": {"name": "e05-001", "uid": "queueunit-1"},
                        "spec": {
                            "consumerRef": {"kind": "Job", "name": "e05-001"},
                            "podSet": [{"name": "main", "count": 0}],
                        },
                        "status": {"phase": "Succeed"},
                    }
                ],
            },
        ]
        latest, admission, observed_ns, allocate_time = e05.queueunit_for_job(
            captures, "e05-001"
        )
        self.assertEqual(latest["status"]["phase"], "Succeed")
        self.assertEqual(admission["spec"]["podSet"][0]["count"], 2)
        self.assertEqual(observed_ns, 100)
        self.assertEqual(allocate_time, "2026-07-24T08:00:00Z")


if __name__ == "__main__":
    unittest.main()
