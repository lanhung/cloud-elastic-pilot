# A01 GOATScaler task-ID 归因 Pilot：G2 首轮报告

## 1. 摘要

2026 年 7 月 21 日在分支 `experiment/02-attribution-pilot` 上完成 A01 G2
首轮真实 ACK 实验。5 个各请求 `1500m` CPU 的 Pod 中，3 个调度到已有节点，
其余 2 个共同触发一个 GOATScaler 供应任务和一个新节点。两个 Pending Pod、
新 Node label 与 Node providerID 的 task-ID 链接完整，Gate-A01 为 **PASS**。

本轮只是 G2 的第 1 次运行，不用于证明 5 次建议重复下的稳定性，也不报告正式
p99 结论。

| 项目 | 值 |
|---|---|
| Git commit | `290b2f0379ef35355145366befadc08a577f7b16` |
| Run ID | `01KY16B9P02NQ2C0JSH1SK0Q1Z` |
| Run name | `a01-attribution-g2-20260721T015840Z` |
| ACK 集群 | `c6fda2390918a4086bad884e8086557bc` |
| Kubernetes | `v1.36.1-aliyun.1` |
| 节点池 | `np7362d82bdacd4fa2b539067792f1fb57` |
| 实验前节点 | 2 个 Ready 节点 |
| 新节点 | `cn-wulanchabu.10.223.26.187` |
| 新节点规格 | `ecs.u2i-c1m1.xlarge` |
| 新节点运行时 | containerd `2.1.6` |
| SLO | 30 秒 |

## 2. 负载与扩容事实

现有两台节点的可调度 CPU 只能接纳 3 个 `1500m` Pod，因此本轮将 G2
副本数设为 5。调度后有 2 个 Pod 因 CPU 不足进入 Pending，并得到同一个
GOATScaler task ID：`asa-0jl10371l7ikd00ky1x1`。

ACK 创建的新 Node 同样带有该 task label，并保存 providerID
`cn-wulanchabu.i-0jleua341tvtyggtcpzb`。两个 Pod 最终都调度到该 Node，形成
预期的一 task 对两 Pod 关系。

| UTC 时间 | 事件 |
|---|---|
| 01:58:47 | Run 创建 |
| 01:59:00 | 第一波 Deployment 扩到 5 个副本 |
| 01:59:01 | 2 个 Pod 首次 `FailedScheduling` / `POD_UNSCHEDULABLE` |
| 01:59:04.357 | ACK 记录供应任务触发时间 |
| 01:59:05 | 两个 Pod 各出现一条 `ProvisionNode` Event，task ID 相同 |
| 01:59:18 | 新 Node 对象创建 |
| 01:59:51 | 新 Node Ready，两个 Pod 调度到该 Node |
| 02:00:36 | Run 完成，Gate-A01 PASS |
| 02:04:32 | ACK 开始缩容低利用率旧节点 `.185` |
| 02:05:26 | 旧 ECS 实例删除完成，节点池容量恢复 3→2 |

## 3. Gate-A01

| 检查项 | 结果 |
|---|---:|
| 原始事件 | 68 |
| 轨迹 | 5/5 完整 |
| Unschedulable Pod | 2 |
| 有 task ID 的 Unschedulable Pod | 2/2 |
| 唯一实验 task | 1 |
| 每 task 最大 Pod 数 | 2 |
| Pod task-ID 覆盖率 | 1.0 |
| Node task-ID 覆盖率 | 1.0 |
| providerID 覆盖率 | 1.0 |
| instance ID 覆盖率 | 0.0（未接入 SLS/ECS，允许） |
| Pod/Node task 冲突 | 0 |
| Gate-A01 | **PASS** |

三种方法在本轮单波、单新增节点场景中结果相同：

| 方法 | TP | FP | FN | Precision | Recall | F1 |
|---|---:|---:|---:|---:|---:|---:|
| task-ID | 2 | 0 | 0 | 1.0 | 1.0 | 1.0 |
| Kubernetes Node | 2 | 0 | 0 | 1.0 | 1.0 | 1.0 |
| 10 分钟时间窗口 | 2 | 0 | 0 | 1.0 | 1.0 | 1.0 |

G2 本身不能证明时间窗口方法在并发 task 下可靠；该差异需要由 G3 验证。

## 4. 近似时延

两个扩容 Pod 的 `POD_UNSCHEDULABLE → NODE_READY` 均为约 50 秒，Pod 层均为
约 21 秒，总轨迹均为约 72 秒。未导入 `ACK_EVENTS_NDJSON`，因此 Node 起点仍是
Kubernetes 近似口径；这些值不能替代严格的 GOATScaler task-created 时延。

测试镜像来自杭州 Registry，而集群位于乌兰察布。本轮主结论只涉及 task-ID
归因；跨地域镜像会影响 Image 层时延，后续正式分层测量应换成同地域不可变 digest。

## 5. 清理状态

- 实验 Namespace 已删除；
- 临时 Deployment、Service 和 Pod 已随 Namespace 删除；
- `hooke-active-run` 已清空；
- 本地 ingester/controller 端口已释放；
- 本地 MySQL 容器保留用于审计；
- ACK 在 `02:04:32–02:05:26Z` 完成缩容，节点池恢复到 2 个健康节点；
- Auto Mode 删除的是更空闲的旧节点 `cn-wulanchabu.10.223.26.185`，保留了本轮
  新节点 `.187` 来承载迁移后的系统 Pod。清理验收因此以总容量恢复为准，不能假定
  本轮新增节点一定是被回收对象。

## 6. 产物

- [summary](../../artifacts/a01-attribution-g2-20260721T015840Z/summary.md)
- [attribution](../../artifacts/a01-attribution-g2-20260721T015840Z/attribution.json)
- [task links](../../artifacts/a01-attribution-g2-20260721T015840Z/task-links.tsv)
- [traces](../../artifacts/a01-attribution-g2-20260721T015840Z/traces.tsv)
- [metrics](../../artifacts/a01-attribution-g2-20260721T015840Z/metrics.tsv)
- [Kubernetes Events](../../artifacts/a01-attribution-g2-20260721T015840Z/kubernetes-events.json)
- [扩容前节点](../../artifacts/a01-attribution-g2-20260721T015840Z/nodes-before.json)
- [扩容后节点](../../artifacts/a01-attribution-g2-20260721T015840Z/nodes-after.json)
- [缩容证据](../../artifacts/a01-attribution-g2-20260721T015840Z/cleanup-evidence.txt)

只读预检产物保存在
[a01-attribution-g2-20260721T015821Z](../../artifacts/a01-attribution-g2-20260721T015821Z/cluster-info.txt)。
