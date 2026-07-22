import importlib.util
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "export-goatscaler-events.py"
SPEC = importlib.util.spec_from_file_location("goatscaler_exporter", SCRIPT)
assert SPEC and SPEC.loader
goatscaler_exporter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = goatscaler_exporter
SPEC.loader.exec_module(goatscaler_exporter)


class GOATScalerExporterTest(unittest.TestCase):
    def test_batch_is_scoped_and_correlated_to_pod_and_node(self):
        task_id = "asa-0jl10371l7ikwggjxpkm"
        batch_id = "batch-123"
        records = [
            {
                "_time_": "2026-07-22T03:34:46.123456Z",
                "content": (
                    f"start provision batch {batch_id}: "
                    "nodepool=np-elastic zone=cn-wulanchabu-b "
                    "instanceTypes=[ecs.c7.large] size=1"
                ),
            },
            {
                "_time_": "2026-07-22T03:34:46.223456Z",
                "content": (
                    f"succeed to trigger batch {batch_id}: "
                    f"provider response activity={task_id}"
                ),
            },
            {
                "_time_": "2026-07-22T03:34:46.323456Z",
                "content": (
                    f"PreBind pod e01/pod-a to vNode {task_id} "
                    f"in batch {batch_id} successfully"
                ),
            },
        ]
        start = datetime(2026, 7, 22, 3, 34, 46, tzinfo=timezone.utc)
        end = datetime(2026, 7, 22, 3, 34, 47, tzinfo=timezone.utc)
        batches = goatscaler_exporter.parse_batches(records, start, end)
        with mock.patch.object(
            goatscaler_exporter,
            "node_tasks",
            return_value={
                task_id: {
                    "node_name": "cn-wulanchabu.10.0.0.10",
                    "node_uid": "node-uid-a",
                    "instance_id": "i-abc",
                    "provider_id": "cn-wulanchabu.i-abc",
                    "nodepool_id": "np-elastic",
                    "instance_type": "ecs.c7.large",
                }
            },
        ):
            output = goatscaler_exporter.normalize(
                batches,
                "cluster-a",
                "run-a",
                {task_id},
                {task_id: {"pod-uid-a"}},
                {task_id: {"e01/pod-a"}},
            )

        self.assertEqual(len(output), 1)
        item = output[0]
        self.assertEqual(item["action"], "CreateNode")
        self.assertEqual(item["event_time"], records[0]["_time_"])
        self.assertEqual(item["task_id"], task_id)
        self.assertEqual(item["pending_pod_uids"], ["pod-uid-a"])
        self.assertEqual(item["pending_pods"], ["e01/pod-a"])
        self.assertEqual(item["node_name"], "cn-wulanchabu.10.0.0.10")
        self.assertEqual(item["instance_id"], "i-abc")
        self.assertEqual(item["source_component"], "ack-goatscaler-sls")

    def test_batch_outside_window_is_rejected(self):
        records = [
            {
                "_time_": "2026-07-22T03:34:45.999999Z",
                "content": (
                    "start provision batch old: nodepool=np zone=zone-a "
                    "instanceTypes=[ecs.c7.large] size=1"
                ),
            }
        ]
        start = datetime(2026, 7, 22, 3, 34, 46, tzinfo=timezone.utc)
        end = datetime(2026, 7, 22, 3, 34, 47, tzinfo=timezone.utc)
        self.assertEqual(goatscaler_exporter.parse_batches(records, start, end), {})


if __name__ == "__main__":
    unittest.main()
