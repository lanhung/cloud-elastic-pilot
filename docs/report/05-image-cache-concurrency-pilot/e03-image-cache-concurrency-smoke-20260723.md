# E03 镜像缓存/并发拉取 27-cell 冒烟报告

## 1. 摘要

2026 年 7 月 23 日在分支 `experiment/05-image-cache-concurrency-pilot` 上完成
E03 镜像大小、缓存状态、单节点拉取并发和节点状态的首轮真实 ACK 冒烟。
固定随机顺序中的 27 个 cell 全部直接通过 E03 fail-closed Gate，63/63 条轨迹
完整且精确，汇总状态为 **PASS**。

| Gate | 结果 |
|---|---:|
| cell | 27/27 PASS |
| 完整轨迹 | 63/63 |
| 精确轨迹 | 63/63 |
| invalid order | 0 |
| cold cell 实际并发达到请求值 | 18/18 |
| warm cell 下载字节为 0、实际 pull 为 0 | 9/9 |
| new-node 运行唯一节点、唯一 task | 9/9 |
| new-node task-ID Precision / Recall | 1 / 1 |
| controller / ingester ERROR | 0 / 0 |

冷缓存的单 Pod 平均 pull-total 时延随镜像大小近似线性增长；并发从 1 增至 2
时单 Pod 平均时延只小幅增加，并发增至 4 时共享带宽竞争更明显。existing 和
new 节点的 pull-total 结果方向接近，没有观察到稳定的节点年龄效应。

所有 warm cell 均由节点缓存命中，没有实际下载。该结果证明缓存和实际并发操纵
有效，但每个 cell 只有 1 次重复，只能判定 **冒烟 Gate PASS**，不能报告稳定的
p50/p95/p99 或统计显著性。

本轮配置 `E03_REQUIRE_UNPACK_SUBSTAGE=false`，因此结论只覆盖 pull-total；
download 与 unpack 没有拆分，报告不会用近似事件补造这两个子阶段。

## 2. 实验问题与判定

E03 首轮冒烟回答三个工程问题：

1. 100、500、1024 MiB 三档不可变镜像能否在 existing/new ACK 节点上形成
   可追踪、可复现的 cold pull-total 样本；
2. 请求并发 1、2、4 是否真的形成同一节点上的 1、2、4 路重叠拉取，而不是把
   同一 digest 的 containerd 合并请求误记为并发；
3. warm 缓存是否真的消除镜像下载，而不是只依赖 `IfNotPresent` 配置推测缓存。

每个 cold cell 必须满足：

- 每个并发槽使用不同不可变 digest；
- 所有 Pod 调度到同一目标节点；
- 精确 `IMAGE_PULL_START/END` 数量等于 Pod 数；
- 实际最大并发等于请求并发；
- 触发 spread 不超过 1000 ms；
- 下载字节不少于确定性 padding 的 98%；
- Image、Pod、App 适用主层完整且精确。

每个 warm cell 必须先逐 digest 预热并核验节点缓存，正式运行中实际 pull 数和
下载字节都必须为 0。new-node cell 还必须从空专用池开始，只出现一个新节点和
一个供应 task，并完成 Pod → task → Node → providerID 归因。

上述测量与数据质量 Gate 全部通过。

## 3. 冻结环境

| 项目 | 值 |
|---|---|
| 会话 | `e03-image-cache-concurrency-pilot-20260723T074416Z` |
| 执行窗口 | 2026-07-23 07:44:16Z–10:31:25Z |
| 分支 | `experiment/05-image-cache-concurrency-pilot` |
| 编排 Git | `8575c8175db41d7625874affa91055d27fd602f5`，clean |
| 镜像构建 Git | `7b6dd2e9248b32b34db6ad592840da4109b8ccc0`，clean |
| 随机种子 | `20260723` |
| 每 cell 重复 | 1 |
| ACK 集群 | `cc224c25bf1e5423a802315aff201c15c` |
| 地域 / 可用区 | `cn-wulanchabu` / `cn-wulanchabu-c` |
| Kubernetes | `v1.36.1-aliyun.1` |
| existing 节点 | `cn-wulanchabu.10.235.204.122` |
| 专用弹性节点池 | `np03d225929590416b8a1225482207b560` |
| 节点池形状 | 自动伸缩启用，`min=0,max=1`，非默认 ESS 池 |
| 节点隔离 | `hooke.io/experiment=elastic:NoSchedule` |
| 实例规格 | `ecs.c7.xlarge`，4 vCPU |
| 系统盘 | `cloud_essd` |
| 应用资源 | CPU `100m/500m`，内存 `128Mi/256Mi` |
| ACR | 同地域个人版 ACR，不可变 digest |
| unpack Gate | `false` |

三档镜像各有 4 个不同 digest。相同尺寸的变体共享 smoke-app 层，但使用不同的
确定性不可压缩 padding 层；所有镜像总大小与 100、500、1024 MiB 目标的误差
均不超过 4096 B。

## 4. 实验设计

### 4.1 冻结矩阵

| 维度 | 水平 |
|---|---|
| image size | 100 / 500 / 1024 MiB |
| requested concurrency | 1 / 2 / 4 |
| existing node cache | cold / warm |
| new node cache | cold |

`new+warm` 被排除：完成预热后该节点已不再是 new 条件。每档尺寸共有 9 个 cell，
总计 27 个 cell。固定随机顺序完整保存在 `schedule.tsv`。

### 4.2 节点与缓存操纵

existing cell 始终使用 `kubernetes.io/hostname` 精确固定到 `.122`：

- cold：逐 digest 删除 containerd/CRI 缓存、等待 GC，再逐个核验为 cold；
- warm：创建短生命周期预热 Pod，删除预热 Namespace，再逐个核验为 warm。

new cell 使用专用 `min=0,max=1` 节点池：

- 运行前 Kubernetes 选中节点数必须为 0；
- 不提前拉取镜像；
- 不可调度 Pod 触发 GOATScaler 创建一个 fresh 节点；
- 同一 cell 的全部 Pod 必须落在该节点；
- 子运行结束后等待 ACK 自动回收。

9 次 new-node 运行依次使用：

```text
cn-wulanchabu.10.235.204.125
cn-wulanchabu.10.235.204.126
cn-wulanchabu.10.235.204.127
cn-wulanchabu.10.235.204.128
cn-wulanchabu.10.235.204.129
cn-wulanchabu.10.235.204.130
cn-wulanchabu.10.235.204.131
cn-wulanchabu.10.235.204.132
cn-wulanchabu.10.235.204.133
```

### 4.3 时间与字节来源

| 指标 | 精确来源 |
|---|---|
| pull-total | 目标节点 containerd/kubelet journal 的 `IMAGE_PULL_START/END` |
| 实际并发 | 精确 pull 区间的最大重叠数 |
| 触发 spread | 同一操作机并行 Deployment patch 的单调时钟 |
| 下载字节 | 精确运行时 pull 事件中的内容字节 |
| Pod/App | CRI sandbox/container 事件与应用源时间日志 |
| Node 归因 | GOATScaler SLS task、Pod annotation、Node label、providerID |

## 5. 结果

### 5.1 cold pull-total

下表为单次 cell 内各 Pod 的平均 pull-total 时延，单位为秒：

| 镜像大小 | existing c1 | existing c2 | existing c4 | new c1 | new c2 | new c4 |
|---|---:|---:|---:|---:|---:|---:|
| 100 MiB | 19.623 | 20.046 | 24.441 | 19.632 | 19.976 | 24.791 |
| 500 MiB | 100.388 | 104.159 | 133.018 | 101.259 | 102.942 | 129.912 |
| 1024 MiB | 211.965 | 224.682 | 296.746 | 209.729 | 221.326 | 273.617 |

相对 c1，c4 的单 Pod 平均 pull-total：

- existing 增加 24.6%、32.5%、40.0%；
- new 增加 26.3%、28.3%、30.5%。

c2 相对 c1 只增加约 1.7%–6.0%。c4 仍然形成真实 4 路重叠，但共享节点网络、
磁盘和解压资源使单 Pod 平均及尾部时延上升。c4 的最大单 Pod pull-total 为：

| 大小 | existing 最大值 | new 最大值 |
|---|---:|---:|
| 100 MiB | 38.285 秒 | 38.020 秒 |
| 500 MiB | 201.918 秒 | 198.784 秒 |
| 1024 MiB | 418.191 秒 | 418.467 秒 |

existing 与 new 的同档结果接近。单次运行中没有观察到 new 节点稳定更慢或更快，
说明 E03 的主要操纵来自大小、缓存和并发，而不是节点名称本身；但 1 次重复不足以
排除网络时变和执行顺序影响。

### 5.2 并发与触发有效性

18 个 cold cell 的实际 pull 并发均精确等于请求值：

| 请求并发 | cold cell | 实际并发 Gate |
|---:|---:|---:|
| 1 | 6 | 6/6 |
| 2 | 6 | 6/6 |
| 4 | 6 | 6/6 |

最大触发 spread 为 1.394 ms，远低于预设的 1000 ms Gate。并发 2/4 使用不同
digest 和不同 padding 层，因此不是 containerd 对同一内容请求的合并。

### 5.3 warm 缓存

9 个 existing-warm cell 均满足：

- 预热后逐 digest 缓存核验通过；
- 正式运行下载字节为 0；
- 实际 pull 并发为 0；
- Image pull-total 为 0；
- Pod 与 App 轨迹仍完整、精确。

这证明 warm 结果来自真实节点缓存命中，而不是缺失事件或串行拉取。

### 5.4 new-node 归因

9 个 new-node cell 共包含 21 个 Pod：

| 检查 | 结果 |
|---|---:|
| 每运行唯一新节点 | 9/9 |
| 每运行唯一供应 task | 9/9 |
| task-ID Precision | 1 |
| task-ID Recall | 1 |
| providerID coverage | 1 |
| task/node 冲突 | 0 |

所有适用 Node 主层均为精确来源。节点供应与 pull-total 使用不同时间源且存在阶段
重叠，本报告不把它们直接相加。

## 6. 数据质量与限制

| 检查 | 结果 |
|---|---:|
| 子运行 completed / PASS | 27/27 |
| 完整轨迹 | 63/63 |
| 精确轨迹 | 63/63 |
| invalid order | 0 |
| controller / ingester ERROR | 0 / 0 |
| E03 validation 文件 | 27 |
| summary cell 集合 | 冻结 27-cell 集合完整 |
| unpack 样本 | 0（按配置） |

限制如下：

1. **每个 cell 只有 1 次重复。** 当前只能验证链路和方向，不能估计方差；
2. **执行顺序只有一个随机种子。** 不能排除时间趋势与 carry-over；
3. **只有一个地域、可用区、实例规格和 ESSD 配置。**
4. **pull-total 未拆分。** 当前没有与 ACK containerd build-id 绑定的
   `IMAGE_DOWNLOAD_*` / `IMAGE_UNPACK_*` 精确探针；
5. **同档镜像共享应用层。** 这是为了控制应用二进制一致性；padding 层保持独立，
   下载字节 Gate 以每个镜像的确定性 padding 为下限；
6. 样本不足 100，不能报告 p99。

## 7. 运行异常与后续修复

### 7.1 Kubernetes/ESS 清零竞态

sequence 6 `new-cold-100mib-c1` 开始前，上一节点已经从 Kubernetes 消失，但
ESS 的上一次收缩尚未完全结束。GOATScaler 第一次扩容收到
`IncorrectCapacity.NoChange`，随后把节点池短暂标为 unhealthy。ESS 完全清零后，
GOATScaler 自动恢复并创建唯一有效 task；该 cell 最终 PASS，task-ID
Precision/Recall 仍为 1。

该事件揭示原编排器的 `wait_elastic_zero` 只检查 Kubernetes Node 数，不足以证明
云侧 scaling group 已经完成移除。

运行后已补充 fail-closed 修复：

1. 节点池只读 hook 从 ACK pool 的精确 `scaling_group_id` 调用 ESS
   `DescribeScalingGroups`；
2. evidence 新增 `total/pending/removing/active` 实时容量；
3. 每个 new cell 前及最终收尾同时要求 Kubernetes Node 数为 0，且四个 ESS
   容量字段全为 0；
4. Kubernetes 已清零但 ESS 未清零时保留逐次云侧 evidence 并继续等待。

该修复发生在成功会话之后，不改变或重算本报告的原始结果。

### 7.2 新节点 flannel 首次重试

21/21 个 new-node Pod 在新节点刚 Ready 时都记录到一次
`FailedCreatePodSandBox`：flannel `/run/flannel/subnet.env` 尚未生成。随后重试
全部成功，形成 21 条精确 sandbox 主轨迹，没有 Pod 或 cell 失败。

同一 Kubernetes 事件分别归类为 `CNI_SETUP_FAILED` 和 `POD_SANDBOX_FAILED`，
因此失败表有 42 行，但只有 21 个唯一事件、21 个唯一 Pod。当前没有真实成功 CNI
起止边界，`cni_samples=0`；报告不会把 Kubernetes Event 时间伪装成成功 CNI
子阶段。

这是 new-node 真实初始化路径的一部分，不影响精确 pull 区间，但会影响 Pod/E2E
尾部，扩大正式样本时应单独统计其发生率。

## 8. 清理状态

主流程在生成汇总前完成并复核：

- 专用节点池恢复为 `active,min=0,max=1,desired=0`；
- Kubernetes 弹性节点数为 0；
- ESS `total/pending/removing/active` 均为 0；
- `.125`–`.133` 九个测试节点均已自动回收；
- 无残留 `e03-*` Namespace；
- 无残留 `hooke-e03-*` Lease；
- 无残留 E03 Pod 或特权 helper；
- 子运行 controller/ingester 已退出；
- `CONFIRM_E03_EXECUTION` 已恢复为 `no`；
- Git 工作树保持 clean。

`hooke-e03-mysql` 按 `STOP_MYSQL_ON_EXIT=false` 保留用于复用和本地审计；它不属于
Kubernetes 实验资源。主流程完成后又执行了一次只读 `make e03-ack-check`，
existing/new 两条预检均通过，未创建工作负载或节点。

## 9. 结论与下一步

E03 首轮 pull-total 冒烟结论为 **PASS**：

- 三档大小、cold/warm 和 1/2/4 路并发操纵全部有效；
- cold 实际并发与请求并发一致；
- warm 缓存完全消除下载；
- 所有 63 条轨迹完整且精确；
- 9 次 new-node 运行的 task-ID 归因全部正确；
- 节点与实验资源最终自动清理完成。

方向上，镜像大小是主要时延来源；c2 对单 Pod 时延影响较小，c4 出现更明显的共享
资源竞争。该结论不能替代正式统计实验。

2026-07-24 收尾复核时，ACK 已对本次集群
`cc224c25bf1e5423a802315aff201c15c` 返回 `ErrorClusterNotFound`，且本机当前
kube context 指向另一集群。因此双重清零修复只完成离线测试，没有对无关集群执行
E03 preflight。

建议按以下顺序推进：

1. 合入 Kubernetes+ESS 双重清零 Gate；确定后续目标 ACK 集群后，先对该集群执行
   一次只读 E03 preflight；
2. 将 `E03_PILOT_REPETITIONS` 提高到 5，验证双重清零和 flannel 重试模式；
3. pilot 稳定后每 cell 至少 30 次，报告 p50/p95；样本不足 100 时继续抑制 p99；
4. 若研究目标要求区分网络下载与 unpack，先实现与 ACK containerd build-id
   绑定的精确探针，再开启 `E03_REQUIRE_UNPACK_SUBSTAGE=true`；
5. 正式实验增加实例规格、磁盘或可用区区组，并记录成本与 registry 限流状态。

## 10. 产物索引

- [会话元数据](../../../artifacts/e03-image-cache-concurrency-pilot-20260723T074416Z/session.json)
- [随机执行顺序](../../../artifacts/e03-image-cache-concurrency-pilot-20260723T074416Z/schedule.tsv)
- [27-cell 汇总](../../../artifacts/e03-image-cache-concurrency-pilot-20260723T074416Z/summary.json)
- [逐运行观测](../../../artifacts/e03-image-cache-concurrency-pilot-20260723T074416Z/observations.tsv)
- [运行索引](../../../artifacts/e03-image-cache-concurrency-pilot-20260723T074416Z/run-index.tsv)
- [sequence 6 ESS 竞态证据](../../../artifacts/e03-image-cache-concurrency-pilot-20260723T074416Z/runs/e03-new-cold-100mib-c1-r1-s6-20260723T082617Z/kubernetes-events.json)
- [sequence 6 E03 校验](../../../artifacts/e03-image-cache-concurrency-pilot-20260723T074416Z/runs/e03-new-cold-100mib-c1-r1-s6-20260723T082617Z/e03-validation.json)
- [最终 sequence 27 校验](../../../artifacts/e03-image-cache-concurrency-pilot-20260723T074416Z/runs/e03-new-cold-100mib-c2-r1-s27-20260723T101720Z/e03-validation.json)

关键汇总文件 SHA-256：

```text
summary.json       7da34320fb2a3378365f785cb985abe53dee31a6832a79c07d895dc5aae86cbe
observations.tsv   fbf65ebec79dda5bff73363af0a7468befec6228239d41cf8a0d2caa3f75c5d2
run-index.tsv      b065c602509c60928ddceb67e89e3c9637bf0f4b763f27ece0c6021211cc98c5
```
