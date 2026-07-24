# E04 KEDA scale-to-zero 1×2 冒烟实验报告

## 1. 摘要

2026 年 7 月 24 日在真实 ACK 集群上完成 E04 KEDA scale-to-zero 首轮
1×2 配对冒烟。实验使用同一固定节点、相同 Redis/worker 镜像和相同消息负载，
分别运行 `cooldownPeriod=60s` 与 `300s` 两个 cell。两次运行均通过 fail-closed
Gate，最终会话结果为 **PASS**。

| Gate | 60 秒 cell | 300 秒 cell |
|---|---:|---:|
| 运行结果 | PASS | PASS |
| 完整消息链 | 12/12 | 12/12 |
| queue depth 样本 | 29 | 29 |
| KEDA external metric 样本 | 50 | 212 |
| metric 请求错误 | 0 | 0 |
| worker Ready Pod | 4 | 4 |
| ScaledObject Inactive→Active→Inactive | 完整 | 完整 |
| HPA 正 desired replicas | 已观测 | 已观测 |
| 最终 scale-to-zero | 已观测 | 已观测 |
| 观测缩容延迟 | 55.028 秒 | 295.032 秒 |

本轮证明了以下真实链路可运行：

```text
producer → Redis list → KEDA external metric → HPA → worker
         → 消息处理完成 → ScaledObject Inactive → Deployment scale-to-zero
```

结论等级是 **冒烟 Gate PASS**。每个 cooldown 只有 1 次运行，不能据此报告稳定的
p50/p95/p99、显著性或正式的 Rule 2 参数结论。ACK 中的 KEDA 2.20.1
ScaledObject condition 不提供 `lastTransitionTime`，因此 Active/Inactive 与
cooldown 观测保留 `approximate=true`，没有包装成精确时间。

## 2. 实验目标与判定

本轮回答以下工程问题：

1. Redis producer 能否以约 1 message/s 的速率产生 12 条可追踪消息；
2. KEDA Redis scaler 能否观测队列，从 0 激活 worker Deployment；
3. HPA 是否出现正 desired replicas，至少一个 worker Pod 是否 Ready；
4. 每条消息是否形成唯一、有序的
   enqueue→dequeue→processing-start→processed 因果链；
5. 队列和 external metric 是否均出现 `0 → 正值 → 0`；
6. busy period 结束后，ScaledObject 是否转为 Inactive；
7. worker 是否在配置 cooldown 后缩容到 0；
8. 两个 cell 的事件、采样、日志和派生指标能否独立追溯；
9. 成功后能否删除 Namespace、Lease、Secret 和所有工作负载。

每个 cell 必须同时满足：

- 初始 worker 的期望、当前、Ready 和 Available 副本均为 0；
- 初始 external metric 存在 0 样本，采样无错误且间隔不超限；
- 12 条消息的四段应用事件数量、身份和顺序完全匹配；
- 实际到达率在配置容差内；
- queue depth 出现正值并最终回到 0；
- ScaledObject 先 Active、后 Inactive；
- HPA 出现正 desired replicas；
- 至少一个 worker Pod Ready；
- scale-to-zero 晚于 busy period 结束；
- 观测 cooldown 位于 polling interval 允许的区间内。

上述 Gate 在成功会话中全部通过。

## 3. 冻结环境

| 项目 | 值 |
|---|---|
| 成功会话 | `e04-keda-scale-to-zero-pilot-20260724T061144Z` |
| 执行窗口 | 2026-07-24 06:11:44Z–06:19:48Z |
| 分支 | `experiment/06-keda-scale-to-zero-pilot` |
| 编排 Git | `3aa1664f1b6c13852de7aae4a37cc823dcba493e`，clean |
| 应用镜像构建 Git | `30b8930059796db22c4a18e1163517f53b0fe914`，clean |
| 随机种子 | `20260724` |
| ACK cluster ID | `c1c5437d0c5264255926d4a28f8c67c20` |
| Kubernetes | `v1.36.1-aliyun.1` |
| KEDA | 2.20.1 |
| 固定节点 | `cn-wulanchabu.10.170.108.83` |
| 节点 OS | Alibaba Cloud Linux 4.0.3（OpenAnolis Edition） |
| kernel / runtime | `6.6.102-5.3.1.alnx4.x86_64` / containerd 2.1.9 |
| cooldown | 60 秒、300 秒 |
| polling interval | 5 秒 |
| min / max replicas | 0 / 4 |
| 配置到达率 | 1 message/s |
| 每个 cell 消息数 | 12 |
| 单消息处理时长 | 2 秒 |
| 每个 cooldown 重复 | 1 |

应用与 Redis 均使用不可变 digest：

```text
app:
crpi-rde6dbx17y795odv.cn-wulanchabu.personal.cr.aliyuncs.com/hooke-lab/cloud-elastic-pilot@sha256:8761ff2e4d116452057bb23b36bb935728125a019749b1b7fa93b57195f71725

redis:
crpi-rde6dbx17y795odv.cn-wulanchabu.personal.cr.aliyuncs.com/hooke-lab/cloud-elastic-pilot@sha256:06ca86a2130235868e8688e47988030cfb0b3560970349e3a23a2f4a62f6c594
```

应用镜像构建大小为 3,340,705 B。Redis、producer 和 worker 均通过
`kubernetes.io/hostname` 固定到同一已有 Ready 节点，不混入 Node 扩容。

## 4. 实验设计

### 4.1 配对顺序

本轮最小冒烟矩阵为 1 个配对区组：

| sequence | block | cell |
|---:|---:|---|
| 1 | 1 | cooldown 60 秒 |
| 2 | 1 | cooldown 300 秒 |

两个 cell 各自使用独立 Namespace、Run ID、Redis Secret、队列 key 和 artifact
目录。前一个 Namespace 删除并完成清理后才进入后一个 cell。

### 4.2 时间与事件来源

| 信号 | 来源 | 口径 |
|---|---|---|
| 消息 enqueue/dequeue/processed | producer/worker stdout 源时间 | 精确应用源时间 |
| queue depth / busy period | producer/worker stdout 源时间 | 精确应用源时间 |
| KEDA metric | external metrics API 轮询 | 观察时间，近似 |
| ScaledObject Active/Inactive | KEDA condition Watch | 本集群无 transition time，近似 |
| HPA desired/current | HPA status Watch | 观察时间，近似 |
| worker Ready | Kubernetes Pod condition | API Server condition 时间 |
| scale-to-zero | Deployment `spec.replicas` 正数→0 | Watch 观察时间，近似 |

stdout 仅作为应用事件载体。导出阶段冻结 Pod UID、Container ID、Node 和日志，
使用进程写出的 `source_time_ns`，不以日志抓取时间替代事件时间。

## 5. 结果

### 5.1 两个 cell 的观测

| 指标 | cooldown 60 秒 | cooldown 300 秒 |
|---|---:|---:|
| Run ID | `01KY9C1A179448PT1ETR7J576N` | `01KY9C4MZXFRV4R5E2REKWP192` |
| Run 窗口 | 80.516 秒 | 321.647 秒 |
| 实际 λ | 0.999950/s | 0.999936/s |
| KEDA Active 反应 | 2.473 秒 | 2.419 秒 |
| HPA 正 desired 反应 | 7.500 秒 | 7.445 秒 |
| 首个 worker Ready | 3.405 秒 | 2.848 秒 |
| 首条消息处理完成 | 4.592 秒 | 4.545 秒 |
| busy period | 14.010 秒 | 14.011 秒 |
| 观测 scale-to-zero | 55.028 秒 | 295.032 秒 |
| worker Pod | 4 | 4 |
| KEDA 样本 | 50 | 212 |

两个 cell 的实际到达率与配置 1 message/s 的相对误差均小于 0.01%。每次均形成
4 个 Ready worker Pod，12 条消息全部处理完成，队列最终回到 0。

观测 scale-to-zero 分别比配置值少约 4.97 秒。该差值与 5 秒 polling interval
同量级，且 Inactive 与 Deployment 归零都是 Watch 观察时间，不应解释为 KEDA
提前违反 cooldown。

### 5.2 消息因果链

每个 cell 的事件计数为：

| 事件 | 每 cell 数量 |
|---|---:|
| `MESSAGE_ENQUEUED` | 12 |
| `MESSAGE_DEQUEUED` | 12 |
| `MESSAGE_PROCESSING_STARTED` | 12 |
| `MESSAGE_PROCESSED` | 12 |
| `BUSY_PERIOD_STARTED` / `ENDED` | 1 / 1 |

所有消息 ID 唯一，四个阶段严格有序，没有丢失、重复或跨 Run/Pod/Container
归因。两个 cell 各有 29 个 exact queue depth 样本。

### 5.3 KEDA/HPA 控制链

每个 cell 均观测到：

- 初始 `KEDA_SCALEDOBJECT_INACTIVE`；
- enqueue 后 `KEDA_SCALEDOBJECT_ACTIVE`；
- external metric 初始 0、正值和 post-active 0；
- HPA 正 desired replicas；
- 4 个 worker Pod Ready；
- busy period 后再次 `KEDA_SCALEDOBJECT_INACTIVE`；
- `KEDA_SCALE_TO_ZERO`。

60 秒 cell 保存 50 个 KEDA 样本，300 秒 cell 保存 212 个样本；metric 请求错误
均为 0。controller 和 ingester 日志没有 ERROR、FATAL 或 PANIC。

### 5.4 Rule 2 计算链路

汇总器基于两个通过 Gate 的 cell 计算：

| 汇总量 | 值 |
|---|---:|
| pooled λ | 0.999943/s |
| 平均冷启动 `μ_s` | 3.126589 秒 |
| 平均 busy period `E[V]` | 14.010517 秒 |
| 目标 elasticity | 0.99 |
| 反解 `τ*` | 1.473255 秒 |

两个 cell 的 predicted elasticity 在 JSON 数值精度下均为 1.0。这里仅证明
公式、聚合和 `τ*` 反解链路能够运行；每个 cell 只有 1 次，不能把这些值作为正式
调优建议。

## 6. 数据质量与限制

| 检查 | 结果 |
|---|---:|
| 子运行 PASS | 2/2 |
| 完整消息链 | 24/24 |
| KEDA metric 请求错误 | 0 |
| 负时延/顺序错误 | 0 |
| Namespace/Run/Pod/Container 交叉归因 | 0 |
| controller / ingester ERROR | 0 / 0 |

限制如下：

1. **每个 cell 只有 1 次。** 只能验证 Gate，不能估计方差、置信区间或分位数；
2. **执行顺序固定为 60→300。** 不能排除时间趋势、镜像缓存或节点缓存影响；
3. **KEDA condition 时间为近似。** KEDA 2.20.1 未提供
   `lastTransitionTime`，Active/Inactive 使用 informer 观察时间；
4. **cooldown 也是近似观测。** 起点使用 Inactive 观察，终点使用 Deployment
   spec 归零观察，误差量级受 polling interval 和 informer 延迟影响；
5. **只有一个固定节点、集群和 KEDA 版本。** 结果不能直接推广到其他节点负载、
   KEDA 版本或 external metric 实现；
6. **不包含 Node 扩容。** 这是为隔离 KEDA 控制链而有意设置；
7. **Rule 2 输入样本过少。** `τ*` 只验证计算实现，不代表生产建议；
8. 当前 preflight 只验证 selector、Ready、taint 和单项资源配置，没有扣除节点上
   已有 Pod requests；正式 Pilot 前应补充可调度容量 Gate。

## 7. 冒烟中发现并修复的问题

成功会话之前有 6 次 fail-closed 尝试，均未进入最终汇总：

| 会话时间 | 现象 | 修复 |
|---|---|---|
| `05:48Z` | Bash `local` 同行初始化在 `set -u` 下引用未绑定的 `timeout_seconds` | `cde2156`：拆分 timeout/deadline 初始化并增加回归测试 |
| `05:50Z` | 原固定节点内存 requests 已达 98%，Redis Pending | 切换到有足够余量的固定节点 `.83`；容量 Gate 仍列为后续项 |
| `05:54Z` | KEDA operator 无法在自身 Namespace 解析短名 `redis` | `214c896`：使用 `redis.<namespace>.svc.cluster.local:6379` |
| `05:59Z` | kubelet 无法验证 distroless 命名用户 `nonroot` | `a14cac9`：显式设置 UID/GID 65532 |
| `06:02Z` | KEDA 不提供 transition time，初始 Inactive 与后续 Inactive 被去重 | `6c7cd37`：按 Active 状态机保存 False→True→False |
| `06:07Z` | validator 与文档冲突，拒绝已明确标记的近似 condition 时间 | `3aa1664`：要求转换存在，同时保留 approximate 质量字段 |

每次失败后都核验 Lease、Namespace 和本地端口无残留，再进入下一次运行。失败会话
产物保留用于审计，不进入成功 `summary.json`。

## 8. 清理状态

成功会话结束后已核验：

- 无 `e04-*` Namespace；
- 无 `hooke-e04-keda-pilot` Lease；
- 无带 `hooke.io/experiment=E04` 的 ScaledObject；
- 无残留 E04 Pod、Job、Deployment、Service 或 Secret；
- 本地 controller/ingester 端口均已释放；
- `hooke-e04-mysql` 容器按配置保留为 running，用于本地审计；
- `CONFIRM_E04_EXECUTION` 已恢复为 `no`；
- `E04_PILOT_REPETITIONS` 已恢复为 5。

## 9. 结论

E04 1×2 冒烟结论为 **PASS**：

- 两个 cooldown cell 均完成真实 KEDA scale-from-zero 和 scale-to-zero；
- 24/24 条消息因果链完整；
- external metric、ScaledObject、HPA、Pod Ready 和 Deployment 归零证据齐全；
- 60/300 秒 cooldown 的观测值分别为 55.028/295.032 秒，方向与 5 秒轮询口径一致；
- 汇总器和 Rule 2/`τ*` 反解链路可运行；
- 所有实验资源已清理。

本轮完成的是冒烟，不是 5×2 正式 Pilot。若继续扩大样本，应先补充节点剩余
requests 容量 Gate，再运行 5 个随机配对区组，并保持 KEDA condition 与 cooldown
的近似质量标记。

## 10. 产物索引

- [成功会话汇总](../../artifacts/e04-keda-scale-to-zero-pilot-20260724T061144Z/summary.json)
- [逐运行观测](../../artifacts/e04-keda-scale-to-zero-pilot-20260724T061144Z/observations.tsv)
- [运行索引](../../artifacts/e04-keda-scale-to-zero-pilot-20260724T061144Z/run-index.tsv)
- [60 秒 cell observation](../../artifacts/e04-keda-scale-to-zero-pilot-20260724T061144Z/runs/01-cooldown-60s/observation.json)
- [300 秒 cell observation](../../artifacts/e04-keda-scale-to-zero-pilot-20260724T061144Z/runs/02-cooldown-300s/observation.json)
- [60 秒原始事件](../../artifacts/e04-keda-scale-to-zero-pilot-20260724T061144Z/runs/01-cooldown-60s/events.ndjson)
- [300 秒原始事件](../../artifacts/e04-keda-scale-to-zero-pilot-20260724T061144Z/runs/02-cooldown-300s/events.ndjson)
- [Kubernetes/KEDA 环境](../../artifacts/e04-keda-scale-to-zero-pilot-20260724T061144Z/keda-deployments.json)
- [首次完整业务链失败会话](../../artifacts/e04-keda-scale-to-zero-pilot-20260724T060226Z)
- [近似时间 Gate 失败会话](../../artifacts/e04-keda-scale-to-zero-pilot-20260724T060723Z)

关键汇总文件 SHA-256：

```text
summary.json      c0af0de5d8094852f375c3bcc4c140e1a6d9c232d28e70bd968d466d82e3a549
observations.tsv  df904c2f316bc2b8ba38e055a15b3e1bd8fd03f0cfd27bdd2e947604a1d5c842
run-index.tsv     cc53951f4fc8d3b3e947c7efef0d6948cfc56ea7872e7e72e9951249174d447a
```
