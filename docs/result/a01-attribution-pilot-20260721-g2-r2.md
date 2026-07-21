# A01 GOATScaler task-ID 归因 Pilot：G2 第二轮报告

## 1. 摘要

2026 年 7 月 21 日在分支 `experiment/02-attribution-pilot` 上完成 A01 G2
第 2 次真实 ACK 实验。5 个各请求 `1500m` CPU 的 Pod 中，3 个调度到已有节点，
其余 2 个共同触发一个 GOATScaler 供应任务和一个新节点。两个 Pending Pod、
新 Node label 与 Node providerID 的 task-ID 链接完整，核心归因检查为 **PASS**；
运行后加固的事件完整性 Gate 为 **FAIL**，原因见下文。

本轮在 R1 后补充了弹性池节点前后差集口径，明确区分“采集器观测到的节点”和
“本轮新增节点”。差集识别出的 1 个新增节点同时具备 Ready、当前 task-ID 和
providerID 证据，避免已有节点遗留的 GOATScaler label 被误计为本轮覆盖。

归因 Gate 的核心关系为 PASS，但控制器日志显示一批 7 条事件因零值 Node
时间戳被 Ingester 拒绝。本轮保留为有效的 task-ID 归因样本，但原始事件数不能
视为完整事件流；修复和后续 Gate 加固见第 5 节。

G2 核心归因样本进度为 **2/5**；按加固后的“服务无 ERROR”完整性标准，两轮均
带有同一已知告警，因此干净重复进度仍为 **0/5**。本报告不报告正式 p99，也不
据此证明稳定性。

| 项目 | 值 |
|---|---|
| Git 基线 | `a3033b8eb4df7dcad75bdbc1b82a1ad8d448c779`（本轮口径修正在当前工作树） |
| Run ID | `01KY18HDQVB09GY7WPBYB0MCGW` |
| Run name | `a01-attribution-g2-20260721T023658Z` |
| ACK 集群 | `c6fda2390918a4086bad884e8086557bc` |
| Kubernetes | `v1.36.1-aliyun.1` |
| 节点池 | `np7362d82bdacd4fa2b539067792f1fb57` |
| 实验前节点 | 2 个 Ready 节点 |
| 新节点 | `cn-wulanchabu.10.223.26.188` |
| 新节点规格 | `ecs.u2i-c1m1.xlarge` |
| 新节点 providerID | `cn-wulanchabu.i-0jlhnuo11kc4qoymbvjn` |
| SLO | 30 秒 |

## 2. 负载与扩容事实

实验前两台节点按 CPU request 尚可接纳 3 个 `1500m` Pod。Deployment 扩至
5 个副本后，2 个 Pod 因 CPU 不足进入 Pending，并获得相同 GOATScaler task ID：
`asa-0jlcpv1j4aj2ypmdfvnu`。

ACK 创建的新 Node 带有同一个 task label，两个 Pending Pod 随后都调度到该
Node，形成预期的一 task 对两 Pod 关系。ESS 侧扩容 activity 同样使用该 ID，
并记录容量从 2 增至 3、新增实例 `i-0jlhnuo11kc4qoymbvjn`。

| UTC 时间 | 事件 |
|---|---|
| 02:37:05 | Run 创建 |
| 02:37:17.901 | 第一波 Deployment 扩到 5 个副本 |
| 02:37:18 | 2 个 Pod 首次 `POD_UNSCHEDULABLE` |
| 02:37:21.342 | ACK 记录供应任务触发时间 |
| 02:37:22–02:37:23 | 两个 Pod 各出现一条 `ProvisionNode` Event，task ID 相同 |
| 02:37:22–02:37:30 | ESS 扩容成功，容量 2→3 |
| 02:37:33 | 新 Node 对象创建 |
| 02:38:11 | 新 Node Ready |
| 02:38:12 | 两个 Pending Pod 调度到新 Node |
| 02:38:27 | 两个扩容 Pod Ready |
| 02:38:50 | Run 完成，Gate-A01 PASS |

## 3. 新增节点口径

本轮新增以下审计逻辑和产物：

- 分别保存扩容前后的弹性池节点名；
- 以集合差生成 `new-node-names.txt`；
- 只对差集内节点计算 Ready、当前 run task-ID 和 providerID 覆盖；
- Gate 使用新增节点指标，原有 `observed_nodes` 只保留为采集器事件诊断值。

本轮 `observed_nodes=2` 并不表示节点池只有两个相关节点；它表示 active-run
期间有两个 Node 产生了采集事件。节点池事实由弹性池快照给出：2→3，其中新增
节点为 1。新增节点专属事件见 `new-node-events.tsv`。

## 4. Gate-A01

| 检查项 | 结果 |
|---|---:|
| 原始事件 | 62 |
| 轨迹 | 5/5 完整 |
| Unschedulable Pod | 2 |
| 有 task ID 的 Unschedulable Pod | 2/2 |
| 唯一实验 task | 1 |
| 每 task 最大 Pod 数 | 2 |
| 弹性池节点 | 2→3 |
| 本轮新增节点 | 1 |
| 新增 Ready 节点 | 1/1 |
| 匹配当前 task 的新增节点 | 1/1 |
| 带 providerID 的当前 task 新增节点 | 1/1 |
| Pod task-ID 覆盖率 | 1.0 |
| Node task-ID 覆盖率 | 1.0（采集器观测节点口径） |
| providerID 覆盖率 | 1.0（采集器观测节点口径） |
| instance ID 覆盖率 | 0.0（未接入 SLS/ECS 输入，允许） |
| Pod/Node task 冲突 | 0 |
| controller / ingester ERROR | 1 / 0（运行后审计发现） |
| 本轮执行时归因 Gate | **PASS** |
| 加固后的完整性 Gate | **FAIL**（已修复，待后续 run 验证） |

三种方法在本轮单波、单新增节点场景中仍然得到相同结果：

| 方法 | TP | FP | FN | Precision | Recall | F1 |
|---|---:|---:|---:|---:|---:|---:|
| task-ID | 2 | 0 | 0 | 1.0 | 1.0 | 1.0 |
| Kubernetes Node | 2 | 0 | 0 | 1.0 | 1.0 | 1.0 |
| 10 分钟时间窗口 | 2 | 0 | 0 | 1.0 | 1.0 | 1.0 |

G2 仍不能验证时间窗口方法在并发 task 下的可靠性；该差异由后续 G3 验证。

## 5. 近似时延与异常

两个扩容 Pod 的 `POD_UNSCHEDULABLE → NODE_READY` 均为约 53 秒，Pod 层均为
约 15 秒，总轨迹均为约 69 秒。未导入 `ACK_EVENTS_NDJSON`，因此 Node 起点仍是
Kubernetes 近似口径，不能替代严格的
`ACK_PROVISION_TASK_CREATED → NODE_READY` 时延。

新 Node 在 `02:38:11Z` 刚 Ready 时，两个 Pod 各出现一次
`FailedCreatePodSandBox`：Flannel 的 `/run/flannel/subnet.env` 尚未生成。网络组件
随后自行恢复，Pod 在约 12–15 秒后开始拉取镜像并于 `02:38:27Z` Ready。该异常
影响 Pod 层时延解释，但没有造成 partial trace、归因冲突或归因 Gate 失败，这两条
CNI 原始 Event 已保留。

控制器在 `02:37:39Z` 记录一次 `failed to send event batch`，批次大小为 7，原因是
新 Node 早期状态中的零值 `lastTransitionTime` 被转换成非正 `event_time_ns`。
Ingester 正确地拒绝了整个批次，因此 `raw_events=62` 不是完整性计数。现存证据仍
完整覆盖本轮 Gate 所需的两个 Pod annotation、新 Node Ready task label、providerID
以及最终调度关系，所以 task-ID 归因结论不变；但不能用本轮事件总数分析事件频率。

R1 日志中也发现相同告警。当前工作树已加入三层防护：零/非正源时间回退到观测
时间并标记 approximate、Batcher 入队前校验单事件、controller/ingester ERROR
计入实验 Gate。G2-R3 必须同时验证这两个错误计数为 0。

测试镜像仍来自杭州 Registry，而集群位于乌兰察布。本轮主结论只涉及 task-ID
归因；正式分层时延实验应使用同地域不可变 digest。

## 6. 清理状态

- 实验 Namespace 已删除；
- `hooke-active-run` 已清空；
- 本地 ingester/controller 端口已释放；
- 本地 MySQL 容器保留用于审计；
- Auto Mode 在 `02:48:27–02:49:21Z` 完成缩容，容量恢复 3→2；
- 本轮新增实例 `i-0jlhnuo11kc4qoymbvjn` 被删除；
- 节点池最终为 2 个健康/服务节点，失败和移除中节点均为 0。

## 7. 与 R1 的阶段性对照

| Run | task-ID F1 | 新增节点覆盖 | 近似 Node 时延 | 总轨迹 | 结果 |
|---|---:|---:|---:|---:|---:|
| G2-R1 | 1.0 | 1/1（由原始快照复核） | 50 秒 | 72 秒 | PASS + 完整性 WARN |
| G2-R2 | 1.0 | 1/1（差集 Gate） | 53 秒 | 69 秒 | PASS + 完整性 WARN |

两轮的 task-ID 归因结果一致，但都不能作为“无事件批次丢失”的干净重复；下一步
从 G2-R3 验证修复，并补足 5 次无 ERROR 重复。

## 8. 产物

- [summary](../../artifacts/a01-attribution-g2-20260721T023658Z/summary.md)
- [attribution](../../artifacts/a01-attribution-g2-20260721T023658Z/attribution.json)
- [task links](../../artifacts/a01-attribution-g2-20260721T023658Z/task-links.tsv)
- [new node events](../../artifacts/a01-attribution-g2-20260721T023658Z/new-node-events.tsv)
- [traces](../../artifacts/a01-attribution-g2-20260721T023658Z/traces.tsv)
- [metrics](../../artifacts/a01-attribution-g2-20260721T023658Z/metrics.tsv)
- [Kubernetes Events](../../artifacts/a01-attribution-g2-20260721T023658Z/kubernetes-events.json)
- [扩容前节点](../../artifacts/a01-attribution-g2-20260721T023658Z/nodes-before.json)
- [扩容后节点](../../artifacts/a01-attribution-g2-20260721T023658Z/nodes-after.json)
- [缩容证据](../../artifacts/a01-attribution-g2-20260721T023658Z/cleanup-evidence.txt)

只读预检产物保存在
[a01-attribution-g2-20260721T023628Z](../../artifacts/a01-attribution-g2-20260721T023628Z/cluster-info.txt)。
