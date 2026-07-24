# Hooke ACK 复现实验指标字典

> 文档版本：v1.0  
> 编制日期：2026-07-18  
> 目标平台：阿里云 ACK，当前以 CPU 阶段为主  
> 配套文件：`hooke_ack_cpu_experiment_plan.md`、`hooke_mysql_schema.sql`  
> 原始论文：*Hooke: Diagnosing and Tuning Elasticity in Heterogeneous Kubernetes Clusters*

---

## 1. 文档目标与边界

本文把复现实验所需指标拆为两类：

1. **原子指标（Atomic Metric / Atomic Event）**：源系统直接产生的时间点、状态、计数或配置快照。采集层只保存原子事实，不在采集时计算 p99、弹性分数或瓶颈结论。
2. **派生指标（Derived Metric）**：由一个或多个原子指标通过确定公式、排序、积分或聚合得到，统一在离线计算阶段生成。

当前主范围包括：

- 控制链路与实验触发；
- Node、Image、Pod、App 四层；
- CPU/内存供需跟踪；
- KEDA scale-to-zero；
- Kueue Gang/部分准入；
- Argo Workflow；
- 采集器质量与开销。

GPU/DRA/MIG 指标放在附录，作为后续独立阶段，不影响 CPU 主链路。

论文的四层兼容口径为：

```text
Node  : 节点供应请求/NodeClaim 创建 → Node Ready
Image : PullImage 开始 → 镜像拉取与解包完成
Pod   : kubelet SyncPod 开始 → Container Started
App   : Container Started → readiness 首次成功
```

ACK 环境中，论文的 `NodeClaimCreated` 替换为 ACK 节点即时弹性的 `ProvisionNode`/provision task 创建时间。现有 Prometheus 直方图可用于分布校验，但论文级逐 Pod 轨迹仍需要事件监听、关联和精确探针。

---

## 2. 采集状态标记


| 等级 | 含义 | 是否需要后续写代码 | 典型例子 |
| --- | --- | --- | --- |
| A0 DIRECT | 已有标准指标端点或 exporter；配置抓取即可 | 否，通常只需 Helm/ServiceMonitor 配置 | kube-state-metrics、kubelet `/metrics`、KEDA `/metrics`、Kueue `/metrics` |
| A1 【需自研适配】 | 官方 API、CR、日志或云 OpenAPI 中存在原子事实，但需要监听、解析、标准化并写入 MySQL | 是 | Pod/Node Condition Watch、ACK GOATScaler 日志解析、ECS 状态轮询、Argo/Kueue CR Watch |
| A2 【需自研探针/埋点】 | 没有通用逐事件时间戳，或已有信号只有聚合值；需 eBPF、CRI 探针、应用埋点或负载器打点 | 是 | containerd Pull 精确起止、kubelet SyncPod、readiness 首次探测成功、Gang barrier |
| A3 DERIVED | 不能采集，必须从原子数据离线计算 | 是，属于 calculator/correlator，而非采集器 | Node/Image/Pod/App 时延、弹性分数、p99、关键路径 |


### 2.1 “直接采集”不等于“论文级精确”

以下两种情况必须区分：

- **已有聚合指标**：例如 `kubelet_image_pull_duration_seconds` 是直方图，只能说明节点上总体拉取分布，不能恢复某个 Pod 的某次拉取。
- **已有对象时间戳**：例如 `kube_pod_status_ready_time` 可以直接抓取，但受 Prometheus 抓取周期、短生命周期 Pod 丢失以及 API 状态同步影响。

因此每个原子指标同时给出：

- **MVP 口径**：两 Worker 冒烟阶段先跑通；
- **论文级口径**：正式复现实验采用的精确来源。

---

## 3. 原子事件公共字段

所有事件进入 `raw_events` 时至少保存以下公共字段。缺少这些字段会导致后续无法可靠关联。


| 字段 | 类型/单位 | 来源 | 用途 |
| --- | --- | --- | --- |
| run_id / run_uuid | 实验运行标识 | experiment-runner；A1【需自研适配】 | 隔离不同重复实验与配置变体 |
| event_code | 受控事件枚举 | 采集器标准化 | 与 `event_type_catalog` 对齐 |
| event_time_ns | UTC Unix epoch ns | 源时间校准后 | 所有时延计算的主时间 |
| source_time_ns | 源时钟原值 | API、日志、eBPF 或应用 | 审计时间转换 |
| observed_time_ns | 采集器看到事件的时间 | 采集器本地时钟 | 计算采集延迟与迟到事件 |
| clock_domain | `apiserver` / `realtime` / `monotonic` | 采集器 | 避免混用单调时钟和墙上时钟 |
| clock_offset_ns | ns | 时间校准模块；A1/A2【需自研】 | eBPF monotonic → UTC 映射 |
| cluster_id | ACK 集群标识 | ACK/配置快照 | 跨集群隔离 |
| namespace / object_kind / object_uid | Kubernetes 标识 | Kubernetes API | 对象级关联 |
| workload_uid / owner_uid | UID | OwnerReferences | Pod → Deployment/Job/Workflow 归属 |
| pod_uid / pod_name | UID/名称 | Pod API | 逐 Pod trace 主键 |
| node_uid / node_name / providerID | UID/名称/云实例映射 | Node API | Node ↔ ECS 关联 |
| container_id / container_name / restart_count | 运行时标识 | Pod status/CRI | 多容器和重启去重 |
| image_ref / image_digest | 镜像引用与 digest | Pod spec/status/containerd | 识别冷/热缓存与镜像版本 |
| resource_version / source_sequence | 版本/序列号 | API Watch 或 agent | 去重、乱序处理 |
| result_code / reason / status_value | 结果 | 源系统 | 失败、重试与条件转换 |
| event_hash | SHA-256 | ingest 端；A1【需自研适配】 | 幂等写入和 Watch 重连去重 |


---

## 4. 工具覆盖总览


| 工具/数据源 | 可直接获得 | 不能直接解决的问题 | 推荐落表 |
| --- | --- | --- | --- |
| Prometheus / ACK Managed Prometheus | 抓取并保存时间序列、直方图、计数器 | 不适合保存逐 Pod 高基数不可变事件；抓取周期会丢短事件 | 聚合留在 Prometheus；必要采样导入 `resource_samples`/`keda_samples` |
| kube-state-metrics | Pod/Node/HPA/Deployment 当前状态与部分 Unix 时间戳 | 不是事件日志；对象删除后指标消失；不能给出 SyncPod、Pull/Unpack 精确时间 | `raw_events` 的 MVP 时间点或旁路校验 |
| kubelet `/metrics` | 镜像拉取、Pod 启动、Pod sandbox、CRI 操作的聚合直方图 | 通常无 Pod UID，不能构造逐 Pod 四层链路 | Prometheus，仅作基线与校验 |
| Kubernetes API Watch | Pod、Node、HPA、Deployment、Event、CRD 的对象转换 | 需要自研 watcher、断线续传、去重和落库 | `raw_events` |
| kubernetes-event-exporter 或 Event API | Pulling/Pulled/FailedScheduling/ProvisionNode 等事件 | Event 可能聚合、过期、重复，不能作为唯一精确事实源 | `raw_events`，标记 `source=event-api` |
| ACK GOATScaler 控制面日志 | 节点即时弹性决策、任务和错误日志 | 需要解析任务 ID 并关联 Pod/ECS/Node | `raw_events`、`node_provision_tasks` |
| ECS/Auto Scaling OpenAPI | 实例 ID、创建时间、生命周期状态、伸缩活动 | 需要轮询/事件订阅和 ACK task 关联 | `node_provision_tasks` |
| containerd metrics | 运行时插件和总体运行状况 | 缺少论文要求的逐 Pod Pull/Unpack 精确链路 | Prometheus，校验用 |
| KEDA `/metrics` | scaler active、metric value、采样延迟、错误 | 请求到达、busy period、首次响应仍不在 KEDA 内 | `keda_samples` |
| Kueue `/metrics` | 准入等待、配额保留等待、ready 等聚合分布 | 无法恢复每个 Workload 成员的逐 Pod 顺序统计量和应用 barrier | Prometheus；CR Watch 进入 MySQL |
| Argo Workflow CR | Workflow/节点 startedAt、finishedAt、phase、DAG 关系 | 真实数据依赖与 artifact 可用时间可能不完整 | `workflow_instances`、`workflow_nodes`、`workflow_edges` |
| OpenTelemetry SDK/Collector | 应用请求、跨度和自定义事件传输 | 仍需在应用/负载器中增加埋点 | `request_events` 或 `raw_events` |
| node-exporter/cAdvisor | 节点和容器 CPU、内存、网络、磁盘使用 | “需求”不等于“使用”；不能替代 requests/desired capacity | `resource_samples`、`collector_health_samples` |


---

## 5. 原子指标字典

### 5.1 实验触发与控制链路


| 事件码 | 原子定义 | 直接工具/来源 | 采集等级 | MySQL | 注意事项 |
| --- | --- | --- | --- | --- | --- |
| RUN_STARTED | 实验运行实际开始 | experiment-runner 写事件 | A1【需自研适配】 | `raw_events` / `experiment_runs` | 必须早于负载触发；保存代码 commit、manifest digest、组件版本 |
| RUN_FINISHED | 实验运行结束或超时 | experiment-runner | A1【需自研适配】 | `raw_events` / `experiment_runs` | 失败实验也必须写结束状态 |
| WORKLOAD_TRIGGERED | 人工 scale、负载器发流、消息生产或 Workflow 提交的起点 | 负载器/实验编排器 | A2【需自研埋点】 | `raw_events` | 端到端时延的统一起点；必须带 request/run/workload ID |
| SCALE_DESIRED_CHANGED | 目标工作负载期望副本数发生变化 | Deployment/Scale API Watch；kube-state-metrics `kube_deployment_spec_replicas` 可旁路采样 | A1【需自研适配】 | `raw_events` / `scale_events` | Prometheus 采样只能近似转换时刻 |
| HPA_DESIRED_CHANGED | HPA status.desiredReplicas 发生变化 | kube-state-metrics `kube_horizontalpodautoscaler_status_desired_replicas`；精确变化用 HPA Watch | A0（采样）+ A1【精确需适配】 | `raw_events` / `scale_events` | 同时保存 currentReplicas、min/max replicas |
| POD_CREATED | Pod metadata.creationTimestamp | kube-state-metrics `kube_pod_created` 或 Pod API | A0；正式建议 A1 Watch | `raw_events` | 短命 Pod 可能在下一次 scrape 前消失 |
| POD_UNSCHEDULABLE | PodScheduled=False 且 reason=Unschedulable 的首次转换 | Pod Condition Watch；Event `FailedScheduling` 可旁路 | A1【需自研适配】 | `raw_events` | 保存 message 中资源/亲和性原因；Event 不作为唯一事实源 |
| POD_SCHEDULED | PodScheduled=True 的 lastTransitionTime | kube-state-metrics `kube_pod_status_scheduled_time` 或 Pod API | A0；正式建议 A1 Watch | `raw_events` | 用于调度等待和 Node 归因边界 |
| POD_BOUND | `spec.nodeName` 首次被设置的观测时间 | Pod Watch | A1【需自研适配】 | `raw_events` | API 没有独立 bind timestamp；以 Watch 观测时间近似，优先使用 POD_SCHEDULED |
| POD_DELETED | Pod deletionTimestamp 或 Delete Watch | Pod API Watch | A1【需自研适配】 | `raw_events` | 用于 partial trace 和失败分类 |


### 5.2 Node 层原子指标

论文兼容主路径：

```text
ACK_PROVISION_TASK_CREATED → NODE_READY
```

ACK 扩展诊断路径：

```text
POD_UNSCHEDULABLE
→ ACK_PROVISION_REQUESTED
→ ACK_PROVISION_TASK_CREATED
→ ECS_INSTANCE_CREATED
→ ECS_INSTANCE_RUNNING
→ NODE_CREATED
→ NODE_READY
```


| 事件/字段 | 原子定义 | 直接工具/来源 | 采集等级 | MySQL | 注意事项 |
| --- | --- | --- | --- | --- | --- |
| ACK_PROVISION_REQUESTED | ACK 为 Pending Pod 发出 ProvisionNode/扩容请求的时间 | Kubernetes Event、ACK GOATScaler 日志 | A1【需自研日志/Event 适配】 | `raw_events` | 保留 provision task ID、Pending Pod UID 列表、节点池和实例规格候选 |
| ACK_PROVISION_TASK_CREATED | ACK 节点供应任务建立时间 | ACK GOATScaler 控制面日志/任务标识 | A1【需自研适配】 | `raw_events` / `node_provision_tasks` | 作为 ACK 下的论文兼容 Node 起点 |
| ACK_PROVISION_FAILED | 供应任务失败、超时或无库存 | GOATScaler 日志、ACK Event | A1【需自研适配】 | `raw_events` / `node_provision_tasks` | 失败样本不能静默删除 |
| ECS_INSTANCE_CREATED | ECS 实例对象创建时间 | ECS/Auto Scaling OpenAPI 或伸缩活动 | A1【需自研 OpenAPI 适配】 | `raw_events` / `node_provision_tasks` | 用 instance ID 与 Node providerID 关联 |
| ECS_INSTANCE_RUNNING | ECS 生命周期进入 Running | ECS DescribeInstances/伸缩活动 | A1【需自研轮询或事件订阅】 | `raw_events` / `node_provision_tasks` | Running 不等于 Kubernetes Ready |
| NODE_CREATED | Kubernetes Node metadata.creationTimestamp | kube-state-metrics `kube_node_created` 或 Node API | A0；正式建议 A1 Watch | `raw_events` / `node_provision_tasks` | 保存 Node UID、providerID、zone、instance type |
| NODE_READY | Node Ready Condition 首次变为 True 的 lastTransitionTime | Node API Watch；`kube_node_status_condition` 只能给当前状态 | A1【需自研适配】 | `raw_events` / `node_provision_tasks` | Node 层终点；按 Node UID 去重 |
| NODE_NOT_READY | Node Ready=False/Unknown 的转换 | Node API Watch | A1【需自研适配】 | `raw_events` | 用于节点故障、抖动和实验排除 |
| NODE_DELETED | Node 删除事件 | Node API Watch | A1【需自研适配】 | `raw_events` | 计算缩容和资源供给变化 |
| node_allocatable_cpu/memory | Node 可分配 CPU 核和内存字节 | kube-state-metrics `kube_node_status_allocatable` | A0 DIRECT | `resource_samples` | 需要结合 Ready、unschedulable、taint 才能形成有效供给 |
| node_labels/taints/zone/instance_type | 节点池与调度属性快照 | Node API、kube-state-metrics info/labels | A0/A1 | `run_objects` / `resource_samples` | 正式实验每次 run 保存配置快照 |
| trigger_pending_pod_set | 一个 ACK provision task 对应的触发 Pending Pod UID 集合 | 不存在完整标准指标；由 GOATScaler 信息、Pending 快照与最终调度联合恢复 | A2【需自研关联逻辑】 | `node_provision_task_pods` | Node 归因的关键输入 |


### 5.3 Image 层原子指标

现成 kubelet 指标可以直接用于总体校验：

- `kubelet_image_manager_ensure_image_requests_total`
- `kubelet_image_pull_duration_seconds`

它们是聚合计数器/直方图，不能替代逐 Pod 的 `IMAGE_PULL_START` 与 `IMAGE_UNPACK_END`。


| 事件/字段 | 原子定义 | 直接工具/来源 | 采集等级 | MySQL | 注意事项 |
| --- | --- | --- | --- | --- | --- |
| IMAGE_ENSURE_REQUEST | kubelet/runtime 开始确认镜像是否存在 | 聚合：`kubelet_image_manager_ensure_image_requests_total` | A0 聚合；逐 Pod 为 A2【需自研探针】 | `raw_events` / `image_operations` | 聚合指标含 `present_locally`、`pull_required` 等标签，但无 Pod UID |
| IMAGE_CACHE_HIT | 目标 digest 在目标 Node 上已可用，无需网络拉取 | 聚合标签 `present_locally`；containerd image/content metadata | A0 聚合；逐 Pod 为 A2【需自研 agent】 | `raw_events` / `image_operations` | 缺少 Pull 事件不自动等价于缓存命中，必须显式判定 |
| IMAGE_PULL_START | containerd 对该镜像执行 Pull 的入口时间 | 近似：Kubernetes Event `Pulling`；精确：containerd uprobe/插件/CRI 代理 | A0/A1 近似；A2【论文级需自研探针】 | `raw_events` / `image_operations` | 论文 Image 层起点 |
| IMAGE_DOWNLOAD_END | 镜像所有需要下载的 blob 完成 | 通常无标准逐 Pod 指标 | A2【需自研 containerd 探针】 | `raw_events` / `image_operations` | 可选细分，不是计算 R_image 的必需项 |
| IMAGE_UNPACK_START | 开始解压/展开镜像层 | 通常无标准逐 Pod指标 | A2【需自研 containerd 探针】 | `raw_events` / `image_operations` | 用于区分网络与本地磁盘瓶颈 |
| IMAGE_UNPACK_END | 最后需要的镜像层完成解包，Pull 返回成功 | 近似：Event `Pulled`；精确：containerd Pull return/解包探针 | A1 近似；A2【论文级需自研探针】 | `raw_events` / `image_operations` | 论文 Image 层终点 |
| IMAGE_READY | 运行时确认镜像可用于 CreateContainer | CRI/runtime result | A2【需自研 CRI/containerd 适配】 | `raw_events` / `image_operations` | 可用于检测 Pull return 到可创建容器的间隙 |
| IMAGE_PULL_FAILED | 拉取/认证/解包失败 | Event `Failed`、Pod waiting reason、containerd 日志 | A1【需自研事件/日志适配】 | `raw_events` / `image_operations` | 保存错误码、重试次数、registry host |
| image_ref / image_digest | 镜像名和不可变 digest | Pod spec/status、containerd metadata | A1【需标准化适配】 | `raw_events` / `image_operations` | 实验比较必须以 digest 而不是 tag 为准 |
| image_size_bytes | 镜像总大小或本次下载字节 | kubelet pull histogram 的 size label、registry/containerd metadata | A0 聚合/A1 元数据适配 | `image_operations` | 明确是压缩下载大小还是解包后大小 |
| concurrent_pull_count | 同一 Node 在 Pull 开始时的活跃拉取数 | 没有通用逐事件指标 | A2【需自研 agent 计数】 | `image_operations.attributes_json` | 用于识别 thundering herd 与层间相关性 |


### 5.4 Pod 层原子指标

现成 kubelet 指标可直接抓取但均为聚合分布，主要包括：

- `kubelet_pod_start_duration_seconds`
- `kubelet_pod_start_sli_duration_seconds`
- `kubelet_pod_start_total_duration_seconds`
- `kubelet_pod_worker_start_duration_seconds`
- `kubelet_pod_worker_duration_seconds`
- `kubelet_run_podsandbox_duration_seconds`
- `kubelet_runtime_operations_duration_seconds`
- `kubelet_pod_status_sync_duration_seconds`


| 事件/字段 | 原子定义 | 直接工具/来源 | 采集等级 | MySQL | 注意事项 |
| --- | --- | --- | --- | --- | --- |
| POD_SCHEDULED | PodScheduled=True 时间 | kube-state-metrics `kube_pod_status_scheduled_time` 或 Pod API | A0/A1 | `raw_events` | 控制/调度分段使用；不是论文 Pod 起点 |
| SYNC_POD_START | kubelet `SyncPod` 本次创建路径开始 | 没有逐 Pod 标准指标；`kubelet_pod_worker_duration_seconds` 只有聚合 | A2【需自研 kubelet eBPF uprobe】 | `raw_events` / `pod_traces` | 论文 Pod 层起点；需记录 kubelet build-id |
| POD_SANDBOX_START | CRI RunPodSandbox 调用开始 | 聚合：`kubelet_run_podsandbox_duration_seconds` | A0 聚合；逐 Pod A2【需自研 CRI 探针】 | `raw_events` | 可选子阶段 |
| POD_SANDBOX_READY | RunPodSandbox 成功返回 | 同上 | A2【需自研 CRI 探针】 | `raw_events` | 与 CNI 初始化相关 |
| CONTAINER_CREATE_START | CRI CreateContainer 调用开始 | 无标准逐 Pod 时间 | A2【需自研 CRI/eBPF 探针】 | `raw_events` | 多容器时每个 container 单独记录 |
| CONTAINER_CREATED | 容器创建完成 | CRI/runtime result | A2【需自研探针】 | `raw_events` | 保存 container ID |
| CONTAINER_START_CALL | CRI StartContainer 调用开始 | 无标准逐 Pod 时间 | A2【需自研 CRI/eBPF 探针】 | `raw_events` | 可拆出 start RPC 自身时延 |
| CONTAINER_STARTED | 容器进入 Running，记录 startedAt | kube-state-metrics `kube_pod_container_state_started` 或 Pod status；精确可用 CRI return | A0 MVP；A1 Watch；A2 精确探针 | `raw_events` / `pod_traces` | 论文 Pod 层终点；必须带 restart_count |
| container_restart_count | 容器重启次数 | kube-state-metrics `kube_pod_container_status_restarts_total` | A0 DIRECT | `pod_traces` / `raw_events` | 每次 restart 视为不同 attempt |
| pod_initialized_time | Pod Initialized 条件时间 | kube-state-metrics `kube_pod_status_initialized_time` | A0 DIRECT | `raw_events`（可选） | 用于分离 init container 时间 |
| pod_status_reported_time | kubelet 状态变化成功写入 API 的时间 | 只有聚合 `kubelet_pod_status_sync_duration_seconds`；逐 Pod需探针/Watch | A0 聚合；A2【逐 Pod需自研】 | `raw_events`（可选） | 用于量化 API 状态可见性延迟 |


### 5.5 App 层原子指标


| 事件/字段 | 原子定义 | 直接工具/来源 | 采集等级 | MySQL | 注意事项 |
| --- | --- | --- | --- | --- | --- |
| READINESS_PROBE_FIRST_SUCCESS | kubelet 对主容器 readiness probe 的第一次成功 | MVP：kube-state-metrics `kube_pod_status_ready_time`；精确：应用/probe sidecar/kubelet 探针 | A0 MVP；A2【论文级需自研埋点/探针】 | `raw_events` / `pod_traces` | 论文 App 层终点；Pod Ready 时间可能晚于探针实际成功 |
| POD_READY | Pod Ready Condition 首次变为 True | kube-state-metrics `kube_pod_status_ready_time` 或 Pod Watch | A0/A1 | `raw_events` / `pod_traces` | 作为 MVP 和 API 同步延迟校验 |
| APP_WARMUP_FINISHED | 应用内部初始化、模型/配置/缓存加载完成 | 应用日志或 OpenTelemetry 自定义事件 | A2【需自研应用埋点】 | `raw_events` | 不同应用需定义稳定语义 |
| FIRST_REQUEST_RECEIVED | 新实例收到首个业务请求 | 应用/sidecar/OpenTelemetry | A2【需自研应用埋点】 | `raw_events` / `request_events` | 需带 request ID 与 pod UID |
| FIRST_RESPONSE_SUCCESS | 新实例或一次唤醒后的首个成功业务响应 | 负载发生器与应用双端打点 | A2【需自研负载器/应用埋点】 | `raw_events` / `request_events` | 真实可服务口径，建议与 readiness 同时报告 |
| USEFUL_WORK_STARTED | Batch/Gang/Workflow 真正开始有效计算 | 应用、MPI/训练框架、测试 worker | A2【需自研应用埋点】 | `raw_events` | 避免把 Ready 当作业务真正开始 |
| readiness_config | initialDelaySeconds、periodSeconds、timeoutSeconds、successThreshold | Pod spec 快照 | A1【需自研配置快照】 | `run_objects` | readiness 周期会量化 App 层误差 |


### 5.6 资源供给与需求原子采样

资源跟踪必须采样原始 `S_i(t)` 与 `W_i(t)`，不能只存最后的 `H_i`。


| 原子采样 | 定义 | 直接工具/来源 | 采集等级 | MySQL | 注意事项 |
| --- | --- | --- | --- | --- | --- |
| node_allocatable_cpu_cores | 每个有效 Ready 节点的 allocatable CPU | kube-state-metrics `kube_node_status_allocatable{resource="cpu"}` | A0 DIRECT | `resource_samples` | 排除 NotReady、cordoned、实验不适用节点 |
| node_allocatable_memory_bytes | 每个有效 Ready 节点的 allocatable memory | 同上，resource=memory | A0 DIRECT | `resource_samples` | 统一字节单位 |
| pod_requested_cpu_cores | Pod/容器 requests.cpu | kube-state-metrics `kube_pod_container_resource_requests`；可选 scheduler `kube_pod_resource_requests` | A0 DIRECT | `resource_samples` | 按 Pod phase/owner 过滤，避免重复 init container 语义错误 |
| pod_requested_memory_bytes | Pod/容器 requests.memory | 同上 | A0 DIRECT | `resource_samples` | 统一字节单位 |
| desired_replicas | Deployment/HPA/KEDA 当前目标副本 | kube-state-metrics HPA/Deployment 指标 | A0 DIRECT | `resource_samples` | 需求模型需明确用 desired 还是实际已创建 Pod requests |
| ready_replicas | 工作负载 Ready 副本数 | 例如 `kube_deployment_status_replicas_ready` | A0 DIRECT | `resource_samples` | 服务容量估计 |
| pending_pod_requests | 所有待调度 Pod 的 requests | Pod API/KSM 状态与 requests 联合 | A0 + 离线 join | `resource_samples` | 需要按 run/workload 过滤 |
| queued_kueue_requests | 尚未创建 Pod 的 Kueue Workload 请求资源 | Kueue Workload spec.podSets | A1【需自研 CR 适配】 | `resource_samples` | 否则会低估排队需求 |
| cpu_usage_cores | 实际 CPU 使用 | cAdvisor/kubelet resource metrics/node-exporter | A0 DIRECT | `resource_samples` | 用于诊断，不替代需求 W |
| memory_working_set_bytes | 实际内存工作集 | cAdvisor/kubelet resource metrics | A0 DIRECT | `resource_samples` | 用于诊断，不替代 requests |
| network_demand | 业务期望网络吞吐/请求率 | 无统一 Kubernetes requests 语义 | A2【需自研业务定义与采样】 | `resource_samples` | 当前 CPU MVP 可先不计算 net 的 H |
| io_demand | 业务期望 IOPS/吞吐 | 无统一 Kubernetes requests 语义 | A2【需自研业务定义与采样】 | `resource_samples` | 当前 CPU MVP 可先不计算 io 的 H |


### 5.7 KEDA 原子指标

KEDA Operator 的标准 Prometheus 指标可直接抓取，包括：

- `keda_scaler_active`
- `keda_scaler_metrics_value`
- `keda_scaler_metrics_latency_seconds`
- `keda_scaler_detail_errors_total`
- `keda_scaled_object_errors_total`
- `keda_internal_scale_loop_latency_seconds`


| 事件/字段 | 原子定义 | 直接工具/来源 | 采集等级 | MySQL | 注意事项 |
| --- | --- | --- | --- | --- | --- |
| ScaledObject 配置快照 | pollingInterval、cooldownPeriod、min/maxReplicaCount、trigger threshold | KEDA ScaledObject CR | A1【E04 已实现 artifact 快照】 | `run_objects` / `keda_samples` | 每次 run 保存，禁止只依赖当前线上配置 |
| KEDA_SCALER_SAMPLE | 某次抓取时的 scaler metric value | external metrics API；可用 `keda_scaler_metrics_value` 交叉校验 | A0/A1【E04 轮询已实现】 | `keda_samples` | API/Prometheus 抓取时间是观察时间，不一定等于内部采样精确时间 |
| KEDA_SCALEDOBJECT_ACTIVE/INACTIVE | scaler active 0↔1 的转换 | ScaledObject condition Watch | A1【E04 已实现】 | `raw_events` / `keda_samples` | 保存 ScaledObject、目标 workload 和 condition transition time；缺失时标 approximate |
| KEDA scaler latency | 拉取上游指标耗时 | `keda_scaler_metrics_latency_seconds` | A0 DIRECT | `keda_samples` | 用于解释控制器延迟，不参与冷启动公式的 μs |
| KEDA errors | scaler/ScaledObject 错误计数 | KEDA error metrics | A0 DIRECT | `keda_samples` | 错误 run 单独分类 |
| HPA desired/current replicas | KEDA 生成的 HPA 副本目标/现状 | kube-state-metrics HPA metrics | A0 DIRECT | `keda_samples` / `resource_samples` | 结合变化检测生成 HPA_DESIRED_CHANGED |
| MESSAGE_ENQUEUED | 消息成功进入系统的时间 | E04 Redis producer 在 `RPUSH` 成功后打点 | A2【E04 已实现】 | `request_events` / `raw_events` | 计算 λ 的基础；仅有 queue depth 不足以恢复到达过程 |
| QUEUE_DEPTH_SAMPLE | 队列长度/lag 的时间序列 | E04 应用 `LLEN`；正式环境也可用官方 exporter | A0/A2【E04 已实现】 | `keda_samples` / `resource_samples` | 用于 busy period 边界与校验 |
| MESSAGE_DEQUEUED | 消息被 worker 成功取出 | E04 worker 在 `BLPOP` 成功后打点 | A2【E04 已实现】 | `request_events` | 计算排队等待 |
| MESSAGE_PROCESSING_STARTED/MESSAGE_PROCESSED | 请求处理起止 | E04 worker 应用打点 | A2【E04 已实现】 | `request_events` | 区分启动延迟和业务处理时间 |
| KEDA_SCALE_TO_ZERO | 目标副本首次降为 0 | Deployment API Watch | A1【E04 已实现】 | `raw_events` / `scale_events` | busy period 和 dormant 区间的边界 |


### 5.8 Kueue/Gang 原子指标

Kueue 标准 Prometheus 指标可用于聚合校验，例如：

- `kueue_quota_reserved_wait_time_seconds`
- `kueue_admission_wait_time_seconds`
- `kueue_admission_checks_wait_time_seconds`
- `kueue_admitted_until_ready_wait_time_seconds`
- `kueue_ready_wait_time_seconds`
- `kueue_admitted_workloads_total`
- `kueue_evicted_workloads_total`

逐 Workload 的 k-th Pod 与 barrier 仍需 CR Watch 和应用事件。


| 事件/字段 | 原子定义 | 直接工具/来源 | 采集等级 | MySQL | 注意事项 |
| --- | --- | --- | --- | --- | --- |
| KUEUE_WORKLOAD_CREATED | Workload metadata.creationTimestamp | Kueue Workload CR | A1【需自研 CR Watch】 | `raw_events` / `kueue_workload_instances` | Job 与 Workload UID 都要保存 |
| KUEUE_QUOTA_RESERVED | QuotaReserved Condition=True 的转换时间 | Kueue Workload status.conditions | A1【需自研 CR Watch】 | `raw_events` / `kueue_workload_instances` | 聚合直方图仅作校验 |
| KUEUE_ADMITTED | Admitted Condition=True 的转换时间 | Kueue Workload status.conditions | A1【需自研 CR Watch】 | `raw_events` / `kueue_workload_instances` | Gang launch 的推荐参考起点 |
| KUEUE_PODS_READY | Workload PodsReady=True 的转换时间 | Kueue Workload status.conditions | A1【需自研 CR Watch】 | `raw_events` / `kueue_workload_instances` | 不等价于应用 barrier 已释放 |
| KUEUE_FINISHED | Workload Finished=True 或所属 Job 完成 | Kueue/Job API | A1【需自研适配】 | `raw_events` / `kueue_workload_instances` | 失败和成功分别保存 |
| n_requested | Workload 请求的总 Pod 数 | Workload spec.podSets[].count | A1【需自研配置解析】 | `kueue_workload_instances` | 多 PodSet 需记录每个角色 |
| k_min_count | 允许开始的最小成员数/部分准入下限 | Workload/Job 配置 | A1【需自研配置解析】 | `kueue_workload_instances` | 字段位置随 Kueue 版本/集成变化，必须锁版本 |
| k_admitted | 本次实际获准的成员数 | Workload status.admission/podSet assignments | A1【需自研 CR 适配】 | `kueue_workload_instances` | 不能用配置 k 代替实际准入数 |
| gang member POD_CREATED/STARTED/READY | 每个成员的生命周期时间 | 公共 Pod 原子事件 | A0/A1/A2，取决于精度 | `gang_members` | 按 PodSet/worker rank 保存 |
| GANG_BARRIER_ENTER | 成员进入应用同步屏障 | 测试 worker/MPI/训练框架 | A2【需自研应用埋点】 | `raw_events` / `gang_members` | 每个 member 一条 |
| GANG_BARRIER_RELEASE | 屏障释放 | 应用协调器/leader | A2【需自研应用埋点】 | `raw_events` / `gang_members` | 计算 barrier duration 和 η(n) |
| USEFUL_WORK_STARTED | Gang 达到可进行有效并行工作的时间 | 应用 | A2【需自研应用埋点】 | `raw_events` / `kueue_workload_instances` | 部分准入实验的真实终点 |


### 5.9 Argo Workflow 原子指标


| 事件/字段 | 原子定义 | 直接工具/来源 | 采集等级 | MySQL | 注意事项 |
| --- | --- | --- | --- | --- | --- |
| ARGO_WORKFLOW_CREATED | Workflow metadata.creationTimestamp | Argo Workflow CR | A1【需自研 CR Watch】 | `raw_events` / `workflow_instances` | 保存 Workflow UID 和模板版本 |
| ARGO_WORKFLOW_STARTED | Workflow status.startedAt | Argo Workflow CR | A1【需自研 CR Watch】 | `raw_events` / `workflow_instances` | 控制器排队时间可由 created→started 计算 |
| ARGO_NODE_STARTED | 每个 Argo node status.startedAt | Workflow status.nodes | A1【需自研解析】 | `raw_events` / `workflow_nodes` | node ID、type、templateName、retry index 必须保存 |
| ARGO_NODE_FINISHED | 每个 Argo node status.finishedAt | Workflow status.nodes | A1【需自研解析】 | `raw_events` / `workflow_nodes` | 保存 phase、message、exit/result |
| ARGO_WORKFLOW_FINISHED | Workflow status.finishedAt | Argo Workflow CR | A1【需自研 CR Watch】 | `raw_events` / `workflow_instances` | 成功、失败、Error 均保留 |
| workflow DAG edges | 显式 depends/dependencies/children/outboundNodes 关系 | Workflow spec + status.nodes | A1【需自研 DAG 解析】 | `workflow_edges` | 用于拓扑排序和关键路径 |
| artifact_input_ready | 阶段所需输入实际可读时间 | 对象存储/应用/Argo artifact 事件 | A2【按业务需自研】 | `raw_events` / `workflow_nodes` | 只解析 YAML 可能漏掉隐式依赖 |
| artifact_output_ready | 阶段输出实际可被下游读取时间 | 应用/对象存储 | A2【按业务需自研】 | `raw_events` / `workflow_nodes` | 用于判断真数据依赖 |
| true_dependency_annotation | 业务确认两阶段是否存在真实数据/副作用依赖 | 实验 manifest 人工注解 | A1【需自研配置约定】 | `workflow_edges` | 调优器不得自动猜测业务正确性 |


### 5.10 采集质量与开销原子指标


| 原子指标/事件 | 定义 | 直接工具/来源 | 采集等级 | MySQL | 注意事项 |
| --- | --- | --- | --- | --- | --- |
| collector_cpu_seconds_total | 采集器 CPU 累计秒数 | cAdvisor/Prometheus `container_cpu_usage_seconds_total` | A0 DIRECT | `collector_health_samples` | 按 controller、agent、ingest、calculator 分开 |
| collector_memory_working_set_bytes | 采集器内存工作集 | cAdvisor/Prometheus | A0 DIRECT | `collector_health_samples` | 每节点 agent 与控制面组件分开 |
| events_observed_total | 采集器收到的原始事件总数 | collector 自暴露 Prometheus counter | A1【需自研 collector 指标】 | `collector_health_samples` | 按 source/event_code 维度控制基数 |
| events_persisted_total | 成功写入 MySQL 的事件数 | ingest 自定义 counter | A1【需自研】 | `collector_health_samples` | 与 observed 差异用于检测丢失 |
| events_deduplicated_total | 因 event_hash 重复被丢弃的数量 | ingest | A1【需自研】 | `collector_health_samples` | Watch 重连时预期会出现少量 |
| BPF_EVENT_LOST | ring buffer reserve/submit 或用户态消费丢失 | BPF/agent 自定义 counter | A2【需自研 eBPF agent】 | `raw_events` / `collector_health_samples` | 必须按 Node 和探针类型记录 |
| WATCH_RECONNECTED | API Watch 重连 | controller/watcher | A1【需自研】 | `raw_events` / `collector_health_samples` | 保存上次 resourceVersion 与重连原因 |
| INGEST_BATCH_FAILED | 批量写 MySQL 失败 | ingest | A1【需自研】 | `raw_events` / `collector_health_samples` | 记录重试次数、错误码和队列深度 |
| export_queue_depth | agent/controller 等待发送的事件数 | 自定义 Prometheus gauge | A1/A2【需自研】 | `collector_health_samples` | 检测采集背压 |
| clock_offset_ns | 节点时间相对标准源偏移 | node-exporter timex/chrony + agent 映射 | A0 系统级；A2 事件级映射 | `collector_health_samples` | 论文级 eBPF 时间转换必需 |
| mysql_insert_latency_seconds | 批写数据库耗时 | ingest 自定义 histogram | A1【需自研】 | `collector_health_samples` | 只做采集系统健康，不参与业务时延 |


---

## 6. 派生指标字典

所有公式统一使用秒。原始时间戳保存为纳秒，计算时：

```text
seconds = (end_time_ns - start_time_ns) / 1e9
```

负数时延不能取绝对值修复，必须标记为时间顺序错误并排除或回查源数据。

### 6.1 单次轨迹的分段时延


| 派生指标 | 公式 | 所需原子指标 | 解释 |
| --- | --- | --- | --- |
| control_reaction_latency | `SCALE_DESIRED_CHANGED - WORKLOAD_TRIGGERED` | WORKLOAD_TRIGGERED、SCALE_DESIRED_CHANGED | 控制/实验编排响应 |
| hpa_reaction_latency | `HPA_DESIRED_CHANGED - REQUEST_ARRIVED` 或 scaler active` | REQUEST_ARRIVED/KEDA_ACTIVE_CHANGED、HPA_DESIRED_CHANGED | KEDA/HPA 控制链路 |
| pod_creation_latency | `POD_CREATED - SCALE_DESIRED_CHANGED` | SCALE_DESIRED_CHANGED、POD_CREATED | 控制器创建 Pod 的时间 |
| scheduler_wait_latency | `POD_SCHEDULED - POD_CREATED` | POD_CREATED、POD_SCHEDULED | 包含无资源等待；另报告 Unschedulable 子段 |
| unschedulable_to_provision_latency | `ACK_PROVISION_TASK_CREATED - POD_UNSCHEDULABLE` | POD_UNSCHEDULABLE、ACK_PROVISION_TASK_CREATED | ACK 扩容决策延迟 |
| node_provision_latency（论文兼容） | `NODE_READY - ACK_PROVISION_TASK_CREATED` | ACK_PROVISION_TASK_CREATED、NODE_READY | R_node |
| node_trigger_to_ready_latency（ACK 扩展） | `NODE_READY - first(POD_UNSCHEDULABLE in task)` | 触发 Pod 集、NODE_READY | 用户感知的完整节点等待 |
| ecs_create_latency | `ECS_INSTANCE_CREATED - ACK_PROVISION_TASK_CREATED` | ACK task、ECS created | 云 API 接单/实例建立 |
| ecs_boot_latency | `ECS_INSTANCE_RUNNING - ECS_INSTANCE_CREATED` | ECS created/running | 实例启动 |
| node_registration_latency | `NODE_CREATED - ECS_INSTANCE_RUNNING` | ECS running、Node created | OS/agent/kubelet 注册 |
| node_ready_after_registration | `NODE_READY - NODE_CREATED` | Node created/ready | kubelet/CNI/节点初始化 |
| image_latency（论文兼容） | `IMAGE_UNPACK_END - IMAGE_PULL_START` | IMAGE_PULL_START、IMAGE_UNPACK_END | R_image |
| image_download_latency | `IMAGE_DOWNLOAD_END - IMAGE_PULL_START` | Pull start、download end | 网络/registry 子阶段 |
| image_unpack_latency | `IMAGE_UNPACK_END - IMAGE_UNPACK_START` | unpack start/end | 本地 CPU/磁盘子阶段 |
| pod_latency（论文兼容） | `CONTAINER_STARTED - SYNC_POD_START` | SYNC_POD_START、CONTAINER_STARTED | R_pod |
| pod_latency_mvp | `CONTAINER_STARTED - POD_SCHEDULED` | POD_SCHEDULED、CONTAINER_STARTED | 仅冒烟近似；不得标成论文 R_pod |
| sandbox_latency | `POD_SANDBOX_READY - POD_SANDBOX_START` | sandbox start/ready | CRI/CNI 子阶段 |
| container_create_latency | `CONTAINER_CREATED - CONTAINER_CREATE_START` | container create start/end | 容器创建子阶段 |
| container_start_rpc_latency | `CONTAINER_STARTED - CONTAINER_START_CALL` | StartContainer call、started | 启动 RPC 子阶段 |
| app_latency（论文兼容） | `READINESS_PROBE_FIRST_SUCCESS - CONTAINER_STARTED` | CONTAINER_STARTED、READINESS_PROBE_FIRST_SUCCESS | R_app |
| app_latency_mvp | `POD_READY - CONTAINER_STARTED` | CONTAINER_STARTED、POD_READY | API 状态近似 |
| service_ready_latency | `FIRST_RESPONSE_SUCCESS - CONTAINER_STARTED` | CONTAINER_STARTED、FIRST_RESPONSE_SUCCESS | 真实业务可服务 |
| readiness_visibility_lag | `POD_READY - READINESS_PROBE_FIRST_SUCCESS` | 精确 probe 成功、Pod Ready | kubelet/API 状态同步延迟 |
| request_queue_latency | `REQUEST_DEQUEUED - REQUEST_ARRIVED` | request arrived/dequeued | KEDA/队列实验 |
| request_processing_latency | `REQUEST_PROCESSING_FINISHED - REQUEST_PROCESSING_STARTED` | 处理起止 | 避免把业务计算混入冷启动 |
| scale_out_ready_latency | `target_replicas_ready_time - WORKLOAD_TRIGGERED` | 触发、目标第 N 个 Ready | 端到端 Ready 口径 |
| scale_out_response_latency | `FIRST_RESPONSE_SUCCESS - REQUEST_ARRIVED` | 首请求到达、首成功响应 | 端到端用户口径 |
| unattributed_latency | `R_e2e - Σ(已定义且顺序不重叠的子段)` | 完整端到端与所有子段 | 发现漏采控制器/队列/同步阶段 |


#### 适用层与缺失层处理

- Pod 落到已有节点时，Node 层为 `not_applicable`，不是 0 秒采集值。
- 镜像缓存命中时，Image 层为 `not_applicable/cache_hit`，在弹性乘积中按中性因子 1 处理，但必须单独报告命中比例。
- 应发生却缺失开始或结束事件时，标记 `event_missing`，不得按 0 秒参与计算。
- 失败、超时、Pod 被删除分别保存，不与成功样本混在一起。

### 6.2 分布统计


| 派生指标 | 公式/算法 | 原子输入 | 说明 |
| --- | --- | --- | --- |
| sample_count | `N = count(valid samples)` | 任一原始时延样本 | 所有统计必须同时报告 N |
| mean_latency | `ΣR_i / N` | R_i | 均值 |
| p50/p95/p99 | `quantile(R, 0.50/0.95/0.99)` | R_i | 使用同一明确的 quantile 实现；p99 建议 N≥100，最好 300+ |
| CDF | `F(r)=count(R_i≤r)/N` | R_i | 比较调优前后整体分布 |
| bootstrap_ci | 对 run/trace 有放回重采样后取统计量 2.5%/97.5% 分位 | 原始样本、随机种子 | 建议 1,000–10,000 次；保存算法版本 |
| failure_rate | `failed_attempts / all_attempts` | 成功/失败终态事件 | 不能只分析成功路径 |


### 6.3 Node 供应归因

一个 ACK 扩容任务可能由多个工作负载的 Pending Pod 共同触发。设：

- 任务供应时延为 `t = NODE_READY - ACK_PROVISION_TASK_CREATED`；
- 触发 Pod 总数为 `m`；
- 工作负载 `w` 在触发集合中有 `n_w` 个 Pod。

则工作负载的 Node 时延分摊为：

```text
node_charge(w) = t × n_w / m
```

每个 Pod 的等比例 charge 为：

```text
node_charge(pod) = t / m
```


| 派生指标 | 公式 | 原子输入 | 验收 |
| --- | --- | --- | --- |
| node_charge_per_workload | `R_node_task × n_w / m` | task 起止、trigger_pending_pod_set、owner UID | 所有 workload charge 加总等于 task latency |
| node_attribution_additivity_error | `Σcharge_w - R_node_task` | 归因结果、task latency | 应在浮点容差内为 0 |
| task_to_pod_association_rate | `已关联触发 Pod 数 / 应关联触发 Pod 数` | ACK task 与 Pending Pod 集 | 正式实验建议 ≥98% |


### 6.4 层弹性、端到端弹性与瓶颈

设工作负载 SLO 时间预算为 `B` 秒，论文中的 `γ = 1/B`。某层有有效时延样本 `R_l^(1)...R_l^(N)`。

#### 层弹性

```text
E_l = (1/N) × Σ exp(-R_l^(i) / B)
```

#### 直接测得的端到端弹性

```text
E_e2e_measured = (1/N) × Σ exp(-R_e2e^(i) / B)
```

#### 独立层假设下的乘积

```text
E_e2e_product = Π_l E_l
composition_error = |E_e2e_measured - E_e2e_product|
```

只对同一 SLO class、同一实验变体和相同适用层集合的样本进行乘积比较。


| 派生指标 | 公式 | 所需原子/中间指标 | 说明 |
| --- | --- | --- | --- |
| layer_elasticity | `mean(exp(-R_l/B))` | 层时延样本、slo_seconds | 范围 (0,1]；失败样本的处理策略需版本化 |
| end_to_end_elasticity_measured | `mean(exp(-R_e2e/B))` | 端到端时延、SLO | 主要结果 |
| end_to_end_elasticity_product | `Π E_l` | 适用层弹性 | 检验层独立/乘法组合 |
| composition_absolute_error | `abs(E_measured-E_product)` | 两种总弹性 | 层相关性高时可能增大 |
| latency_share_w_l | `Σ_i R_l,i / Σ_i Σ_q R_q,i` | 完整且相同适用层的 trace | 各层份额加总为 1 |
| bottleneck_score | `w_l / E_l` | latency share、layer elasticity | 分数最大层优先优化 |
| elasticity_gain_ratio | `E_after / E_before` | 配对变体弹性 | 同时报告绝对增益 `E_after-E_before` |
| p99_reduction | `p99_before - p99_after` | 调优前后时延样本 | 秒与百分比都报告 |


### 6.5 供需跟踪分数与 Elasticity Profile

对资源 `i`，保存离散采样点 `(t_j, S_i(t_j), W_i(t_j))`。使用梯形或分段常数积分，算法必须固定版本。

```text
H_i_raw = 1 - [Σ |S_i(t_j)-W_i(t_j)| × Δt_j]
                / [Σ W_i(t_j) × Δt_j]
```

当分母为 0 时，该窗口无有效需求，结果记为 `NULL/not_applicable`，不得直接记 1。

论文将 Profile 写成：

```text
E_profile(i,g,m) = H_i × Π E_l
```

其中：

- `i`：cpu、memory；GPU/io/net 后续按可用数据扩展；
- `g`：pod、job、workflow；
- `m`：standard、scale-to-zero、mig。

`H_i_raw` 可能小于 0。建议数据库保留 raw 值，展示层另生成：

```text
H_i_display = min(1, max(0, H_i_raw))
```

不得覆盖 raw 值。


| 派生指标 | 公式/构造 | 原子输入 | 说明 |
| --- | --- | --- | --- |
| supply_capacity_S_cpu | 对所有 Ready、可调度、属于目标池的 Node allocatable CPU 求和 | Node Ready/cordon/taint、allocatable | 按固定采样间隔构造 |
| demand_capacity_W_cpu | 实验定义的目标需求：desired replicas × 单 Pod requests，或队列/Workload requests | desired、Pod/Workload requests | 必须在 protocol 中选择一个需求定义 |
| supply_demand_tracking_H | 上式积分 | S_i(t)、W_i(t) | 同时报告过供给与欠供给积分 |
| under_provision_area | `Σ max(W-S,0)Δt` | S、W | 欠供给损失 |
| over_provision_area | `Σ max(S-W,0)Δt` | S、W | 空闲成本 |
| elasticity_profile_score | `H_i_raw × ΠE_l` | H_i、适用层弹性 | 按 resource/granularity/mode 分 cell |


### 6.6 KEDA Rule 2 派生指标

#### 到达率

```text
λ = N_arrivals / observation_seconds
```

同时可报告平均到达间隔：

```text
mean_interarrival = mean(REQUEST_ARRIVED[i] - REQUEST_ARRIVED[i-1])
```

#### 冷启动样本

推荐保存两套：

```text
cold_start_ready    = first_pod_ready - first_request_arrived
cold_start_response = first_response_success - first_request_arrived
```

仅当触发前目标副本数为 0 时计为 cold start。

#### Busy period

一个 busy period 从 dormant 状态下首个请求到达开始，到队列深度为 0、in-flight=0 且持续一个去抖窗口结束。每个 period 保存起止原子时间，随后：

```text
V_i = busy_end_i - busy_start_i
E[V] = mean(V_i)
μ_s = mean(cold_start_i)
```

#### 论文 Rule 2

```text
Xi(τ) = exp(-λτ) + λμ_s + λE[V]
π0(τ) = exp(-λτ) / Xi(τ)
E_s2z_bound(τ) = 1 - π0(τ) × μ_s / (μ_s + 1/λ)
τ* = min { τ ≥ 0 : E_s2z_bound(τ) ≥ E_target }
```

所有时间用秒，`λ` 用 req/s。


| 派生指标 | 公式 | 原子输入 | 说明 |
| --- | --- | --- | --- |
| arrival_rate_lambda | `count(REQUEST_ARRIVED)/window` | REQUEST_ARRIVED | 可按固定窗口和全 run 两种口径 |
| cold_start_mean_mu_s | `mean(cold_start_i)` | replicas_before=0、request、ready/response | 明确使用 ready 或 response 版本 |
| busy_period_mean_E_V | `mean(busy_end-busy_start)` | queue depth、in-flight、request events | busy 边界算法版本化 |
| dormant_fraction | `dormant_time / observation_time` | replica=0 区间 | 成本/冷启动解释 |
| cold_start_probability | `cold_arrivals / all_arrivals` | 请求与 replica 状态 | 实测值，可与 π0 比较 |
| keda_predicted_elasticity | Rule 2 公式 | λ、μs、E[V]、τ | 对每个 τ 计算 |
| recommended_cooldown_tau_star | 满足目标弹性的最小 τ | 预测曲线、E_target | 只生成建议，不自动应用 |
| model_absolute_error | `abs(E_measured(τ)-E_predicted(τ))` | 实测端到端弹性、预测值 | 验证公式拟合 |


### 6.7 Kueue Gang Rule 3 派生指标

对一次 Workload：

- 参考起点 `t0 = KUEUE_ADMITTED`；
- 每个成员 `j` 的 launch delay：`r_j = POD_READY_j - t0`；
- 将 `r_j` 升序排序；
- `R_(k:n)` 为第 k 小值；
- `t_k` 为第 k 个 Pod Ready 的时间；
- `B_n = USEFUL_WORK_STARTED - t_k`，或采用明确的 `GANG_BARRIER_RELEASE - t_k`。

```text
R_gang = R_(k:n) + B_n
E_(k:n) = mean(exp(-R_(k:n)/B_slo))
η(n) = mean(exp(-B_n/B_slo))
E_gang_predicted = E_(k:n) × η(n)
E_gang_measured = mean(exp(-R_gang/B_slo))
```


| 派生指标 | 公式 | 原子输入 | 说明 |
| --- | --- | --- | --- |
| kth_pod_launch_delay | 第 k 个 Ready 的 `POD_READY - KUEUE_ADMITTED` | KUEUE_ADMITTED、成员 POD_READY、k/n | 顺序统计量 |
| slowest_pod_launch_delay | `R_(n:n)` | 所有成员 Ready | 严格 gang 的最慢 Pod |
| median_pod_launch_delay | `R_(ceil(n/2):n)` | 所有成员 Ready | 部分准入对照 |
| barrier_duration_B_n | `USEFUL_WORK_STARTED - t_k` | kth ready、barrier/useful work | 不得只用 PodsReady 条件代替 |
| barrier_factor_eta | `mean(exp(-B_n/B_slo))` | barrier 样本、SLO | 按 n 分组 |
| gang_elasticity_predicted | `E_(k:n)×η(n)` | 顺序统计弹性、barrier factor | Rule 3 |
| gang_elasticity_measured | `mean(exp(-(USEFUL_WORK_STARTED-KUEUE_ADMITTED)/B_slo))` | admitted、useful work | 直接实测 |
| partial_admission_gain | `E_k<n / E_k=n` 或绝对差 | 不同 k 变体 | 前提是业务语义允许部分启动 |


### 6.8 Argo Workflow 派生指标

Workflow 实验必须先在 protocol 中选定阶段权重语义：

1. **启动弹性口径（推荐用于 Hooke）**：阶段从满足依赖/eligible 到 `USEFUL_WORK_STARTED` 的响应时延；
2. **Wall-clock 诊断口径**：`ARGO_NODE_FINISHED - ARGO_NODE_STARTED`，包含业务计算时间。

两种口径不能混在一个弹性乘积中。

对 DAG 中每条有向路径 `p`：

```text
path_delay(p) = Σ stage_delay_j, j∈p
critical_path = argmax_p path_delay(p)
critical_path_length = number_of_stages(critical_path)
E_wf_predicted = Π E_stage_j, j∈critical_path
```

直接实测：

```text
R_wf = workflow_response_end - workflow_trigger_or_created
E_wf_measured = mean(exp(-R_wf/B_slo))
```


| 派生指标 | 公式/算法 | 原子输入 | 说明 |
| --- | --- | --- | --- |
| workflow_queue_latency | `ARGO_WORKFLOW_STARTED - ARGO_WORKFLOW_CREATED` | Workflow created/started | 控制器排队 |
| stage_duration | `ARGO_NODE_FINISHED - ARGO_NODE_STARTED` | node start/finish | wall-clock 诊断 |
| stage_startup_delay | `USEFUL_WORK_STARTED - stage_eligible_time` | DAG 入边完成、应用 useful start | Hooke 启动弹性口径；需应用事件 |
| critical_path | DAG 上最大累计 delay 路径 | workflow_edges、stage delay | 拓扑算法 |
| critical_path_length | 关键路径阶段数 | critical path | 论文工作流变量 L |
| stage_elasticity | `mean(exp(-R_stage/B_slo))` | 阶段时延样本 | 按 stage/template/variant 分组 |
| workflow_elasticity_predicted | `Π E_stage on critical path` | stage elasticity、critical path | 论文 corollary |
| workflow_elasticity_measured | `mean(exp(-R_wf/B_slo))` | Workflow 端到端时延 | 与预测比较 |
| workflow_model_absolute_error | `abs(E_measured-E_predicted)` | 预测/实测 | 验证乘积关系 |
| parallelization_gain | `E_parallel/E_serial` 及关键路径减少量 | 串行/并行 DAG 变体 | 同时核对 true dependency annotation |


### 6.9 数据质量与采集开销派生指标


| 派生指标 | 公式 | 原子输入 | 说明 |
| --- | --- | --- | --- |
| trace_completion_ratio | `complete_traces / all_expected_traces` | pod_traces status、预期 Pod 集 | 区分 not_applicable 与 missing |
| required_event_completeness | `observed_required_events / expected_required_events` | 事件目录、trace | 按事件码分别报告 |
| duplicate_ratio | `deduplicated / observed` | collector counters | 高值可能表示 Watch 重放或 hash 构造错误 |
| bpf_event_loss_ratio | `lost / (submitted + lost)` | BPF counters | 按 Node/探针分组 |
| invalid_time_order_ratio | `negative_or_impossible_segments / attempted_segments` | 原子时间戳 | 正式目标 <0.1% |
| event_observation_lag | `observed_time - event_time` | 两个公共时间字段 | 报告 p50/p95/p99 |
| node_attribution_additivity_error | `Σcharges - task_latency` | Node 归因 | 应接近 0 |
| collector_cpu_percent_per_node | `rate(cpu_seconds_total)/logical_cpu ×100` | collector CPU、Node CPU | agent 每节点 |
| collector_memory_mb_per_node | `working_set_bytes/2^20` | collector memory | agent 每节点 |
| added_scale_out_latency | collector-on 与 collector-off 配对样本的分布差/均值差 | 两种 collector_mode 的 e2e 时延 | 建议同时做 KS 检验和置信区间 |
| ingest_success_ratio | `persisted/(persisted+failed_after_retry)` | ingest counters | 正式数据应接近 1 |


---

## 7. MVP 与论文级口径对照


| 主题 | MVP 可先使用 | 论文级/正式口径 | 后续代码标记 |
| --- | --- | --- | --- |
| Node | Pod Unschedulable、ACK Event/GOATScaler 日志、Node Ready Watch | ACK task 精确建立时间 + ECS 生命周期 + trigger Pod 归因 | A1 ACK adapter + correlator |
| Image | Kubernetes Pulling/Pulled Event、kubelet pull histogram | containerd Pull/Unpack 逐 Pod 精确事件 | A2 containerd eBPF/插件 |
| Pod | Scheduled、`kube_pod_container_state_started` | SyncPod → ContainerStarted | A2 kubelet/CRI eBPF |
| App | `kube_pod_status_ready_time` | readiness probe 首次成功 + first response | A2 应用/probe 埋点 |
| KEDA | KEDA metrics + HPA/KSM + queue depth | 请求级 enqueue/dequeue/processed 与 busy period | E04 已实现 A2 producer/worker + A1 CR/HPA adapter，待 ACK 冒烟 |
| Kueue | Kueue metrics + Workload 状态导出 | 逐 Workload condition、成员 rank、barrier/useful work | A1 CR adapter + A2 worker 埋点 |
| Argo | Workflow CR startedAt/finishedAt/nodes | DAG parser、stage eligible、true dependency、artifact ready | A1 parser + 按需 A2 应用埋点 |
| 资源跟踪 | KSM allocatable/requests/replicas | 加入 queued Workload、节点有效性、业务 net/io demand | A1 join/采样器；net/io 为 A2 |


### 7.1 结论

- 两 Worker 冒烟阶段可以先依靠 kube-state-metrics、kubelet metrics、KEDA/Kueue metrics 和 CR/API 状态跑通存储与计算。
- **仅使用现成 Prometheus 指标无法完整复现论文的逐 Pod 四层轨迹。**
- 正式复现前，至少必须补齐 ACK task 适配、Kubernetes/CR Watch、containerd/kubelet 精确探针和应用语义埋点。
- 现阶段先把所有 A1/A2 项标入开发 backlog，不在指标层提前实现或伪造。

---

## 8. 待开发采集模块清单（仅标记，本文不写代码）


| 模块 | 职责 | 等级 | 覆盖指标 |
| --- | --- | --- | --- |
| collector-k8s-watch | Pod、Node、HPA、Deployment、Event Watch；UID/Condition 转换；Watch 重连 | A1 | POD_CREATED、POD_UNSCHEDULABLE、POD_SCHEDULED、NODE_READY、HPA_DESIRED_CHANGED |
| collector-ack-provision | GOATScaler 日志/Event、provision task、ECS OpenAPI、Node providerID 关联 | A1 | ACK_PROVISION_*、ECS_INSTANCE_*、trigger task metadata |
| collector-crd | KEDA ScaledObject、Kueue Workload、Argo Workflow 监听与快照 | A1 | KEDA/Kueue/Argo 原子事件 |
| agent-containerd-ebpf | Pull/Unpack 入口返回、digest、Node/Pod 关联、active pull count | A2 | IMAGE_PULL_START、IMAGE_UNPACK_END 等 |
| agent-kubelet-cri-ebpf | SyncPod、RunPodSandbox、CreateContainer、StartContainer | A2 | SYNC_POD_START、sandbox/container 子阶段 |
| app-probe-sdk | readiness 首次成功、warmup、first request/response、useful work | A2 | App/KEDA/Gang/Workflow 语义事件 |
| experiment-load-generator | 请求到达、消息 ID、发送/响应时间、run ID 注入 | A2 | WORKLOAD_TRIGGERED、REQUEST_ARRIVED、FIRST_RESPONSE_SUCCESS |
| correlator | 10 分钟窗口、Pod/Node/Image/Request/Workflow 关联、partial trace、Node 比例归因 | A3 | pod_traces、node_provision_task_pods |
| calculator | 所有时延、分位数、弹性、H、KEDA/Gang/Workflow 公式、Bootstrap | A3 | 所有结果表 |


---

## 9. 原子指标采集优先级

### P0：先配置即可直接采集

1. kube-state-metrics：Pod/Node/HPA/Deployment 时间和状态；
2. kubelet `/metrics`：镜像、Pod、CRI 聚合直方图；
3. KEDA `/metrics`；
4. Kueue `/metrics`；
5. cAdvisor/node-exporter；
6. ACK GOATScaler 控制面日志收集；
7. Argo Workflow CR 保留。

### P1：必须写适配器，但不涉及 eBPF

1. Kubernetes API/CR Watch；
2. ACK provision task 与 ECS 生命周期适配；
3. 实验 run/config/version 快照；
4. 原始事件幂等写 MySQL；
5. Node task ↔ Pending Pod 关联；
6. Argo DAG 解析。

### P2：正式论文精度所需

1. containerd Pull/Unpack eBPF；
2. kubelet SyncPod/CRI eBPF；
3. readiness/first-response 应用埋点；
4. KEDA 请求与 busy period 事件；
5. Gang barrier/useful-work 事件。

---

## 10. 指标计算的数据过滤规则

正式计算前统一应用以下规则：

1. 只使用同一 `run_id`、配置 variant、SLO class 和代码/镜像版本；
2. 以 UID、container ID、image digest 关联，不以名称作为主键；
3. 每个 restart attempt 独立计算；
4. `not_applicable`、`event_missing`、`failed`、`timeout` 分开；
5. 不将缺失层填 0；
6. 不删除失败 run；
7. 负时延和明显时钟跳变进入质量报告；
8. Prometheus 直方图只做旁路验证，不反推单 Pod 事件；
9. warm/cold node、warm/cold image cache、scale-from-zero 必须显式分组；
10. 所有计算结果保存 formula version、参数、样本 SQL/过滤条件和随机种子。

---

## 11. 与现有 MySQL DDL 的对应关系


| 数据类别 | DDL 表 | 主要内容 |
| --- | --- | --- |
| 不可变原子事件 | `raw_events` | 所有 event_code、时间、UID、来源、payload |
| 伸缩事件 | `scale_events` | 触发、目标副本、首 Pod/目标 Ready、首响应 |
| 节点供应任务 | `node_provision_tasks` | ACK task、ECS、Node 生命周期 |
| 节点触发归因 | `node_provision_task_pods` | 触发 Pod 集、比例 charge |
| 镜像操作 | `image_operations` / `image_operation_consumers` | Pull/Unpack、cache、共享消费者 |
| Pod 四层轨迹 | `pod_traces` | 层起止、latency、完整性/缺失 mask |
| 请求事件 | `request_events` | KEDA 到达、出队、处理、响应 |
| KEDA 采样/周期 | `keda_samples` / `keda_busy_periods` | scaler、queue、busy period |
| Kueue/Gang | `kueue_workload_instances` / `gang_members` | 准入、成员、barrier |
| Argo | `workflow_instances` / `workflow_nodes` / `workflow_edges` | Workflow 与 DAG |
| 资源供需 | `resource_samples` | S_i(t)、W_i(t)、usage |
| 采集质量 | `collector_health_samples` | CPU、内存、丢失、队列、写入 |
| 派生结果 | `layer_metric_results`、`elasticity_profile_results`、各专项 result 表 | 公式结果与统计量 |


---

## 12. 可选附录：GPU/DRA/MIG 后续指标

当前 CPU 阶段不采集，下列项目先保留事件定义。


| 事件/指标 | 定义 | 直接来源 | 等级 |
| --- | --- | --- | --- |
| RESOURCE_CLAIM_CREATED | ResourceClaim 创建 | Kubernetes DRA API | A1【需自研 Watch】 |
| RESOURCE_CLAIM_ALLOCATED | Claim 获得设备分配 | ResourceClaim status | A1【需自研 Watch】 |
| RESOURCE_CLAIM_PREPARED | 节点侧设备准备完成 | DRA driver/Claim 状态 | A1/A2【需适配】 |
| MIG_RESHAPE_REQUESTED | 请求改变 MIG profile | 调度器/driver/实验 runner | A2【需自研】 |
| MIG_RESHAPE_STARTED/FINISHED | 重构实际起止 | NVIDIA driver/MIG manager 日志、DCGM | A1/A2【需自研适配】 |
| FIRST_CUDA_SUCCESS | 新分区首次 CUDA 操作成功 | GPU 测试应用 | A2【需自研应用埋点】 |
| GPU drain cost D | `reshape_finished - reshape_requested` 或 `first_cuda_success - requested` | 上述原子事件 | A3 DERIVED |
| mean reshape interval T_avg | 连续 reshape requested 的平均间隔 | reshape requested | A3 DERIVED |
| profile mismatch probability ρ | `mismatch_requests/all_gpu_requests` | requested/current profile | A3 DERIVED |
| GPU elasticity bound | `max(0,1-ρD/T_avg)` | D、T_avg、ρ | A3 DERIVED |


---

## 13. 参考依据与版本注意事项

### 13.1 论文依据

- Hooke §4.1：Node/Image/Pod/App 四层和逐 Pod trace；
- Algorithm 1：节点供应任务与触发 Pod 的比例归因；
- Eq. (1)：层弹性；
- Eq. (2)：供需跟踪；
- Rule 1–4：层组合、KEDA、Gang、GPU；
- Workflow corollary：关键路径阶段弹性乘积；
- §5：eBPF、controller hooks、10 分钟 correlator 和 partial trace。

### 13.2 官方工具依据

本文工具与指标名称按以下官方资料核对：

- Kubernetes Metrics Reference（v1.36 页面，2026）；
- kube-state-metrics Pod/HPA/Resource metrics 文档；
- KEDA 2.20 Prometheus integration；
- Kueue Prometheus Metrics（2026-05 文档）；
- Argo Workflows Field Reference；
- 阿里云 ACK 节点即时弹性/ack-goatscaler 日志文档；
- ECS 实例生命周期与 OpenAPI 文档。

### 13.3 版本锁定要求

Kubernetes 中多项 kubelet 指标仍为 Alpha，KEDA/Kueue 指标和 CR 字段也会随版本变化。每次正式实验必须记录：

```text
Kubernetes version
ACK component versions
containerd version + build-id
kubelet version + build-id
kube-state-metrics version
KEDA version
Kueue version
Argo Workflows version
Prometheus scrape interval
所有镜像 digest
```

部署后先从实际 `/metrics` 端点导出 metric name 清单，不能只依据文档假设某个指标一定已启用。

---

## 14. 最终实施结论

当前可直接部署并获得的部分主要是：状态快照、聚合直方图、控制器 Prometheus 指标和 Argo/Kueue/KEDA 对象状态。

真正无法由开源工具直接给出、已经标为后续自研的核心项是：

```text
ACK provision task 与触发 Pod 的可靠关联
containerd Pull/Unpack 逐 Pod 精确时间
kubelet SyncPod/CRI 逐 Pod 精确时间
readiness 首次成功与首个业务响应
Gang barrier 与 useful-work 起点
Argo 真数据依赖/Artifact ready（按业务需要）
所有跨源 trace 关联和派生公式计算
```

E04 已补齐 KEDA 请求级消息链、busy period、CR/HPA/metric 观察和 Rule 2 汇总，
当前状态为代码已实现、待 ACK 冒烟。其余项目后续写代码时不需要重新设计指标，
只需严格按照本文事件码、字段语义和公式实现。
