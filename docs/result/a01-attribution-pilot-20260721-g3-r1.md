# A01 GOATScaler task-ID 归因 Pilot：G3 首轮报告

## 1. 摘要

2026 年 7 月 21 日在分支 `experiment/02-attribution-pilot` 上完成 A01 G3
第 1 次真实 ACK 实验。首波创建 5 个各请求 `1500m` CPU 的 Pod，10 秒后
第二波创建 1 个请求 `1000m` CPU 的 Pod。首波的 2 个 Pending Pod 共享
第 1 个 task 和新节点，第二波 Pod 触发第 2 个 task 和新节点。

本轮执行时 Gate 直接 **PASS**，6/6 轨迹完整，controller/ingester ERROR 均为 0，
被拒事件批次为 0。task-ID 和 Kubernetes-node 归因的 F1 均为 1.0；
10 分钟时间窗口把第二波 Pod 错连到第一波节点，F1 降为 **0.667**。
G3 核心与干净重复进度均为 **1/5**。

| 项目 | 值 |
|---|---|
| Git 基线 | `8abc7b6ab326e292612c55861c906f20b4283e0b` |
| Run ID | `01KY1GW6RN9TJX22M6MD4TRQVH` |
| Run name | `a01-attribution-g3-20260721T050240Z` |
| ACK 集群 | `c6fda2390918a4086bad884e8086557bc` |
| Kubernetes | `v1.36.1-aliyun.1` |
| 节点池 | `np7362d82bdacd4fa2b539067792f1fb57` |
| 实验前/扩容后节点 | 2 / 4 |
| 波间隔 | 10.274 秒 |
| SLO | 30 秒 |

## 2. 两个 task 与节点

| 波次 | Pending Pod | task ID | 新节点 | providerID / ECS |
|---|---:|---|---|---|
| wave1 | 2 | `asa-0jl78xnpn1f8p028cj4a` | `cn-wulanchabu.10.217.82.93` | `cn-wulanchabu.i-0jl835sf8nuqhvaafyzd` / `i-0jl835sf8nuqhvaafyzd` |
| wave2 | 1 | `asa-0jl10371l7ikfcuwsfpb` | `cn-wulanchabu.10.223.26.192` | `cn-wulanchabu.i-0jl4lsjnd4wnskt6h7vj` / `i-0jl4lsjnd4wnskt6h7vj` |

每个 Pending Pod 的 annotation、目标 Node label、Node providerID 和 ESS activity 一致，
Pod/Node task 冲突为 0。

## 3. 时间线

| UTC 时间 | 事件 |
|---|---|
| 05:02:47 | Run 创建 |
| 05:03:00.181 | wave1 扩到 5 个副本，2 个唯一 Pod Unschedulable |
| 05:03:03.613 | ACK 记录 wave1 task 触发时间 |
| 05:03:05–05:03:10 | wave1 ESS 扩容成功，容量 2→3 |
| 05:03:10.455 | wave2 扩到 1 个副本，该 Pod Unschedulable |
| 05:03:13 | wave1 Node 创建 |
| 05:03:14.328 | ACK 记录 wave2 task 触发时间 |
| 05:03:15–05:03:21 | wave2 ESS 扩容成功，容量 3→4 |
| 05:03:23 | wave2 Node 创建 |
| 05:03:50 | wave1 Node Ready，两个 wave1 Pending Pod 调度 |
| 05:04:00–05:04:01 | wave2 Node Ready，wave2 Pod 调度 |
| 05:04:09 | 两个 wave1 扩容 Pod Ready |
| 05:04:18 | wave2 扩容 Pod Ready |
| 05:04:50 | Run 停止并计算归因 |
| 05:04:51 | Gate-A01 执行时直接 PASS |

## 4. Gate-A01

| 检查项 | 结果 |
|---|---:|
| 原始事件 | 95 |
| 轨迹 | 6/6 完整 |
| Unschedulable 事件 | 10 |
| 唯一 Unschedulable Pod | 3 |
| 有 task ID 的唯一 Pod | 3/3 |
| 唯一实验 task | 2 |
| 每 task 最大 Pod 数 | 2 |
| 弹性池节点 | 2→4 |
| 本轮新增节点 | 2 |
| 新增 Ready 节点 | 2/2 |
| 匹配当前 task 的新增节点 | 2/2 |
| 带 providerID 的当前 task 新增节点 | 2/2 |
| Pod/Node task 冲突 | 0 |
| controller / ingester ERROR | 0 / 0 |
| 被拒事件批次 | 0 |
| 执行时 Gate | **PASS** |

## 5. 归因方法对照

| 方法 | TP | FP | FN | Precision | Recall | F1 |
|---|---:|---:|---:|---:|---:|---:|
| task-ID | 3 | 0 | 0 | 1.000 | 1.000 | 1.000 |
| Kubernetes-node | 3 | 0 | 0 | 1.000 | 1.000 | 1.000 |
| 10 分钟时间窗口 | 2 | 1 | 1 | 0.667 | 0.667 | 0.667 |

wave2 Pod 在 `05:03:10` 进入 Unschedulable。时间窗口法选择了之后最早 Ready 的
wave1 Node（`05:03:50`），其 task ID 为 `asa-0jl78xnpn1f8p028cj4a`；但 wave2 Pod
实际由 `05:04:00` Ready 的 wave2 Node 承载，正确 task ID 为
`asa-0jl10371l7ikfcuwsfpb`。这个反例表明，并发供应时不能用“窗口内第一个
Ready Node”代替官方 task-ID 关联。

## 6. 事件完整性与近似时延

两个新节点的 `NODE_CREATED`、`ACK_PROVISION_TASK_UPDATED`、
`NODE_NOT_READY` 和 `NODE_READY` 序列都完整。两条零值源时间的
`NODE_NOT_READY` 都使用观测时间回退，保留 approximate 标记，无批次丢失。

| 波次 | Pending Pod | 近似 Node 时延 | Pod 层 | 总轨迹 |
|---|---:|---:|---:|---:|
| wave1 | 2 | 50 秒 | 19 秒 | 69 秒 |
| wave2 | 1 | 50 秒 | 16 秒 | 68 秒 |

未导入 `ACK_EVENTS_NDJSON`，Node 层仍是 Kubernetes 近似口径。两个 wave1 Pod 和
一个 wave2 Pod 在新 Node 刚 Ready 后各出现一次 Flannel
`FailedCreatePodSandBox`，随后自行恢复；它影响 Pod 层时延，不影响归因结论。

## 7. 清理状态

- 成功路径自动删除了实验 Namespace；
- `hooke-active-run` 已清空；
- 本地 ingester/controller 端口已释放；
- 本地 MySQL 容器保留用于审计；
- Auto Mode 在 `05:13:27–05:14:25Z` 通过一次 activity 删除 2 台 ECS，容量恢复 4→2；
- 两台新增实例 `i-0jl835sf8nuqhvaafyzd` 和 `i-0jl4lsjnd4wnskt6h7vj` 已删除，ECS 复查返回 0 个实例；
- 节点池最终为 2 个健康/服务节点，失败、移除中和等待移除节点均为 0。

## 8. G3 进度与下一步

G3 核心归因和无丢批干净重复均为 **1/5**。首轮已同时验证：

- 两波可稳定生成两个 task 和两个新节点；
- task-ID 精确归因在并发供应下仍为 F1=1；
- 时间窗口法出现预期的跨 task 错配。

后续 G3-R2–R5 保持本轮参数不变，验证该反例是否稳定重现。

## 9. 产物

- [summary](../../artifacts/a01-attribution-g3-20260721T050240Z/summary.md)
- [attribution](../../artifacts/a01-attribution-g3-20260721T050240Z/attribution.json)
- [task links](../../artifacts/a01-attribution-g3-20260721T050240Z/task-links.tsv)
- [new node events](../../artifacts/a01-attribution-g3-20260721T050240Z/new-node-events.tsv)
- [traces](../../artifacts/a01-attribution-g3-20260721T050240Z/traces.tsv)
- [metrics](../../artifacts/a01-attribution-g3-20260721T050240Z/metrics.tsv)
- [Kubernetes Events](../../artifacts/a01-attribution-g3-20260721T050240Z/kubernetes-events.json)
- [wave1 trigger](../../artifacts/a01-attribution-g3-20260721T050240Z/wave1-trigger-utc.txt)
- [wave2 trigger](../../artifacts/a01-attribution-g3-20260721T050240Z/wave2-trigger-utc.txt)
- [扩容前节点](../../artifacts/a01-attribution-g3-20260721T050240Z/nodes-before.json)
- [扩容后节点](../../artifacts/a01-attribution-g3-20260721T050240Z/nodes-after.json)
- [清理证据](../../artifacts/a01-attribution-g3-20260721T050240Z/cleanup-evidence.txt)

只读预检产物保存在
[a01-attribution-g3-20260721T050226Z](../../artifacts/a01-attribution-g3-20260721T050226Z/cluster-info.txt)。
