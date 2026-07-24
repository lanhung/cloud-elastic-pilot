# A01 GOATScaler task-ID 归因 Pilot：G1 第 5 轮与最终报告

## 1. 摘要

2026 年 7 月 21 日在分支 `experiment/02-attribution-pilot` 上完成 A01 G1
第 5 次真实 ACK 实验。单个请求 `3200m` CPU、`256Mi` memory 的 Pod 再次
稳定形成一 Pod、一 task、一新 Node。

本轮执行时 Gate 直接 **PASS**，1/1 轨迹完整，controller/ingester ERROR 均为 0，
被拒事件批次为 0。task-ID、Kubernetes-node 和 10 分钟时间窗口三种方法的 F1
均为 1.0。G1 核心与无丢批干净重复均达到 **5/5**，G1 结论为 **PASS**。

| 项目 | 值 |
|---|---|
| Git 基线 | `4177e6cc66cc7fa3454a4c49efa54292f0e63ddf` |
| Run ID | `01KY1RBQWCKHPKHFB3KB3VRS4Y` |
| Run name | `a01-attribution-g1-20260721T071331Z` |
| ACK 集群 | `c6fda2390918a4086bad884e8086557bc` |
| Kubernetes | `v1.36.1-aliyun.1` |
| 节点池 | `np7362d82bdacd4fa2b539067792f1fb57` |
| Pod 请求 | `3200m` CPU / `256Mi` memory |
| 实验前/扩容后节点 | 2 / 3 |
| SLO | 30 秒 |

## 2. task 与节点

| Pending Pod | task ID | 新节点 | providerID / ECS |
|---:|---|---|---|
| 1 | `asa-0jl462kb2vgj1jizh0t7` | `cn-wulanchabu.10.223.26.199` | `cn-wulanchabu.i-0jlda3a6gkmii2jhnzhx` / `i-0jlda3a6gkmii2jhnzhx` |

Pod annotation、目标 Node label、Node providerID 和 ESS activity 一致，
Pod/Node task 冲突为 0。

## 3. 时间线

| UTC 时间 | 事件 |
|---|---|
| 07:13:36 | Run 创建 |
| 07:13:48.849 | 单 Pod Deployment 扩到 1 个副本，Pod Unschedulable |
| 07:13:52.270 | ACK 记录 task 触发时间 |
| 07:13:53–07:13:59 | ESS 扩容成功，容量 2→3 |
| 07:14:01 | 新 Node 创建 |
| 07:14:37 | 新 Node Ready，Pod 调度到新 Node |
| 07:14:39 | 首次 Flannel sandbox 创建失败 |
| 07:14:57 | Pod 自恢复并 Ready |
| 07:15:20 | Run 停止并计算归因 |
| 07:15:21 | Gate-A01 执行时直接 PASS |

## 4. Gate-A01

| 检查项 | 结果 |
|---|---:|
| 原始事件 | 24 |
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

G1 只有一个供应 task，因此三种方法结果一致是预期行为。并发 task 下应优先使用
task-ID 的结论由 G3 提供，本组完成最简单链路的稳定性验证。

## 6. 事件完整性与近似时延

新节点的 `NODE_CREATED`、`ACK_PROVISION_TASK_UPDATED`、`NODE_NOT_READY` 和
`NODE_READY` 序列完整。零值源时间的 `NODE_NOT_READY` 使用观测时间回退，保留
approximate 标记，无批次丢失。

| 近似 Node 时延 | Image 层 | Pod 层 | App 层 | 总轨迹 |
|---:|---:|---:|---:|---:|
| 48 秒 | 4 秒 | 20 秒 | 未单列 | 68 秒 |

未导入 `ACK_EVENTS_NDJSON`，Node 层仍是 Kubernetes 近似口径。Pod 在新 Node
刚 Ready 后出现一次 Flannel `FailedCreatePodSandBox`，随后自行恢复；它影响
Pod 层时延，不影响归因结论。

## 7. 清理状态

- 成功路径自动删除了实验 Namespace；
- `hooke-active-run` 已清空；
- 本地 ingester/controller 端口已释放；
- 本地 MySQL 容器保留用于审计；
- Auto Mode 在 `07:24:27–07:25:22Z` 通过一次 activity 删除新增 ECS，容量恢复 3→2；
- 新增实例 `i-0jlda3a6gkmii2jhnzhx` 已删除，ECS 复查返回 0 个实例；
- 节点池最终为 2 个健康/服务节点，失败、移除中和等待移除节点均为 0。

## 8. G1 最终对照与 A01 结论

| Run | 原始事件 | task-ID F1 | Kubernetes-node F1 | 时间窗口 F1 | Node / Image / Pod / App | 总轨迹 | 完整性 |
|---|---:|---:|---:|---:|---|---:|---|
| G1-R1 | 24 | 1.000 | 1.000 | 1.000 | 48 / 4 / 19 / 1 秒 | 69 秒 | PASS |
| G1-R2 | 27 | 1.000 | 1.000 | 1.000 | 45 / 3 / 18 / 1 秒 | 66 秒 | PASS |
| G1-R3 | 27 | 1.000 | 1.000 | 1.000 | 44 / 4 / 15 / 1 秒 | 61 秒 | PASS |
| G1-R4 | 27 | 1.000 | 1.000 | 1.000 | 50 / 3 / 18 / 1 秒 | 68 秒 | PASS |
| G1-R5 | 24 | 1.000 | 1.000 | 1.000 | 48 / 4 / 20 / 未单列 | 68 秒 | PASS |

G1 结论为 **PASS**：

- 5/5 运行均生成一个 task 和一个新节点；
- 5/5 个唯一 Pending Pod-task-Node-providerID 链接全部正确；
- 5/5 条轨迹完整，五轮服务 ERROR、归因冲突和事件批次丢失均为 0；
- 扩容分别覆盖 `cn-wulanchabu-b` 和 `cn-wulanchabu-c`，结论不依赖单一可用区；
- Node 层近似时延在 44–50 秒内变化，未改变归因结果。

至此 A01 的 G1、G2、G3 三组建议重复均完成：各组核心归因与无丢批干净重复
均达到 **5/5**。G1 验证一 Pod、一 task、一 Node；G2 验证一 task 对多个 Pod；
G3 验证并发 task 下 task-ID F1=1，而时间窗口法稳定错配。A01 不再需要重跑。

## 9. 产物

- [summary](../../../artifacts/a01-attribution-g1-20260721T071331Z/summary.md)
- [attribution](../../../artifacts/a01-attribution-g1-20260721T071331Z/attribution.json)
- [task links](../../../artifacts/a01-attribution-g1-20260721T071331Z/task-links.tsv)
- [new node events](../../../artifacts/a01-attribution-g1-20260721T071331Z/new-node-events.tsv)
- [traces](../../../artifacts/a01-attribution-g1-20260721T071331Z/traces.tsv)
- [metrics](../../../artifacts/a01-attribution-g1-20260721T071331Z/metrics.tsv)
- [Kubernetes Events](../../../artifacts/a01-attribution-g1-20260721T071331Z/kubernetes-events.json)
- [wave1 trigger](../../../artifacts/a01-attribution-g1-20260721T071331Z/wave1-trigger-utc.txt)
- [扩容前节点](../../../artifacts/a01-attribution-g1-20260721T071331Z/nodes-before.json)
- [扩容后节点](../../../artifacts/a01-attribution-g1-20260721T071331Z/nodes-after.json)
- [清理证据](../../../artifacts/a01-attribution-g1-20260721T071331Z/cleanup-evidence.txt)

只读预检产物保存在
[a01-attribution-g1-20260721T071310Z](../../../artifacts/a01-attribution-g1-20260721T071310Z/cluster-info.txt)。
