# A01 GOATScaler task-ID 归因 Pilot：G3 第 3 轮报告

## 1. 摘要

2026 年 7 月 21 日在分支 `experiment/02-attribution-pilot` 上完成 A01 G3
第 3 次真实 ACK 实验。首波创建 5 个各请求 `1500m` CPU 的 Pod，约 10 秒后
第二波创建 1 个请求 `1000m` CPU 的 Pod。首波的 2 个 Pending Pod 共享
第 1 个 task 和新节点，第二波 Pod 触发第 2 个 task 和新节点。

本轮执行时 Gate 直接 **PASS**，6/6 轨迹完整，controller/ingester ERROR 均为 0，
被拒事件批次为 0。task-ID 和 Kubernetes-node 归因的 F1 均为 1.0；
10 分钟时间窗口连续第 3 轮把第二波 Pod 错连到第一波节点，F1 为 **0.667**。
G3 核心与干净重复进度均为 **3/5**。

| 项目 | 值 |
|---|---|
| Git 基线 | `b5a692ee27974f66dbd5f2e10b2fec8fb069ef45` |
| Run ID | `01KY1JSKM5ZRBCVEABV6FFNEE5` |
| Run name | `a01-attribution-g3-20260721T053614Z` |
| ACK 集群 | `c6fda2390918a4086bad884e8086557bc` |
| Kubernetes | `v1.36.1-aliyun.1` |
| 节点池 | `np7362d82bdacd4fa2b539067792f1fb57` |
| 实验前/扩容后节点 | 2 / 4 |
| 波间隔 | 10.317 秒 |
| SLO | 30 秒 |

## 2. 两个 task 与节点

| 波次 | Pending Pod | task ID | 新节点 | providerID / ECS |
|---|---:|---|---|---|
| wave1 | 2 | `asa-0jl78xnpn1f8pfuh8z1p` | `cn-wulanchabu.10.223.26.194` | `cn-wulanchabu.i-0jl87na1grqx1quhtc8x` / `i-0jl87na1grqx1quhtc8x` |
| wave2 | 1 | `asa-0jl0ticeqq155yj4cuve` | `cn-wulanchabu.10.217.82.95` | `cn-wulanchabu.i-0jlf32wvkcuxehm8yh92` / `i-0jlf32wvkcuxehm8yh92` |

每个 Pending Pod 的 annotation、目标 Node label、Node providerID 和 ESS activity 一致，
Pod/Node task 冲突为 0。

## 3. 时间线

| UTC 时间 | 事件 |
|---|---|
| 05:36:19 | Run 创建 |
| 05:36:32.573 | wave1 扩到 5 个副本，2 个唯一 Pod Unschedulable |
| 05:36:36.054 | ACK 记录 wave1 task 触发时间 |
| 05:36:37–05:36:46 | wave1 ESS 扩容成功，容量 2→3 |
| 05:36:42.890 | wave2 扩到 1 个副本，该 Pod Unschedulable |
| 05:36:46.344 | ACK 记录 wave2 task 触发时间 |
| 05:36:47–05:36:51 | wave2 ESS 扩容成功，容量 3→4 |
| 05:36:49 | wave1 Node 创建 |
| 05:36:53 | wave2 Node 创建 |
| 05:37:23 | wave1 Node Ready，两个 wave1 Pending Pod 调度 |
| 05:37:31–05:37:32 | wave2 Pod 调度，wave2 Node Ready |
| 05:37:42 | 两个 wave1 扩容 Pod Ready |
| 05:37:47 | wave2 扩容 Pod Ready |
| 05:38:19 | Run 停止并计算归因 |
| 05:38:20 | Gate-A01 执行时直接 PASS |

## 4. Gate-A01

| 检查项 | 结果 |
|---|---:|
| 原始事件 | 92 |
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

wave2 Pod 在 `05:36:43` 左右进入 Unschedulable。时间窗口法选择了之后最早 Ready 的
wave1 Node（`05:37:23`），其 task ID 为 `asa-0jl78xnpn1f8pfuh8z1p`；但 wave2 Pod
实际由约 `05:37:32` Ready 的 wave2 Node 承载，正确 task ID 为
`asa-0jl0ticeqq155yj4cuve`。R3 再次复现了跨 task 错配。

## 6. 事件完整性与近似时延

两个新节点的 `NODE_CREATED`、`ACK_PROVISION_TASK_UPDATED`、
`NODE_NOT_READY` 和 `NODE_READY` 序列都完整。两条零值源时间的
`NODE_NOT_READY` 都使用观测时间回退，保留 approximate 标记，无批次丢失。

| 波次 | Pending Pod | 近似 Node 时延 | Pod 层 | 总轨迹 |
|---|---:|---:|---:|---:|
| wave1 | 2 | 51 秒 | 18 秒 | 70 秒 |
| wave2 | 1 | 49 秒 | 15 秒 | 64 秒 |

未导入 `ACK_EVENTS_NDJSON`，Node 层仍是 Kubernetes 近似口径。两个 wave1 Pod 和
一个 wave2 Pod 在新 Node 刚 Ready 后各出现一次 Flannel
`FailedCreatePodSandBox`，随后自行恢复；它影响 Pod 层时延，不影响归因结论。

## 7. 清理状态

- 成功路径自动删除了实验 Namespace；
- `hooke-active-run` 已清空；
- 本地 ingester/controller 端口已释放；
- 本地 MySQL 容器保留用于审计；
- Auto Mode 在 `05:47:27–05:48:21Z` 通过一次 activity 删除 2 台 ECS，容量恢复 4→2；
- 两台新增实例 `i-0jl87na1grqx1quhtc8x` 和 `i-0jlf32wvkcuxehm8yh92` 已删除，ECS 复查返回 0 个实例；
- 节点池最终为 2 个健康/服务节点，失败、移除中和等待移除节点均为 0。

## 8. G3 进度与下一步

G3 核心归因和无丢批干净重复均为 **3/5**。R1–R3 均得到 task-ID F1=1、
时间窗口 F1=0.667，且均无服务 ERROR、无事件批次丢失。清理确认后保持参数不变
继续 G3-R4。

## 9. 产物

- [summary](../../../artifacts/a01-attribution-g3-20260721T053614Z/summary.md)
- [attribution](../../../artifacts/a01-attribution-g3-20260721T053614Z/attribution.json)
- [task links](../../../artifacts/a01-attribution-g3-20260721T053614Z/task-links.tsv)
- [new node events](../../../artifacts/a01-attribution-g3-20260721T053614Z/new-node-events.tsv)
- [traces](../../../artifacts/a01-attribution-g3-20260721T053614Z/traces.tsv)
- [metrics](../../../artifacts/a01-attribution-g3-20260721T053614Z/metrics.tsv)
- [Kubernetes Events](../../../artifacts/a01-attribution-g3-20260721T053614Z/kubernetes-events.json)
- [wave1 trigger](../../../artifacts/a01-attribution-g3-20260721T053614Z/wave1-trigger-utc.txt)
- [wave2 trigger](../../../artifacts/a01-attribution-g3-20260721T053614Z/wave2-trigger-utc.txt)
- [扩容前节点](../../../artifacts/a01-attribution-g3-20260721T053614Z/nodes-before.json)
- [扩容后节点](../../../artifacts/a01-attribution-g3-20260721T053614Z/nodes-after.json)
- [清理证据](../../../artifacts/a01-attribution-g3-20260721T053614Z/cleanup-evidence.txt)

只读预检产物保存在
[a01-attribution-g3-20260721T053605Z](../../../artifacts/a01-attribution-g3-20260721T053605Z/cluster-info.txt)。
