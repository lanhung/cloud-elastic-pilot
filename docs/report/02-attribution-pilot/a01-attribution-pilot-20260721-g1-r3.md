# A01 GOATScaler task-ID 归因 Pilot：G1 第 3 轮报告

## 1. 摘要

2026 年 7 月 21 日在分支 `experiment/02-attribution-pilot` 上完成 A01 G1
第 3 次真实 ACK 实验。单个请求 `3200m` CPU、`256Mi` memory 的 Pod 在另一个
可用区再次稳定形成一 Pod、一 task、一新 Node。

本轮执行时 Gate 直接 **PASS**，1/1 轨迹完整，controller/ingester ERROR 均为 0，
被拒事件批次为 0。task-ID、Kubernetes-node 和 10 分钟时间窗口三种方法的 F1
均为 1.0。G1 核心与无丢批干净重复进度均为 **3/5**。

| 项目 | 值 |
|---|---|
| Git 基线 | `4177e6cc66cc7fa3454a4c49efa54292f0e63ddf` |
| Run ID | `01KY1PVR12TJYA5PVC3WNHZC4E` |
| Run name | `a01-attribution-g1-20260721T064718Z` |
| ACK 集群 | `c6fda2390918a4086bad884e8086557bc` |
| Kubernetes | `v1.36.1-aliyun.1` |
| 节点池 | `np7362d82bdacd4fa2b539067792f1fb57` |
| Pod 请求 | `3200m` CPU / `256Mi` memory |
| 实验前/扩容后节点 | 2 / 3 |
| SLO | 30 秒 |

## 2. task 与节点

| Pending Pod | task ID | 新节点 | providerID / ECS |
|---:|---|---|---|
| 1 | `asa-0jl462kb2vgj17ossouw` | `cn-wulanchabu.10.217.82.98` | `cn-wulanchabu.i-0jlda3a6gkmihqpazn9b` / `i-0jlda3a6gkmihqpazn9b` |

Pod annotation、目标 Node label、Node providerID 和 ESS activity 一致，
Pod/Node task 冲突为 0。

## 3. 时间线

| UTC 时间 | 事件 |
|---|---|
| 06:47:23 | Run 创建 |
| 06:47:36.085 | 单 Pod Deployment 扩到 1 个副本，Pod Unschedulable |
| 06:47:40.180 | ACK 记录 task 触发时间 |
| 06:47:41–06:47:46 | ESS 扩容成功，容量 2→3 |
| 06:47:49 | 新 Node 创建 |
| 06:48:20 | 新 Node Ready |
| 06:48:21 | Pod 调度到新 Node，首次 Flannel sandbox 创建失败 |
| 06:48:37 | Pod 自恢复并 Ready |
| 06:49:00 | Run 停止并计算归因 |
| 06:49:01 | Gate-A01 执行时直接 PASS |

## 4. Gate-A01

| 检查项 | 结果 |
|---|---:|
| 原始事件 | 27 |
| 轨迹 | 1/1 完整 |
| Unschedulable 事件 | 2 |
| 唯一 Unschedulable Pod | 1 |
| 有 task ID 的唯一 Pod | 1/1 |
| 唯一实验 task | 1 |
| 每 task 最大 Pod 数 | 1 |
| 弹性池节点 | 2→3 |
| 本轮新增节点 | 1 |
| 新增 Ready 节点 | 1/1 |
| 匹配当前 task 的新增节点 | 1/1 |
| 带 providerID 的当前 task 新增节点 | 1/1 |
| Pod/Node task 冲突 | 0 |
| controller / ingester ERROR | 0 / 0 |
| 被拒事件批次 | 0 |
| 执行时 Gate | **PASS** |

## 5. 归因方法对照

| 方法 | TP | FP | FN | Precision | Recall | F1 |
|---|---:|---:|---:|---:|---:|---:|
| task-ID | 1 | 0 | 0 | 1.000 | 1.000 | 1.000 |
| Kubernetes-node | 1 | 0 | 0 | 1.000 | 1.000 | 1.000 |
| 10 分钟时间窗口 | 1 | 0 | 0 | 1.000 | 1.000 | 1.000 |

G1 只有一个供应 task，因此三种方法结果一致是预期行为。本轮扩容落在
`cn-wulanchabu-c`，与前两轮的 `cn-wulanchabu-b` 不同，但归因链路仍一致。

## 6. 事件完整性与近似时延

新节点的 `NODE_CREATED`、`ACK_PROVISION_TASK_UPDATED`、`NODE_NOT_READY` 和
`NODE_READY` 序列完整。零值源时间的 `NODE_NOT_READY` 使用观测时间回退，保留
approximate 标记，无批次丢失。

| 近似 Node 时延 | Image 层 | Pod 层 | App 层 | 总轨迹 |
|---:|---:|---:|---:|---:|
| 44 秒 | 4 秒 | 15 秒 | 1 秒 | 61 秒 |

未导入 `ACK_EVENTS_NDJSON`，Node 层仍是 Kubernetes 近似口径。Pod 在新 Node
刚 Ready 后出现一次 Flannel `FailedCreatePodSandBox`，随后自行恢复；它影响
Pod 层时延，不影响归因结论。

## 7. 清理状态

- 成功路径自动删除了实验 Namespace；
- `hooke-active-run` 已清空；
- 本地 ingester/controller 端口已释放；
- 本地 MySQL 容器保留用于审计；
- Auto Mode 在 `06:58:27–06:59:20Z` 通过一次 activity 删除新增 ECS，容量恢复 3→2；
- 新增实例 `i-0jlda3a6gkmihqpazn9b` 已删除，ECS 复查返回 0 个实例；
- 节点池最终为 2 个健康/服务节点，失败、移除中和等待移除节点均为 0。

## 8. G1 进度与下一步

G1 核心归因和无丢批干净重复均为 **3/5**。R1–R3 均为执行时直接 PASS；
清理确认后保持参数不变继续 G1-R4。

## 9. 产物

- [summary](../../../artifacts/a01-attribution-g1-20260721T064718Z/summary.md)
- [attribution](../../../artifacts/a01-attribution-g1-20260721T064718Z/attribution.json)
- [task links](../../../artifacts/a01-attribution-g1-20260721T064718Z/task-links.tsv)
- [new node events](../../../artifacts/a01-attribution-g1-20260721T064718Z/new-node-events.tsv)
- [traces](../../../artifacts/a01-attribution-g1-20260721T064718Z/traces.tsv)
- [metrics](../../../artifacts/a01-attribution-g1-20260721T064718Z/metrics.tsv)
- [Kubernetes Events](../../../artifacts/a01-attribution-g1-20260721T064718Z/kubernetes-events.json)
- [wave1 trigger](../../../artifacts/a01-attribution-g1-20260721T064718Z/wave1-trigger-utc.txt)
- [扩容前节点](../../../artifacts/a01-attribution-g1-20260721T064718Z/nodes-before.json)
- [扩容后节点](../../../artifacts/a01-attribution-g1-20260721T064718Z/nodes-after.json)
- [清理证据](../../../artifacts/a01-attribution-g1-20260721T064718Z/cleanup-evidence.txt)

只读预检产物保存在
[a01-attribution-g1-20260721T064710Z](../../../artifacts/a01-attribution-g1-20260721T064710Z/cluster-info.txt)。
