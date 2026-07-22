import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "scripts" / "ack-node-pool-control.sh"


FAKE_ALIYUN = r"""#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

state_path = Path(os.environ["FAKE_ACK_STATE"])
log_path = Path(os.environ["FAKE_ACK_LOG"])
args = sys.argv[1:]

def log(action):
    with log_path.open("a", encoding="utf-8") as stream:
        stream.write(action + "\n")

state = json.loads(state_path.read_text(encoding="utf-8"))
if "DescribeClusterDetail" in args:
    log("DescribeClusterDetail")
    print(json.dumps({
        "cluster_id": "cluster-a",
        "region_id": "region-a",
        "state": "running",
        "master_url": json.dumps({
            "api_server_endpoint": "https://api.example.test:6443",
            "intranet_api_server_endpoint": "https://10.0.0.1:6443",
        }),
    }))
elif "DescribeClusterNodePoolDetail" in args:
    log("DescribeClusterNodePoolDetail")
    print(json.dumps({
        "nodepool_info": {
            "nodepool_id": "pool-a",
            "name": "e02-pool",
            "resource_group_id": "rg-a",
            "region_id": "region-a",
            "type": "ess",
            "is_default": False,
        },
        "status": {"state": "active"},
        "auto_scaling": {
            "enable": True,
            "min_instances": state["min"],
            "max_instances": state["max"],
        },
        "kubernetes_config": {
            "unschedulable": False,
            "taints": [
                {
                    "key": "hooke.io/experiment",
                    "value": "elastic",
                    "effect": "NoSchedule",
                }
            ] if state.get("taint", True) else [],
        },
    }))
elif "ModifyClusterNodePool" in args:
    log("ModifyClusterNodePool")
    body = json.loads(args[args.index("--body") + 1])
    state["min"] = body["auto_scaling"]["min_instances"]
    state["max"] = body["auto_scaling"]["max_instances"]
    state_path.write_text(json.dumps(state), encoding="utf-8")
    print(json.dumps({
        "nodepool_id": "pool-a",
        "request_id": "request-a",
        "task_id": "task-a",
    }))
elif "DescribeTaskInfo" in args:
    log("DescribeTaskInfo")
    remaining = int(state.get("task_query_failures", 0))
    if remaining > 0:
        state["task_query_failures"] = remaining - 1
        state_path.write_text(json.dumps(state), encoding="utf-8")
        raise SystemExit(3)
    print(json.dumps({
        "task_id": args[args.index("--task_id") + 1],
        "cluster_id": "cluster-a",
        "state": "success",
        "target": {"id": "cluster-a", "type": "cluster"},
    }))
else:
    raise SystemExit("unexpected fake aliyun invocation: " + repr(args))
"""


class ACKNodePoolControlTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fake = self.root / "aliyun"
        self.fake.write_text(textwrap.dedent(FAKE_ALIYUN), encoding="utf-8")
        self.fake.chmod(0o755)
        self.state = self.root / "state.json"
        self.log = self.root / "calls.log"
        self.state.write_text(json.dumps({"min": 0, "max": 1, "taint": True}), encoding="utf-8")
        self.log.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update(
            {
                "ALIYUN_CLI_BIN": str(self.fake),
                "FAKE_ACK_STATE": str(self.state),
                "FAKE_ACK_LOG": str(self.log),
                "E02_ACK_CONTROL_TIMEOUT_SECONDS": "5",
                "E02_ACK_CONTROL_POLL_SECONDS": "1",
                "E02_ACK_STABILITY_POLLS": "2",
                "E02_NODE_POOL_CONTROL_STATE_FILE": str(self.root / "control-state.json"),
                "ALIYUN_CLI_REGION": "region-a",
            }
        )

    def tearDown(self):
        self.temp.cleanup()

    def run_hook(self, action, evidence, *extra, check=True):
        command = [
            str(HOOK),
            "--action",
            action,
            "--cluster-id",
            "cluster-a",
            "--node-pool-id",
            "pool-a",
            "--node-pool-name",
            "e02-pool",
            "--resource-group-id",
            "rg-a",
            "--expected-api-server",
            "https://api.example.test:6443",
            "--selector-key",
            "node.alibabacloud.com/nodepool-id",
            "--selector-value",
            "pool-a",
            "--taint-key",
            "hooke.io/experiment",
            "--taint-value",
            "elastic",
            "--taint-effect",
            "NoSchedule",
            "--evidence",
            str(evidence),
            *extra,
        ]
        return subprocess.run(
            command,
            env=self.env,
            text=True,
            capture_output=True,
            check=check,
        )

    def calls(self):
        return self.log.read_text(encoding="utf-8").splitlines()

    def test_check_is_read_only_and_snapshot_set_restore_round_trip(self):
        check = self.root / "check.json"
        self.run_hook("check", check)
        self.assertEqual(
            self.calls(), ["DescribeClusterDetail", "DescribeClusterNodePoolDetail"]
        )
        self.assertEqual(json.loads(check.read_text(encoding="utf-8"))["min_size"], 0)

        snapshot = self.root / "snapshot.json"
        self.run_hook("snapshot", snapshot)
        changed = self.root / "changed.json"
        self.run_hook("set-min", changed, "--min-size", "1")
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["min"], 1)
        self.assertEqual(json.loads(changed.read_text(encoding="utf-8"))["observed_min_size"], 1)

        restored = self.root / "restored.json"
        self.run_hook("restore", restored, "--snapshot", str(snapshot))
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["min"], 0)
        self.assertEqual(json.loads(restored.read_text(encoding="utf-8"))["observed_min_size"], 0)
        self.assertEqual(self.calls().count("ModifyClusterNodePool"), 2)
        self.assertEqual(self.calls().count("DescribeTaskInfo"), 2)

    def test_rejects_pool_without_required_taint_before_mutation(self):
        self.state.write_text(
            json.dumps({"min": 0, "max": 1, "taint": False}), encoding="utf-8"
        )
        result = self.run_hook(
            "set-min", self.root / "bad.json", "--min-size", "1", check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("ModifyClusterNodePool", self.calls())

    def test_retries_task_query_and_accepts_generic_cluster_target(self):
        self.state.write_text(
            json.dumps(
                {"min": 0, "max": 1, "taint": True, "task_query_failures": 1}
            ),
            encoding="utf-8",
        )
        evidence = self.root / "retried.json"
        self.run_hook("set-min", evidence, "--min-size", "1")
        payload = json.loads(evidence.read_text(encoding="utf-8"))
        self.assertEqual(payload["task_state"], "success")
        self.assertEqual(self.calls().count("DescribeTaskInfo"), 2)

    def test_rejects_kube_context_cloud_cluster_mismatch_before_mutation(self):
        result = self.run_hook(
            "set-min",
            self.root / "wrong-cluster.json",
            "--min-size",
            "1",
            check=False,
        )
        self.assertEqual(result.returncode, 0)
        # Re-run with a deliberately different kube API endpoint.
        command = [
            str(HOOK),
            "--action", "set-min",
            "--cluster-id", "cluster-a",
            "--node-pool-id", "pool-a",
            "--node-pool-name", "e02-pool",
            "--resource-group-id", "rg-a",
            "--expected-api-server", "https://other.example.test:6443",
            "--selector-key", "node.alibabacloud.com/nodepool-id",
            "--selector-value", "pool-a",
            "--taint-key", "hooke.io/experiment",
            "--taint-value", "elastic",
            "--taint-effect", "NoSchedule",
            "--evidence", str(self.root / "mismatch.json"),
            "--min-size", "0",
        ]
        before = self.calls().count("ModifyClusterNodePool")
        mismatch = subprocess.run(command, env=self.env, text=True, capture_output=True)
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertEqual(self.calls().count("ModifyClusterNodePool"), before)

    def test_ambiguous_prior_submission_restores_but_fails_closed(self):
        snapshot = self.root / "snapshot.json"
        self.run_hook("snapshot", snapshot)
        self.state.write_text(
            json.dumps({"min": 1, "max": 1, "taint": True}), encoding="utf-8"
        )
        control_state = Path(self.env["E02_NODE_POOL_CONTROL_STATE_FILE"])
        control_state.write_text(
            json.dumps(
                {
                    "version": 1,
                    "cluster_id": "cluster-a",
                    "node_pool_id": "pool-a",
                    "phase": "submitting",
                    "prior_mutation_uncertain": False,
                }
            ),
            encoding="utf-8",
        )
        evidence = self.root / "ambiguous-restore.json"
        result = self.run_hook(
            "restore", evidence, "--snapshot", str(snapshot), check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.state.read_text(encoding="utf-8"))["min"], 0)
        self.assertTrue(
            json.loads(evidence.read_text(encoding="utf-8"))["prior_mutation_uncertain"]
        )


if __name__ == "__main__":
    unittest.main()
