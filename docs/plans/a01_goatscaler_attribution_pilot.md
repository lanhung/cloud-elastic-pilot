# A01 GOATScaler task-ID 归因 Pilot

## 目标

在正式四层基线前，验证 ACK 官方关联字段能否稳定恢复：

```text
Pending Pod
  -> goatscaler.io/provision-task-id (Pod annotation)
  -> goatscaler.io/provision-task-id (Node label)
  -> Node providerID
  -> ECS instance ID（有 SLS/OpenAPI 输入时）
```

本实验仍是小规模 Pilot，不报告 p99，也不用于证明调优收益。

## 实验组

| 组 | 配置 | 建议重复 | 目的 |
|---|---|---:|---|
| G1 | 单波、1 个触发扩容的 Pod | 5 | 验证一 Pod、一 task、一 Node |
| G2 | 单波、多个 Pod，共享一次扩容 | 5 | 验证一 task 对多 Pod |
| G3 | 两波不同资源请求，间隔 5–15 秒 | 5 | 验证并发 task 与时间窗口错配 |

每次 run 使用独立 Namespace。下一次 run 前必须等待弹性池回到目标初始状态。

## 配置

```bash
cp configs/attribution-pilot.env.example configs/attribution-pilot.env
chmod 600 configs/attribution-pilot.env
$EDITOR configs/attribution-pilot.env
```

G1 使用示例默认值。G2 增加 `NODE_SCALE_REPLICAS`，并确保资源请求能形成预期的一任务多 Pod。G3 设置：

```bash
ENABLE_SECOND_NODE_SCALE_WAVE="true"
NODE_SCALE_WAVE_STAGGER_SECONDS="10"
EXPECTED_TASK_COUNT="2"
```

G2 还应设置 `EXPECTED_TASK_COUNT="1"` 和至少为 2 的
`EXPECTED_MIN_PODS_PER_TASK`。若平台实际生成的 task 数与实验组假设不同，本轮直接失败并保留产物，不把它改写成预期结果。

先只做预检：

```bash
make attribution-ack-check
```

执行单次 run：

```bash
make attribution-ack
```

## 归因方法

计算器同时输出三种方法：

1. `task-id`：Pod task annotation 与 Node task label 精确连接；
2. `kubernetes-node`：只使用 Pod 最终调度 Node；
3. `time-window`：选择 Pod Unschedulable 后窗口内第一个 Ready Node。

后两种方法只在评价阶段读取 task ID，用于与官方关系比较，不把 task ID 当作其预测输入。

## Gate-A01

- 每个 Unschedulable Pod 都采到 task ID；
- 至少一个新增 Node 采到相同 task ID；
- task-ID 方法 precision、recall 均为 1；
- Pod/Node task ID 不冲突；
- providerID 被保存；
- 失败、超时和 partial trace 原样保留；
- 没有 SLS/ECS 输入时，`instance_id_coverage=0` 是允许的，但不得伪造。

## 产物

除第一轮产物外，新增：

```text
attribution.json
task-links.tsv
nodes-before.json
nodes-after.json
kubernetes-events.json
wave1-trigger-utc.txt
wave2-trigger-utc.txt（仅 G3）
```
