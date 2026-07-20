# ACK/GOATScaler 异构 Kubernetes 弹性诊断与调优：相关工作与创新性调研

- 调研日期：2026-07-20
- 检索截止：2026-07-20（UTC+8）
- 调研对象：本仓库的 ACK 版 Hooke 复现与适配方案
- 本地基准稿件：[`docs/paper/hooke.pdf`](../paper/hooke.pdf)
- 本地实验方案：[`docs/plans/hooke_ack_experiment_execution_guide.md`](../plans/hooke_ack_experiment_execution_guide.md)
- 本地指标目录：[`docs/metric/hooke_ack_metric_catalog.md`](../metric/hooke_ack_metric_catalog.md)

## 1. 结论先行

### 1.1 这个方向有人做过吗？

**做过，而且相邻研究很多；但截至检索截止日，没有检出与本项目完全等价的公开论文或开源系统。**

已经有成果覆盖了本项目的几乎每一个单点组成部分：云弹性定义与度量、Kubernetes Cluster Autoscaler 实验评估、Pod 启动时延分解、镜像拉取/解包加速、Kubernetes 控制面因果追踪、Serverless 冷启动与保活策略、Gang Scheduling、工作流关键路径优化，以及动态 MIG 重配置。换言之，不能把“多层弹性”“逐阶段启动时延”“eBPF 追踪”“冷启动调优”或“动态 MIG”中的任何一个单点直接宣称为首创。

本项目目前仍有潜在空白：在真实 ACK Managed Pro 上，利用 `goatscaler.io/provision-task-id` 将待调度 Pod、`ProvisionNode` 事件、GOATScaler 供应任务、ECS 实例、Node Ready、containerd 镜像阶段、kubelet/CRI 启动阶段和应用首次就绪/首次成功响应连成逐 Pod 证据链，再用这条证据链验证瓶颈归因和调优收益。公开检索中没有发现以 **ACK GOATScaler** 为对象、同时覆盖这条跨云控制面与节点数据面的完整学术评估。

因此，当前最稳妥的定位不是“发明 Hooke 的通用思想”，而是：

> **对托管云 Kubernetes 中事件驱动节点供给进行可复现、任务级、跨平面的因果测量；以 ACK GOATScaler 为首个实证对象，量化相关层之间的组合误差，并验证带成本约束的调优建议。**

### 1.2 已经有名为 Hooke 的论文发表了吗？

截至 2026-07-20，本次对公开 Web、arXiv、DBLP 和 Crossref 的题名精确检索均未找到题为 **“Hooke: Diagnosing and Tuning Elasticity in Heterogeneous Kubernetes Clusters”** 的公开记录。

仓库中的 PDF 是一份 10 页匿名稿件：没有作者、机构、会议/期刊、DOI、arXiv ID 或公开代码地址；正文使用 “We will release Hooke” 的将来时。文件元数据日期为 2026-07-12，SHA-256 为：

```text
54f9acb28565e2514f50a221ab13118efd1dda31020d82baeea0662cc6a32d53
```

所以在作者或来源方提供可核验的录用/发表信息前，应把它标为 **本地匿名未发表稿件**，不能在论文中把其自述实验数字当作已经同行评审的外部结果。公开数据库“未检出”也不等价于证明它从未投稿、未被匿名评审或不存在未索引版本。

### 1.3 值得继续做吗？

**值得，但必须收窄贡献并补强实验方法。** 工程价值较高，学术新颖性目前为“中等、可提升”，不是“天然首创”。最有希望的第一篇工作应聚焦 CPU 主链路和 GOATScaler，而不是同时承担 KEDA、Kueue、Argo、DRA 与 MIG 五条研究线。

建议第一阶段保留：

1. GOATScaler/ECS/Node 的任务级关联与真实冷节点供给；
2. Node、Image、Pod、Application 四层逐 Pod 时间线；
3. 层间相关性、重叠区间与无法归因时延；
4. warm node、image pre-pull 等少量可控干预的延迟—成本前沿；
5. 采集准确性、完整性、时钟误差与系统开销。

GPU/DRA/MIG 应作为后续独立阶段重新立题，因为该方向已有密集工作，而且本地 Hooke 稿件中的 Kubernetes 版本和无中断重配置陈述需要修正。

## 2. 本次调研如何界定“相同研究”

本项目目标链路可抽象为：

```text
工作负载扩容触发
  -> Pod Unschedulable / GOATScaler ProvisionNode
  -> GOATScaler provision-task-id / ECS 创建与 Running
  -> Kubernetes Node 注册与 Ready
  -> containerd Pull / Unpack
  -> kubelet SyncPod / CRI ContainerStarted
  -> Readiness 首次成功 / 应用首次成功响应
```

只有同时具备下列多数条件，才视为“直接同类”：

- 覆盖云实例供给、Kubernetes、容器运行时和应用四个平面；
- 用 UID、task ID、instance ID、container ID 等稳定标识做逐请求或逐 Pod 关联；
- 能处理并发扩容、一任务多 Pod、失败、缺失和部分 trace；
- 输出可验证的瓶颈归因，而不仅是多个互不关联的仪表盘；
- 以真实节点从零扩容为实验对象，而不只是 HPA、仿真或已有节点上的 Pod 启动；
- 以调优前后实测结果和成本作为闭环，而不只给经验规则。

按这个较严格的判定标准，现有工作大多只覆盖其中一个或几个切面；这也是本项目仍可能形成独立贡献的原因。

## 3. 检索方法与限制

### 3.1 检索渠道

本次使用了：

- 通用 Web 学术检索；
- arXiv API、DBLP Search API、Crossref 元数据检索；
- ACM、IEEE、USENIX、期刊 DOI 页面等出版方或论文主页；
- Kubernetes、KEDA、Kueue、NVIDIA、Google Cloud、AWS、Alibaba Cloud ACK 的官方文档；
- CNCF 与公开开源项目页面，用于确认系统能力与公开状态。

检索词按五组展开：

1. 题名与来源：`"Hooke: Diagnosing and Tuning Elasticity in Heterogeneous Kubernetes Clusters"`；
2. 弹性评估：`cloud elasticity metric`、`Kubernetes autoscaler evaluation`、`scale-out latency attribution`；
3. 启动与追踪：`Kubernetes pod startup latency breakdown`、`control plane distributed tracing`、`containerd image pull tracing eBPF`；
4. 平台特定：`ACK GOATScaler paper`、`goatscaler provision-task-id`、`Karpenter NodeClaim latency`；
5. 扩展方向：`KEDA cold start cooldown`、`gang scheduling elasticity`、`workflow critical path`、`DRA MIG dynamic reconfiguration`。

### 3.2 证据等级

本报告按以下顺序使用证据：同行评审论文/正式出版记录 > 官方项目文档 > arXiv 预印本 > 工程博客。云产品的行为和字段以官方文档为准；厂商自报性能只作为平台背景，不作为独立学术结论。

### 3.3 限制

- 未使用付费的 Scopus、Web of Science 全库检索，因此“未检出直接同类”是检索范围内的结论，不是数学意义的不存在证明。
- Semantic Scholar 与 OpenAlex 在检索期间出现限流，未将其结果作为否定性证据。
- GOATScaler 是快速演进的托管产品；文档、事件字段和日志可见性需在每次实验时保存版本与快照。
- 本报告评估的是公开成果和当前项目设计，不验证本地 Hooke 稿件所声称的 32 节点实验、性能提升和采集开销。

## 4. 精确题名与稿件来源审计

| 渠道 | 查询 | 结果（2026-07-20） | 可得结论 |
| --- | --- | --- | --- |
| 通用 Web | 完整英文题名、核心短语加引号 | 未检出对应论文页、作者页或代码页 | 没有发现公开可访问版本 |
| [arXiv API](https://export.arxiv.org/api/query?search_query=all:%22Hooke%20Diagnosing%20and%20Tuning%20Elasticity%20in%20Heterogeneous%20Kubernetes%20Clusters%22&start=0&max_results=5) | 完整题名 | `totalResults=0` | 未在 arXiv 建立该题名记录 |
| [DBLP](https://dblp.org/search?q=Hooke%20Diagnosing%20Tuning%20Elasticity%20Heterogeneous%20Kubernetes%20Clusters) | 题名核心词 | 精确结果为 0 | 未在 DBLP 收录 |
| [Crossref](https://search.crossref.org/?q=Hooke%3A%20Diagnosing%20and%20Tuning%20Elasticity%20in%20Heterogeneous%20Kubernetes%20Clusters) | 题名模糊召回后做规范化精确比对 | 精确题名为 0 | 未发现 DOI 元数据记录 |

本地 PDF 自述 Hooke 有 4,830 行 Go/Python、在 32 节点引力波工作负载集群上将 p99 从 94 秒降至 41 秒、带来 2.3 倍弹性提升，并称节点层占 61%。这些数字可用作待复现的假设，但在没有原始数据、代码、版本、作者身份和公开 artifact 前，不应作为本项目的预期真值，也不应据此宣称已复现。

## 5. 已有成果版图

### 5.1 总览矩阵

| 研究面 | 代表成果 | 已完成的主要工作 | 与本项目重叠 | 仍未覆盖的部分 |
| --- | --- | --- | --- | --- |
| 云弹性定义与度量 | Herbst 等，ICAC 2013；Ai 等，2016；BECloud，2016 | 定义弹性的速度、精度、供需偏差和综合量化方法 | 弹性评分、供需跟踪、时间预算 | ACK 事件链、逐 Pod 层级归因 |
| Kubernetes 节点弹性评估 | Tamiru 等，CloudCom 2020 | 在 GKE 比较 Cluster Autoscaler/Node Auto-Provisioning，量化欠供给与过供给 | 真实集群、节点扩容、调参 | GOATScaler 任务级因果链、运行时与应用阶段 |
| Kubernetes 自动调优 | AHPA（Alibaba，arXiv 2023） | ACK 上的预测 HPA，报告资源利用与成本改善 | ACK、弹性调优、生产部署 | 节点从零供给和四层诊断 |
| 启动时延可观测性 | GKE Startup Latency、EKS kubelet SLI | 暴露 Pod 首次 Ready、调度、镜像拉取、HPA 推荐、Node startup 等分布 | 多阶段启动时延 | 单一 task/Pod 因果链、GOATScaler 与 ECS 内部阶段、闭环归因 |
| 编排时延优化 | Ulysses，ACM TOIT | 按 SLO 优先化 Kubernetes 编排工作，降低高负载编排时延 | Pod 编排时延、SLO | 云节点供给、镜像和应用联合追踪 |
| 可复现编排基准 | COFFEE，ICPE 2023 | 对启动、故障、滚动升级建立可复现 benchmark 与 artifact | 实验规范、启动性能 | ACK 供应任务和跨层逐 Pod trace |
| 镜像冷启动 | Slacker，FAST 2016；DADI，ATC 2020；Beni 等，SAC 2021 | lazy pulling、远程镜像、并行/复用等显著降低容器冷启动 | Image 层、冷启动干预 | 与节点供给和应用 SLO 的联合归因 |
| Kubernetes 控制面追踪 | Kelemetry；Ehira 等，arXiv 2024 | 关联 audit/event/informer 或传播因果 ID，重建对象级联关系 | 控制面因果关联、对象生命周期 | 云厂商供应任务、containerd、应用首次成功响应 |
| eBPF 应用可观测性 | Pixie | 无侵入网络协议、应用性能和系统遥测 | eBPF、节点侧低侵入采集 | ACK 任务语义和完整供应链 |
| Serverless/KEDA 冷启动 | Shahrad 等，ATC 2020；冷启动系统综述；KEDA 官方语义 | 保活窗口优化、冷启动缓解、scale-to-zero 冷却参数 | cooldown/回收阈值调优 | ACK 节点供给参与时的联合成本—时延优化 |
| 工作流关键路径 | AQUATOPE，ASPLOS 2023；Workflow Critical Path，2021 | 多阶段函数工作流预热、资源分配和关键路径分析 | DAG 关键路径、端到端 SLO | GOATScaler 四层 trace 对关键路径的实测贡献 |
| Gang Scheduling | Kueue；Kubernetes 原生 Gang Scheduling | all-or-nothing、partial admission、`minCount`/PodGroup 等 | batch/gang 入场与 barrier | 与节点供应时延联合形成的实证弹性模型 |
| MIG 动态重配置 | MISO、TGS、MIGRator、FGCS 2026 | 动态选择 MIG 形状、重配置与任务调度联合优化 | GPU profile 变化、重配置代价 | Kubernetes DRA 对比静态 MIG 的同口径 ACK 全链路测量 |
| ACK GOATScaler | ACK 官方文档与示例 | 说明即时弹性、关键事件、task ID 标签/注解和库存感知 | 本项目的真实目标平台 | 未检出公开同行评审的任务级四层测量论文 |

### 5.2 云弹性度量并不是空白

[Herbst、Kounev 和 Reussner 的 ICAC 2013 论文](https://www.usenix.org/conference/icac13/technical-sessions/presentation/herbst)已经给出云弹性的精确定义，并从速度与精度角度提出量化方法。[Ai 等的工作](https://doi.org/10.1155/2016/7519507)使用连续时间马尔可夫链测量弹性；[BECloud](https://doi.org/10.1016/j.future.2016.05.014)把伸缩性、准确度、时间和成本纳入分析。因此，本项目可以提出适合逐层 trace 的新指标或验证现有指标，但不宜使用“首次量化云弹性”或“此前没有弹性指标”这样的表述。

真正可以追问的是：现有全局供需指标能否指出 ACK 冷扩容的责任层？在层时延相关、重叠和事件缺失时，层分数是否仍能正确预测端到端 SLO？这比再造一个无验证的综合分数更有研究价值。

### 5.3 Kubernetes 自动伸缩已经有真实实验与生产成果

[Tamiru 等的 CloudCom 2020 论文](https://ieeexplore.ieee.org/document/9407312/)在真实 GKE 环境评估了 Cluster Autoscaler 与 Node Auto-Provisioning，使用欠供给、过供给等指标，并指出工作负载组成和参数配置显著影响结果。[AHPA](https://arxiv.org/abs/2303.03640)则是 Alibaba 在 ACK 上的预测式 HPA 实践，论文报告其自 2021 年部署并改善 CPU 利用和成本。

这些结果说明“在 Kubernetes 上做真实弹性实验”和“给出自动调参建议”都已有先例。本项目的区别必须落到 **节点供应任务如何与逐 Pod 运行时/应用事件精确拼接**，以及这种细粒度证据能否比 Cluster Autoscaler/HPA 聚合指标产生更准确的诊断和更好的干预选择。

[Karpenter NodeClaim 官方文档](https://karpenter.sh/docs/concepts/nodeclaims/)已经把节点创建显式拆为 launch、registration 和 initialization，并保留 NodeClaim、provider ID、Node 和触发 Pod 集合等信息。因此，把本地稿件的 NodeClaim 路径映射到 GOATScaler task 是合理的复现接口，但“观察节点供应生命周期”本身不是新能力。可研究的差异是：GOATScaler 没有与 Karpenter NodeClaim 完全相同的公开 CRD 状态机，本项目能否借助 task ID、Event 与 ECS API 恢复同等或更完整的语义，并量化两类接口的可观测性差异。

### 5.4 Pod 启动分解已经进入云厂商产品

[GKE Startup Latency 指标](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/monitor-startup-latency-metrics)已经提供单 Pod 首次 Ready、调度、镜像拉取、HPA 推荐和 Node startup 等时延分布。[AWS EKS 的可扩展性测试说明](https://aws.amazon.com/blogs/containers/deep-dive-into-amazon-eks-scalability-testing/)也明确区分 kubelet Pod Startup SLI 与包含节点扩容、镜像和 init container 的总时延。

所以“四段柱状图”本身不足以成为论文贡献。项目需要证明：

- GKE/EKS 式阶段指标在并发 ACK 扩容中会在哪些场景误归因或无法归因；
- task ID、Pod UID、instance ID 和 container ID 的联合关系能提高多少 attribution precision/recall；
- GOATScaler/ECS 的不可见间隙占多少，是否受可用区、库存、实例类型影响；
- 诊断所选的干预是否真的优于只看现有 dashboard 的干预。

### 5.5 镜像层已有成熟论文，适合作为基线而非首创点

[Slacker（FAST 2016）](https://www.usenix.org/conference/fast16/technical-sessions/presentation/harter)指出传统镜像下载对启动时延影响巨大，并用 lazy fetching 改善启动。[DADI（USENIX ATC 2020）](https://www.usenix.org/conference/atc20/presentation/li-huiba)来自 Alibaba 的大规模容器镜像服务实践，直接针对下载和解包瓶颈。[Beni 等（SAC 2021）](https://doi.org/10.1145/3412841.3441887)也研究了 Kubernetes 弹性扩容中的容器冷启动缓解。

因此 Image 层的论文价值不在“发现拉镜像很慢”，而在于量化它与 ACK 节点启动的并行/串行关系、缓存状态、ACR 同地域传输、并发 pull 和应用 SLO 之间的交互，并在相同成本边界下比较 custom image、预拉取和远程/lazy image 等策略。

### 5.6 Kubernetes 因果追踪已有非常接近的邻居

[Kelemetry](https://www.cncf.io/blog/2023/07/27/kelemetry-global-tracing-for-kubernetes-control-plane/)由字节跳动公开，关联 Kubernetes event、audit log 和 informer，重建对象生命周期及对象之间的级联关系；其[开源仓库](https://github.com/kubewharf/kelemetry)可作为直接基线。[Ehira 等的预印本](https://arxiv.org/abs/2411.01336)通过在对象元数据和 controller 之间传播因果过程 ID，分解控制面级联变化的时间。

这两项工作会直接削弱“首个 Kubernetes 控制面因果追踪器”的主张，但也帮助明确空白：它们的主要边界是 Kubernetes 对象与 controller，没有公开展示 ACK GOATScaler 供应 task、ECS 生命周期、containerd pull/unpack 和应用首次响应构成的端到端证据链。

一个强基线不是只在 related work 里引用 Kelemetry，而是部署 Kelemetry 或实现同等的 Kubernetes-only 关联方案，对比：完整 trace 比例、错配率、事件延迟、不可归因时长和诊断正确率。

### 5.7 KEDA、工作流和 Gang 都不是新题，但可成为验证场景

[KEDA `ScaledObject` 文档](https://keda.sh/docs/2.21/reference/scaledobject-spec/)明确规定 `cooldownPeriod` 默认 300 秒并用于缩到零；Serverless 领域已经广泛研究保活窗口和冷启动，[Shahrad 等的生产轨迹研究](https://www.usenix.org/conference/atc20/presentation/shahrad)还提出了基于负载直方图的混合保活策略。因而“根据冷启动调 cooldown”不是新规则。

[AQUATOPE（ASPLOS 2023）](https://people.csail.mit.edu/delimitrou/papers/2023.asplos.aquatope.pdf)已经对多阶段 Serverless 工作流进行端到端 QoS 管理、预热与资源配置；[Workflow Critical Path](https://doi.org/10.1016/j.tbench.2021.100001)也专门讨论工作流关键路径度量。关键路径重构不能独立宣称首创。

[Kueue](https://kueue.sigs.k8s.io/docs/overview/)支持 all-or-nothing、partial admission 和 ProvisioningRequest 等批处理能力；当前 Kubernetes 文档也已出现处于 alpha 阶段的[原生 Gang Scheduling](https://kubernetes.io/docs/concepts/scheduling-eviction/gang-scheduling/)与 PodGroup/minCount 语义。因此 Kueue 不能被描述为唯一 gang 实现，后续实验还应固定 Kubernetes/Kueue 版本，解释为何使用 Kueue 而非原生实现或 Volcano。

这三类更适合作为“追踪方法能否迁移到不同弹性模式”的外部验证，而不是第一阶段同时展开三个调优子论文。

### 5.8 GPU/DRA/MIG 有明显先行工作，且本地稿件存在事实风险

已有工作包括：

- [TGS（NSDI 2023）](https://www.usenix.org/conference/nsdi23/presentation/wu)研究 MIG 场景下的 GPU 共享与调度，并明确讨论重配置需要 GPU 空闲的约束；
- [MISO（SoCC 2022）](https://doi.org/10.1145/3542929.3563510)动态选择 MIG 分区以提高吞吐；
- [“Improving GPU Multi-Tenancy Through Dynamic Multi-Instance GPU Reconfiguration”（MIGRator）](https://arxiv.org/abs/2407.13126)研究多租户连续学习中的动态 MIG 重配置；
- [“Solving the task scheduling and GPU reconfiguration problem on MIG devices via deep reinforcement learning”](https://doi.org/10.1016/j.future.2025.108145)已在 Future Generation Computer Systems 发表。

这足以否定“此前无人研究动态 MIG 重配置”的宽泛主张。仍可能成立的窄问题是：在同一 Kubernetes/ACK 环境中，用相同 workload、SLO、节点供给与应用就绪口径，比较 DRA 驱动的设备申请路径和预设静态 MIG profile 的弹性—干扰—成本曲线。

本地 Hooke 稿件写道：“DRA, GA since Kubernetes 1.31, re-partitions GPUs between MIG profiles without draining the node。”截至本次检索，[Kubernetes 官方文档把 DRA 标记为 v1.35 stable](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)，并把 DRA 定义为通过 ResourceSlice、DeviceClass、ResourceClaim 和第三方 driver 完成设备发布、分配、准备与回收的框架；DRA 本身不等于 MIG profile 的无中断重配置。[NVIDIA GPU Operator 的 MIG Manager 文档](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-mig.html)明确说明重配置前会停止 GPU pods/clients，某些情形还需要节点重启。

因此，稿件中的 “Kubernetes 1.31 GA”“DRA 自动重分 MIG”“without draining”“固定 3.5 秒”都不能直接继承。GPU 阶段应先锁定 Kubernetes、ACK、GPU Operator、NVIDIA DRA driver、GPU 型号和固件版本，再通过真实事件定义“停止业务 Pod”“停止 operator pod”“重启节点”和“设备可重新分配”各自的时间边界。

## 6. ACK/GOATScaler 专项检索结果

### 6.1 官方已经公开了足够关键的关联字段

[ACK 节点伸缩概览](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/overview-of-node-scaling/)将 GOATScaler 描述为事件驱动的节点即时弹性组件。[节点即时弹性文档](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/instant-elasticity)列出：

- Pod 事件：`ProvisionNode`、`ProvisionNodeFailed`、`ResetPod`；
- 节点池事件：`InstanceInventoryStatusChanged`；
- Node label：`goatscaler.io/provision-task-id:{task-id}`；
- Pod annotation：`goatscaler.io/provision-task-id`。

这意味着 task ID 不是必须从自由文本日志中猜测的字段，而是可以作为 Pod—供应任务—Node 的官方 join key。再用 Node `providerID` 连接 ECS instance ID，就能构建比纯时间窗口启发式更可靠的主链路。时间窗口只应作为 task ID 缺失时的降级策略，并单独报告置信度。

### 6.2 GOATScaler 日志不能被默认假定已经存在

[ACK 控制面日志文档](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/collect-control-plane-component-logs-of-ack-managed-cluster)把 `ack-goatscaler` 标为“非默认采集”，但允许在 collected components 中手工启用。因此，本地实验方案“GOATScaler 控制面日志已经采集到 SLS”应改成可验证的 preflight：

1. 确认当前 ACK/GOATScaler 版本允许手工采集该组件；
2. 记录 SLS Logstore、采集配置和实际字段样例；
3. 即使日志可用，也以官方 task ID 标签/注解、Kubernetes Event 和 ECS OpenAPI 作为相互校验的独立来源；
4. 若日志不可用，实验仍应能用 task ID + Event + providerID/ECS API 完成降级 trace，并明确不可见区间。

### 6.3 是否已有 GOATScaler 学术论文？

以 `"GOATScaler" Kubernetes paper ACK autoscaling`、题名/摘要组合和站点限定进行检索，召回结果主要为 Alibaba Cloud 官方文档、开发者文章和示例仓库，未检出以 GOATScaler 的任务级端到端时延、跨层瓶颈归因或可复现实验为主题的同行评审论文。

这是一项有价值的空白，但表述应是“截至 2026-07-20，在公开检索范围内未检出”，而不是未经限定的“全球第一”。投稿前还应补做 Scopus、Web of Science、Google Scholar、CNKI 和万方的系统检索，并保存 PRISMA 式筛选记录。

## 7. 与最接近方案的直接比较

符号：`✓` 已有公开证据；`△` 部分覆盖；`—` 未覆盖；`目标` 表示本项目计划实现，尚不是已有结果。

| 方案 | 云实例/节点供应 | K8s 对象因果链 | containerd 镜像阶段 | 应用首次就绪/响应 | 逐 Pod/task 关联 | 调优闭环 | 公开验证状态 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 本项目 ACK 版 | 目标 | 目标 | 目标 | 目标 | 目标 | 目标 | 尚待实验 |
| 本地 Hooke 匿名稿 | ✓（自述 Karpenter） | ✓（自述） | ✓（自述） | ✓（自述） | ✓（自述） | ✓（自述） | 无公开 artifact，未独立核验 |
| GKE Startup Latency | △（Node startup 分布） | △ | ✓（聚合指标） | ✓（First Ready） | △ | — | 官方生产指标 |
| Kelemetry | — | ✓ | — | — | ✓（对象级） | — | 开源、大规模生产自述 |
| Ehira/CPID | — | ✓ | — | — | ✓（因果 ID） | — | arXiv 预印本 |
| COFFEE | —/△ | △ | △ | △ | — | — | 同行评审 + artifact |
| Ulysses | — | ✓（编排时延） | — | △ | △ | ✓（优先级） | 正式论文 |
| DADI/Slacker | — | — | ✓ | △ | — | ✓（镜像机制） | 正式论文 |
| Tamiru CA 评估 | ✓ | △ | — | △ | — | △ | 同行评审 |
| AQUATOPE | — | — | —/△ | ✓ | ✓（workflow） | ✓ | 同行评审 |

这个比较表也揭示了投稿时最重要的实验：不能只证明“我能画出四层时延”，而要证明横跨这些方案边界的关联能带来可量化的诊断增益。

## 8. 可以主张、需要谨慎和不应主张的创新点

### 8.1 绿色：有希望形成主要贡献

1. **GOATScaler 任务级跨平面 trace。** 以官方 provision task ID 为主键，连接 Pod、GOATScaler、ECS、Node、containerd、CRI 和应用事件；公开检索暂未发现同类论文。
2. **并发扩容下的归因准确性。** 建立带 ground truth 的注入实验，测量一任务多 Pod、多任务竞争、失败重试和库存变化下的 precision、recall、trace completeness 与 unattributed latency。
3. **层相关和重叠感知的组合模型。** 验证独立乘积何时失效，用事件 DAG/关键路径、联合分布或层级统计模型代替简单相加与独立假设。
4. **延迟—成本联合验证。** 对 warm node、预拉镜像、custom image 等建议报告时延改善、空闲资源分钟数和费用，不把“更快”自动等同于“更优”。
5. **可复现 ACK 数据集与适配规范。** 在脱敏后发布原子事件 schema、关联算法、失败样本、版本清单与分析代码；这会把一次云上测试提升为可复用研究资产。

### 8.2 黄色：可以作为系统贡献，但不能单独支撑首创

- Node/Image/Pod/Application 四层分类；
- 将 Karpenter NodeClaim 映射为 GOATScaler ProvisionNode/task；
- operator-reviewed YAML recommendation；
- 用 eBPF 捕获 containerd/kubelet 函数边界；
- KEDA、Kueue、Argo 作为多模式 workload 验证。

这些组合可能有价值，但每个组件都有先行工作。必须通过覆盖度、准确性、开销和实际调优收益来证明组合不是简单集成。

### 8.3 红色：当前证据下不应使用

- “首个云弹性度量/首个多层弹性指标”；
- “首个 Kubernetes Pod 启动阶段分解”；
- “首个 Kubernetes 控制面因果追踪系统”；
- “首次发现镜像拉取是冷启动瓶颈”；
- “首次根据冷启动调整 KEDA cooldown/保活窗口”；
- “首次使用工作流关键路径做弹性调优”；
- “首次研究动态 MIG 重配置”；
- “DRA 从 Kubernetes 1.31 起 GA，并能无 drain 地切换 MIG profile”；
- 在没有公开来源和复现实验前，把本地 Hooke 的 `94 s -> 41 s`、`2.3x`、`0.8% CPU` 当作已知事实。

## 9. 当前实验设计中需要优先修正的问题

### 9.1 30 次样本不能支撑稳定 p99

实验指南提出每个 cell 30 次同时输出 p99，而指标目录又建议 p99 至少 100、最好 300 个样本。30 次样本的经验 p99 几乎就是最大值，置信区间极不稳定。建议：

- smoke/pilot 的 30 次只报告原始点、p50、p95 和 bootstrap 区间；
- 若 p99 是论文主要结论，按目标相对误差和置信水平做 power/sample-size 设计，通常需要数百至上千个独立样本；
- 把 run 作为随机效应或 cluster bootstrap 单位，避免同一节点/同一波次内的 Pod 被错误当作完全独立样本。

### 9.2 四层时延不一定可加

节点初始化时可能并行发生镜像预取、CNI/CSI/DaemonSet 启动；Pod 调度、镜像拉取和 readiness 也可能有重叠。若直接令 `R_e2e = R_node + R_image + R_pod + R_app`，可能重复计时或留下空洞。

建议保存事件区间而不只保存 duration，并构造事件 DAG：

- 端到端 wall clock 是主要观测量；
- 每层独占 critical-path contribution 与重叠时长分开；
- `R_unattributed` 允许为正，但任何负值或重复覆盖都进入数据质量告警；
- 同时报告 sequential decomposition 和 critical-path decomposition，不能混用。

### 9.3 弹性乘积只应作为待检验假设

本地定义若为：

```text
E_l = mean(exp(-R_l / B))
E_product = product(E_l)
```

则只有在层时延可加且各 `R_l` 独立时，才有：

```text
E[exp(-sum(R_l) / B)] = product(E[exp(-R_l / B)])
```

而云库存、节点规格、镜像缓存、并发度和负载类型往往同时影响多层，独立性很可能不成立。应把直接测得的 `E_e2e` 作为主要结果，把 `E_product` 作为 null model，并报告 composition error、层间相关、条件分层和校准后的联合模型。证明这个简单模型何时失效，本身可能比宣称它普遍成立更有论文价值。

### 9.4 需要真正的归因 ground truth

仅凭最终调度结果和时间邻近无法知道哪个 Pending Pod 触发了哪个供应任务。优先级应是：

1. Pod/Node 的 GOATScaler task ID；
2. Kubernetes Event 的 involvedObject UID 与 task 信息；
3. Node providerID 到 ECS instance ID；
4. GOATScaler/SLS 与 ECS OpenAPI 双源核验；
5. 只有前述字段缺失时才使用时间窗口 + 资源匹配，并给出低置信标记。

可以用人为生成的、间隔可控且资源请求唯一的 scale-out 波次建立 ground truth，然后再进入随机并发负载。

### 9.5 时钟误差必须进入结果，而不只是做 NTP 检查

事件来自 Kubernetes API server、ACK/GOATScaler、ECS、SLS、各 Node 和负载器。需要保存 `event_time`、`observed_time`、source clock、ingest time，并周期性估计节点与采集端偏移。对跨时钟的短区间应给出不确定度；当时钟误差与待测时延同量级时，不应给出伪精确的毫秒结论。

### 9.6 eBPF 探针需要版本锁定和降级路径

containerd/kubelet uprobe 或函数级 hook 会依赖二进制 build ID、符号和编译优化。每次 run 必须保存 Kubernetes、containerd、kubelet、内核、CNI/CSI 与探针版本；升级后重新做 ABI/符号验证。正式设计应提供 CRI 事件、Kubernetes Event 或日志的低精度降级路径，并比较两种来源的偏差，而不是在探针失配时静默缺数。

### 9.7 warm node 的收益必须与成本共同报告

“预留一个 Ready 节点比从零创建更快”是预期结果，不足以形成研究发现。至少应报告：

- 每减少 1 秒 p95/p99 所增加的 idle node-minutes 和费用；
- 不同到达率下 warm capacity 的 break-even point；
- 规格、可用区、库存状态和 Spot/按量价格的分层结果；
- 与 custom image、image pre-pull、Pod priority/overprovisioning 等基线的 Pareto frontier。

## 10. 推荐的论文问题与实验范围

### 10.1 第一阶段建议题目

可考虑：

> **Causal Scale-out Latency Attribution for Event-driven Node Provisioning in Managed Kubernetes: An Empirical Study of ACK GOATScaler**

中文可表述为：

> **托管 Kubernetes 事件驱动节点供给的因果时延归因：ACK GOATScaler 实证研究**

这比“复现 Hooke”更能说明独立研究贡献，也避免继承原稿中尚未证实的通用性和 GPU 结论。

### 10.2 建议研究问题

- **RQ1：可恢复性。** 在并发、重试、失败和事件缺失下，task-ID 驱动方法能以多高的完整率和归因 precision/recall 恢复真实扩容链路？
- **RQ2：瓶颈分布。** GOATScaler 冷扩容的端到端时延如何随实例类型、可用区、库存、Pod 数量、镜像状态和并发度变化？哪个阶段在什么条件下主导？
- **RQ3：组合规律。** 四层时延是否独立、可加？简单弹性乘积的误差有多大，事件 DAG 或联合模型能改善多少预测？
- **RQ4：诊断价值。** 与 Kubernetes-only 指标或 dashboard 相比，跨平面 trace 是否更准确地选择了干预？调优后延迟、失败率和成本分别变化多少？
- **RQ5：可迁移性。** 适配器接口能否在不改变核心 schema/归因算法的情况下迁移到 Karpenter 或另一托管云？此项可作为加分实验，不应阻塞 ACK 主结果。

### 10.3 必要基线

1. Kubernetes Event + kube-state-metrics/kubelet metrics，不接 GOATScaler/ECS；
2. GKE-style startup phase dashboard 的等价实现；
3. Kelemetry 或等价 Kubernetes object trace；
4. 仅按时间窗口做 Node attribution 的启发式；
5. GOATScaler task-ID 关联的完整方案；
6. 调优侧至少比较 cold baseline、warm node、image pre-pull/custom image；
7. 实验方法参考 [COFFEE](https://doi.org/10.1145/3578244.3583726)，并发布可复现实验 artifact。

### 10.4 主要评价指标

- trace completeness、event loss、duplicate ratio、invalid ordering；
- attribution precision/recall/F1、task-to-Pod additivity error；
- event observation lag、clock uncertainty、unattributed latency；
- Node/Image/Pod/App 与 E2E 的 p50/p95/p99 和置信区间；
- failure/timeout/partial trace 比例，不把失败样本静默删除；
- collector CPU、内存、网络、SLS 写入量与存储成本；
- 调优前后 paired effect、绝对时延变化、弹性分数变化；
- idle resource time、ECS/ACR/SLS 增量费用与 Pareto frontier。

### 10.5 推荐阶段划分

| 阶段 | 内容 | 是否作为首篇论文主结果 |
| --- | --- | --- |
| A | GOATScaler task/ECS/Node 关联、数据质量、真实 cold-node | 是 |
| B | containerd + CRI + app 四层链路、组合误差 | 是 |
| C | warm node 与 image 策略的成本—时延闭环 | 是 |
| D | KEDA scale-to-zero | 可作为一个外部验证场景 |
| E | Kueue gang、Argo workflow | 后续或附录，不宜同时做深 |
| F | DRA vs static MIG | 独立 GPU 论文，先重新核实平台能力 |

## 11. 近期行动清单

### P0：开始大规模实验前

- [ ] 向 Hooke PDF 提供方索要作者、版本、投稿/录用状态、代码和数据来源；在此之前固定标记为匿名未发表稿。
- [ ] 在真实 ACK 集群读取 Pod annotation 与 Node label，确认 `goatscaler.io/provision-task-id` 的格式、生命周期和一对多关系。
- [ ] 确认 `ack-goatscaler` 控制面日志是否已手工加入 SLS collected components，并保存一份脱敏字段样例。
- [ ] 验证 Node `providerID`、ECS instance ID 和 task ID 的连接是否在失败/重试场景仍成立。
- [ ] 将实验指南中的“30 次输出 p99”改为 pilot 口径；另做 tail sample-size 设计。
- [ ] 明确四层区间的允许重叠关系，先实现 event DAG 与 `R_unattributed` 校验。

### P1：形成可投稿 CPU 结果

- [ ] 建立 task ID 方案与 Kubernetes-only/时间窗口方案的 ground-truth 对比。
- [ ] 随机化实验顺序，并按 zone、instance type、库存状态、cache state 分层。
- [ ] 预注册主要 RQ、主要指标、排除规则和失败样本处理方式。
- [ ] 对每个调优建议同时报告时延、成功率、资源闲置和费用。
- [ ] 发布脱敏原子事件、schema、关联器、分析脚本和完整版本 manifest。

### P2：GPU 阶段前

- [ ] 删除或修正“DRA v1.31 GA”与“without draining”的前提。
- [ ] 在 ACK 上验证受支持的 Kubernetes/DRA API、NVIDIA DRA driver 和 GPU Operator 版本。
- [ ] 分别测量停止业务 Pod、停止 GPU client、MIG geometry 改变、节点 reboot、ResourceClaim 可用和应用恢复。
- [ ] 把 MISO、TGS、MIGRator 与已发表的 MIG 重配置调度工作纳入正式 related work 和 baseline。

## 12. 最终判断

| 判断项 | 结论 | 置信度 |
| --- | --- | --- |
| Hooke 精确题名已有公开论文 | 本次未检出；本地文件应视为匿名未发表稿 | 高（针对所查公开库） |
| 四层弹性/启动分解整体无人研究 | 不成立，各层与相邻组合均有大量成果 | 高 |
| 已有公开 GOATScaler 任务级四层论文 | 本次未检出 | 中（需付费数据库与中文库复核） |
| ACK 适配本身足以发表强系统论文 | 不足；仅移植更偏工程贡献 | 高 |
| task-ID 跨平面归因有研究潜力 | 有，尤其在准确性、失败和并发条件下 | 中高 |
| 独立乘积是可靠通用定律 | 尚无证据，且很可能受相关性/重叠破坏 | 高 |
| GPU/DRA/MIG 可沿用本地稿件结论 | 不可，版本与重配置语义需要重做 | 高 |
| 当前项目是否值得继续 | 值得，建议 CPU 主链路先行、GPU 独立 | 中高 |

一句话概括：**相邻模块都有人做过，真正可能的新东西是把 ACK GOATScaler 的供应任务变成可核验的跨平面因果链，并证明这条链在并发、失败和成本约束下能产生比现有指标更准确的诊断与更有效的调优。**

## 13. 主要参考资料

### 弹性定义、测量与 Kubernetes autoscaling

1. Herbst, N. R., Kounev, S., Reussner, R. “Elasticity in Cloud Computing: What It Is, and What It Is Not.” ICAC 2013. [USENIX](https://www.usenix.org/conference/icac13/technical-sessions/presentation/herbst)
2. Ai, W. et al. “On Elasticity Measurement in Cloud Computing.” Scientific Programming, 2016. [DOI](https://doi.org/10.1155/2016/7519507)
3. “BECloud: A New Approach to Analyse Elasticity Enablers of Cloud Services.” Future Generation Computer Systems, 2016. [DOI](https://doi.org/10.1016/j.future.2016.05.014)
4. Tamiru, M. A. et al. “An Experimental Evaluation of the Kubernetes Cluster Autoscaler in the Cloud.” IEEE CloudCom 2020. [IEEE](https://ieeexplore.ieee.org/document/9407312/)
5. Zhang, Y. et al. “AHPA: Adaptive Horizontal Pod Autoscaling Systems on Alibaba Cloud Container Service for Kubernetes.” 2023. [arXiv](https://arxiv.org/abs/2303.03640)
6. Straesser, M. et al. “Autoscaler Evaluation and Configuration: A Practitioner's Guideline.” ICPE 2023. [DOI](https://doi.org/10.1145/3578244.3583721)
7. Straesser, M. et al. “A Systematic Approach for Benchmarking of Container Orchestration Frameworks.” ICPE 2023. [DOI](https://doi.org/10.1145/3578244.3583726), [COFFEE artifact](https://doi.org/10.5281/zenodo.7603961)
8. Medel, V. et al. “Characterising Resource Management Performance in Kubernetes.” Computers & Electrical Engineering, 2018. [DOI](https://doi.org/10.1016/j.compeleceng.2018.03.041)
9. Barletta, V. S. et al. “SLO-aware Prioritization of Orchestration Times for Containerized Services.” ACM Transactions on Internet Technology. [DOI](https://doi.org/10.1145/3767329)

### Pod 启动、镜像与可观测性

10. Google Cloud. “Monitor startup latency metrics.” [GKE 官方文档](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/monitor-startup-latency-metrics)
11. AWS. “Deep dive into Amazon EKS scalability testing.” [AWS Containers Blog](https://aws.amazon.com/blogs/containers/deep-dive-into-amazon-eks-scalability-testing/)
12. Harter, T. et al. “Slacker: Fast Distribution with Lazy Docker Containers.” FAST 2016. [USENIX](https://www.usenix.org/conference/fast16/technical-sessions/presentation/harter)
13. Li, H. et al. “DADI: Block-Level Image Service for Agile and Elastic Application Deployment.” USENIX ATC 2020. [USENIX](https://www.usenix.org/conference/atc20/presentation/li-huiba)
14. Beni, E. H. et al. “Reducing Cold Starts during Elastic Scaling of Containers in Kubernetes.” SAC 2021. [DOI](https://doi.org/10.1145/3412841.3441887)
15. Xu, S. et al. “Kelemetry: Global Tracing for Kubernetes Control Plane.” [CNCF 介绍](https://www.cncf.io/blog/2023/07/27/kelemetry-global-tracing-for-kubernetes-control-plane/), [GitHub](https://github.com/kubewharf/kelemetry)
16. Ehira, Y. et al. “Distributed Tracing for Cascading Changes of Objects in the Kubernetes Control Plane.” 2024. [arXiv](https://arxiv.org/abs/2411.01336)
17. Pixie. “What is Pixie?” [官方文档](https://docs.px.dev/about-pixie/what-is-pixie/)

### Serverless、工作流与批调度

18. KEDA. “ScaledObject specification.” [官方文档](https://keda.sh/docs/2.21/reference/scaledobject-spec/)
19. Shahrad, M. et al. “Serverless in the Wild: Characterizing and Optimizing the Serverless Workload at a Large Cloud Provider.” USENIX ATC 2020. [USENIX](https://www.usenix.org/conference/atc20/presentation/shahrad)
20. Golec, M. et al. “Cold Start Latency in Serverless Computing: A Systematic Review, Taxonomy, and Future Directions.” [arXiv](https://arxiv.org/abs/2310.08437)
21. Ramanathan, A. et al. “AQUATOPE: QoS-and-Uncertainty-Aware Resource Management for Multi-stage Serverless Workflows.” ASPLOS 2023. [论文 PDF](https://people.csail.mit.edu/delimitrou/papers/2023.asplos.aquatope.pdf)
22. Nguyen, D. D., Karavanic, K. L. “Workflow Critical Path: A Data-oriented Critical Path Metric for Holistic HPC Workflows.” 2021. [DOI](https://doi.org/10.1016/j.tbench.2021.100001)
23. Kueue. “Overview.” [官方文档](https://kueue.sigs.k8s.io/docs/overview/)
24. Kubernetes. “Gang Scheduling.” [官方文档](https://kubernetes.io/docs/concepts/scheduling-eviction/gang-scheduling/)

### DRA、MIG 与 GPU 调度

25. Kubernetes. “Dynamic Resource Allocation.” [官方文档](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
26. NVIDIA. “GPU Operator with MIG.” [官方文档](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-mig.html)
27. NVIDIA. “DRA Driver for NVIDIA GPUs.” [官方文档](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/dra-intro-install.html)
28. Wu, B. et al. “Transparent GPU Sharing in Container Clouds for Deep Learning Workloads.” NSDI 2023. [USENIX](https://www.usenix.org/conference/nsdi23/presentation/wu)
29. “MISO: Exploiting Multi-Instance GPU Capability on Multi-Tenant GPU Clusters.” SoCC 2022. [DOI](https://doi.org/10.1145/3542929.3563510)
30. Wang, T. et al. “Improving GPU Multi-Tenancy Through Dynamic Multi-Instance GPU Reconfiguration.” 2024. [arXiv](https://arxiv.org/abs/2407.13126)
31. “Solving the Task Scheduling and GPU Reconfiguration Problem on MIG Devices via Deep Reinforcement Learning.” Future Generation Computer Systems, 2026. [DOI](https://doi.org/10.1016/j.future.2025.108145)

### ACK/GOATScaler 与节点供给

32. Alibaba Cloud ACK. “Overview of node scaling in ACK clusters.” [官方文档](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/overview-of-node-scaling/)
33. Alibaba Cloud ACK. “Use node instant scaling to automatically scale nodes.” [官方文档](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/instant-elasticity)
34. Alibaba Cloud ACK. “Collect control plane component logs of ACK managed clusters.” [官方文档](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/collect-control-plane-component-logs-of-ack-managed-cluster)
35. Karpenter. “NodeClaims.” [官方文档](https://karpenter.sh/docs/concepts/nodeclaims/)
36. AWS. “Eliminate Kubernetes node scaling lag with pod priority and over-provisioning.” [AWS Containers Blog](https://aws.amazon.com/blogs/containers/eliminate-kubernetes-node-scaling-lag-with-pod-priority-and-over-provisioning/)
