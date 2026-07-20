# Hooke ACK 固定节点与节点扩容实验报告

## 1. 报告摘要

2026 年 7 月 20 日在阿里云 ACK 集群上完成两次实验：固定节点链路冒烟，以及包含真实 ECS/Node 扩容的节点扩容冒烟。两次 Gate-S 均为 **PASS**。

| 实验 | Run ID | 主要目标 | 准确结果 | 结论 |
|---|---|---|---|---|
| 实验一：固定节点冒烟 | `01KXYPTH55DP6VMMFX9F86R97Y` | 验证 Pod 创建、调度、容器启动、Ready、落库、关联与计算链路 | 3/3 条轨迹完整 | PASS |
| 实验二：节点扩容冒烟 | `01KXYQE1B4W1H0P83GFTGXYGQW` | 验证 Pending Pod 触发 ACK 新节点、Node Ready、Pod 落位及回收 | 实验 Namespace 内 6/6 条轨迹完整；节点 2→3→2 | PASS |

核心结论：

1. Hooke 的 ACK 采集、MySQL 幂等落库、Pod 轨迹关联、分层样本计算和 Gate-S 链路可以工作。
2. 固定节点实验中 Pod 层平均耗时为 1 秒，App 层平均耗时约 6.67 秒，App 是主要瓶颈。
3. 节点扩容实验成功创建 1 个新节点；从首次 `POD_UNSCHEDULABLE` 到 `NODE_READY` 为 69 秒。
4. 测试结束后新增节点被 ACK 自动回收，节点池恢复到原来的 2 个健康节点。

## 2. 实验环境

| 项目 | 配置 |
|---|---|
| 云平台 | 阿里云 ACK |
| 地域 | 乌兰察布 `cn-wulanchabu` |
| 集群类型 | ACK Managed Kubernetes |
| Kubernetes | `1.36.1-aliyun.1` |
| 容器运行时 | containerd `2.1.9` |
| Pod 网络 | Flannel |
| 初始节点数 | 2 |
| 初始节点规格 | `ecs.c7.xlarge`，4 vCPU |
| 节点池 | `default-nodepool`，自动伸缩开启，min=1、max=5 |
| 本地 Go | `1.23.12` |
| 本地 MySQL | MySQL `8.4.9` Docker 容器 |
| 测试镜像 | `registry.cn-hangzhou.aliyuncs.com/google_containers/echoserver:1.10` |
| 实验 SLO | 30 秒 |
| 时间口径 | 表内时间统一使用 UTC；北京时间为 UTC+8 |

本仓库目录没有 Git 元数据，因此本报告无法记录 commit SHA；报告对应 2026-07-20 实验完成后的工作区源码快照。

## 3. 采集口径与限制

本轮尚未启用精确 eBPF 探针，也没有导入 GOATScaler/SLS NDJSON，因此采用以下近似口径：

| 层 | 起点 | 终点 | 精度 |
|---|---|---|---|
| Node | `POD_UNSCHEDULABLE` | `NODE_READY` | 近似 |
| Image | Kubernetes `Pulling` Event | Kubernetes `Pulled` Event | 近似 |
| Pod | `POD_SCHEDULED` | `CONTAINER_STARTED` | 近似 |
| App | `CONTAINER_STARTED` | Pod Ready 推导的 `READINESS_PROBE_FIRST_SUCCESS` | 近似 |

因此，69 秒的 Node 层结果用于验证真实扩容链路和采集闭环，不应表述为论文严格口径下的 GOATScaler 任务创建到 Node Ready 时延。

## 4. 实验一：固定节点冒烟

### 4.1 目的与方法

在已有节点上串行执行 3 次 Deployment `0 → 1 → 0`：

- CPU request/limit：`100m / 500m`；
- 内存 request/limit：`64Mi / 256Mi`；
- readiness：HTTP `GET /`；
- 每轮等待 Pod Ready，执行 HTTP 访问，然后缩容到 0；
- 采集 Kubernetes Pod、Deployment 和 Event，并在实验结束后构建轨迹及计算分层指标。

### 4.2 Gate-S 结果

| 指标 | 结果 |
|---|---:|
| 原始事件 | 36 |
| Pod 创建/调度/容器启动/Ready | 各 3 |
| Readiness 成功事件 | 3 |
| 轨迹数 | 3 |
| 完整轨迹 | 3 |
| Pod 层样本 | 3 |
| App 层样本 | 3 |
| Gate-S | **PASS** |

### 4.3 时延与弹性结果

| 样本 | Pod 层 | App 层 | 总时延 |
|---|---:|---:|---:|
| 1 | 1 秒 | 10 秒 | 11 秒 |
| 2 | 1 秒 | 9 秒 | 10 秒 |
| 3 | 1 秒 | 1 秒 | 2 秒 |

| 指标 | 值 |
|---|---:|
| Pod 平均时延 | 1.00 秒 |
| App 平均时延 | 6.67 秒 |
| App p50 / p95 / p99 | 9.00 / 9.90 / 9.98 秒 |
| Pod 弹性分数 | 0.9672 |
| App 弹性分数 | 0.8082 |
| 总弹性分数 | 0.7817 |
| 主要瓶颈 | App |

镜像已经缓存在节点上，Kubernetes 只产生了 `IMAGE_PULL_END`，没有配对的 `IMAGE_PULL_START`，因此本次固定节点实验不计算 Image 层耗时。

## 5. 实验二：真实节点扩容冒烟

### 5.1 目的与方法

本次运行先重复 3 轮固定节点冒烟，然后执行 S03 节点扩容：

- 使用节点池标签 `node.alibabacloud.com/nodepool-id` 限制测试 Pod；
- 创建 3 个测试 Pod；
- 每个 Pod 请求 `1500m` CPU、`256Mi` 内存；
- 现有节点资源不足时产生 `POD_UNSCHEDULABLE`；
- ACK 自动伸缩节点池创建新 ECS/Node；
- 等待全部 Pod Ready，记录扩容前后 Node 集合；
- 测试结束后 Deployment 缩容到 0，等待 ACK 自动回收空闲节点。

### 5.2 扩容时间线

| UTC 时间 | 事件 |
|---|---|
| 02:59:40 | 创建实验 Run |
| 03:01:07 | 启动 S03 节点扩容阶段 |
| 03:01:13 | 2 个 Pod 首次进入 `POD_UNSCHEDULABLE` |
| 03:01:16.617 | ACK Kubernetes Event 显示 `ProvisionNode` |
| 03:01:26 | 新 Node 对象创建：`cn-wulanchabu.10.100.120.126` |
| 03:02:22 | 新 Node 进入 Ready，两个 Pending Pod 完成调度 |
| 03:02:39 | 新节点上的两个测试容器启动 |
| 03:02:40 | 两个测试 Pod Ready |
| 03:02:54 左右 | 扩容测试负载缩容到 0 |
| 03:03:01 | 实验 Run 完成，Gate-S PASS |
| 03:14:11 | Kubernetes 节点数恢复到 2 |
| 03:14:40 | ACK 节点池确认 total=2、serving=2、removing=0 |

关键阶段耗时：

| 阶段 | 耗时 |
|---|---:|
| `POD_UNSCHEDULABLE → NODE_READY` | 69 秒 |
| Node 对象创建 → Node Ready | 56 秒 |
| 新节点 Pod 调度 → 容器启动 | 17 秒 |
| 容器启动 → Pod Ready | 1 秒 |
| 测试负载清零 → Kubernetes 删除新 Node | 约 11 分 17 秒 |

### 5.3 准确过滤后的结果

原始 Run 汇总包含 active-run 窗口内其他 Namespace 的 Pod 事件。为避免错误结论，本节只统计 `hooke-experiments-scale` Namespace；过滤后结果如下：

| 指标 | 结果 |
|---|---:|
| 实验 Pod 数 | 6（固定节点 3 + 扩容阶段 3） |
| 完整轨迹 | 6/6 |
| Pod 创建/调度/启动/Ready | 各 6 |
| Readiness 成功事件 | 6 |
| `POD_UNSCHEDULABLE` | 2 |
| Node 层样本 | 2 |
| Image 层样本 | 2 |
| Pod 层样本 | 6 |
| App 层样本 | 6 |
| 节点变化 | 2 → 3 → 2 |
| Gate-S | **PASS** |

| 层 | 样本数 | 最小值 | 平均值 | 最大值 |
|---|---:|---:|---:|---:|
| Node | 2 | 69 秒 | 69 秒 | 69 秒 |
| Image | 2 | 1 秒 | 2.5 秒 | 4 秒 |
| Pod | 6 | 0 秒 | 6 秒 | 17 秒 |
| App | 6 | 1 秒 | 6.83 秒 | 10 秒 |

两个 Node 层样本来自同一扩容批次、同一个新节点，不能视为两个独立的节点扩容样本。新节点承载两个 Pending Pod，因此两条轨迹共享同一个 69 秒 Node 层时延。

### 5.4 扩缩容结果

- 扩容前节点：2；
- 扩容后节点：3；
- 新节点：`cn-wulanchabu.10.100.120.126`；
- 新节点规格：`ecs.u2i-c1m1.xlarge`；
- 测试结束后只剩 DaemonSet Pod，满足自动缩容条件；
- ACK 最终恢复为 2 个 serving/healthy 节点，没有 removing 或 removing-wait 节点；
- 没有遗留测试 Deployment、Pod 或 Service。

## 6. 实验期间发现并修复的问题

1. **Kubernetes UID 编译错误**：将 6 处 `.UID.String()` 改为 `string(UID)`。
2. **MySQL 8.4 schema 不兼容**：将默认时间表达式从 `UTC_TIMESTAMP(6)` 改为 UTC 会话下的 `CURRENT_TIMESTAMP(6)`。
3. **Docker Hub 不可达**：节点拉取 `nginx:1.27-alpine` 超时，改用阿里云公共 `echoserver` 镜像。
4. **事件 ID 冲突**：同一 informer 回调产生的 `POD_READY` 与 readiness 事件曾复用 `event_id`；现已为每个原子事件生成独立 ID。
5. **0 ms 样本被丢弃**：秒级 Kubernetes 时间戳可能产生合法的 0 ms 区间；现改为按起止时间是否有效决定是否保留样本。
6. **active-run 数据污染**：节点扩容期间 active run 曾被当作所有 Namespace 的 fallback，导致原始汇总显示 `traces=21`。按实验 Namespace 过滤后的准确值为 6/6；代码已修复为 active run 只回退到集群级对象，相关回归测试和完整验证均通过。

原始产物保持不变，以便审计。实验二的原始 `summary.md` 中 `raw_events=137`、`traces=21` 不应直接用于业务结论。

## 7. 结论与后续建议

本轮证明了 Hooke 在 ACK 上的基础采集和真实节点扩容闭环可以运行：Pending Pod 能触发节点池扩容，新 Node 可被观察到并关联到实验 Pod，测试结束后节点能自动回收。

后续正式实验建议：

1. 接入 GOATScaler/SLS 原始日志，把 Node 起点从 `POD_UNSCHEDULABLE` 升级为严格的 `ACK_PROVISION_TASK_CREATED`。
2. 锁定 ACK 节点 containerd/kubelet build-id 后启用 eBPF，替换 Pod/Image 近似口径。
3. 每轮使用全新实验 Namespace，避免历史 Kubernetes Event 进入新 Run。
4. 使用专用 min=0 弹性节点池和固定实例规格，减少系统 Pod 数量、节点资源余量和实例选型对结果的影响。
5. 正式测量至少重复 30 次，报告 p50/p95/p99、置信区间和失败率；当前 3 次样本只适合作为链路冒烟。

## 8. 产物索引

### 实验一

- [summary](../artifacts/first-smoke-20260720T024854Z/summary.md)
- [traces](../artifacts/first-smoke-20260720T024854Z/traces.tsv)
- [metrics](../artifacts/first-smoke-20260720T024854Z/metrics.tsv)
- [report](../artifacts/first-smoke-20260720T024854Z/report.json)

### 实验二

- [summary（含已知污染，见第 6 节）](../artifacts/first-smoke-20260720T025934Z/summary.md)
- [扩容前节点](../artifacts/first-smoke-20260720T025934Z/nodes-before.txt)
- [扩容后节点](../artifacts/first-smoke-20260720T025934Z/nodes-after.txt)
- [新增节点](../artifacts/first-smoke-20260720T025934Z/new-node-names.txt)
- [原始轨迹](../artifacts/first-smoke-20260720T025934Z/traces.tsv)
- [原始事件统计](../artifacts/first-smoke-20260720T025934Z/events.tsv)

