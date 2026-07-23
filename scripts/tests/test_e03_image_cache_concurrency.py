import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "e03-image-cache-concurrency.py"
SPEC = importlib.util.spec_from_file_location("e03_image_cache_concurrency", SCRIPT)
assert SPEC and SPEC.loader
e03 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = e03
SPEC.loader.exec_module(e03)


def image(slot: int) -> str:
    return (
        "registry.example.com/hooke/e03@sha256:"
        + f"{slot:064x}"
    )


def node_payload(name: str = "node-a", uid: str = "node-uid-a") -> dict:
    return {
        "metadata": {
            "name": name,
            "uid": uid,
            "labels": {
                "nodepool": "fixed",
                "node.kubernetes.io/instance-type": "ecs.c7.large",
                "topology.kubernetes.io/zone": "zone-a",
            },
        },
        "spec": {"providerID": "provider-a"},
        "status": {"conditions": [{"type": "Ready", "status": "True"}]},
    }


def pod_payload(
    *,
    run_id: str,
    slot: int,
    node_name: str = "node-a",
) -> dict:
    workload = f"e03-workload-p{slot}"
    return {
        "metadata": {
            "name": f"{workload}-pod",
            "namespace": "e03-test",
            "uid": f"pod-uid-{slot}",
            "labels": {
                "app": workload,
                "hooke.io/experiment": "true",
            },
            "annotations": {"hooke.io/run-id": run_id},
        },
        "spec": {
            "nodeName": node_name,
            "containers": [
                {
                    "name": "app",
                    "image": image(slot),
                    "imagePullPolicy": "IfNotPresent",
                }
            ],
        },
        "status": {
            "containerStatuses": [
                {
                    "name": "app",
                    "containerID": "containerd://" + f"{slot:064x}",
                }
            ]
        },
    }


def event(
    *,
    run_id: str,
    slot: int,
    event_type: str,
    at_ns: int,
    download_bytes: int | None = None,
) -> dict:
    attributes = {"precision": "test"}
    if download_bytes is not None:
        attributes["download_bytes"] = download_bytes
    return {
        "cluster_id": "cluster-a",
        "run_id": run_id,
        "pod_uid": f"pod-uid-{slot}",
        "pod_name": f"e03-workload-p{slot}-pod",
        "namespace": "e03-test",
        "node_name": "node-a",
        "event_type": event_type,
        "event_time_ns": at_ns,
        "source_time_ns": at_ns,
        "approximate": False,
        "image_ref": image(slot),
        "image_digest": image(slot).split("@", 1)[1],
        "attributes": attributes,
    }


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


def write_ndjson(path: Path, rows: list[dict]) -> None:
    path.write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )


def write_summary(path: Path, expected: int) -> None:
    keys = (
        "traces",
        "expected_traces",
        "complete_traces",
        "image_layer_samples",
        "exact_image_samples",
        "exact_pod_samples",
        "exact_app_samples",
    )
    lines = ["# summary", "", "- result: **PASS**"]
    lines.extend(f"- {key}: {expected}" for key in keys)
    lines.extend(
        [
            "- invalid_order_count: 0",
            "- untraceable_primary_samples: 0",
            "- exact_node_samples: 0",
            "- image_batch_enabled: true",
            f"- image_batch_size: {expected}",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


class ScheduleTest(unittest.TestCase):
    def test_matrix_has_27_cells_without_false_new_warm_cells(self):
        cells = e03.experiment_cells()
        self.assertEqual(len(cells), 27)
        self.assertFalse(
            any(
                item["node_state"] == "new"
                and item["cache_state"] == "warm"
                for item in cells
            )
        )
        self.assertEqual(
            {item["size_mib"] for item in cells},
            {100, 500, 1024},
        )
        self.assertEqual(
            {item["requested_concurrency"] for item in cells},
            {1, 2, 4},
        )

    def test_schedule_is_deterministic_and_block_complete(self):
        first = e03.generate_schedule(2, 20260723)
        second = e03.generate_schedule(2, 20260723)
        self.assertEqual(first, second)
        self.assertEqual(len(first), 54)
        self.assertEqual(
            [item["sequence"] for item in first],
            list(range(1, 55)),
        )
        expected_cells = {item["cell"] for item in e03.experiment_cells()}
        for block in (1, 2):
            self.assertEqual(
                {
                    item["cell"]
                    for item in first
                    if item["block"] == block
                },
                expected_cells,
            )


class OverlapTest(unittest.TestCase):
    def test_overlap_requires_positive_duration(self):
        maximum, overlap = e03.overlap_metrics(
            [(10, 100), (20, 90), (30, 80), (40, 70)]
        )
        self.assertEqual(maximum, 4)
        self.assertEqual(overlap, 30)

    def test_touching_intervals_are_not_concurrent(self):
        maximum, _ = e03.overlap_metrics([(10, 20), (20, 30)])
        self.assertEqual(maximum, 1)

    def test_invalid_interval_fails(self):
        with self.assertRaises(e03.ValidationError):
            e03.overlap_metrics([(10, 10)])


class RunValidationTest(unittest.TestCase):
    def make_artifact(
        self,
        root: Path,
        *,
        cache_state: str,
        concurrency: int,
        concurrent: bool = True,
        include_unpack: bool = False,
    ) -> tuple[Path, list[str]]:
        artifact = root / "run"
        artifact.mkdir()
        run_id = "run-e03-a"
        images = [image(slot) for slot in range(1, concurrency + 1)]
        write_json(
            artifact / "run.json",
            {
                "run_id": run_id,
                "cluster_id": "cluster-a",
                "labels": {
                    "experiment": "E03-image-cache-concurrency",
                    "phase": "pilot",
                    "sequence": 1,
                    "block": 1,
                    "repetition": 1,
                    "random_seed": 20260723,
                    "cell": f"existing-{cache_state}-100mib-c{concurrency}",
                    "node_state": "existing",
                    "cache_state": cache_state,
                    "size_mib": 100,
                    "requested_concurrency": concurrency,
                    "image_digests_csv": ",".join(
                        item.rsplit("@", 1)[1] for item in images
                    ),
                },
            },
        )
        write_summary(artifact / "summary.md", concurrency)
        write_json(
            artifact / "experiment-namespace.json",
            {
                "name": "e03-test",
                "uid": "namespace-uid-e03",
                "run_id": run_id,
                "created_by_run": True,
            },
        )
        patch_starts = [
            1_000_000 + (slot - 1) * 1_000_000
            for slot in range(1, concurrency + 1)
        ]
        write_json(
            artifact / "image-batch-timing.json",
            {
                "run_id": run_id,
                "cluster_id": "cluster-a",
                "namespace": "e03-test",
                "namespace_uid": "namespace-uid-e03",
                "path": "fixed",
                "requested_concurrency": concurrency,
                "clock_type": "CLOCK_MONOTONIC",
                "batch_start_monotonic_ns": 500_000,
                "batch_end_monotonic_ns": 20_000_000,
                "trigger_spread_ns": max(patch_starts) - min(patch_starts),
                "deployments": [
                    {
                        "workload": f"e03-workload-p{slot}",
                        "deployment_uid": f"deployment-uid-{slot}",
                        "pod_uid": f"pod-uid-{slot}",
                        "pod_name": f"e03-workload-p{slot}-pod",
                        "scale": {
                            "started_monotonic_ns": patch_starts[slot - 1],
                            "ended_monotonic_ns": (
                                patch_starts[slot - 1] + 100_000
                            ),
                            "returncode": 0,
                        },
                        "rollout": {
                            "started_monotonic_ns": 10_000_000 + slot * 100_000,
                            "ended_monotonic_ns": 15_000_000 + slot * 100_000,
                            "returncode": 0,
                        },
                    }
                    for slot in range(1, concurrency + 1)
                ],
            },
        )
        write_json(
            artifact / "pods-batch.json",
            {
                "items": [
                    pod_payload(run_id=run_id, slot=slot)
                    for slot in range(1, concurrency + 1)
                ]
            },
        )
        write_json(
            artifact / "nodes-after.json",
            {"items": [node_payload()]},
        )
        rows: list[dict] = []
        for slot in range(1, concurrency + 1):
            if cache_state == "cold":
                start = 1_000 + (slot * 10 if concurrent else slot * 1_000)
                end = start + (2_000 if concurrent else 500)
                rows.extend(
                    [
                        event(
                            run_id=run_id,
                            slot=slot,
                            event_type="IMAGE_PULL_START",
                            at_ns=start,
                        ),
                        event(
                            run_id=run_id,
                            slot=slot,
                            event_type="IMAGE_PULL_END",
                            at_ns=end,
                            download_bytes=110 * 1024 * 1024,
                        ),
                    ]
                )
                if include_unpack:
                    rows.extend(
                        [
                            event(
                                run_id=run_id,
                                slot=slot,
                                event_type="IMAGE_UNPACK_START",
                                at_ns=start + 100,
                            ),
                            event(
                                run_id=run_id,
                                slot=slot,
                                event_type="IMAGE_UNPACK_END",
                                at_ns=end + 500,
                            ),
                        ]
                    )
            else:
                rows.append(
                    event(
                        run_id=run_id,
                        slot=slot,
                        event_type="IMAGE_CACHE_HIT",
                        at_ns=1_000 + slot,
                    )
                )
        write_ndjson(artifact / "runtime-events.ndjson", rows)
        return artifact, images

    def arguments(
        self,
        artifact: Path,
        images: list[str],
        *,
        cache_state: str,
        node_state: str = "existing",
        require_unpack: bool = False,
    ) -> dict:
        return {
            "artifact_dir": artifact,
            "node_state": node_state,
            "cache_state": cache_state,
            "size_mib": 100,
            "requested_concurrency": len(images),
            "images": images,
            "cluster_id": "cluster-a",
            "selector_key": "nodepool",
            "selector_value": "fixed",
            "expected_instance_type": "ecs.c7.large",
            "expected_zone": "zone-a",
            "expected_registry": "registry.example.com",
            "disk_type": "cloud_essd",
            "min_download_bytes": 100 * 1024 * 1024,
            "max_trigger_spread_ms": 100.0,
            "existing_node_name": "node-a",
            "require_unpack": require_unpack,
        }

    def test_cold_batch_validates_real_overlap_and_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact, images = self.make_artifact(
                Path(directory), cache_state="cold", concurrency=4
            )
            result = e03.validate_run(
                **self.arguments(
                    artifact,
                    images,
                    cache_state="cold",
                )
            )
            self.assertEqual(result["actual_pull_concurrency"], 4)
            self.assertEqual(
                result["download_bytes_total"],
                4 * 110 * 1024 * 1024,
            )
            self.assertEqual(result["scheduled_node"], "node-a")

    def test_new_node_batch_requires_one_fresh_selected_node(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact, images = self.make_artifact(
                Path(directory), cache_state="cold", concurrency=1
            )
            run = json.loads((artifact / "run.json").read_text(encoding="utf-8"))
            run["labels"]["node_state"] = "new"
            run["labels"]["cell"] = "new-cold-100mib-c1"
            write_json(artifact / "run.json", run)
            summary = (artifact / "summary.md").read_text(encoding="utf-8")
            (artifact / "summary.md").write_text(
                summary.replace(
                    "- exact_node_samples: 0",
                    "- exact_node_samples: 1",
                ),
                encoding="utf-8",
            )
            timing = json.loads(
                (artifact / "image-batch-timing.json").read_text(
                    encoding="utf-8"
                )
            )
            timing["path"] = "node-scale"
            write_json(artifact / "image-batch-timing.json", timing)
            write_json(artifact / "nodes-before.json", {"items": []})
            result = e03.validate_run(
                **self.arguments(
                    artifact,
                    images,
                    cache_state="cold",
                    node_state="new",
                )
            )
            self.assertEqual(result["new_node_uid"], "node-uid-a")

    def test_requested_parallelism_fails_when_pulls_are_serial(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact, images = self.make_artifact(
                Path(directory),
                cache_state="cold",
                concurrency=2,
                concurrent=False,
            )
            with self.assertRaisesRegex(
                e03.ValidationError,
                "actual positive-duration pull concurrency",
            ):
                e03.validate_run(
                    **self.arguments(
                        artifact,
                        images,
                        cache_state="cold",
                    )
                )

    def test_runtime_event_target_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact, images = self.make_artifact(
                Path(directory), cache_state="cold", concurrency=1
            )
            rows = [
                json.loads(line)
                for line in (artifact / "runtime-events.ndjson")
                .read_text(encoding="utf-8")
                .splitlines()
            ]
            rows[0]["node_name"] = "wrong-node"
            write_ndjson(artifact / "runtime-events.ndjson", rows)
            with self.assertRaisesRegex(
                e03.ValidationError,
                "node_name",
            ):
                e03.validate_run(
                    **self.arguments(
                        artifact,
                        images,
                        cache_state="cold",
                    )
                )

    def test_batch_timing_path_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact, images = self.make_artifact(
                Path(directory), cache_state="cold", concurrency=1
            )
            timing = json.loads(
                (artifact / "image-batch-timing.json").read_text(
                    encoding="utf-8"
                )
            )
            timing["path"] = "node-scale"
            write_json(artifact / "image-batch-timing.json", timing)
            with self.assertRaisesRegex(
                e03.ValidationError,
                "timing identity",
            ):
                e03.validate_run(
                    **self.arguments(
                        artifact,
                        images,
                        cache_state="cold",
                    )
                )

    def test_warm_batch_requires_cache_hits_and_zero_download(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact, images = self.make_artifact(
                Path(directory), cache_state="warm", concurrency=2
            )
            result = e03.validate_run(
                **self.arguments(
                    artifact,
                    images,
                    cache_state="warm",
                )
            )
            self.assertEqual(result["actual_pull_concurrency"], 0)
            self.assertEqual(result["download_bytes_total"], 0)

    def test_unpack_gate_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact, images = self.make_artifact(
                Path(directory), cache_state="cold", concurrency=1
            )
            with self.assertRaisesRegex(
                e03.ValidationError,
                "unpack substage is required",
            ):
                e03.validate_run(
                    **self.arguments(
                        artifact,
                        images,
                        cache_state="cold",
                        require_unpack=True,
                    )
                )

    def test_unpack_gate_accepts_real_endpoints(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact, images = self.make_artifact(
                Path(directory),
                cache_state="cold",
                concurrency=1,
                include_unpack=True,
            )
            result = e03.validate_run(
                **self.arguments(
                    artifact,
                    images,
                    cache_state="cold",
                    require_unpack=True,
                )
            )
            self.assertEqual(result["unpack_sample_count"], 1)
            self.assertIsNotNone(result["download_latency_ms_mean"])
            self.assertIsNotNone(result["unpack_latency_ms_mean"])


class SummaryTest(unittest.TestCase):
    def test_summary_requires_and_aggregates_the_frozen_matrix(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schedule = e03.generate_schedule(1, 42)
            schedule_path = root / "schedule.tsv"
            schedule_fields = [
                "sequence",
                "block",
                "repetition",
                "cell",
                "node_state",
                "cache_state",
                "size_mib",
                "requested_concurrency",
            ]
            e03.write_tsv(schedule_path, schedule_fields, schedule)
            index_rows = []
            for row in schedule:
                artifact = root / f"run-{row['sequence']}"
                validation = root / f"validation-{row['sequence']}.json"
                payload = {
                    "status": "PASS",
                    "artifact_dir": str(artifact),
                    "sequence": row["sequence"],
                    "block": row["block"],
                    "repetition": row["repetition"],
                    "random_seed": 42,
                    "cell": row["cell"],
                    "node_state": row["node_state"],
                    "cache_state": row["cache_state"],
                    "size_mib": row["size_mib"],
                    "requested_concurrency": row["requested_concurrency"],
                    "actual_pull_concurrency": (
                        row["requested_concurrency"]
                        if row["cache_state"] == "cold"
                        else 0
                    ),
                    "trigger_spread_ms": 5.0,
                    "max_concurrency_overlap_ms": 100.0,
                    "download_bytes_total": (
                        row["size_mib"]
                        * row["requested_concurrency"]
                        * 1024
                        * 1024
                        if row["cache_state"] == "cold"
                        else 0
                    ),
                    "pull_latency_ms_mean": 10.0,
                    "pull_latency_ms_max": 12.0,
                    "image_total_latency_ms_mean": 10.0,
                    "image_total_latency_ms_max": 12.0,
                    "download_latency_ms_mean": None,
                    "download_latency_ms_max": None,
                    "unpack_sample_count": 0,
                    "unpack_latency_ms_mean": None,
                    "unpack_latency_ms_max": None,
                    "scheduled_node": "node-a",
                    "instance_type": "ecs.c7.large",
                    "zone": "zone-a",
                    "disk_type": "cloud_essd",
                    "run_id": f"run-{row['sequence']}",
                }
                write_json(validation, payload)
                index_rows.append(
                    {
                        **row,
                        "artifact_dir": str(artifact),
                        "validation": str(validation),
                    }
                )
            index_path = root / "run-index.tsv"
            e03.write_tsv(
                index_path,
                schedule_fields + ["artifact_dir", "validation"],
                index_rows,
            )
            summary, observations = e03.summarize_runs(
                run_index=index_path,
                schedule_path=schedule_path,
                expected_repetitions=1,
                expected_seed=42,
            )
            self.assertEqual(summary["status"], "PASS")
            self.assertEqual(summary["cell_count"], 27)
            self.assertEqual(summary["run_count"], 27)
            self.assertEqual(len(observations), 27)
            with self.assertRaisesRegex(
                e03.ValidationError,
                "schedule does not match seed",
            ):
                e03.summarize_runs(
                    run_index=index_path,
                    schedule_path=schedule_path,
                    expected_repetitions=1,
                    expected_seed=43,
                )


if __name__ == "__main__":
    unittest.main()
