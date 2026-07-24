import copy
import importlib.util
import math
import re
import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "e04-keda-scale-to-zero.py"
RUNNER = Path(__file__).resolve().parents[1] / "ack-keda-scale-to-zero.sh"
SPEC = importlib.util.spec_from_file_location("e04_runner", SCRIPT)
assert SPEC and SPEC.loader
e04_runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = e04_runner
SPEC.loader.exec_module(e04_runner)


class E04KEDAScaleToZeroTest(unittest.TestCase):
    def test_wait_http_initializes_timeout_before_deadline_under_nounset(self):
        runner = RUNNER.read_text()
        match = re.search(r"(?ms)^wait_http\(\) \{\n.*?^\}", runner)
        self.assertIsNotNone(match)
        program = "\n".join(
            [
                "set -u",
                match.group(0),
                "curl() { return 0; }",
                'wait_http "http://127.0.0.1/readyz" 1 "test service"',
            ]
        )
        subprocess.run(["bash", "-c", program], check=True)

    def test_schedule_is_randomized_within_complete_blocks(self):
        schedule = e04_runner.generate_schedule(5, 20260724)
        self.assertEqual(len(schedule), 10)
        self.assertEqual(
            [row["sequence"] for row in schedule], list(range(1, 11))
        )
        for block in range(1, 6):
            self.assertEqual(
                {
                    row["cooldown_seconds"]
                    for row in schedule
                    if row["block"] == block
                },
                {60, 300},
            )

    def test_metric_capture_normalization_preserves_source_and_observed_times(self):
        base = 1_800_000_000_000_000_000
        captures = [
            {
                "observed_time_ns": base + 2_000_000_000,
                "namespace": "e04",
                "scaled_object": "worker",
                "metric_name": "s0-redis-worker",
                "payload": {
                    "apiVersion": "external.metrics.k8s.io/v1beta1",
                    "items": [
                        {
                            "metricName": "s0-redis-worker",
                            "timestamp": "2027-01-15T08:00:01.123456789Z",
                            "value": "1500m",
                            "metricLabels": None,
                        }
                    ],
                },
            }
        ]
        events = e04_runner.normalize_metric_samples(
            captures,
            "cluster-a",
            "run-a",
            base,
            base + 10_000_000_000,
        )
        self.assertEqual(len(events), 1)
        item = events[0]
        self.assertEqual(item["observed_time_ns"], base + 2_000_000_000)
        self.assertEqual(
            item["event_time_ns"],
            e04_runner.timestamp_ns("2027-01-15T08:00:01.123456789Z"),
        )
        self.assertEqual(item["attributes"]["metric_value_float"], 1.5)
        self.assertTrue(item["approximate"])
        self.assertEqual(len(item["event_id"]), 26)

    def test_capture_error_fails_normalization(self):
        with self.assertRaisesRegex(e04_runner.ValidationError, "failed request"):
            e04_runner.normalize_metric_samples(
                [
                    {
                        "observed_time_ns": 100,
                        "namespace": "e04",
                        "scaled_object": "worker",
                        "error": "metrics API unavailable",
                    }
                ],
                "cluster",
                "run",
                1,
                200,
            )

    def test_validate_run_requires_complete_exact_causal_chain(self):
        config, initial, scaled_object, events = self.valid_run()
        observation = e04_runner.validate_run(
            events, initial, scaled_object, config
        )
        self.assertEqual(observation["result"], "PASS")
        self.assertAlmostEqual(observation["observed_lambda_per_second"], 1)
        self.assertAlmostEqual(observation["cold_start_seconds"], 2.5)
        self.assertAlmostEqual(
            observation["observed_scale_to_zero_seconds"], 60
        )
        self.assertEqual(observation["message_count"], 2)
        self.assertFalse(observation["active_transition_approximate"])
        self.assertFalse(observation["inactive_transition_approximate"])
        self.assertTrue(observation["cooldown_timing_approximate"])

        approximate_transitions = copy.deepcopy(events)
        for item in approximate_transitions:
            if item["event_type"] in {
                "KEDA_SCALEDOBJECT_ACTIVE",
                "KEDA_SCALEDOBJECT_INACTIVE",
            }:
                item["approximate"] = True
        approximate_observation = e04_runner.validate_run(
            approximate_transitions, initial, scaled_object, config
        )
        self.assertTrue(
            approximate_observation["active_transition_approximate"]
        )
        self.assertTrue(
            approximate_observation["inactive_transition_approximate"]
        )
        self.assertTrue(approximate_observation["cooldown_timing_approximate"])

        broken = [
            item
            for item in events
            if not (
                item["event_type"] == "MESSAGE_PROCESSED"
                and item["attributes"].get("message_id") == "message-2"
            )
        ]
        with self.assertRaisesRegex(
            e04_runner.ValidationError, "MESSAGE_PROCESSED count"
        ):
            e04_runner.validate_run(
                broken, initial, scaled_object, config
            )

    def test_summary_solves_tau_star_from_pooled_inputs(self):
        config, initial, scaled_object, events = self.valid_run()
        first = e04_runner.validate_run(events, initial, scaled_object, config)
        second = copy.deepcopy(first)
        second.update(
            {
                "sequence": 2,
                "block": 1,
                "cell_id": "cooldown-300s",
                "cooldown_seconds": 300,
            }
        )
        schedule = [
            {
                "sequence": "1",
                "block": "1",
                "cell_id": "cooldown-60s",
                "cooldown_seconds": "60",
            },
            {
                "sequence": "2",
                "block": "1",
                "cell_id": "cooldown-300s",
                "cooldown_seconds": "300",
            },
        ]
        summary, rows = e04_runner.summarize(
            schedule, [first, second], 0.99, 3600
        )
        self.assertEqual(summary["result"], "PASS")
        self.assertEqual(summary["run_count"], 2)
        self.assertEqual(len(summary["cells"]), 2)
        self.assertTrue(
            math.isfinite(summary["recommended_cooldown_tau_star_seconds"])
        )
        self.assertEqual(len(rows), 2)

    def test_rendered_manifests_keep_secret_references_and_zero_baseline(self):
        config, _, _, _ = self.valid_run()
        config.update(
            {
                "cluster_id": "cluster",
                "redis_name": "redis",
                "producer_name": "producer",
                "completion_key": "completed",
                "app_image": "registry/e04@sha256:" + "a" * 64,
                "redis_image": "registry/redis@sha256:" + "b" * 64,
                "node_selector_key": "hooke.io/pool",
                "node_selector_value": "fixed",
                "taint_key": "",
                "taint_value": "",
                "processing_duration": "2s",
                "queue_sample_interval": "1s",
                "producer_timeout_seconds": 900,
                "redis_cpu_request": "100m",
                "redis_cpu_limit": "500m",
                "redis_memory_request": "128Mi",
                "redis_memory_limit": "256Mi",
                "worker_cpu_request": "100m",
                "worker_cpu_limit": "500m",
                "worker_memory_request": "64Mi",
                "worker_memory_limit": "128Mi",
                "producer_cpu_request": "50m",
                "producer_cpu_limit": "250m",
                "producer_memory_request": "32Mi",
                "producer_memory_limit": "64Mi",
            }
        )
        base, producer = e04_runner.render_manifests(
            config, "e04-run", "run-id", "redis-auth"
        )
        worker = next(
            item
            for item in base["items"]
            if item["kind"] == "Deployment"
            and item["metadata"]["name"] == "worker"
        )
        worker_security = worker["spec"]["template"]["spec"]["containers"][0][
            "securityContext"
        ]
        self.assertTrue(worker_security["runAsNonRoot"])
        self.assertEqual(worker_security["runAsUser"], 65532)
        self.assertEqual(worker_security["runAsGroup"], 65532)
        scaled_object = next(
            item for item in base["items"] if item["kind"] == "ScaledObject"
        )
        self.assertEqual(worker["spec"]["replicas"], 0)
        self.assertEqual(scaled_object["spec"]["cooldownPeriod"], 60)
        password_env = next(
            item
            for item in worker["spec"]["template"]["spec"]["containers"][0]["env"]
            if item["name"] == "E04_REDIS_PASSWORD"
        )
        address_env = next(
            item
            for item in worker["spec"]["template"]["spec"]["containers"][0]["env"]
            if item["name"] == "E04_REDIS_ADDRESS"
        )
        self.assertEqual(
            address_env["value"], "redis.e04-run.svc.cluster.local:6379"
        )
        self.assertEqual(
            password_env["valueFrom"]["secretKeyRef"]["name"], "redis-auth"
        )
        self.assertNotIn("value", password_env)
        self.assertEqual(producer["kind"], "Job")
        invalid = copy.deepcopy(config)
        invalid["worker_cpu_request"] = "1"
        invalid["worker_cpu_limit"] = "500m"
        with self.assertRaisesRegex(
            e04_runner.ValidationError, "exceeds its limit"
        ):
            e04_runner.render_manifests(
                invalid, "e04-run", "run-id", "redis-auth"
            )

    @staticmethod
    def valid_run():
        second = 1_000_000_000
        base = 1_800_000_000 * second
        config = {
            "sequence": 1,
            "block": 1,
            "cell_id": "cooldown-60s",
            "cooldown_seconds": 60,
            "polling_interval_seconds": 5,
            "min_replicas": 0,
            "max_replicas": 4,
            "lambda_per_second": 1,
            "message_count": 2,
            "worker_name": "worker",
            "scaled_object_name": "worker-scaler",
            "queue_key": "queue",
            "list_length": "1",
            "activation_list_length": "0",
            "arrival_rate_relative_tolerance": 0.1,
            "metric_sample_max_gap_seconds": 100,
        }
        scaled_object = {
            "metadata": {"name": "worker-scaler"},
            "spec": {
                "pollingInterval": 5,
                "cooldownPeriod": 60,
                "minReplicaCount": 0,
                "maxReplicaCount": 4,
                "scaleTargetRef": {"name": "worker"},
                "triggers": [
                    {
                        "type": "redis",
                        "metadata": {
                            "addressFromEnv": "E04_REDIS_ADDRESS",
                            "passwordFromEnv": "E04_REDIS_PASSWORD",
                            "listName": "queue",
                            "listLength": "1",
                            "activationListLength": "0",
                            "databaseIndex": "0",
                            "enableTLS": "false",
                        },
                    }
                ],
            },
        }
        initial = {
            "deployment": {
                "spec": {"replicas": 0},
                "status": {
                    "replicas": 0,
                    "readyReplicas": 0,
                    "availableReplicas": 0,
                },
            },
            "scaled_object": {
                "status": {
                    "conditions": [{"type": "Active", "status": "False"}]
                }
            },
        }

        events = []

        def generic(event_type, offset, **fields):
            item = {
                "cluster_id": "cluster",
                "run_id": "run",
                "event_type": event_type,
                "event_time_ns": base + int(offset * second),
                "source_time_ns": base + int(offset * second),
                "observed_time_ns": base + int(offset * second),
                "approximate": False,
                "attributes": {},
            }
            item.update(fields)
            events.append(item)
            return item

        def application(event_type, offset, attrs, pod):
            generic(
                event_type,
                offset,
                source_component="application-event-log",
                pod_name=pod,
                pod_uid=pod + "-uid",
                attributes={
                    **attrs,
                    "persistence": "container-stdout",
                    "precision": "application-source-timestamp",
                },
            )

        generic(
            "KEDA_SCALEDOBJECT_CREATED",
            90,
            workload_name="worker-scaler",
        )
        generic(
            "KEDA_SCALEDOBJECT_READY",
            91,
            workload_name="worker-scaler",
        )
        application(
            "QUEUE_DEPTH_SAMPLE",
            99,
            {
                "queue_depth": 0,
                "completed_count": 0,
                "observer": "producer",
            },
            "producer-abc",
        )
        application(
            "BUSY_PERIOD_STARTED",
            100,
            {"message_count": 2},
            "producer-abc",
        )
        application(
            "MESSAGE_ENQUEUED",
            100,
            {"message_id": "message-1", "sequence": 1},
            "producer-abc",
        )
        application(
            "QUEUE_DEPTH_SAMPLE",
            100.1,
            {
                "queue_depth": 1,
                "completed_count": 0,
                "observer": "producer",
            },
            "producer-abc",
        )
        application(
            "MESSAGE_ENQUEUED",
            101,
            {"message_id": "message-2", "sequence": 2},
            "producer-abc",
        )
        application(
            "QUEUE_DEPTH_SAMPLE",
            101.1,
            {
                "queue_depth": 2,
                "completed_count": 0,
                "observer": "producer",
            },
            "producer-abc",
        )
        generic(
            "KEDA_SCALEDOBJECT_ACTIVE",
            101.2,
            workload_name="worker-scaler",
        )
        generic(
            "HPA_DESIRED_REPLICAS_CHANGED",
            101.5,
            attributes={"scaled_object": "worker-scaler", "desired_replicas": 1},
        )
        generic("POD_READY", 102.5, pod_name="worker-abc", pod_uid="worker-uid")
        for message_id, sequence, dequeue, processed in (
            ("message-1", 1, 102, 103),
            ("message-2", 2, 102.2, 104),
        ):
            application(
                "MESSAGE_DEQUEUED",
                dequeue,
                {"message_id": message_id, "sequence": sequence},
                "worker-abc",
            )
            application(
                "MESSAGE_PROCESSING_STARTED",
                dequeue,
                {"message_id": message_id, "sequence": sequence},
                "worker-abc",
            )
            application(
                "MESSAGE_PROCESSED",
                processed,
                {"message_id": message_id, "sequence": sequence},
                "worker-abc",
            )
        application(
            "QUEUE_DEPTH_SAMPLE",
            104,
            {
                "queue_depth": 0,
                "completed_count": 2,
                "observer": "producer",
            },
            "producer-abc",
        )
        application(
            "BUSY_PERIOD_ENDED",
            104.1,
            {"message_count": 2},
            "producer-abc",
        )
        generic(
            "KEDA_SCALEDOBJECT_INACTIVE",
            104.2,
            workload_name="worker-scaler",
        )
        generic(
            "KEDA_SCALE_TO_ZERO",
            164.2,
            workload_name="worker",
            approximate=True,
            attributes={"scaled_object": "worker-scaler", "desired_replicas": 0},
        )
        for offset, value in ((99, 0), (101.3, 2), (104.3, 0)):
            generic(
                "KEDA_SCALER_SAMPLE",
                offset,
                source_component="keda-external-metrics-api",
                observed_time_ns=base + int(offset * second),
                approximate=True,
                attributes={
                    "scaled_object": "worker-scaler",
                    "metric_name": "s0-redis-worker",
                    "metric_value_float": value,
                },
            )
        return config, initial, scaled_object, events


if __name__ == "__main__":
    unittest.main()
