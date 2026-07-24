# ACK 固定节点第一轮冒烟实验报告

## 1. 摘要

2026 年 7 月 24 日在真实 ACK 集群上完成第一轮固定节点冒烟。实验连续执行
3 次 Deployment `0 → 1 → 0`，每次均成功 rollout、通过 HTTP 检查并形成完整
Pod 轨迹。最终 Gate-S 判定为 **PASS**。

| Gate | 结果 |
|---|---:|
| 固定节点重复 | 3/3 成功 |
| HTTP 检查 | 3/3 成功 |
| 原始事件 | 37 |
| 完整轨迹 | 3/3 |
| Pod / App 层样本 | 3 / 3 |
| Image 层样本 | 1 |
| invalid order | 0 |
| 不可追溯主层样本 | 0 |
| controller / ingester ERROR | 0 / 0 |
| 最终结果 | **PASS** |

本轮证明了“ACK 真实事件 → 本地 ingester/MySQL → 关联 → 计算 → 报告”的端到端
链路可用。3 条轨迹的精确覆盖率均为 0，Image、Pod 和 App 主层使用 Kubernetes
事件或状态代理边界，因此本报告的结论等级是 **链路冒烟通过**，不是精确性能或
统计结论。

## 2. 实验目标与判定范围

本轮主要回答以下工程问题：

1. 本地 controller 能否通过 kubeconfig 持续采集真实 ACK Pod 与 Kubernetes
   Event；
2. 采集事件能否进入 MySQL，并按 `run_id`、Pod UID、Node Name 和 Container
   关联为完整轨迹；
3. 同一工作负载连续重建 3 次时，rollout、readiness 与 HTTP 服务是否都能成功；
4. 关联器和计算器能否产出可追溯的分层样本、弹性指标和质量结果；
5. 成功后能否删除本轮唯一实验 Namespace，不污染后续实验。

本轮没有启用节点扩容，因此不检验 ACK 节点供应、GOATScaler task 归因或 Node
层时延。`ENABLE_NODE_SCALE_SMOKE=false`，Node 层相关计数为 0 属于预期结果。

Gate-S 要求至少形成 3 条完整固定节点轨迹，并包含以下观测：

- `POD_CREATED`
- `POD_SCHEDULED`
- `CONTAINER_STARTED`
- `POD_READY`
- `READINESS_PROBE_FIRST_SUCCESS`

同时要求时序合法、派生结果可追溯、controller/ingester 无 ERROR。上述条件全部
满足。

## 3. 冻结环境

| 项目 | 值 |
|---|---|
| Run ID | `01KY9527NF0WSZBBQGNRGJBZXD` |
| Run 名称 | `first-smoke-20260724T041003Z` |
| 运行窗口 | 2026-07-24 04:10:17Z–04:11:38Z |
| 分支 | `experiment/06-keda-scale-to-zero-pilot` |
| 基础 Git commit | `30b8930059796db22c4a18e1163517f53b0fe914` |
| Git 状态 | dirty；包含本轮启动前的脚本和 smoke 配置修正 |
| ACK cluster ID | `c061d99ce379f4e37a9ff97e027a36ca6` |
| kube context | `209359284623428234-c1c5437d0c5264255926d4a28f8c67c20` |
| 实验 Namespace | `hooke-experiments-scale-20260724t041003z` |
| Kubernetes server | `v1.36.1-aliyun.1` |
| 节点数 | 2，运行前后均为 Ready |
| 节点 OS | Alibaba Cloud Linux 4.0.3（OpenAnolis Edition） |
| kernel / runtime | `6.6.102-5.3.1.alnx4.x86_64` / containerd 2.1.9 |
| 测试镜像 | `registry.cn-hangzhou.aliyuncs.com/google_containers/echoserver:1.10` |
| Pull policy | `IfNotPresent` |
| CPU request / limit | `100m` / `500m` |
| 内存 request / limit | `64Mi` / `256Mi` |
| readiness / request path | `/` / `/` |
| SLO | 30 秒 |
| 重复数 | 3 |

采集和计算服务采用混合部署：

- 测试 Deployment、Service 和 Pod 运行在 ACK；
- controller、ingester、correlator、calculator 和 MySQL 运行在本地 Linux
  操作机；
- controller 通过本地 kubeconfig Watch ACK；
- ACK 不访问本地 MySQL，也不上传 kubeconfig。

## 4. 实验设计与执行

### 4.1 执行流程

1. 运行只读预检，验证 kube context、API Server 指纹、RBAC、Docker、Go 和
   kubectl；
2. 启动或复用本地 MySQL 8.4 容器；
3. 构建 migration、ingester、controller、correlator、calculator 和 CLI；
4. 应用数据库 schema，创建唯一 `run_id`；
5. 启动本地 ingester 与 Kubernetes controller；
6. 创建唯一实验 Namespace；
7. 对同一 Deployment 连续执行 3 次 `0 → 1 → 0`；
8. 每次等待 rollout 成功，通过本地 `kubectl port-forward` 执行 HTTP 检查；
9. 停止采集并执行关联、计算、Gate-S 和产物导出；
10. 删除本轮 Deployment、Service 和实验 Namespace。

### 4.2 控制条件

3 次运行使用相同镜像、资源 request/limit、readiness 配置和 Deployment。
配置没有设置固定 `nodeSelector`，但实际 3 个 Pod 均调度到同一 Ready 节点：

```text
cn-wulanchabu.10.170.108.83
```

第一轮记录到一次 Image Pull 区间；后两轮镜像已缓存，没有形成完整 Image
Pull 区间。该顺序是缓存状态变化，不是随机化的 cold/warm 对照设计。

### 4.3 时间口径

编排器使用同一操作机的 `CLOCK_MONOTONIC` 记录“发出 scale 请求 → rollout
成功”，不受操作机墙钟校准影响。分层轨迹来自 Kubernetes Pod 状态和 Event，
当前时间分辨率约为 1 秒，且边界均为近似口径。

Image、Pod 和 App 区间存在重叠，不能直接相加。计算器采用
`union-with-latest-ending-active-layer-allocation` 规则计算关键路径分配。

## 5. 实验结果

### 5.1 单轮结果

| 轮次 | Pod 后缀 | 节点 | scale→rollout | 轨迹 total | Image | Pod | App | HTTP |
|---:|---|---|---:|---:|---:|---:|---:|---|
| 1 | `tsvjl` | `.83` | 5.651917 秒 | 5 秒 | 4 秒 | 4 秒 | 1 秒 | 成功 |
| 2 | `vh6b2` | `.83` | 1.656868 秒 | 1 秒 | 无完整区间 | 0 秒 | 1 秒 | 成功 |
| 3 | `mjhpr` | `.83` | 1.669891 秒 | 1 秒 | 无完整区间 | 0 秒 | 1 秒 | 成功 |

3 次 scale、rollout 和 evidence 命令的返回码均为 0。编排器单调时钟结果的算术
平均值为 2.992892 秒；该数值只描述本次冒烟，不作为稳态均值或 SLO 分位数。

第一轮耗时较长与首次镜像拉取方向一致；但本轮没有随机化缓存顺序、独立冷缓存
复现或精确 runtime 探针，不能把三轮差异定量归因为镜像下载。

### 5.2 原始事件

| 事件类型 | 数量 | approximate |
|---|---:|---:|
| `EXPERIMENT_STARTED` / `EXPERIMENT_STOPPED` | 1 / 1 | false |
| `POD_CREATED` | 3 | false |
| `POD_SCHEDULED` | 3 | false |
| `POD_INITIALIZED` | 3 | false |
| `POD_READY` | 3 | false |
| `POD_DELETED` | 3 | false |
| `IMAGE_PULL_START` / `IMAGE_PULL_END` | 1 / 3 | true |
| `CONTAINER_STARTED` / `CONTAINER_STOPPED` | 3 / 3 | true |
| `READINESS_PROBE_FIRST_SUCCESS` | 3 | true |
| `DEPLOYMENT_DESIRED_REPLICAS_CHANGED` | 7 | true |

合计 37 条事件。3 个 Pod 均能通过 Pod UID 和 Node Name 关联到各自轨迹，没有
负时延或事件顺序错误。

### 5.3 轨迹与数据质量

| 指标 | 结果 |
|---|---:|
| trace count | 3 |
| complete count | 3 |
| exact trace count | 0 |
| approximate Image / Pod / App | 1 / 3 / 3 |
| invalid order | 0 |
| mean exact coverage | 0 |
| mean unattributed | 0 ms |
| mean overlap | 1333.333 ms |
| sandbox / CNI / image-unpack 样本 | 0 / 0 / 0 |
| sandbox / CNI 失败 Pod | 0 / 0 |

完整轨迹表示必需的链路边界齐全，不等于边界精确。当前 Pod 层使用
`POD_SCHEDULED` 代理 SyncPod 起点，App 层使用 Pod Ready 代理首次 readiness
成功，Image 层来自 Kubernetes Event。

### 5.4 计算器输出

| scope | elasticity | 样本数 |
|---|---:|---:|
| Image | 0.875173 | 1 |
| Pod | 0.958391 | 3 |
| App | 0.967216 | 3 |
| Total | 0.811261 | 3 |

计算器诊断瓶颈为 `pod`，依据是“平均关键路径贡献 / 分层 elasticity”。这些分数
可用于验证公式和数据流，但由于样本量小、边界近似且 Image 只有 1 个样本，不能
作为正式性能排名。系统按最少 100 个样本的规则抑制了 p99。

## 6. 数据质量与限制

1. **全部分层边界均为近似口径。** `exact_trace_count=0`，本轮未接入节点
   runtime journal、eBPF 或应用 SDK 精确源时间；
2. **只有 3 次重复。** 不能估计方差、置信区间或稳定的 p95/p99；
3. **缓存顺序没有随机化。** 第一轮 cold、后两轮 warm 的执行顺序与时间趋势
   混杂；
4. **Image 样本只有 1 个。** `IMAGE_PULL_END` 在缓存命中时仍可出现，但缺少
   配对 `IMAGE_PULL_START`，不会被构造成完整 Image 区间；
5. **镜像使用 tag 而非 digest。** `echoserver:1.10` 没有冻结为不可变
   `sha256`，长期复现存在镜像内容漂移风险；
6. **未显式固定目标节点。** 3 次恰好落在同一节点，但配置没有通过 hostname
   selector 强制该条件；
7. **没有 Node 层实验。** 节点扩容、供应 task、providerID 归因和 Node Ready
   时延均未覆盖；
8. **时钟精度有限。** 分层事件表现为整秒边界，0 秒 Pod 样本表示落在同一秒，
   不表示真实耗时为零；
9. **工作树不是 clean。** 运行基于记录的 commit，并包含第 7 节所述启动修正，
   正式实验前应提交、标记并冻结版本。

## 7. 预检异常与修复

完整冒烟前执行了多次 fail-closed 预检，均未创建 ACK 工作负载：

| 阶段 | 现象 | 处置 |
|---|---|---|
| JSON 配置校验 | 未配置 `RUN_LABELS_JSON` 时，Bash 默认值被解析为非法 JSON | 将默认赋值改为显式的 `'{}'` |
| kube context 校验 | 配置引用的旧 context 已不在 kubeconfig | 切换到 kubeconfig 中唯一且当前选中的 ACK context |
| API Server 指纹校验 | 配置仍保存旧地址 `8.130.169.28` | 只读核验当前 ACK 节点后，更新为 `121.89.86.225` |

修复后，`make smoke-ack-check` 于 2026-07-24 04:10:00Z 通过，并明确报告没有
创建本地服务或集群工作负载；随后才启动完整冒烟。

## 8. 清理与审计状态

主流程完成后已核验：

- Gate-S 结果为 PASS；
- 实验 Namespace `hooke-experiments-scale-20260724t041003z` 已删除；
- 集群运行前后均为原有 2 个 Ready 节点，没有创建新节点；
- controller 和 ingester 日志没有 ERROR、FATAL 或 PANIC；
- MySQL 容器和数据卷按配置保留，便于后续审计；
- 本轮保存 50 个产物文件，约 166 KB。

主要证据：

- [Gate-S 汇总](../../../artifacts/first-smoke-20260724T041003Z/summary.md)
- [最终计算报告](../../../artifacts/first-smoke-20260724T041003Z/report.json)
- [原始事件计数](../../../artifacts/first-smoke-20260724T041003Z/events.tsv)
- [关联轨迹](../../../artifacts/first-smoke-20260724T041003Z/traces.tsv)
- [编排器单调时钟](../../../artifacts/first-smoke-20260724T041003Z/orchestrator-timing.tsv)
- [轨迹质量](../../../artifacts/first-smoke-20260724T041003Z/trace-quality.tsv)
- [Kubernetes 版本](../../../artifacts/first-smoke-20260724T041003Z/kubernetes-version.yaml)
- [controller 日志](../../../artifacts/first-smoke-20260724T041003Z/controller.log)
- [ingester 日志](../../../artifacts/first-smoke-20260724T041003Z/ingester.log)

## 9. 结论与下一步

本轮固定节点冒烟结论为 **PASS**：

- 真实 ACK 事件能够进入本地数据链路；
- 3 次 rollout 和 HTTP 检查全部成功；
- 3/3 条轨迹完整且可追溯；
- 关联、计算、质量 Gate 和清理流程均正常；
- 没有事件顺序错误或服务端 ERROR。

该结果足以证明基础实验链路可用，但不足以支持精确性能结论。建议正式测量前：

1. 将测试镜像固定为不可变 digest，并用 hostname selector 冻结目标节点；
2. 接入 runtime journal/eBPF 和应用源时间，要求 Image、Pod、App 精确覆盖；
3. 将 cold/warm 条件拆分并随机化顺序，增加独立重复；
4. 样本量达到预设统计功效后再报告 p95/p99；
5. 将 Node 扩容作为独立实验启用，接入 GOATScaler task 与 providerID 归因。
