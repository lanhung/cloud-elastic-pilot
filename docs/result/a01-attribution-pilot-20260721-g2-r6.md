# A01 GOATScaler task-ID 归因 Pilot：G2 第六轮报告

## 1. 摘要

2026 年 7 月 21 日在分支 `experiment/02-attribution-pilot` 上完成 A01 G2
第 6 次真实 ACK 实验。5 个各请求 `1500m` CPU 的 Pod 中，3 个调度到已有节点，
其余 2 个共同触发一个 GOATScaler 供应任务和一个新节点。task-ID 精确连接、
新增节点差集、providerID 保存和服务日志完整性检查均通过。

本轮执行时 Gate 直接 **PASS**。controller/ingester ERROR 均为 0，被拒事件
批次为 0。G2 核心归因保持 **5/5**，无事件批次丢失的干净重复
进度达到 **4/5**。

| 项目 | 值 |
|---|---|
| Git 基线 | `7144c3a8641b941967ea4313f57d433b2ac5fa01` |
| Run ID | `01KY1D138S2AMBGTJGAS4Q4TX9` |
| Run name | `a01-attribution-g2-20260721T035526Z` |
| ACK 集群 | `c6fda2390918a4086bad884e8086557bc` |
| Kubernetes | `v1.36.1-aliyun.1` |
| 节点池 | `np7362d82bdacd4fa2b539067792f1fb57` |
| 实验前节点 | 2 个 Ready 节点 |
| 新节点 | `cn-wulanchabu.10.223.26.190` |
| 新节点规格 | `ecs.u2i-c1m1.xlarge` |
| 新节点 providerID | `cn-wulanchabu.i-0jlh5d561rcwtb5b6ou4` |
| GOATScaler task | `asa-0jl10371l7ikehaezjsk` |
| SLO | 30 秒 |

## 2. 时间线与扩容事实

| UTC 时间 | 事件 |
|---|---|
| 03:55:33 | Run 创建 |
| 03:55:45.704 | Deployment 扩到 5 个副本 |
| 03:55:45 | 2 个唯一 Pod 进入 Unschedulable，共产生 4 条状态更新 |
| 03:55:48.997 | ACK 记录供应任务触发时间 |
| 03:55:50–03:55:58 | ESS 扩容成功，容量 2→3 |
| 03:56:00 | 新 Node 创建，零时间戳 NotReady 使用观测时间回退 |
| 03:56:34 | 新 Node Ready |
| 03:56:35 | 两个 Pending Pod 调度到新 Node，各出现一次 Flannel sandbox 初始化失败 |
| 03:56:53 | 两个扩容 Pod Ready |
| 03:57:16 | Run 停止并计算归因结果 |
| 03:57:17 | Gate-A01 执行时直接 PASS |

两个 Pending Pod 的 annotation、新 Node label 和 providerID 使用同一 task ID。
ESS activity `asa-0jl10371l7ikehaezjsk` 也以该 ID 扩容，创建实例
`i-0jlh5d561rcwtb5b6ou4`。

## 3. Gate-A01

| 检查项 | 结果 |
|---|---:|
| 原始事件 | 69 |
| 轨迹 | 5/5 完整 |
| Unschedulable 事件 | 4 |
| 唯一 Unschedulable Pod | 2 |
| 有 task ID 的唯一 Pod | 2/2 |
| 唯一实验 task | 1 |
| 每 task 最大 Pod 数 | 2 |
| 弹性池节点 | 2→3 |
| 本轮新增节点 | 1 |
| 新增 Ready 节点 | 1/1 |
| 匹配当前 task 的新增节点 | 1/1 |
| 带 providerID 的当前 task 新增节点 | 1/1 |
| Pod/Node task 冲突 | 0 |
| controller / ingester ERROR | 0 / 0 |
| 被拒事件批次 | 0 |
| 执行时 Gate | **PASS** |

三种归因方法结果一致：task-ID、Kubernetes Node 和 10 分钟时间窗口均为
TP=2、FP=0、FN=0，Precision/Recall/F1 均为 1.0。G2 只有一个供应 task，
仍不能证明时间窗口方法在并发 task 下可靠，该差异留给 G3。

## 4. 事件完整性

新节点的 `NODE_CREATED`、`ACK_PROVISION_TASK_UPDATED`、
`NODE_NOT_READY` 和 `NODE_READY` 序列完整。`NODE_NOT_READY` 的零值源时间
使用观测时间回退，保留 `approximate=1` 和
`event_time_fallback=observed_time` 标记。

日志审计未发现 ERROR 或批次拒绝。这是零时间戳修复后第 4 个无事件批次
丢失的干净重复，也是唯一 Pod 计数 Gate 修正后第 3 个执行时直接 PASS 的
真实 ACK 运行。

## 5. 近似时延与 CNI 告警

两个扩容 Pod 的 `POD_UNSCHEDULABLE → NODE_READY` 均为约 49 秒，Pod 层均为
约 17 秒，应用层均为约 1 秒，总轨迹均为约 68 秒。未导入
`ACK_EVENTS_NDJSON`，Node 层仍是 Kubernetes 近似口径。

与 R2–R5 相同，新 Node 刚 Ready 后 Flannel 的 `/run/flannel/subnet.env` 尚未生成，
导致两个 Pod 各一次 `FailedCreatePodSandBox`，随后自行恢复。该问题影响 Pod
层时延，不影响 task-ID 归因。

## 6. 清理状态

- 成功路径自动删除了实验 Namespace；
- `hooke-active-run` 已清空；
- 本地 ingester/controller 端口已释放；
- 本地 MySQL 容器保留用于审计；
- Auto Mode 在 `04:06:27–04:07:20Z` 完成缩容，容量恢复 3→2；
- 本轮新增实例 `i-0jlh5d561rcwtb5b6ou4` 已删除，ECS 复查返回 0 个实例；
- 节点池最终为 2 个健康/服务节点，失败、移除中和等待移除节点均为 0。

## 7. G2 阶段性对照

| Run | task-ID F1 | 新增节点覆盖 | 服务 ERROR | 近似 Node 时延 | 总轨迹 | 结论 |
|---|---:|---:|---:|---:|---:|---|
| G2-R1 | 1.0 | 1/1 | 1 | 50 秒 | 72 秒 | 核心 PASS，完整性 WARN |
| G2-R2 | 1.0 | 1/1 | 1 | 53 秒 | 69 秒 | 核心 PASS，完整性 WARN |
| G2-R3 | 1.0 | 1/1 | 0 | 51 秒 | 69 秒 | 修正后 PASS，首个干净重复 |
| G2-R4 | 1.0 | 1/1 | 0 | 48 秒 | 65 秒 | 执行时 PASS，第 2 个干净重复 |
| G2-R5 | 1.0 | 1/1 | 0 | 46 秒 | 64 秒 | 执行时 PASS，第 3 个干净重复 |
| G2-R6 | 1.0 | 1/1 | 0 | 49 秒 | 68 秒 | 执行时 PASS，第 4 个干净重复 |

下一步继续 G2-R7，完成第 5 个无批次丢失的干净重复。

## 8. 产物

- [summary](../../artifacts/a01-attribution-g2-20260721T035526Z/summary.md)
- [attribution](../../artifacts/a01-attribution-g2-20260721T035526Z/attribution.json)
- [task links](../../artifacts/a01-attribution-g2-20260721T035526Z/task-links.tsv)
- [new node events](../../artifacts/a01-attribution-g2-20260721T035526Z/new-node-events.tsv)
- [traces](../../artifacts/a01-attribution-g2-20260721T035526Z/traces.tsv)
- [metrics](../../artifacts/a01-attribution-g2-20260721T035526Z/metrics.tsv)
- [Kubernetes Events](../../artifacts/a01-attribution-g2-20260721T035526Z/kubernetes-events.json)
- [扩容前节点](../../artifacts/a01-attribution-g2-20260721T035526Z/nodes-before.json)
- [扩容后节点](../../artifacts/a01-attribution-g2-20260721T035526Z/nodes-after.json)
- [清理证据](../../artifacts/a01-attribution-g2-20260721T035526Z/cleanup-evidence.txt)

只读预检产物保存在
[a01-attribution-g2-20260721T035515Z](../../artifacts/a01-attribution-g2-20260721T035515Z/cluster-info.txt)。
