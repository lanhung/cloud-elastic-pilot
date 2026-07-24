import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "export-application-events.py"
SPEC = importlib.util.spec_from_file_location("application_exporter", SCRIPT)
assert SPEC and SPEC.loader
application_exporter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = application_exporter
SPEC.loader.exec_module(application_exporter)


class ApplicationEventExporterTest(unittest.TestCase):
    def setUp(self):
        self.pod_uid = "11111111-2222-3333-4444-555555555555"
        self.image = "registry.example.com/e04/app@sha256:" + "a" * 64
        self.pods = {
            "items": [
                {
                    "metadata": {
                        "uid": self.pod_uid,
                        "namespace": "e04-run",
                        "name": "producer-abc",
                    },
                    "spec": {
                        "nodeName": "node-a",
                        "containers": [{"name": "producer", "image": self.image}],
                    },
                    "status": {
                        "containerStatuses": [
                            {
                                "name": "producer",
                                "containerID": "containerd://" + "b" * 64,
                            }
                        ]
                    },
                }
            ]
        }

    def test_normalize_preserves_source_time_and_correlation(self):
        at_ns = 1_800_000_000_123_456_789
        record = {
            "hooke_event_type": "MESSAGE_ENQUEUED",
            "source_time_ns": at_ns,
            "hooke_cluster_id": "cluster-a",
            "hooke_run_id": "run-a",
            "pod_namespace": "e04-run",
            "pod_name": "producer-abc",
            "pod_uid": self.pod_uid,
            "node_name": "node-a",
            "container_name": "producer",
            "workload_kind": "Job",
            "workload_name": "producer",
            "hooke_attributes": {"message_id": "message-1", "sequence": 1},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pods_path = root / "pods.json"
            pods_path.write_text(json.dumps(self.pods), encoding="utf-8")
            logs = root / "logs"
            logs.mkdir()
            (logs / "producer.log").write_text(
                "[pod/producer-abc/container/producer] "
                + json.dumps(record, separators=(",", ":"))
                + "\n",
                encoding="utf-8",
            )
            targets = application_exporter.load_targets(pods_path)
            events = application_exporter.normalize_events(
                "cluster-a", "run-a", targets, logs, at_ns - 1, at_ns + 1
            )
            output = root / "events.ndjson"
            application_exporter.write_ndjson(output, events)
            written = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(written["event_time_ns"], at_ns)
        self.assertEqual(written["pod_uid"], self.pod_uid)
        self.assertEqual(written["container_id"], "b" * 64)
        self.assertEqual(written["image_digest"], "sha256:" + "a" * 64)
        self.assertEqual(
            written["attributes"]["persistence"], "container-stdout"
        )
        self.assertFalse(written["approximate"])
        self.assertRegex(written["event_id"], r"^[0-9A-HJKMNP-TV-Z]{26}$")

    def test_unknown_pod_uid_fails_closed(self):
        target = application_exporter.PodTarget(
            uid=self.pod_uid,
            namespace="e04-run",
            name="producer-abc",
            node_name="node-a",
            containers={
                "producer": application_exporter.ContainerTarget(
                    name="producer", image=self.image, container_id="container"
                )
            },
        )
        record = {
            "hooke_event_type": "MESSAGE_ENQUEUED",
            "source_time_ns": 100,
            "hooke_cluster_id": "cluster-a",
            "hooke_run_id": "run-a",
            "pod_namespace": "e04-run",
            "pod_name": "producer-abc",
            "pod_uid": "different",
            "node_name": "node-a",
            "container_name": "producer",
        }
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            (logs / "producer.log").write_text(json.dumps(record), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "unknown Pod UID"):
                application_exporter.normalize_events(
                    "cluster-a", "run-a", [target], logs, 1, 200
                )


if __name__ == "__main__":
    unittest.main()
