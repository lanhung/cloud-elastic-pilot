# E02 Node / warm-pool 对照冒烟（1×1 配对）实验报告

## 1. 摘要

2026 年 7 月 23 日在分支 `experiment/04-node-warm-pool-pilot` 上完成 E02
Node / warm-pool 对照的首个配对冒烟。成功会话包含 1 个 cold-node 和 1 个
warm-node 真实 ACK 运行，两次运行均直接 **PASS**，两条轨迹均完整，所有适用
主层的精确覆盖率均为 1.0。

| 指标 | cold-node | warm-node | 配对变化 |
|---|---:|---:|---:|
| 端到端 `e2e` | 112.382 秒 | 14.661 秒 | **减少 97.721 秒（86.95%）** |
| 相对速度 | 1.00× | 7.67× | warm 为 cold 的 7.67× |
| Image | 13.158 秒 | 13.152 秒 | -0.006 秒（-0.05%） |
| Pod | 13.646 秒 | 13.355 秒 | -0.291 秒（-2.13%） |
| App | 0.424 秒 | 0.643 秒 | +0.219 秒 |
| 镜像下载字节 | 69,789,432 B | 69,789,432 B | 相同 |
| 新弹性节点 | 1 | 0 | warm 跳过节点供应 |

本次对照在相同节点、相同镜像 digest、相同下载字节、相同资源 request 和相同
应用工作量下完成。warm-node 相比 cold-node 的 Image、Pod 阶段基本不变，
而端到端时间减少 97.721 秒，方向上支持“预留 Ready 节点能够显著降低
scale-out 延迟”的 E02 假设。

本报告的结论等级是 **冒烟 Gate PASS**，不是统计意义上的正式实验结论。
当前只有 1 个配对区组，不能报告稳定的 p50/p95/p99，也不能排除顺序效应、
单可用区和单实例规格的偶然性。

## 2. 实验问题与判定

E02 要回答的问题是：

> 在工作负载、镜像和应用初始化条件相同的情况下，将专用弹性节点池从
> `min=0` 的 cold-node 状态变为保留 1 个 Ready 节点的 warm-node 状态，
> 能否显著降低从扩容请求到 Deployment 成功 rollout 的端到端时间？

主指标 `e2e_ms` 定义为操作机同一进程中，以 `CLOCK_MONOTONIC` 测得的
“scale 请求发出 → Deployment rollout 成功”区间。该指标不依赖集群节点之间
的墙钟同步。

本次冒烟的预设 Gate 为：

1. cold-node 运行前，专用节点池 `min=0` 且选中节点数为 0；
2. cold-node 必须出现唯一新节点、唯一供应 task，并完成 Pod → task → Node →
   providerID 归因；
3. warm-node 运行前，同一专用池必须有且仅有 1 个 Ready 节点；
4. 两次运行使用相同不可变镜像 digest，且 warm-node 运行前明确清除镜像缓存；
5. 每次运行严格产生 1 条完整轨迹，所有适用主层必须为精确来源；
6. 实验结束后恢复原始 `min=0,max=1` 配置，删除工作负载、Lease 和测试节点。

上述测量与数据质量 Gate 全部通过。清理阶段使用了一次人工触发的 ACK 标准节点
移除 API，详见第 7 节，因此当前编排尚不能认定为完全无人值守。

## 3. 冻结环境

| 项目 | 值 |
|---|---|
| 成功会话 | `e02-node-warm-pool-pilot-20260723T030153Z` |
| 执行窗口 | 2026-07-23 03:01:53Z–03:09:36Z |
| 分支 | `experiment/04-node-warm-pool-pilot` |
| 编排 Git | `d880da4cdb515a839cda042c0c8c3ddeb7501eb7`，clean |
| 镜像构建 Git | `a8d5f2407fb4be6a19654a348817eba9494cc722`，clean |
| 随机种子 | `20260723` |
| ACK 集群 | `cc224c25bf1e5423a802315aff201c15c` |
| 地域 / 可用区 | `cn-wulanchabu` / `cn-wulanchabu-c` |
| Kubernetes | `v1.36.1-aliyun.1` |
| 节点 OS | Alibaba Cloud Linux 4.0.3（OpenAnolis Edition） |
| kernel / runtime | `6.6.102-5.3.1.alnx4.x86_64` / containerd 2.1.9 |
| 专用节点池 | `np03d225929590416b8a1225482207b560` |
| 节点池初始配置 | 自动伸缩启用，`min=0,max=1`，ESS 非默认池 |
| 节点池隔离 | `hooke.io/experiment=elastic:NoSchedule` |
| 实例规格 | `ecs.c7.large`，按量付费，2 vCPU |
| 应用工作量 | 500m request / 1 CPU limit，256 MiB request / 512 MiB limit |
| 应用初始化 | 0 MiB 额外内存工作量 |
| 重复数 | 每变体 1 次，共 1 个配对区组 |

实验使用同地域 ACR 的不可变 small 镜像：

```text
crpi-rde6dbx17y795odv.cn-wulanchabu.personal.cr.aliyuncs.com/hooke-lab/cloud-elastic-pilot@sha256:4e634020fb2e4bb57369a537104b36c7fcdf97bd38a1ceb16177c4044a0e5326
```

镜像本地构建大小为 70,405,727 B，确定性 padding 为 64 MiB。两次运行实际
下载均为 69,789,432 B（66.556 MiB）。

## 4. 实验设计

### 4.1 自变量与控制变量

唯一目标自变量是节点状态：

| 变体 | 节点池与运行前状态 |
|---|---|
| cold-node | `min=0`，专用节点数为 0；由不可调度 Pod 触发 GOATScaler 创建节点 |
| warm-node | `min=1`，保留 cold-node 创建的同一 Ready 节点，无实验 Pod |

控制变量包括：

- 相同镜像 digest；
- 相同 CPU、内存和应用初始化工作量；
- 相同节点池、实例规格与可用区；
- 相同应用 readiness 语义；
- 两个变体均为冷镜像条件；
- 同一个 Node UID、providerID 和 ECS 实例承载配对运行。

warm-node 前执行了精确 digest 缓存删除与冷缓存核验。两次运行下载字节完全相同，
说明本实验比较的是“节点不存在 / 节点 Ready”，而不是“镜像冷 / 镜像热”。

### 4.2 实际执行顺序

固定种子生成的本次顺序为：

1. `cold-node`, block 1, repetition 1；
2. `warm-node`, block 1, repetition 1。

cold-node 从 0 节点开始，GOATScaler 创建
`cn-wulanchabu.10.235.204.124`，providerID 为
`cn-wulanchabu.i-0jl3ntev5ntyqux4mwsh`。warm-node 将节点池下限设为 1，
等待同一节点稳定 Ready，清除镜像缓存后再运行相同工作负载。

### 4.3 事件来源

| 层 | 边界 | 来源 |
|---|---|---|
| Node | ACK provision task → 新节点 Ready | GOATScaler SLS、Node task label、providerID |
| Image | CRI `PullImage` start → end | 节点 containerd/kubelet journal |
| Pod | `RunPodSandbox` start → container start | 节点 containerd CRI journal |
| App | container start → readiness 首次成功 | 应用结构化源时间日志 |
| E2E | scale request → rollout 成功 | 操作机 `CLOCK_MONOTONIC` |

Image 区间包含在 Pod 生命周期中，各层存在重叠，不能直接相加。

## 5. 结果

### 5.1 端到端配对结果

| 变体 | Run ID | E2E | 完整轨迹 | 精确覆盖率 |
|---|---|---:|---:|---:|
| cold-node | `01KY6ESEGZT8QK5KCC3GTTZBQH` | 112.382 秒 | 1/1 | 1.0 |
| warm-node | `01KY6F0QCKGA1KP7HBKQ12WF0F` | 14.661 秒 | 1/1 | 1.0 |

配对差值为：

```text
112.382181874 s - 14.660817105 s = 97.721364769 s
```

warm-node 的 E2E 相对 cold-node 减少 **86.95%**，相对速度为 **7.67×**。

### 5.2 分层与操纵有效性

| 检查项 | cold-node | warm-node |
|---|---:|---:|
| 原始事件 | 43 | 25 |
| 适用层数 | 4 | 3 |
| Node 精确样本 | 1 | 不适用 |
| Image 精确样本 | 1 | 1 |
| Pod 精确样本 | 1 | 1 |
| App 精确样本 | 1 | 1 |
| 镜像下载 | 69,789,432 B | 69,789,432 B |
| Image | 13.158 秒 | 13.152 秒 |
| Pod | 13.646 秒 | 13.355 秒 |
| App | 0.424 秒 | 0.643 秒 |
| 不可调度事件 / Pod | 2 / 1 | 0 / 0 |
| 新节点 / 新 Ready 节点 | 1 / 1 | 0 / 0 |

Image 时间仅相差 6.473 ms，Pod 时间仅相差 290.639 ms；两者都远小于
97.721 秒的 E2E 差值。warm-node 没有不可调度事件、供应 task 或新 Ready
节点，说明 warm 路径确实跳过了节点供应。

cold-node 的 GOATScaler task-ID 归因 Precision、Recall、F1 均为 1，
Pod annotation、Node task label、节点名和 providerID 无冲突。

### 5.3 Node 层的解释边界

cold-node 轨迹中存在 1 个精确 Node 主层样本，原始 Node 区间为
78.906 秒；计算器也将 cold-node 的诊断瓶颈标记为 `node`。但是 GOATScaler、
Kubernetes 和节点 journal 属于不同墙钟来源，本次没有独立完成跨来源时钟校准，
因此汇总文件将科学主指标 `node_ms` 置为 `null`，只保留
`trace_node_ms_raw=78905.629` 作为审计字段。

所以本报告用同一操作机单调时钟的 97.721 秒 E2E 配对差值支持方向性结论，
不把 78.906 秒包装成已校准的精确 Node 供应耗时。

## 6. 数据质量与限制

| 检查项 | 结果 |
|---|---:|
| 运行状态 completed | 2/2 |
| 子运行结果 PASS | 2/2 |
| 完整轨迹 | 2/2 |
| 所有适用主层精确 | 2/2 |
| invalid order | 0 |
| 不可追踪主层样本 | 0 |
| controller / ingester ERROR | 0 / 0 |
| 冷节点 task-ID Precision / Recall | 1 / 1 |

仍需明确以下限制：

1. **样本量只有 1 对。** 当前结果只能通过冒烟 Gate，不能估计方差或稳定的
   p50/p95/p99；
2. **顺序固定为 cold → warm。** 镜像缓存已显式清除，但 OS 页缓存、网络状态和
   集群时间趋势等二阶 carry-over 不能由单对实验排除；
3. **只有一个实例规格和可用区。** 结果不能直接推广到其他规格、磁盘、地域或
   网络条件；
4. **跨来源时钟未校准。** E2E 可比较，Node 精确原始边界可审计，但 Node 与其他层
   的跨时钟分解不作为正式定量结果；
5. **没有真实 CNI 起止边界。** 本轮 `cni_samples=0`，没有用近似事件伪造 CNI
   子阶段；
6. cold-node 记录到 1 次 sandbox/CNI 失败尝试，随后成功重试并形成完整精确
   sandbox 轨迹；warm-node 对应计数为 0。单样本不足以判断该差异是否稳定；
7. 成功会话的节点清理使用了人工触发的 ACK API，测量结果完整，但当前恢复流程
   还不是完全无人值守。

## 7. 执行异常、修复与恢复

成功配对之前有两次 fail-closed 尝试，均未混入本报告的汇总：

| 会话 | 现象 | 处置 |
|---|---|---|
| `20260723T023500Z` | Lease `acquireTime` 缺少 Kubernetes MicroTime 要求的 6 位小数，创建被 API Server 拒绝 | 提交 `9ffc3bd`，统一输出 Kubernetes MicroTime，并增加测试 |
| `20260723T024554Z` | cold-node 已 PASS；进入 warm 前，真实 `ModifyClusterNodePool` 响应使用 `cluster_id/instanceId`，旧校验只接受 `nodepool_id`，因此 fail-closed | 提交 `d880da4`，兼容两种响应结构并保持错误集群标识拒绝 |

第二次尝试没有完整 warm 配对，因此其 cold 数据不进入本报告。故障 Lease 被保留，
节点池经过额外恢复栅栏确认 `min=0,max=1`，随后按 UID 前置条件释放 Lease。

修复后通过的本地质量门包括：

- 31 个 Python hook / 编排测试；
- 全部 Shell 语法检查；
- `gofmt`、`go mod tidy`、`go vet ./...`；
- `go test ./...` 与 `go build ./cmd/...`；
- Helm lint。

### 7.1 成功会话的节点回收

成功会话的 ACK 恢复任务
`T-6a61857604dfdd0103000063` 已将节点池配置恢复为 `min=0,max=1`，
`prior_mutation_uncertain=false`。为限制清理等待时间，在确认以下前置条件后，
人工调用 ACK `RemoveNodePoolNodes`：

- 精确节点池和节点 UID/providerID 匹配；
- 节点池 `desired_nodes=0`；
- 节点上非 DaemonSet Pod 数为 0；
- 实例为目标可用区内的按量付费 `ecs.c7.large`；
- 调用启用 `drain_node=true`、`release_node=true`。

节点移除任务 `T-6a6185b71227030103000055` 成功。该操作发生在 warm 测量完成和
节点池恢复之后，不进入 cold/warm 的 E2E 测量区间，但说明在扩大样本前需要把
受控回收纳入编排或调整专用池缩容策略。

## 8. 清理状态

报告生成前已完成以下复核：

- 节点池连续 3 次观测均为 `min=0,max=1,active`；
- ACK 节点数和 Kubernetes 选中节点数均为 0；
- cold/warm 使用的两台测试 ECS 均已释放；
- 无残留 `e02-*` Namespace；
- 无残留 `hooke-e02-*` Lease；
- 子运行 ingester/controller 已退出；
- E02 MySQL 与本地 compose 测试容器均已停止，数据卷保留用于审计；
- 本地 `CONFIRM_E02_POOL_MUTATION` 已恢复为 `no`。

专用空节点池、`hooke-system` Namespace、ACR 镜像和 GOATScaler SLS 日志配置
被有意保留，用于后续重复实验。

## 9. 结论与下一步

E02 首个配对冒烟结论为 **PASS**：

- cold-node 和 warm-node 均得到完整、精确、可追踪的轨迹；
- 两次运行在同节点、相同冷镜像条件下完成，控制变量有效；
- warm-node E2E 从 112.382 秒降至 14.661 秒，减少 86.95%；
- Image 和 Pod 时间基本不变，差异方向与跳过 Node 供应一致；
- cold-node 的 GOATScaler task-ID 归因正确。

该结论只证明实验链路和效应方向，不代表正式统计结论。建议按以下顺序推进：

1. 将 `RemoveNodePoolNodes` 作为有严格身份、工作负载和 Lease Gate 的受控恢复
   fallback，消除人工清理；
2. 先把 `E02_PILOT_REPETITIONS` 从 1 提高到 5，验证配对差值和恢复流程可重复；
3. pilot 稳定后，每个变体至少执行 30 次，再报告 p50/p95；样本不足 100 时继续
   抑制 p99；
4. 正式实验增加多实例规格或多可用区区组，并记录实际成本；
5. 若需要精确报告 Node 分段，再引入跨来源时钟校准，不用原始墙钟差替代。

## 10. 产物索引

- [成功会话元数据](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/session.json)
- [执行顺序](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/schedule.tsv)
- [配对汇总](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/summary.json)
- [逐运行观测](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/observations.tsv)
- [cold-node 运行摘要](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/runs/e02-cold-node-r1-s1-20260723T030220Z/summary.md)
- [cold-node E02 校验](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/runs/e02-cold-node-r1-s1-20260723T030220Z/e02-validation.json)
- [warm-node 运行摘要](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/runs/e02-warm-node-r1-s2-20260723T030621Z/summary.md)
- [warm-node E02 校验](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/runs/e02-warm-node-r1-s2-20260723T030621Z/e02-validation.json)
- [warm 前镜像缓存清理](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/cache-reset-2.json)
- [warm 前冷缓存核验](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/cache-cold-2.json)
- [节点池原始快照](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/node-pool-snapshot.json)
- [节点池恢复证据](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/node-pool-restore.json)
- [最终节点池检查](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/node-pool-restore-final-check.json)
- [人工节点移除证据](../../../artifacts/e02-node-warm-pool-pilot-20260723T030153Z/manual-node-removal.json)
- [失败会话恢复证据](../../../artifacts/e02-node-warm-pool-pilot-20260723T024554Z/manual-recovery.json)
