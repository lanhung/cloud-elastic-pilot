import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "e08-collector-overhead.py"
SPEC = importlib.util.spec_from_file_location("e08_collector_overhead", SCRIPT)
assert SPEC and SPEC.loader
e08 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = e08
SPEC.loader.exec_module(e08)

IMAGE = "registry.example.com/hooke/e08@sha256:" + "a" * 64
NODES = ["worker-a", "worker-b"]
RUN_ID = "01J00000000000000000000000"
NAMESPACE = "e08-cell"


def pod(index):
    node = NODES[index % 2]
    return {
        "metadata": {
            "name": f"worker-{index}",
            "namespace": NAMESPACE,
            "uid": f"pod-{index}",
            "creationTimestamp": "2026-07-27T00:00:00Z",
        },
        "spec": {"nodeName": node},
        "status": {
            "phase": "Succeeded",
            "containerStatuses": [
                {
                    "restartCount": 0,
                    "imageID": "docker-pullable://" + IMAGE,
                    "state": {
                        "terminated": {
                            "startedAt": f"2026-07-27T00:00:0{index + 1}Z"
                        }
                    },
                }
            ],
        },
    }


def event(uid, event_type, source):
    return {
        "run_id": RUN_ID,
        "namespace": NAMESPACE,
        "pod_uid": uid,
        "event_type": event_type,
        "source_component": source,
        "observed_time_ns": 1_000_000_000,
        "ingest_time_ns": 1_100_000_000,
    }


def system_pods(enabled=True):
    items = [
        {
            "metadata": {
                "name": "ingester",
                "namespace": "hooke-e08-system",
                "labels": {"app.kubernetes.io/name": "hooke-ingester"},
            },
            "spec": {"nodeName": "worker-a"},
        }
    ]
    if enabled:
        items.append(
            {
                "metadata": {
                    "name": "controller",
                    "namespace": "hooke-e08-system",
                    "labels": {"app.kubernetes.io/name": "hooke-controller"},
                },
                "spec": {"nodeName": "worker-a"},
            }
        )
        items.extend(
            [
                {
                    "metadata": {
                        "name": f"agent-{index}",
                        "namespace": "hooke-e08-system",
                        "labels": {"app.kubernetes.io/name": "hooke-node-agent"},
                    },
                    "spec": {"nodeName": node},
                }
                for index, node in enumerate(NODES)
            ]
        )
    return {"items": items}


def resource_sample(enabled=True):
    items = [
        {
            "metadata": {"name": "ingester", "namespace": "hooke-e08-system"},
            "containers": [{"usage": {"cpu": "5m", "memory": "20Mi"}}],
        }
    ]
    if enabled:
        items.extend(
            [
                {
                    "metadata": {
                        "name": "controller",
                        "namespace": "hooke-e08-system",
                    },
                    "containers": [{"usage": {"cpu": "10m", "memory": "30Mi"}}],
                },
                *[
                    {
                        "metadata": {
                            "name": f"agent-{index}",
                            "namespace": "hooke-e08-system",
                        },
                        "containers": [
                            {"usage": {"cpu": "2m", "memory": "10Mi"}}
                        ],
                    }
                    for index in range(2)
                ],
            ]
        )
    return {"items": items}


def sample(name, value, **labels):
    return {(name, tuple(sorted(labels.items()))): value}


class E08CollectorOverheadTest(unittest.TestCase):
    def test_schedule_is_frozen_off_10_100(self):
        schedule = e08.generate_schedule()
        self.assertEqual(
            [
                (
                    item["mode"],
                    item["collector_enabled"],
                    item["sample_percent"],
                )
                for item in schedule
            ],
            [
                ("collector-off", False, 0),
                ("collector-on-10-percent", True, 10),
                ("collector-on-100-percent", True, 100),
            ],
        )

    def test_workload_is_digest_pinned_and_spans_two_nodes(self):
        manifest = e08.workload_manifest(
            namespace=NAMESPACE,
            name="e08-workload",
            run_id=RUN_ID,
            cluster_id="ack",
            image=IMAGE,
            ingester_url="http://hooke-ingester:8080",
            target_nodes=NODES,
            completions=4,
            parallelism=2,
            work_duration="5s",
            cpu_request="25m",
            memory_request="32Mi",
        )
        spec = manifest["spec"]
        pod_spec = spec["template"]["spec"]
        self.assertEqual(spec["completionMode"], "Indexed")
        self.assertEqual(spec["parallelism"], 2)
        self.assertEqual(pod_spec["containers"][0]["image"], IMAGE)
        values = pod_spec["affinity"]["nodeAffinity"][
            "requiredDuringSchedulingIgnoredDuringExecution"
        ]["nodeSelectorTerms"][0]["matchExpressions"][0]["values"]
        self.assertEqual(values, NODES)
        self.assertEqual(
            pod_spec["topologySpreadConstraints"][0]["topologyKey"],
            "kubernetes.io/hostname",
        )

    def test_100_percent_cell_requires_complete_traces_and_no_loss(self):
        pods = [pod(index) for index in range(4)]
        events = []
        for item in pods:
            uid = item["metadata"]["uid"]
            for kind in e08.APPLICATION_EVENT_TYPES:
                events.append(event(uid, kind, "e08-workload"))
            for kind in e08.CONTROLLER_EVENT_TYPES:
                events.append(event(uid, kind, "kubernetes-pod-watch"))
        after = {}
        after.update(sample("hooke_collector_sample_percent", 100))
        after.update(
            sample(
                "hooke_collector_sampling_events_total", 12, decision="kept"
            )
        )
        after.update(
            sample(
                "hooke_collector_queue_events_total", 12, result="enqueued"
            )
        )
        after.update(
            sample(
                "hooke_collector_delivery_events_total", 12, result="sent"
            )
        )
        after.update(sample("hooke_collector_queue_depth", 0))
        result = e08.summarize_cell(
            cell=e08.generate_schedule()[2],
            run_id=RUN_ID,
            workload_namespace=NAMESPACE,
            target_nodes=NODES,
            image=IMAGE,
            expected_pods=4,
            job_payload={"status": {"succeeded": 4}},
            pods_payload={"items": pods},
            events=events,
            metrics_samples=[resource_sample()],
            system_pods_payload=system_pods(),
            metrics_before={},
            metrics_after=after,
        )
        self.assertEqual(result["gate"], "PASS")
        self.assertEqual(result["trace_complete_rate"], 1)
        self.assertFalse(result["collector_metrics"]["ring_buffer_supported"])
        self.assertEqual(
            sorted(result["resources"]["node_agent"]["per_node"]), NODES
        )

    def test_off_cell_rejects_no_application_data(self):
        pods = [pod(index) for index in range(4)]
        with self.assertRaisesRegex(e08.ValidationError, "application events"):
            e08.summarize_cell(
                cell=e08.generate_schedule()[0],
                run_id=RUN_ID,
                workload_namespace=NAMESPACE,
                target_nodes=NODES,
                image=IMAGE,
                expected_pods=4,
                job_payload={"status": {"succeeded": 4}},
                pods_payload={"items": pods},
                events=[],
                metrics_samples=[resource_sample(enabled=False)],
                system_pods_payload=system_pods(enabled=False),
                metrics_before={},
                metrics_after={},
            )

    def test_10_percent_cell_requires_partial_pod_population(self):
        pods = [pod(index) for index in range(4)]
        events = []
        for item in pods:
            uid = item["metadata"]["uid"]
            for kind in e08.APPLICATION_EVENT_TYPES:
                events.append(event(uid, kind, "e08-workload"))
        for kind in e08.CONTROLLER_EVENT_TYPES:
            events.append(event("pod-0", kind, "kubernetes-pod-watch"))
        after = {}
        after.update(sample("hooke_collector_sample_percent", 10))
        after.update(
            sample(
                "hooke_collector_sampling_events_total", 3, decision="kept"
            )
        )
        after.update(
            sample(
                "hooke_collector_sampling_events_total",
                9,
                decision="sampled_out",
            )
        )
        after.update(
            sample(
                "hooke_collector_queue_events_total", 3, result="enqueued"
            )
        )
        after.update(
            sample(
                "hooke_collector_delivery_events_total", 3, result="sent"
            )
        )
        after.update(sample("hooke_collector_queue_depth", 0))
        result = e08.summarize_cell(
            cell=e08.generate_schedule()[1],
            run_id=RUN_ID,
            workload_namespace=NAMESPACE,
            target_nodes=NODES,
            image=IMAGE,
            expected_pods=4,
            job_payload={"status": {"succeeded": 4}},
            pods_payload={"items": pods},
            events=events,
            metrics_samples=[resource_sample()],
            system_pods_payload=system_pods(),
            metrics_before={},
            metrics_after=after,
        )
        self.assertEqual(result["trace_complete_rate"], 0.25)
        self.assertEqual(result["collector_metrics"]["sampling_sampled_out"], 9)

    def test_aggregate_does_not_claim_formal_statistics(self):
        cells = []
        for row in e08.generate_schedule():
            cells.append(
                {
                    **row,
                    "gate": "PASS",
                    "target_nodes": NODES,
                    "image": IMAGE,
                }
            )
        result = e08.aggregate(e08.generate_schedule(), cells)
        self.assertEqual(result["gate"], "PASS")
        self.assertFalse(result["formal_statistics_executed"])


if __name__ == "__main__":
    unittest.main()
