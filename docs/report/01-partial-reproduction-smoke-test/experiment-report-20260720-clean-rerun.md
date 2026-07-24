# Hooke ACK 两次实验干净复跑报告

## 1. 摘要

2026 年 7 月 20 日在分支 `experiment/01-partial-reproduction-smoke-test`
上补齐实验隔离与 Gate-S 校验后，重新完成固定节点冒烟和真实 ACK 节点扩容实验。
两次最终 Run 均为 **PASS**，轨迹数与预期完全一致，没有再次出现历史 Kubernetes
Event 归入新 Run 的问题。

| 实验 | Run ID | Namespace | 结果 |
|---|---|---|---|
| 固定节点冒烟 | `01KXZ5D9JYBWJ9E915WQDR98ER` | `hooke-experiments-scale-20260720t070349z` | 3/3 完整轨迹，PASS |
| 真实节点扩容 | `01KXZ5H6K7ND5D9PHP4PN1KE10` | `hooke-experiments-scale-20260720t070558z` | 6/6 完整轨迹，节点 2→3→2，PASS |

## 2. 本分支补充内容

引用的首次实验已经修复 UID 转换、MySQL 8.4 schema、事件 ID 冲突、0 ms
样本和跨 Namespace active-run 污染。本次审计发现并补齐了另一处可复现性缺口：

- Kubernetes Event 的生命周期可能长于 Pod。复用同一实验 Namespace 时，controller
  启动后的 informer 初始列表会读到旧 Pod Event，并按 Namespace 当前注解归入新 Run。
- 一次诊断扩容 Run `01KXZ4F6PSTS6DCQ3VE3SN6F6D` 因此得到
  `traces=9、complete=6`；多出的 3 条正是紧邻前一次固定节点 Run 的旧 Pod Event。
- 脚本现默认为每个 Run 创建带 UTC 时间戳的独立 Namespace，并在清理阶段删除。
- Gate-S 从“轨迹数至少达到下限”收紧为“Pod、关键事件、轨迹和层样本必须恰好等于
  本轮预期数量”。若以后再发生污染，实验会直接失败。
- `scripts/verify.sh` 新增所有 Shell 脚本的 `bash -n` 语法检查。
- 修正首次实验报告移动到 `docs/result/` 后失效的相对产物链接。

诊断 Run 的原始产物仍保留在
[first-smoke-20260720T064724Z](../../../artifacts/first-smoke-20260720T064724Z/summary.md)，
但不作为最终实验结论。

## 3. 环境与验证

| 项目 | 值 |
|---|---|
| ACK 地域 | 乌兰察布 `cn-wulanchabu` |
| 集群 ID | `c061d99ce379f4e37a9ff97e027a36ca6` |
| Kubernetes | `1.36.1-aliyun.1` |
| 容器运行时 | containerd `2.1.9` |
| 节点池 | `default-nodepool`，自动伸缩 min=1、max=5 |
| 实验前节点 | 2 个 Ready 节点 |
| Go | `1.23.12` |
| Helm | `4.2.3` |
| MySQL | Docker MySQL `8.4`，UTC 会话 |
| 测试镜像 | `registry.cn-hangzhou.aliyuncs.com/google_containers/echoserver:1.10` |
| SLO | 30 秒 |

复跑前已通过：

- Shell 语法检查；
- `gofmt`；
- `go mod tidy`；
- `go vet ./...`；
- `go test ./...`；
- `go build ./cmd/...`；
- Helm lint（仅有未传 `global.clusterID` 时的预期提示）。

## 4. 实验一：固定节点冒烟

### 4.1 结果

| 指标 | 结果 |
|---|---:|
| 原始事件 | 36 |
| 预期轨迹 | 3 |
| 实际轨迹 | 3 |
| 完整轨迹 | 3/3 |
| Pod 层样本 | 3 |
| App 层样本 | 3 |
| Gate-S | **PASS** |

三条轨迹的分层耗时：

| 样本 | Pod 层 | App 层 | 总时延 |
|---|---:|---:|---:|
| 1 | 1 秒 | 9 秒 | 10 秒 |
| 2 | 1 秒 | 10 秒 | 11 秒 |
| 3 | 1 秒 | 10 秒 | 11 秒 |

| 指标 | 值 |
|---|---:|
| Pod 平均时延 | 1.00 秒 |
| App 平均时延 | 9.67 秒 |
| Pod 弹性分数 | 0.9672 |
| App 弹性分数 | 0.7246 |
| 总弹性分数 | 0.7009 |
| 瓶颈层 | App |

镜像已缓存在固定节点上，因此只有近似 `IMAGE_PULL_END`，没有可配对的
`IMAGE_PULL_START`，本 Run 不计算 Image 层耗时。

## 5. 实验二：真实节点扩容

### 5.1 扩容事实与时间线

本 Run 先执行 3 轮固定节点冒烟，再创建 3 个各请求 `1500m` CPU 的扩容 Pod。
一个 Pod 落在现有节点，两个 Pod 因资源不足进入 Pending，并共同触发一个新节点。

| UTC 时间 | 事件 |
|---|---|
| 07:06:03 | Run 创建 |
| 07:07:36 | 2 个扩容 Pod 首次 `POD_UNSCHEDULABLE` |
| 07:07:40 | ACK Event 记录 `ProvisionNode` |
| 07:07:50 | 新 Node 对象创建：`cn-wulanchabu.10.100.120.127` |
| 07:08:47 | 新 Node Ready；两个 Pending Pod 完成调度 |
| 07:09:05 | 新节点上的两个容器启动 |
| 07:09:06 | 两个 Pod Ready |
| 07:09:27 | Run 完成，Gate-S PASS |
| 07:20:56 | Kubernetes 删除空闲新 Node，节点数恢复为 2 |
| 07:21:34 | ACK 节点池确认 `total=2、serving=2、removing_wait=0` |

### 5.2 Gate-S 与指标

| 指标 | 结果 |
|---|---:|
| 原始事件 | 71 |
| 预期轨迹 | 6 |
| 实际轨迹 | 6 |
| 完整轨迹 | 6/6 |
| `POD_UNSCHEDULABLE` | 2 |
| 本轮 `NODE_READY` | 1 |
| Node / Image 层样本 | 各 2 |
| Pod / App 层样本 | 各 6 |
| 节点变化 | 2→3→2 |
| Gate-S | **PASS** |

| 层 | 样本数 | 平均时延 | p50 | p95 | 弹性分数 |
|---|---:|---:|---:|---:|---:|
| Node | 2 | 71 秒 | 71 秒 | 71 秒 | 0.0938 |
| Image | 2 | 4 秒 | 4 秒 | 4.9 秒 | 0.8757 |
| Pod | 6 | 6.67 秒 | 1 秒 | 18 秒 | 0.8277 |
| App | 6 | 6.83 秒 | 9.5 秒 | 10 秒 | 0.8041 |

- 总弹性分数：`0.0547`；
- 瓶颈层：Node；
- 新节点：`cn-wulanchabu.10.100.120.127`；
- Node 对象创建到 Ready：57 秒；
- 新节点 Pod 调度到容器启动：18 秒；
- 容器启动到 Pod Ready：1 秒；
- 测试负载清零到 Kubernetes 删除新 Node：约 11 分 35 秒；
- 测试负载清零到 ACK 云侧回收完成：约 12 分 13 秒。

两个 71 秒 Node 样本来自同一次扩容批次并共享同一个新节点，不能视为两次独立节点扩容。

## 6. 采集口径与限制

本轮仍是第一阶段冒烟，不是论文级精确实验：

| 层 | 本轮起点 → 终点 | 口径 |
|---|---|---|
| Node | `POD_UNSCHEDULABLE → NODE_READY` | 近似；未导入 GOATScaler/SLS NDJSON |
| Image | Kubernetes `Pulling → Pulled` Event | 近似 |
| Pod | `POD_SCHEDULED → CONTAINER_STARTED` | 近似 |
| App | `CONTAINER_STARTED → Pod Ready` 推导 readiness 成功 | 近似 |

因此 71 秒只能表述为本轮 Pending Pod 到 Node Ready 的扩容链路耗时，不能替代
严格的 `ACK_PROVISION_TASK_CREATED → NODE_READY` 指标。

## 7. 清理结果

- 两次最终 Run 的独立实验 Namespace 均已删除；
- 临时 Deployment、Pod 和 Service 均已删除；
- `hooke-active-run` 已清空；
- 本地 MySQL 容器保留，用于审计原始数据；
- 扩容新增节点已自动释放；最终节点池状态为
  `total=2、serving=2、healthy=2、removing=0、removing_wait=0、desired=2`。

## 8. 产物索引

### 固定节点 Run

- [summary](../../../artifacts/first-smoke-20260720T070349Z/summary.md)
- [events](../../../artifacts/first-smoke-20260720T070349Z/events.tsv)
- [traces](../../../artifacts/first-smoke-20260720T070349Z/traces.tsv)
- [metrics](../../../artifacts/first-smoke-20260720T070349Z/metrics.tsv)
- [report](../../../artifacts/first-smoke-20260720T070349Z/report.json)

### 节点扩容 Run

- [summary](../../../artifacts/first-smoke-20260720T070558Z/summary.md)
- [events](../../../artifacts/first-smoke-20260720T070558Z/events.tsv)
- [traces](../../../artifacts/first-smoke-20260720T070558Z/traces.tsv)
- [metrics](../../../artifacts/first-smoke-20260720T070558Z/metrics.tsv)
- [report](../../../artifacts/first-smoke-20260720T070558Z/report.json)
- [扩容前节点](../../../artifacts/first-smoke-20260720T070558Z/nodes-before.txt)
- [扩容后节点](../../../artifacts/first-smoke-20260720T070558Z/nodes-after.txt)
- [新增节点](../../../artifacts/first-smoke-20260720T070558Z/new-node-names.txt)
