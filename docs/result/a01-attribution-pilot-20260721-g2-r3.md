# A01 GOATScaler task-ID 归因 Pilot：G2 第三轮报告

## 1. 摘要

2026 年 7 月 21 日在分支 `experiment/02-attribution-pilot` 上完成 A01 G2
第 3 次真实 ACK 实验。5 个各请求 `1500m` CPU 的 Pod 中，3 个调度到已有节点，
其余 2 个共同触发一个 GOATScaler 供应任务和一个新节点。task-ID 精确连接、
新增节点差集和服务日志完整性检查均通过。

本轮成功验证了 R1/R2 后的零时间戳修复：新 Node 早期 `NODE_NOT_READY` 的零值
源时间回退到观测时间并标记 approximate，`NODE_CREATED`、task 更新和
`NODE_READY` 均完整入库，controller/ingester ERROR 均为 0。

执行时的 `summary.md` 仍返回 FAIL，但原因是 Gate 把 4 条 Unschedulable 状态更新
与 2 个唯一 task-ID Pod 比较。实际是同两个 Pod 各产生两条状态更新。事后按唯一
`pod_uid` 复核为 **PASS_AFTER_GATE_FIX**，原始 FAIL 摘要保持不变以供审计。

G2 核心归因进度为 **3/5**，无事件批次丢失的干净重复进度为 **1/5**。

| 项目 | 值 |
|---|---|
| Git 基线 | `a3033b8eb4df7dcad75bdbc1b82a1ad8d448c779`（修复位于当前工作树） |
| Run ID | `01KY19QCAVDPNMD6MA0V7J8QJ7` |
| Run name | `a01-attribution-g2-20260721T025742Z` |
| ACK 集群 | `c6fda2390918a4086bad884e8086557bc` |
| Kubernetes | `v1.36.1-aliyun.1` |
| 节点池 | `np7362d82bdacd4fa2b539067792f1fb57` |
| 实验前节点 | 2 个 Ready 节点 |
| 新节点 | `cn-wulanchabu.10.223.26.189` |
| 新节点规格 | `ecs.u2i-c1m1.xlarge` |
| 新节点 providerID | `cn-wulanchabu.i-0jl7bdnyve2pz7h2555q` |
| GOATScaler task | `asa-0jl462kb2vgiy954pp6a` |
| SLO | 30 秒 |

## 2. 时间线与扩容事实

| UTC 时间 | 事件 |
|---|---|
| 02:57:49 | Run 创建 |
| 02:58:01.646 | Deployment 扩到 5 个副本 |
| 02:58:01 | 2 个唯一 Pod 进入 Unschedulable，共产生 4 条状态更新 |
| 02:58:05.700 | ACK 记录供应任务触发时间 |
| 02:58:06–02:58:15 | ESS 扩容成功，容量 2→3 |
| 02:58:17 | 新 Node 创建；零时间戳 NotReady 使用观测时间回退 |
| 02:58:52 | 新 Node Ready，两个 Pending Pod 调度到该 Node |
| 02:58:54 | 两个 Pod 各出现一次 Flannel sandbox 初始化失败 |
| 02:59:10 | 两个扩容 Pod Ready |
| 02:59:33 | Run 完成并计算归因结果 |
| 02:59:34 | 旧 Gate 因事件行/唯一 Pod 计数单位不一致返回 FAIL |

两个 Pending Pod 的 annotation、新 Node label 和 providerID 使用同一 task ID。
ESS activity 也以该 task ID 扩容，并创建实例 `i-0jl7bdnyve2pz7h2555q`。

## 3. 时间戳修复验证

R1/R2 中，新 Node 初始 Ready Condition 可能携带 Go 零时间。旧采集函数将其覆盖
为负 `event_time_ns`，使 Ingester 拒绝包含该事件的整个批次。本轮修复后，新节点
事件序列为：

| Event | approximate | 时间回退标记 | task/provider |
|---|---:|---|---:|
| `NODE_CREATED` | 0 | 无 | 完整 |
| `ACK_PROVISION_TASK_UPDATED` | 1 | 无 | 完整 |
| `NODE_NOT_READY` | 1 | `event_time_fallback=observed_time` | 完整 |
| `NODE_READY` | 0 | 无 | 完整 |

此外，Batcher 会在入队前校验单个事件，避免一个非法事件拖掉整批。结果：

- controller ERROR：0；
- ingester ERROR：0；
- 被拒事件批次：0；
- 原始事件：69。

## 4. Gate 复核

| 检查项 | 结果 |
|---|---:|
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
| 执行时 Gate | **FAIL（计数缺陷）** |
| 修正后 Gate | **PASS_AFTER_GATE_FIX** |

三种归因方法结果一致：task-ID、Kubernetes Node 和 10 分钟时间窗口均为
TP=2、FP=0、FN=0，Precision/Recall/F1 均为 1.0。G2 仍不能证明时间窗口方法在
并发 task 下可靠，该差异留给 G3。

Gate 已改为使用 `COUNT(DISTINCT pod_uid)` 比较唯一 Pod，同时保留事件行数作为
诊断值。详细复核见 `posthoc-gate.md`。

## 5. 近似时延与 CNI 告警

两个扩容 Pod 的 `POD_UNSCHEDULABLE → NODE_READY` 均为约 51 秒，Pod 层均为
约 18 秒，总轨迹均为约 69 秒。未导入 `ACK_EVENTS_NDJSON`，Node 层仍是
Kubernetes 近似口径。

与 R2 相同，新 Node 刚 Ready 后 Flannel 的 `/run/flannel/subnet.env` 尚未生成，
导致两个 Pod 各一次 `FailedCreatePodSandBox`，随后自行恢复。该问题影响 Pod
层时延，不影响 task-ID 归因。正式分层时延实验仍应使用同地域不可变镜像，并将
Node Ready 与 CNI Ready 分开观测。

## 6. 清理状态

- 失败路径保留的空实验 Namespace 已手动删除；
- `hooke-active-run` 已清空；
- 本地 ingester/controller 端口已释放；
- 本地 MySQL 容器保留用于审计；
- Auto Mode 在 `03:08:27–03:09:22Z` 完成缩容，容量恢复 3→2；
- 本轮新增实例 `i-0jl7bdnyve2pz7h2555q` 被删除；
- 节点池最终为 2 个健康/服务节点，失败和移除中节点均为 0。

## 7. G2 阶段性对照

| Run | task-ID F1 | 新增节点覆盖 | 服务 ERROR | 近似 Node 时延 | 总轨迹 | 结论 |
|---|---:|---:|---:|---:|---:|---|
| G2-R1 | 1.0 | 1/1 | 1 | 50 秒 | 72 秒 | 核心 PASS，完整性 WARN |
| G2-R2 | 1.0 | 1/1 | 1 | 53 秒 | 69 秒 | 核心 PASS，完整性 WARN |
| G2-R3 | 1.0 | 1/1 | 0 | 51 秒 | 69 秒 | 修正后 PASS，首个干净重复 |

下一步继续 G2-R4，并要求执行时 Gate 直接 PASS、服务 ERROR 为 0。

## 8. 产物

- [原始 summary](../../artifacts/a01-attribution-g2-20260721T025742Z/summary.md)
- [事后 Gate 复核](../../artifacts/a01-attribution-g2-20260721T025742Z/posthoc-gate.md)
- [attribution](../../artifacts/a01-attribution-g2-20260721T025742Z/attribution.json)
- [task links](../../artifacts/a01-attribution-g2-20260721T025742Z/task-links.tsv)
- [new node events](../../artifacts/a01-attribution-g2-20260721T025742Z/new-node-events.tsv)
- [traces](../../artifacts/a01-attribution-g2-20260721T025742Z/traces.tsv)
- [metrics](../../artifacts/a01-attribution-g2-20260721T025742Z/metrics.tsv)
- [Kubernetes Events](../../artifacts/a01-attribution-g2-20260721T025742Z/kubernetes-events.json)
- [扩容前节点](../../artifacts/a01-attribution-g2-20260721T025742Z/nodes-before.json)
- [扩容后节点](../../artifacts/a01-attribution-g2-20260721T025742Z/nodes-after.json)
- [清理证据](../../artifacts/a01-attribution-g2-20260721T025742Z/cleanup-evidence.txt)

只读预检产物保存在
[a01-attribution-g2-20260721T025733Z](../../artifacts/a01-attribution-g2-20260721T025733Z/cluster-info.txt)。
