# E01 四层基线 Pilot（4×5）正式报告

## 1. 摘要

2026 年 7 月 22 日在分支 `experiment/03-four-layer-baseline-pilot` 上完成
E01 四层基线正式 pilot。实验使用随机顺序执行 4 个 cell，每个 cell 5 次，
共 20 次真实 ACK 运行。20/20 次运行在执行时直接 **PASS**，20/20 条轨迹完整，
所有适用的主层边界均为精确来源，事件顺序错误、不可追踪主层样本、
controller/ingester ERROR 均为 0。

| 项目 | 结果 |
|---|---:|
| 正式运行 | 20/20 PASS |
| 完整轨迹 | 20/20 |
| 精确主层覆盖率 | 20/20 为 1.0 |
| 精确 Pod sandbox | 20/20 |
| 事件顺序错误 | 0 |
| 不可追踪主层样本 | 0 |
| 新节点 task-ID 归因 | 10/10，Precision=1、Recall=1 |
| 固定节点 warm/cold 缓存核验 | 10/10 运行、每次 4/4 节点通过 |

四个 cell 的端到端中位数分别为：

- existing + warm + small + light：**1.827 秒**；
- existing + cold + large + light：**107.411 秒**；
- new + cold + small + light：**102.995 秒**；
- new + cold + large + heavy：**201.228 秒**。

本轮结论是 **E01 pilot 数据质量通过**。这些 5 次重复可以验证实验操作、
分层路径和大致量级，但不足以给出稳定的 p95/p99；按执行指南，下一阶段应在
集群可持续保留时把每个 cell 扩展到 30 次。

## 2. 冻结环境

| 项目 | 值 |
|---|---|
| 实验源代码 Git | `c618409ba2ff6d1d60d94e1c96eef3cc1e80fbbd`，clean |
| 会话 | `e01-four-layer-pilot-20260722T043027Z` |
| 执行窗口 | 2026-07-22 04:30:27Z–06:21:20Z |
| 随机种子 | `20260721` |
| ACK 集群 | `c29d758c0c7434b94af9e03aaa592acdd`，`cn-wulanchabu` |
| Kubernetes | `v1.36.1-aliyun.1` |
| 节点系统 / runtime | Alibaba Cloud Linux 4.0.3 / containerd 2.1.9 |
| 固定节点池 | `np09759243973942b29a4d7035f76c066b`，4 个 Ready 节点 |
| 弹性节点池 | `npe5f50a5bc3d241c4b6d25a356194b227`，min=0、max=4 |
| 应用事件 | 结构化 stdout 日志，导出时保留应用源时间 |
| light / heavy 初始化 | 0 MiB / 4096 MiB 真实内存工作量 |
| 副本数 | 1 |

GOATScaler 版本为 `v0.6.2-9186193`。正式运行期间启用空节点缩容，
`ScaleDownOnlyEmptyNodes=true`、`ScaleDownUnneededTime=1m`、
`ScaleDownUtilizationThreshold=0.7`。ACK 对新节点仍有固定约 10 分钟保护期；
runner 在每个 new-node cell 前等待弹性池回到 0，保护期和清场时间不计入轨迹。

镜像来自同地域的公有 ACR 个人版仓库，并使用不可变 digest：

| 变体 | 镜像 digest | 本地构建大小 |
|---|---|---:|
| small | `sha256:358e971861a348711304d25851c9e97efc024de35640be8d57e304ff71fafd18` | 70,405,723 B |
| large | `sha256:5fd35d93e8cdeae9939dc1546f854267c2b23d6814a5d0a4e9a8ff7c0cfd98c5` | 540,311,142 B |

两个镜像与实验源代码提交严格绑定，且 small/large 仅使用不同的确定性 padding
层形成体积差异。

## 3. 实验设计与数据质量 Gate

四个 cell 为：

1. existing + warm + small + light；
2. existing + cold + large + light；
3. new + cold + small + light；
4. new + cold + large + heavy。

20 个 `(cell, repetition)` 使用固定种子整体打乱。每次 existing-warm 运行前，
都在 4 个固定节点上核验精确 digest 和 manifest blob 存在；每次 existing-cold
运行前都删除精确 digest，等待垃圾回收，并核验 4 个节点的 image 与 manifest
blob 均不存在。每次 new-cold 运行前都确认弹性节点数为 0。

主层精确来源如下：

| 层 | 起止边界 | 来源 |
|---|---|---|
| Node | ACK provision task → 新节点 Ready | GOATScaler SLS task、Node/instance 关联 |
| Image | CRI `PullImage` start → end，或明确 cache hit | 节点 containerd/kubelet journal，RFC3339Nano |
| Pod | `RunPodSandbox` start → 精确 container start | 节点 containerd CRI journal |
| App | container start → readiness 首次成功 | 应用结构化日志源时间 |

Gate 还要求预期轨迹数严格为 1、适用层样本数严格为 1、所有适用主层精确、
无负时延或错误顺序、新节点 task/Pod/Node/providerID 链路唯一且无冲突。

## 4. 分层结果

下表为 5 次重复的 `p50 [min, max]`，单位为秒。pilot 只有 5 个样本，
因此不把样本最大值包装成稳定 p95。

| Cell | Node | Image | Pod | App | 端到端 |
|---|---:|---:|---:|---:|---:|
| existing-warm-small-light | — | 0.000 [0.000, 0.000] | 0.113 [0.110, 0.121] | 0.885 [0.878, 0.889] | 1.827 [1.385, 2.078] |
| existing-cold-large-light | — | 106.251 [104.670, 107.116] | 106.374 [104.800, 107.298] | 0.594 [0.199, 0.700] | 107.411 [105.876, 108.401] |
| new-cold-small-light | 70.248 [61.791, 71.126] | 13.052 [12.955, 14.896] | 13.775 [13.151, 15.052] | 0.623 [0.076, 0.819] | 102.995 [98.058, 106.036] |
| new-cold-large-heavy | 72.971 [69.925, 73.429] | 106.720 [104.719, 107.831] | 106.890 [104.932, 108.338] | 3.192 [2.828, 3.368] | 201.228 [198.146, 202.178] |

这些层是重叠区间，不能直接相加。尤其 Image 拉取发生在 Pod sandbox 到容器启动
的 Pod 区间内；端到端还保留触发到首个活动层、层间空洞等未归因时间。

### 4.1 镜像条件操纵

| Cell | 每次运行下载字节 | 结果 |
|---|---:|---|
| existing-warm-small-light | 0 B | 明确 cache hit，5/5 |
| existing-cold-large-light | 537,047,154 B（512.17 MiB） | 冷拉取，5/5 |
| new-cold-small-light | 69,789,428 B（66.56 MiB） | 新节点冷拉取，5/5 |
| new-cold-large-heavy | 539,694,847 B（514.69 MiB） | 新节点冷拉取，5/5 |

large 的 Image 中位数约为 small 的 8.2 倍（106.720 秒对 13.052 秒）。
existing-warm 的 Image 层稳定为 0，而 existing-cold-large 稳定约 106 秒，说明
warm/cold 与镜像大小操纵在真实节点 runtime 证据中清晰可辨。

### 4.2 新节点供应与归因

10 次 new-node 运行均满足：

- 运行前弹性池为 0；
- 唯一实验 Pod 进入 Unschedulable；
- 产生 1 个本轮 GOATScaler task 和 1 个新 Ready 节点；
- Pod annotation、Node task label、providerID/instance ID 一致；
- task-ID 方法 Precision=1、Recall=1、F1=1；
- 归因冲突为 0。

small 与 large-heavy 两组 Node 中位数分别为 70.248 秒和 72.971 秒，量级相近；
镜像大小的主要差异落在 Image/Pod 区间，而没有被错误计入 Node 供应层。

## 5. 完整性与限制

| 检查项 | 结果 |
|---|---:|
| 运行状态 completed | 20/20 |
| 完整轨迹 | 20/20 |
| 精确主层轨迹 | 20/20 |
| 精确 Image / Pod / App 样本 | 20/20 / 20/20 / 20/20 |
| 精确 Node 样本 | 10/10 适用运行 |
| 精确 sandbox | 20/20 |
| invalid order / negative latency | 0 / 0 |
| controller / ingester ERROR | 0 / 0 |

仍有四项边界需要明确：

1. 本集群没有可用的真实 CNI 起止边界，因此 `cni_samples=0`，本轮未开启
   `REQUIRE_CNI_SUBSTAGE`，也没有制造伪 CNI 事件；
2. CRI journal 给出了精确 `PullImage` 边界和下载字节，但没有把 download 与 unpack
   再拆成两个独立子阶段；该拆分仍需绑定节点 build-id 的真实探针；
3. 20 条轨迹的事件边界均为精确来源，但跨来源时钟偏移/不确定度没有独立校准，
   `clock_known_trace_count=0`；“精确边界”不等于已证明跨节点时钟零误差；
4. 每 cell 仅 5 次。p50 仅用于 pilot 量级判断，p95/p99 必须在至少 30 次正式重复后报告。

## 6. 清理状态

- 20 个独立实验 Namespace 均已删除；
- 没有带 E01 实验标签的残留 Pod；
- 本地 ingester/controller 已退出；
- 本地 MySQL 容器保留，用于审计原始事件；
- 报告生成时最后一台弹性节点仍处于 ACK 新节点保护期，节点上无实验 Pod，
  将由 GOATScaler 自动缩容；它不影响 20 次已完成测量。

## 7. 结论与下一步

E01 pilot 结论为 **PASS**：四种路径能稳定包含或跳过预期层，缓存操纵真实有效，
新节点 task-ID 归因正确，20 次运行均得到完整、可追踪的精确主层轨迹。

下一步不是立即修改指标算法，而是：

1. 在可持续保留集群的窗口中，把每个 cell 从 5 次扩展到 30 次；
2. 30 次数据完成后再报告 p50/p95，并继续抑制样本不足的 p99；
3. 若需要拆分 Image download/unpack 或 CNI 子阶段，再单独实现与 ACK 节点版本绑定的
   探针，不用近似事件替代；
4. E01 正式重复完成后进入 E02 的 cold-node / warm-node 对照。

## 8. 产物索引

- [会话元数据](../../artifacts/e01-four-layer-pilot-20260722T043027Z/session.json)
- [随机执行顺序](../../artifacts/e01-four-layer-pilot-20260722T043027Z/schedule.tsv)
- [镜像构建元数据](../../artifacts/e01-four-layer-pilot-20260722T043027Z/image-build.env)
- [固定节点 large 冷缓存证据](../../artifacts/e01-four-layer-pilot-20260722T043027Z/cache-cold-19.json)
- [固定节点 small 热缓存证据](../../artifacts/e01-four-layer-pilot-20260722T043027Z/cache-warm-18.json)
- [existing-warm 代表运行](../../artifacts/e01-four-layer-pilot-20260722T043027Z/runs/e01-existing-warm-small-light-r4-20260722T061324Z/summary.md)
- [existing-cold 代表运行](../../artifacts/e01-four-layer-pilot-20260722T043027Z/runs/e01-existing-cold-large-light-r2-20260722T061428Z/summary.md)
- [new-cold-small 代表运行](../../artifacts/e01-four-layer-pilot-20260722T043027Z/runs/e01-new-cold-small-light-r1-20260722T052813Z/summary.md)
- [new-cold-large-heavy 代表运行](../../artifacts/e01-four-layer-pilot-20260722T043027Z/runs/e01-new-cold-large-heavy-r5-20260722T061659Z/summary.md)
- [GOATScaler 配置快照](../../artifacts/e01-four-layer-pilot-20260722T041010Z/goatscaler-config-after-integration.json)

