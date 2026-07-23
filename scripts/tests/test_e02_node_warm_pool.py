import csv
import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "e02-node-warm-pool.py"
TEST_IMAGE = "registry.example.com/hooke/smoke@sha256:" + "a" * 64
SPEC = importlib.util.spec_from_file_location("e02_node_warm_pool", SCRIPT)
assert SPEC and SPEC.loader
e02 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = e02
SPEC.loader.exec_module(e02)


def node(name="node-a", uid="node-uid-a", provider="provider-a", ready=True, unschedulable=False):
    return {
        "metadata": {
            "name": name,
            "uid": uid,
            "labels": {
                "node.kubernetes.io/instance-type": "ecs.c7.large",
                "topology.kubernetes.io/zone": "zone-a",
                "nodepool": "elastic",
            },
        },
        "spec": {
            "providerID": provider,
            "unschedulable": unschedulable,
            "taints": [
                {"key": "hooke.io/experiment", "value": "elastic", "effect": "NoSchedule"}
            ],
        },
        "status": {
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}]
        },
    }


def workload_pod(
    node_name="node-a",
    uid="pod-uid-a",
    image=TEST_IMAGE,
    *,
    namespace="e02-warm-node-test1234",
    run_id="run-warm-node",
    workload="workload-a",
    replica_set_name="workload-a-rs",
    replica_set_uid="replica-set-uid-a",
):
    return {
        "metadata": {
            "name": "workload-a",
            "namespace": namespace,
            "uid": uid,
            "labels": {"hooke.io/experiment": "true", "app": workload},
            "annotations": {"hooke.io/run-id": run_id},
            "ownerReferences": [
                {
                    "apiVersion": "apps/v1",
                    "kind": "ReplicaSet",
                    "name": replica_set_name,
                    "uid": replica_set_uid,
                    "controller": True,
                }
            ],
        },
        "spec": {
            "nodeName": node_name,
            "nodeSelector": {"nodepool": "elastic"},
            "containers": [
                {
                    "name": "app",
                    "image": image,
                    "imagePullPolicy": "IfNotPresent",
                    "command": ["/smoke-app"],
                    "env": [
                        {"name": "HOOKE_CLUSTER_ID", "value": "cluster-a"},
                        {"name": "HOOKE_RUN_ID", "value": run_id},
                        {"name": "HOOKE_STARTUP_WORK_MIB", "value": "0"},
                        {"name": "HOOKE_WORKLOAD_KIND", "value": "Deployment"},
                        {"name": "HOOKE_WORKLOAD_NAME", "value": workload},
                        {"name": "HOOKE_CONTAINER_NAME", "value": "app"},
                    ],
                    "resources": {
                        "requests": {"cpu": "500m", "memory": "256Mi"},
                        "limits": {"cpu": "1000m", "memory": "512Mi"},
                    },
                }
            ],
            "tolerations": [
                {
                    "key": "hooke.io/experiment",
                    "operator": "Equal",
                    "value": "elastic",
                    "effect": "NoSchedule",
                }
            ],
        },
        "status": {
            "containerStatuses": [
                {"name": "app", "containerID": "containerd://" + "c" * 64}
            ]
        },
    }


def cni_pod(node_name="node-a", ready=True):
    return {
        "metadata": {"name": "flannel-a"},
        "spec": {"nodeName": node_name},
        "status": {
            "phase": "Running",
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
        },
    }


def write_tsv(path, fields, rows):
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


class KubernetesMicroTimeTest(unittest.TestCase):
    def test_microtime_is_utc_with_exactly_six_fractional_digits(self):
        value = datetime(2026, 7, 23, 2, 35, 23, 1234, tzinfo=timezone.utc)
        self.assertEqual(
            e02.format_kubernetes_microtime(value),
            "2026-07-23T02:35:23.001234Z",
        )

    def test_microtime_rejects_naive_datetime(self):
        with self.assertRaises(e02.ValidationError):
            e02.format_kubernetes_microtime(datetime(2026, 7, 23, 2, 35, 23))


class ScheduleTest(unittest.TestCase):
    def test_schedule_is_deterministic_and_paired(self):
        first = e02.generate_schedule(5, 20260722)
        second = e02.generate_schedule(5, 20260722)
        self.assertEqual(first, second)
        self.assertEqual(len(first), 10)
        self.assertEqual([item["sequence"] for item in first], list(range(1, 11)))
        for block in range(1, 6):
            selected = [item for item in first if item["block"] == block]
            self.assertEqual({item["variant"] for item in selected}, set(e02.VARIANTS))
            self.assertTrue(all(item["repetition"] == block for item in selected))


class PoolStateTest(unittest.TestCase):
    def arguments(self, mode, nodes, pods=None, cni=None, require_cni=False):
        return e02.validate_pool_state(
            mode=mode,
            nodes_payload={"items": nodes},
            pods_payload={"items": pods or []},
            cni_payload={"items": cni or []} if cni is not None else None,
            selector_key="nodepool",
            selector_value="elastic",
            expected_instance_type="ecs.c7.large",
            expected_zone="zone-a",
            taint_key="hooke.io/experiment",
            taint_value="elastic",
            taint_effect="NoSchedule",
            require_cni=require_cni,
        )

    def test_cold_requires_zero_nodes_and_no_target_workload(self):
        result = self.arguments("cold-node", [])
        self.assertTrue(result["valid"])
        self.assertEqual(result["non_daemon_workloads"], [])
        with self.assertRaises(e02.ValidationError):
            self.arguments("cold-node", [node()])
        with self.assertRaises(e02.ValidationError):
            self.arguments("cold-node", [], [workload_pod(node_name="")])
        business_pod = workload_pod(node_name="")
        business_pod["metadata"]["labels"].pop("hooke.io/experiment")
        with self.assertRaises(e02.ValidationError):
            self.arguments("cold-node", [], [business_pod])

    def test_daemonset_targeting_pool_is_not_a_scale_down_blocker(self):
        daemon_pod = workload_pod(node_name="")
        daemon_pod["metadata"]["labels"].pop("hooke.io/experiment")
        daemon_pod["metadata"]["ownerReferences"] = [
            {"kind": "DaemonSet", "controller": True}
        ]
        result = self.arguments("cold-node", [], [daemon_pod])
        self.assertEqual(result["non_daemon_workloads"], [])

    def test_warm_requires_one_ready_schedulable_node_and_ready_cni(self):
        result = self.arguments(
            "warm-node", [node()], cni=[cni_pod()], require_cni=True
        )
        self.assertEqual(result["node"]["uid"], "node-uid-a")
        with self.assertRaises(e02.ValidationError):
            self.arguments("warm-node", [node(ready=False)], cni=[cni_pod()], require_cni=True)
        with self.assertRaises(e02.ValidationError):
            self.arguments("warm-node", [node(unschedulable=True)], cni=[cni_pod()], require_cni=True)
        with self.assertRaises(e02.ValidationError):
            self.arguments("warm-node", [node()], cni=[cni_pod(ready=False)], require_cni=True)
        with self.assertRaises(e02.ValidationError):
            self.arguments("warm-node", [node()], pods=[workload_pod()], cni=[cni_pod()], require_cni=True)
        business_pod = workload_pod()
        business_pod["metadata"]["labels"].pop("hooke.io/experiment")
        with self.assertRaises(e02.ValidationError):
            self.arguments(
                "warm-node", [node()], pods=[business_pod], cni=[cni_pod()], require_cni=True
            )
        missing_taint = node()
        missing_taint["spec"]["taints"] = []
        with self.assertRaises(e02.ValidationError):
            self.arguments("warm-node", [missing_taint], cni=[cni_pod()], require_cni=True)


class ControlEvidenceTest(unittest.TestCase):
    def base(self, action):
        return {
            "action": action,
            "cluster_id": "cluster-a",
            "node_pool_id": "pool-a",
            "node_pool_name": "e02-pool",
            "resource_group_id": "rg-a",
            "region_id": "region-a",
            "api_server": "https://api.example.test:6443",
            "observed_at": "2026-07-22T00:00:00Z",
            "auto_scaling_enabled": True,
            "nodepool_type": "ess",
            "is_default": False,
            "selector": {"key": "nodepool", "value": "elastic"},
            "taint": {
                "key": "hooke.io/experiment",
                "value": "elastic",
                "effect": "NoSchedule",
            },
        }

    def validate(self, payload, action, min_size=None, snapshot=None):
        return e02.validate_control_evidence(
            payload,
            expected_action=action,
            expected_cluster_id="cluster-a",
            expected_node_pool_id="pool-a",
            expected_node_pool_name="e02-pool",
            expected_resource_group_id="rg-a",
            expected_region_id="region-a",
            expected_api_server="https://api.example.test:6443",
            expected_selector_key="nodepool",
            expected_selector_value="elastic",
            expected_taint_key="hooke.io/experiment",
            expected_taint_value="elastic",
            expected_taint_effect="NoSchedule",
            expected_min_size=min_size,
            snapshot=snapshot,
        )

    def test_snapshot_set_and_restore_are_verified(self):
        snapshot = self.base("snapshot") | {"min_size": 0, "max_size": 1}
        self.validate(snapshot, "snapshot")
        changed = self.base("set-min") | {
            "requested_min_size": 1,
            "observed_min_size": 1,
            "observed_max_size": 1,
            "changed": True,
            "task_id": "task-a",
            "task_state": "success",
        }
        self.validate(changed, "set-min", min_size=1)
        restored = self.base("restore") | {
            "observed_min_size": 0,
            "observed_max_size": 1,
            "prior_mutation_uncertain": False,
            "task_id": "task-restore",
            "task_state": "success",
        }
        self.validate(restored, "restore", snapshot=snapshot)
        with self.assertRaises(e02.ValidationError):
            self.validate(restored | {"observed_min_size": 1}, "restore", snapshot=snapshot)
        with self.assertRaises(e02.ValidationError):
            self.validate(self.base("check") | {"min_size": 2, "max_size": 2}, "check")


class RunValidationTest(unittest.TestCase):
    image = TEST_IMAGE
    seed = 20260722
    expected_command = ["/smoke-app"]

    def make_fixture(self, root, variant):
        artifact = root / variant
        artifact.mkdir()
        is_cold = variant == "cold-node"
        run_id = f"run-{variant}"
        namespace = f"e02-{variant}-fixture"
        namespace_uid = f"namespace-uid-{variant}"
        workload = "node-scale-a" if is_cold else "fixed-a"
        replica_set_name = f"{workload}-rs"
        replica_set_uid = f"replica-set-uid-{variant}"
        deployment_uid = f"deployment-uid-{variant}"
        schedule_item = next(
            item
            for item in e02.generate_schedule(1, self.seed)
            if item["variant"] == variant
        )
        summary = "\n".join(
            [
                "# Hooke ACK first smoke summary",
                "",
                "- result: **PASS**",
                f"- run_id: `{run_id}`",
                f"- node_layer_samples: {1 if is_cold else 0}",
                f"- exact_node_samples: {1 if is_cold else 0}",
                "- pod_unschedulable_events: 1" if is_cold else "- pod_unschedulable_events: 0",
                f"- new_elastic_nodes: {1 if is_cold else 0}",
                "- provision_requested_events: 1" if is_cold else "- provision_requested_events: 0",
                f"- sandbox_failed_pods: {1 if is_cold else 0}",
                f"- sandbox_failure_attempts: {1 if is_cold else 0}",
                f"- cni_failed_pods: {1 if is_cold else 0}",
                f"- cni_failure_attempts: {1 if is_cold else 0}",
                "",
            ]
        )
        (artifact / "summary.md").write_text(summary, encoding="utf-8")
        (artifact / "run.json").write_text(
            json.dumps(
                {
                    "run_id": run_id,
                    "cluster_id": "cluster-a",
                    "labels": {
                        "experiment": "E02-node-warm-pool",
                        "phase": "pilot",
                        "variant": variant,
                        "sequence": schedule_item["sequence"],
                        "block": schedule_item["block"],
                        "repetition": schedule_item["repetition"],
                        "random_seed": self.seed,
                        "image_ref": self.image,
                        "image_state": "cold",
                        "replicas": 1,
                        "image_build_commit": "1" * 40,
                        "orchestrator_commit": "2" * 40,
                    },
                }
            ),
            encoding="utf-8",
        )
        (artifact / "experiment-namespace.json").write_text(
            json.dumps(
                {
                    "name": namespace,
                    "uid": namespace_uid,
                    "run_id": run_id,
                    "created_by_run": True,
                }
            ),
            encoding="utf-8",
        )
        event_ids = {
            event_type: f"{index:026d}"
            for index, event_type in enumerate(
                (
                "POD_SANDBOX_START",
                "POD_SANDBOX_END",
                "IMAGE_PULL_START",
                "IMAGE_PULL_END",
                "CONTAINER_STARTED",
                "READINESS_PROBE_FIRST_SUCCESS",
                ),
                1,
            )
        }
        quality = {
            "pod_start_event": "POD_SANDBOX_START",
            "pod_start_event_id": event_ids["POD_SANDBOX_START"],
            "image_start_event": "IMAGE_PULL_START",
            "image_start_event_id": event_ids["IMAGE_PULL_START"],
            "image_end_event": "IMAGE_PULL_END",
            "image_end_event_id": event_ids["IMAGE_PULL_END"],
            "container_started_event_id": event_ids["CONTAINER_STARTED"],
            "app_end_event": "READINESS_PROBE_FIRST_SUCCESS",
            "app_end_event_id": event_ids["READINESS_PROBE_FIRST_SUCCESS"],
            "node_clock_uncertainty_unknown": True,
            "sandbox_clock_uncertainty_unknown": True,
        }
        write_tsv(
            artifact / "traces.tsv",
            [
                "pod_name",
                "container_name",
                "node_name",
                "complete",
                "node_ms",
                "image_ms",
                "pod_ms",
                "app_ms",
                "total_ms",
                "overlap_ms",
                "unattributed_ms",
                "exact_coverage",
                "invalid_order_count",
                "quality",
            ],
            [
                {
                    "pod_name": "workload-a",
                    "container_name": "app",
                    "node_name": "node-a",
                    "complete": 1,
                    "node_ms": 500 if is_cold else "NULL",
                    "image_ms": 400,
                    "pod_ms": 1200,
                    "app_ms": 800,
                    "total_ms": 3000,
                    "overlap_ms": 0,
                    "unattributed_ms": 0,
                    "exact_coverage": 1,
                    "invalid_order_count": 0,
                    "quality": json.dumps(quality, separators=(",", ":")),
                }
            ],
        )
        (artifact / "pods-workload-1.json").write_text(
            json.dumps(
                {
                    "items": [
                        workload_pod(
                            namespace=namespace,
                            run_id=run_id,
                            workload=workload,
                            replica_set_name=replica_set_name,
                            replica_set_uid=replica_set_uid,
                        )
                    ]
                }
            ),
            encoding="utf-8",
        )
        write_tsv(
            artifact / "orchestrator-timing.tsv",
            [
                "cluster_id",
                "run_id",
                "namespace",
                "namespace_uid",
                "workload",
                "iteration",
                "path",
                "requested_replicas",
                "clock_type",
                "clock_source",
                "source_host",
                "boot_id",
                "start_monotonic_ns",
                "end_monotonic_ns",
                "scale_rc",
                "rollout_rc",
                "evidence_rc",
                "deployment_uid",
                "replica_set_uid",
                "replica_set_name",
                "deployment_generation_before",
                "deployment_generation_after",
                "observed_generation",
                "pod_uid",
                "pod_name",
            ],
            [
                {
                    "cluster_id": "cluster-a",
                    "run_id": run_id,
                    "namespace": namespace,
                    "namespace_uid": namespace_uid,
                    "workload": workload,
                    "iteration": 1,
                    "path": "node-scale" if is_cold else "fixed",
                    "requested_replicas": 1,
                    "clock_type": "CLOCK_MONOTONIC",
                    "clock_source": "python-time.monotonic_ns",
                    "source_host": "fixture-host",
                    "boot_id": "11111111-2222-3333-4444-555555555555",
                    "start_monotonic_ns": 10_000_000_000 if is_cold else 20_000_000_000,
                    "end_monotonic_ns": 13_000_000_000 if is_cold else 21_000_000_000,
                    "scale_rc": 0,
                    "rollout_rc": 0,
                    "evidence_rc": 0,
                    "deployment_uid": deployment_uid,
                    "replica_set_uid": replica_set_uid,
                    "replica_set_name": replica_set_name,
                    "deployment_generation_before": 1,
                    "deployment_generation_after": 2,
                    "observed_generation": 2,
                    "pod_uid": "pod-uid-a",
                    "pod_name": "workload-a",
                }
            ],
        )
        runtime = []
        for event_type, at in [
            ("POD_SANDBOX_START", 2_000_000_000),
            ("POD_SANDBOX_END", 2_500_000_000),
            ("IMAGE_PULL_START", 2_600_000_000),
            ("IMAGE_PULL_END", 3_000_000_000),
            ("CONTAINER_STARTED", 3_200_000_000),
            ("READINESS_PROBE_FIRST_SUCCESS", 4_000_000_000),
        ]:
            item = {
                "cluster_id": "cluster-a",
                "run_id": run_id,
                "event_id": event_ids[event_type],
                "event_type": event_type,
                "event_time_ns": at,
                "namespace": namespace,
                "pod_name": "workload-a",
                "pod_uid": "pod-uid-a",
                "node_name": "node-a",
                "node_uid": "node-uid-a",
                "approximate": False,
                "clock_type": "realtime",
                "source_time_ns": at,
                "source_instance": "node-a",
            }
            if event_type.startswith("POD_SANDBOX"):
                item["source_component"] = "containerd-cri-journal"
                item["attributes"] = {
                    "precision": "containerd-cri-journal",
                    "runtime_operation": "RunPodSandbox",
                    "association": "pod-uid+sandbox-id",
                    "sandbox_id": "sandbox-a",
                }
            elif event_type in {"IMAGE_PULL_START", "IMAGE_PULL_END", "CONTAINER_STARTED"}:
                item["source_component"] = "containerd-cri-journal"
                item["container_name"] = "app"
                item["container_id"] = "c" * 64
                item["image_ref"] = self.image
                item["image_digest"] = "sha256:" + "a" * 64
                item["result"] = (
                    "started" if event_type == "IMAGE_PULL_START" else "success"
                )
                item["attributes"] = {
                    "precision": "containerd-cri-journal",
                    "runtime_operation": (
                        "PullImage" if event_type.startswith("IMAGE_PULL") else "StartContainer"
                    ),
                    "association": "pod-uid+sandbox-id+container-id",
                    "sandbox_id": "sandbox-a",
                }
            else:
                item["source_component"] = "application-event-log"
                item["container_name"] = "app"
                item["container_id"] = "c" * 64
                item["image_ref"] = self.image
                item["image_digest"] = "sha256:" + "a" * 64
                item["attributes"] = {
                    "precision": "application-source-timestamp",
                    "persistence": "container-stdout",
                }
            if event_type == "IMAGE_PULL_END":
                item["attributes"]["download_bytes"] = 70_000_000
            runtime.append(item)
        (artifact / "runtime-events.ndjson").write_text(
            "".join(json.dumps(item) + "\n" for item in runtime), encoding="utf-8"
        )
        failures = []
        if is_cold:
            failures = [
                {
                    "cluster_id": "cluster-a",
                    "run_id": run_id,
                    "namespace": namespace,
                    "pod_uid": "pod-uid-a",
                    "pod_name": "workload-a",
                    "event_type": "POD_SANDBOX_FAILED",
                    "event_uid": "event-sandbox",
                    "attempts": 1,
                },
                {
                    "cluster_id": "cluster-a",
                    "run_id": run_id,
                    "namespace": namespace,
                    "pod_uid": "pod-uid-a",
                    "pod_name": "workload-a",
                    "event_type": "CNI_SETUP_FAILED",
                    "event_uid": "event-cni",
                    "attempts": 1,
                },
            ]
        write_tsv(
            artifact / "sandbox-failures.tsv",
            [
                "cluster_id",
                "run_id",
                "namespace",
                "pod_uid",
                "pod_name",
                "event_type",
                "event_uid",
                "attempts",
            ],
            failures,
        )
        write_tsv(
            artifact / "trace-timestamps.tsv",
            [
                "pod_uid",
                "pod_name",
                "node_name",
                "trigger_time_ns",
                "node_start_ns",
                "node_ready_ns",
                "image_pull_start_ns",
                "image_pull_end_ns",
                "image_unpack_end_ns",
                "sync_pod_start_ns",
                "pod_sandbox_start_ns",
                "pod_sandbox_end_ns",
                "container_started_ns",
                "readiness_success_ns",
                "node_clock_uncertainty_unknown",
                "sandbox_clock_uncertainty_unknown",
            ],
            [
                {
                    "pod_uid": "pod-uid-a",
                    "pod_name": "workload-a",
                    "node_name": "node-a",
                    "trigger_time_ns": 1_000_000_000,
                    "node_start_ns": 1_000_000_000 if is_cold else "NULL",
                    "node_ready_ns": 1_500_000_000 if is_cold else "NULL",
                    "image_pull_start_ns": 2_600_000_000,
                    "image_pull_end_ns": 3_000_000_000,
                    "image_unpack_end_ns": "NULL",
                    "sync_pod_start_ns": 2_000_000_000,
                    "pod_sandbox_start_ns": 2_000_000_000,
                    "pod_sandbox_end_ns": 2_500_000_000,
                    "container_started_ns": 3_200_000_000,
                    "readiness_success_ns": 4_000_000_000,
                    "node_clock_uncertainty_unknown": "true",
                    "sandbox_clock_uncertainty_unknown": "true",
                }
            ],
        )
        write_tsv(
            artifact / "pod-lifecycle-events.tsv",
            [
                "cluster_id",
                "run_id",
                "namespace",
                "pod_uid",
                "pod_name",
                "node_name",
                "event_type",
                "event_time_ns",
            ],
            [
                {
                    "cluster_id": "cluster-a",
                    "run_id": run_id,
                    "namespace": namespace,
                    "pod_uid": "pod-uid-a",
                    "pod_name": "workload-a",
                    "node_name": "node-a",
                    "event_type": "POD_SCHEDULED",
                    "event_time_ns": 1_500_000_000,
                }
            ],
        )
        before = {"items": [] if is_cold else [node()]}
        after = {"items": [node()]}
        before_path = root / f"{variant}-before.json"
        after_path = root / f"{variant}-after.json"
        before_path.write_text(json.dumps(before), encoding="utf-8")
        after_path.write_text(json.dumps(after), encoding="utf-8")
        warm_state = None
        if not is_cold:
            warm_state = root / "warm-state.json"
            warm_state.write_text(
                json.dumps(
                    {
                        "valid": True,
                        "mode": "warm-node",
                        "selected_node_count": 1,
                        "selector": "nodepool=elastic",
                        "node": e02.node_identity(node()),
                        "instance_type": "ecs.c7.large",
                        "zone": "zone-a",
                        "taint": {
                            "key": "hooke.io/experiment",
                            "value": "elastic",
                            "effect": "NoSchedule",
                        },
                        "cni_ready_pods": ["flannel-a"],
                        "residual_experiment_pods": [],
                        "non_daemon_workloads": [],
                    }
                ),
                encoding="utf-8",
            )
        return artifact, before_path, after_path, warm_state

    def validate(self, fixture, variant):
        artifact, before, after, warm_state = fixture
        return e02.validate_run(
            variant=variant,
            artifact_dir=artifact,
            pool_before_path=before,
            pool_after_path=after,
            warm_state_path=warm_state,
            expected_cluster_id="cluster-a",
            expected_image=self.image,
            expected_instance_type="ecs.c7.large",
            expected_zone="zone-a",
            selector_key="nodepool",
            selector_value="elastic",
            taint_key="hooke.io/experiment",
            taint_value="elastic",
            taint_effect="NoSchedule",
            expected_command=self.expected_command,
            expected_startup_work_mib=0,
            expected_cpu_request="500m",
            expected_cpu_limit="1000m",
            expected_memory_request="256Mi",
            expected_memory_limit="512Mi",
            min_download_bytes=64 * 1024 * 1024,
            require_warm_cni=variant == "warm-node",
        )

    def write_summary_evidence(self, root, results):
        schedule_rows = e02.generate_schedule(1, self.seed)
        schedule_path = root / "schedule.tsv"
        write_tsv(
            schedule_path,
            ["sequence", "block", "variant", "repetition"],
            schedule_rows,
        )
        by_variant = {item["variant"]: item for item in results}
        index_rows = []
        for schedule_item in schedule_rows:
            result = by_variant[schedule_item["variant"]]
            validation = root / f"validation-{schedule_item['sequence']}.json"
            validation.write_text(json.dumps(result), encoding="utf-8")
            index_rows.append(
                {
                    **schedule_item,
                    "artifact_dir": result["artifact_dir"],
                    "validation": validation,
                }
            )
        index_path = root / "run-index.tsv"
        write_tsv(
            index_path,
            ["sequence", "block", "variant", "repetition", "artifact_dir", "validation"],
            index_rows,
        )
        return index_path, schedule_path

    def test_cold_and_warm_run_gates_and_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cold = self.validate(self.make_fixture(root, "cold-node"), "cold-node")
            warm = self.validate(self.make_fixture(root, "warm-node"), "warm-node")
            self.assertEqual(cold["sandbox_failure_attempts"], 1)
            self.assertEqual(cold["cni_failure_attempts"], 1)
            self.assertIsNone(cold["node_ready_to_sandbox_start_ms"])
            self.assertIsNone(warm["node_ms"])
            self.assertIsNone(warm["node_ready_to_sandbox_start_ms"])

            index, schedule = self.write_summary_evidence(root, (cold, warm))
            observations, summary = e02.summarize_runs(index, 1, schedule, self.seed)
            self.assertEqual(len(observations), 2)
            self.assertEqual(summary["comparison"]["median_e2e_reduction_ms"], 2000)
            self.assertEqual(summary["percentiles_suppressed"], ["p95", "p99"])

    def test_warm_run_rejects_cache_hit_or_node_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.make_fixture(root, "warm-node")
            artifact, _, after, _ = fixture
            with (artifact / "runtime-events.ndjson").open("a", encoding="utf-8") as stream:
                stream.write(
                    json.dumps(
                        {
                            "event_type": "IMAGE_CACHE_HIT",
                            "pod_uid": "pod-uid-a",
                            "approximate": False,
                        }
                    )
                    + "\n"
                )
            with self.assertRaises(e02.ValidationError):
                self.validate(fixture, "warm-node")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.make_fixture(root, "warm-node")
            _, _, after, _ = fixture
            after.write_text(
                json.dumps({"items": [node(uid="replacement")]}), encoding="utf-8"
            )
            with self.assertRaises(e02.ValidationError):
                self.validate(fixture, "warm-node")

    def test_run_gate_rejects_unbound_or_invalid_measurements(self):
        cases = (
            "cold-null-node",
            "nan-image",
            "wrong-runtime-node",
            "wrong-runtime-container",
            "wrong-runtime-source",
            "trace-image-mismatch",
            "short-download",
            "bad-warm-state",
        )
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                variant = "warm-node" if case == "bad-warm-state" else "cold-node"
                fixture = self.make_fixture(root, variant)
                artifact, _, _, warm_state = fixture
                if case in {"cold-null-node", "nan-image", "trace-image-mismatch"}:
                    rows = e02.read_tsv(artifact / "traces.tsv")
                    if case == "cold-null-node":
                        rows[0]["node_ms"] = "NULL"
                    elif case == "nan-image":
                        rows[0]["image_ms"] = "NaN"
                    else:
                        rows[0]["image_ms"] = "999999"
                    write_tsv(artifact / "traces.tsv", list(rows[0]), rows)
                elif case in {
                    "wrong-runtime-node",
                    "wrong-runtime-container",
                    "wrong-runtime-source",
                    "short-download",
                }:
                    events = e02.read_ndjson(artifact / "runtime-events.ndjson")
                    if case == "wrong-runtime-node":
                        events[0]["node_name"] = "node-other"
                    elif case == "wrong-runtime-container":
                        next(
                            event
                            for event in events
                            if event["event_type"] == "IMAGE_PULL_START"
                        )["container_id"] = "missing-container"
                    elif case == "wrong-runtime-source":
                        next(
                            event
                            for event in events
                            if event["event_type"] == "READINESS_PROBE_FIRST_SUCCESS"
                        )["source_component"] = "untrusted-source"
                    else:
                        for event in events:
                            if event["event_type"] == "IMAGE_PULL_END":
                                event["attributes"]["download_bytes"] = 1
                    (artifact / "runtime-events.ndjson").write_text(
                        "".join(json.dumps(event) + "\n" for event in events),
                        encoding="utf-8",
                    )
                else:
                    state = json.loads(warm_state.read_text(encoding="utf-8"))
                    state["valid"] = False
                    warm_state.write_text(json.dumps(state), encoding="utf-8")
                with self.assertRaises(e02.ValidationError):
                    self.validate(fixture, variant)

    def test_warm_rejects_target_failure_with_missing_uid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.make_fixture(root, "warm-node")
            artifact = fixture[0]
            write_tsv(
                artifact / "sandbox-failures.tsv",
                [
                    "cluster_id",
                    "run_id",
                    "namespace",
                    "pod_uid",
                    "pod_name",
                    "event_type",
                    "event_uid",
                    "attempts",
                ],
                [
                    {
                        "cluster_id": "cluster-a",
                        "run_id": "run-warm-node",
                        "namespace": "e02-warm-node-fixture",
                        "pod_uid": "",
                        "pod_name": "workload-a",
                        "event_type": "POD_SANDBOX_FAILED",
                        "event_uid": "ambiguous-event",
                        "attempts": 2,
                    }
                ],
            )
            with self.assertRaises(e02.ValidationError):
                self.validate(fixture, "warm-node")

    def test_false_clock_flags_do_not_create_cross_source_interval(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.make_fixture(root, "cold-node")
            artifact = fixture[0]
            rows = e02.read_tsv(artifact / "trace-timestamps.tsv")
            rows[0]["node_clock_uncertainty_unknown"] = "false"
            rows[0]["sandbox_clock_uncertainty_unknown"] = "false"
            write_tsv(artifact / "trace-timestamps.tsv", list(rows[0]), rows)
            result = self.validate(fixture, "cold-node")
            self.assertFalse(result["node_sandbox_clock_known"])
            self.assertIsNone(result["node_ready_to_sandbox_start_ms"])

    def test_orchestrator_timing_identity_interval_and_owner_are_bound(self):
        for case in ("namespace", "pod_uid", "end_before_start", "owner"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fixture = self.make_fixture(root, "cold-node")
                artifact = fixture[0]
                if case == "owner":
                    pod_path = artifact / "pods-workload-1.json"
                    payload = json.loads(pod_path.read_text(encoding="utf-8"))
                    payload["items"][0]["metadata"]["ownerReferences"][0]["uid"] = "other-rs"
                    pod_path.write_text(json.dumps(payload), encoding="utf-8")
                else:
                    rows = e02.read_tsv(artifact / "orchestrator-timing.tsv")
                    if case == "namespace":
                        rows[0]["namespace"] = "e02-cold-node-other"
                    elif case == "pod_uid":
                        rows[0]["pod_uid"] = "other-pod"
                    else:
                        rows[0]["end_monotonic_ns"] = rows[0]["start_monotonic_ns"]
                    write_tsv(
                        artifact / "orchestrator-timing.tsv", list(rows[0]), rows
                    )
                with self.assertRaises(e02.ValidationError):
                    self.validate(fixture, "cold-node")

    def test_trace_metrics_and_selected_event_ids_are_bound_to_endpoints(self):
        for case in ("pod_ms", "raw_total", "quality_event_id"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fixture = self.make_fixture(root, "cold-node")
                artifact = fixture[0]
                rows = e02.read_tsv(artifact / "traces.tsv")
                if case == "pod_ms":
                    rows[0]["pod_ms"] = "1199"
                elif case == "raw_total":
                    rows[0]["total_ms"] = "2999"
                else:
                    quality = json.loads(rows[0]["quality"])
                    quality["pod_start_event_id"] = "other-event"
                    rows[0]["quality"] = json.dumps(quality)
                write_tsv(artifact / "traces.tsv", list(rows[0]), rows)
                with self.assertRaises(e02.ValidationError):
                    self.validate(fixture, "cold-node")

    def test_runtime_event_ids_must_match_storage_contract(self):
        for bad_id in ("A" * 27, "I" * 26):
            with self.subTest(bad_id=bad_id), tempfile.TemporaryDirectory() as directory:
                fixture = self.make_fixture(Path(directory), "cold-node")
                artifact = fixture[0]
                events = e02.read_ndjson(artifact / "runtime-events.ndjson")
                target = next(
                    event
                    for event in events
                    if event["event_type"] == "POD_SANDBOX_START"
                )
                target["event_id"] = bad_id
                (artifact / "runtime-events.ndjson").write_text(
                    "".join(json.dumps(event) + "\n" for event in events),
                    encoding="utf-8",
                )
                rows = e02.read_tsv(artifact / "traces.tsv")
                quality = json.loads(rows[0]["quality"])
                quality["pod_start_event_id"] = bad_id
                rows[0]["quality"] = json.dumps(quality, separators=(",", ":"))
                write_tsv(artifact / "traces.tsv", list(rows[0]), rows)
                with self.assertRaises(e02.ValidationError):
                    self.validate(fixture, "cold-node")

    def test_raw_trace_total_does_not_drive_orchestrator_e2e(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.make_fixture(root, "cold-node")
            artifact = fixture[0]
            traces = e02.read_tsv(artifact / "traces.tsv")
            traces[0]["total_ms"] = "2500"
            write_tsv(artifact / "traces.tsv", list(traces[0]), traces)
            timestamps = e02.read_tsv(artifact / "trace-timestamps.tsv")
            timestamps[0]["trigger_time_ns"] = "1500000000"
            write_tsv(
                artifact / "trace-timestamps.tsv", list(timestamps[0]), timestamps
            )
            result = self.validate(fixture, "cold-node")
            self.assertEqual(result["trace_total_ms_raw"], 2500)
            self.assertEqual(result["e2e_ms"], 3000)

    def test_run_labels_index_and_schedule_mismatches_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.make_fixture(root, "cold-node")
            run_path = fixture[0] / "run.json"
            payload = json.loads(run_path.read_text(encoding="utf-8"))
            payload["labels"]["sequence"] = 0
            run_path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(e02.ValidationError):
                self.validate(fixture, "cold-node")

        for case in ("index", "schedule", "validation-label"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                cold = self.validate(self.make_fixture(root, "cold-node"), "cold-node")
                warm = self.validate(self.make_fixture(root, "warm-node"), "warm-node")
                index, schedule = self.write_summary_evidence(root, (cold, warm))
                if case == "index":
                    rows = e02.read_tsv(index)
                    rows[0]["artifact_dir"] = rows[1]["artifact_dir"]
                    write_tsv(index, list(rows[0]), rows)
                elif case == "schedule":
                    rows = e02.read_tsv(schedule)
                    rows[0]["variant"] = "warm-node"
                    write_tsv(schedule, list(rows[0]), rows)
                else:
                    first = e02.read_tsv(index)[0]
                    validation_path = Path(first["validation"])
                    validation = json.loads(validation_path.read_text(encoding="utf-8"))
                    validation["random_seed"] = self.seed + 1
                    validation_path.write_text(json.dumps(validation), encoding="utf-8")
                with self.assertRaises(e02.ValidationError):
                    e02.summarize_runs(index, 1, schedule, self.seed)


if __name__ == "__main__":
    unittest.main()
