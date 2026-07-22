import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "export-runtime-journal-events.py"
SPEC = importlib.util.spec_from_file_location("runtime_exporter", SCRIPT)
assert SPEC and SPEC.loader
runtime_exporter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runtime_exporter
SPEC.loader.exec_module(runtime_exporter)


def journal_line(at, message):
    return json.dumps(
        {"__REALTIME_TIMESTAMP": str(at // 1000), "MESSAGE": message},
        separators=(",", ":"),
    )


def containerd_message(at, message):
    seconds, nanos = divmod(at, 1_000_000_000)
    stamp = runtime_exporter.datetime.fromtimestamp(
        seconds, tz=runtime_exporter.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%S")
    stamp = f"{stamp}.{nanos:09d}Z"
    return f'time="{stamp}" level=info msg="{message}"'


class RuntimeJournalExporterTest(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.image = "registry.example.com/hooke/e01@sha256:" + "a" * 64
        self.uid = "11111111-2222-3333-4444-555555555555"
        self.sandbox = "b" * 64
        self.container_id = "c" * 64
        self.pod = runtime_exporter.PodTarget(
            uid=self.uid,
            namespace="e01-test",
            name="workload-abc",
            node_name="node-a",
            node_uid="node-uid-a",
            containers={
                "app": runtime_exporter.ContainerTarget(
                    name="app", image=self.image, container_id=self.container_id
                )
            },
        )

    def runtime_lines(self, include_pull=True):
        base = 1_800_000_000_000_000_000
        messages = [
            (
                base + 100_000,
                f"RunPodSandbox for &PodSandboxMetadata{{Name:{self.pod.name},Uid:{self.uid},Namespace:{self.pod.namespace},Attempt:0,}}",
            ),
            (
                base + 200_000,
                f'RunPodSandbox for &PodSandboxMetadata{{Name:{self.pod.name},Uid:{self.uid},Namespace:{self.pod.namespace},Attempt:0,}} returns sandbox id \\"{self.sandbox}\\"',
            ),
        ]
        if include_pull:
            messages.extend(
                [
                    (base + 300_000, f'PullImage \\"{self.image}\\"'),
                    (
                        base + 350_000,
                        f'PullImageInfo: DownloadBytes=70000000 image.name=\\"{self.image}\\"',
                    ),
                    (
                        base + 400_000,
                        f'PullImage \\"{self.image}\\" returns image reference \\"sha256:{"d" * 64}\\"',
                    ),
                ]
            )
        messages.extend(
            [
                (
                    base + 500_000,
                    f'CreateContainer within sandbox \\"{self.sandbox}\\" for container &ContainerMetadata{{Name:app,Attempt:0,}}',
                ),
                (
                    base + 600_000,
                    f'CreateContainer within sandbox \\"{self.sandbox}\\" for &ContainerMetadata{{Name:app,Attempt:0,}} returns container id \\"{self.container_id}\\"',
                ),
                (
                    base + 700_000,
                    f'StartContainer for \\"{self.container_id}\\" returns successfully',
                ),
            ]
        )
        return "\n".join(
            journal_line(at, containerd_message(at, message))
            for at, message in messages
        )

    def test_timestamp_ns_preserves_nanoseconds_and_offset(self):
        value = runtime_exporter.timestamp_ns("2026-07-22T11:34:46.899967158+08:00")
        expected = runtime_exporter.timestamp_ns("2026-07-22T03:34:46.899967158Z")
        self.assertEqual(value, expected)
        self.assertEqual(value % 1_000_000_000, 899_967_158)

    def test_cold_pull_is_joined_by_uid_sandbox_and_container(self):
        records = runtime_exporter.parse_journal(self.runtime_lines())
        events = runtime_exporter.normalize_events(
            "cluster-a", "run-a", [self.pod], {"node-a": (records, [])}
        )
        self.assertEqual(
            [item["event_type"] for item in events],
            [
                "POD_SANDBOX_START",
                "POD_SANDBOX_END",
                "IMAGE_PULL_START",
                "IMAGE_PULL_END",
                "CONTAINER_STARTED",
            ],
        )
        pull_end = next(item for item in events if item["event_type"] == "IMAGE_PULL_END")
        self.assertEqual(pull_end["attributes"]["download_bytes"], 70_000_000)
        self.assertFalse(any(item["approximate"] for item in events))
        self.assertFalse(
            any(item["event_type"].startswith("CNI_") for item in events)
        )

    def test_warm_image_uses_explicit_kubelet_cache_decision(self):
        runtime_records = runtime_exporter.parse_journal(
            self.runtime_lines(include_pull=False)
        )
        hit_time = 1_800_000_000_000_300_000
        hit_message = (
            f'I0101 00:00:00.000000 1 event.go:1] "Event occurred" '
            f'object="{self.pod.namespace}/{self.pod.name}" '
            'fieldPath="spec.containers{app}" reason="Pulled" '
            f'message="Container image \\"{self.image}\\" already present on machine '
            'and can be accessed by the pod"'
        )
        kubelet_records = runtime_exporter.parse_journal(
            journal_line(hit_time, hit_message)
        )
        events = runtime_exporter.normalize_events(
            "cluster-a",
            "run-a",
            [self.pod],
            {"node-a": (runtime_records, kubelet_records)},
        )
        self.assertEqual(
            [item["event_type"] for item in events],
            [
                "POD_SANDBOX_START",
                "POD_SANDBOX_END",
                "IMAGE_CACHE_HIT",
                "CONTAINER_STARTED",
            ],
        )
        cache = next(item for item in events if item["event_type"] == "IMAGE_CACHE_HIT")
        self.assertEqual(cache["event_time_ns"], hit_time)
        self.assertEqual(cache["result"], "cache-hit")

    def test_application_event_uses_embedded_source_timestamp(self):
        at_ns = 1_800_000_000_123_456_789
        record = {
            "hooke_event_type": "READINESS_PROBE_FIRST_SUCCESS",
            "source_time_ns": at_ns,
            "hooke_cluster_id": "cluster-a",
            "hooke_run_id": "run-a",
            "pod_namespace": self.pod.namespace,
            "pod_name": self.pod.name,
            "pod_uid": self.pod.uid,
            "node_name": self.pod.node_name,
            "container_name": "app",
            "workload_kind": "Deployment",
            "workload_name": "workload-a",
            "hooke_attributes": {"path": "/readyz", "status": 200},
        }
        with tempfile.TemporaryDirectory() as directory:
            artifact_dir = Path(directory)
            (artifact_dir / "pod-logs-workload-1.ndjson").write_text(
                "[pod/workload-abc/container/app] "
                + json.dumps(record, separators=(",", ":"))
                + "\n",
                encoding="utf-8",
            )
            events = runtime_exporter.application_events(
                artifact_dir,
                "cluster-a",
                "run-a",
                [self.pod],
                at_ns - 1,
                at_ns + 1,
            )

        self.assertEqual(len(events), 1)
        item = events[0]
        self.assertEqual(item["source_time_ns"], at_ns)
        self.assertEqual(item["event_time_ns"], at_ns)
        self.assertEqual(item["source_component"], "application-event-log")
        self.assertEqual(item["container_id"], self.container_id)
        self.assertEqual(item["image_digest"], "sha256:" + "a" * 64)
        self.assertEqual(item["attributes"]["persistence"], "container-stdout")
        self.assertFalse(item["approximate"])


if __name__ == "__main__":
    unittest.main()
