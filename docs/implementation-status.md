# 实现状态

| 模块 | 状态 | 可用于第一轮冒烟 | 说明 |
|---|---|---:|---|
| 原子事件模型/校验/hash | 已实现 | 是 | 纳秒时间、观察时间、近似标记 |
| Ingester/MySQL 批量幂等写入 | 已实现 | 是 | `INSERT IGNORE` + `event_hash` |
| 实验运行 API/CLI | 已实现 | 是 | create/stop/get |
| Pod/Node/Event/Deployment/HPA watcher | 已实现 | 是 | 只读 Informer |
| KEDA/Kueue/Argo 动态 watcher | 已实现 | 是 | CRD 存在时自动启动 |
| ACK 日志配置化适配器 | 已实现 | 是 | HTTP/NDJSON；需用真实日志配置字段 |
| 应用埋点 SDK | 已实现 | 是 | readiness、首请求及通用事件 |
| Pod 轨迹关联 | 已实现 | 是 | 精确与近似起点分开标记 |
| GOATScaler task-ID 归因 | G2 核心归因 5/5 通过、无批次丢失重复 3/5；R4/R5 执行时 Gate 直接 PASS，严格完整性目标待 R6/R7 | 是 | Pod annotation ↔ Node label；新增节点差集、唯一 Pod 与服务日志 Gate；与 K8s-only/时间窗口对照 |
| 层弹性和瓶颈 | 已实现 | 是 | 可写 MySQL |
| 资源供需 `H_i` | 公式已实现 | 需补采样器 | 输入点结构已定义 |
| KEDA Rule 2 | 公式已实现 | 后续正式实验 | 含反解 cooldown |
| Gang Rule 3 | 公式已实现 | 后续正式实验 | k-th order + barrier |
| Workflow critical path | 公式已实现 | 后续正式实验 | 拓扑排序和乘积 |
| GPU Rule 4 | 公式已实现 | 否 | GPU 采集后使用 |
| eBPF containerd/kubelet | 接口/契约已建 | 否 | 必须先取得 ACK build-id/符号 |
| 直接 SLS Consumer | 未绑定环境 | 否 | 当前可用真实导出/HTTP；需实际 project/logstore |
| ECS OpenAPI 轮询器 | 未实现 | 否 | 是否需要取决于 GOATScaler 日志完整性 |
| 自动应用调优 patch | 不实现 | 不适用 | 只生成建议，避免改变业务语义 |

## 不应误解的地方

“公式已实现”不等于“原子输入已采集”。例如 `H_i`、Gang barrier 和 GPU reshape 都需要对应采样器或业务埋点。工程通过接口和事件类型预留了路径，但不会用假数据填充。
