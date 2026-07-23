import importlib.util
import json
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "run-image-batch-rollout.py"
SPEC = importlib.util.spec_from_file_location("run_image_batch_rollout", SCRIPT)
assert SPEC and SPEC.loader
batch = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = batch
SPEC.loader.exec_module(batch)


class ParseWorkloadsTest(unittest.TestCase):
    def test_accepts_distinct_nonempty_names(self):
        self.assertEqual(
            batch.parse_workloads('["work-p1","work-p2","work-p4"]'),
            ["work-p1", "work-p2", "work-p4"],
        )

    def test_rejects_empty_or_duplicate_names(self):
        for value in ("[]", '[""]', '["work","work"]', "{}"):
            with self.subTest(value=value):
                with self.assertRaises(batch.RolloutError):
                    batch.parse_workloads(value)


class PatchTest(unittest.TestCase):
    def test_patch_binds_uid_and_run_before_scaling(self):
        value = json.loads(batch.scale_patch("deployment-uid", "run-a"))
        self.assertEqual(
            value,
            [
                {
                    "op": "test",
                    "path": "/metadata/uid",
                    "value": "deployment-uid",
                },
                {
                    "op": "test",
                    "path": "/metadata/annotations/hooke.io~1run-id",
                    "value": "run-a",
                },
                {
                    "op": "replace",
                    "path": "/spec/replicas",
                    "value": 1,
                },
            ],
        )


if __name__ == "__main__":
    unittest.main()
