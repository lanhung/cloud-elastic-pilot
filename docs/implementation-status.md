# 实现状态

| 模块 | 状态 | 可用于第一轮冒烟 | 说明 |
|---|---|---:|---|
| 原子事件模型/校验/hash | 已实现 | 是 | source/event/observed/ingest 四时间、时钟偏移/不确定度、近似标记 |
| Ingester/MySQL 批量幂等写入 | 已实现 | 是 | `INSERT IGNORE` + `event_hash` |
| 实验运行 API/CLI | 已实现 | 是 | create/stop/get |
| Pod/Node/Event/Deployment/HPA watcher | 已实现 | 是 | 只读 Informer |
| KEDA/Kueue/Argo 动态 watcher | 已实现 | 是 | CRD 存在时自动启动 |
| ACK 日志配置化适配器 | 已实现 | 是 | HTTP/NDJSON；需用真实日志配置字段 |
| 应用埋点 SDK | 已实现 | 是 | readiness、首请求及通用事件 |
| Pod 轨迹关联 | 已实现 | 是 | 精确来源优先；PodSandbox/CNI 子阶段；事件 ID 可追溯 |
| GOATScaler task-ID 归因 | A01 完成：G1/G2/G3 核心与无丢批干净重复均 5/5；G1/G2 task-ID F1=1，G3 task-ID F1=1、时间窗口 F1=0.667 | 是 | Pod annotation ↔ Node label；新增节点差集、唯一 Pod 与服务日志 Gate；与 K8s-only/时间窗口对照 |
| 层弹性和瓶颈 | 已实现 | 是 | 可写 MySQL |
| 资源供需 `H_i` | 公式已实现 | 需补采样器 | 输入点结构已定义 |
| KEDA Rule 2 | 公式已实现 | 后续正式实验 | 含反解 cooldown |
| Gang Rule 3 | 公式已实现 | 后续正式实验 | k-th order + barrier |
| Workflow critical path | 公式已实现 | 后续正式实验 | 拓扑排序和乘积 |
| GPU Rule 4 | 公式已实现 | 否 | GPU 采集后使用 |
| 四层时间线/DAG | 已实现 | E01 pilot | 覆盖并集、重叠、未归因、关键路径贡献；不假设层时延可加 |
| E01 四单元编排 | Pilot 已完成：20/20 PASS | 是 | 4 cells × 5 随机顺序；digest/cache/精确事件 Gate 全部通过，结果见 `docs/result/e01-four-layer-baseline-pilot-20260722.md` |
| ACK CRI/应用事件导出 | E01 pilot 20/20 精确主层轨迹 | 是 | containerd CRI RFC3339Nano、kubelet 明确缓存判定、应用源时间日志；sandbox 20/20 精确，不伪造缺失的 CNI 边界 |
| eBPF containerd/kubelet | 接口/契约及真实 NDJSON 导入已建 | 否 | Pull/Unpack 等更细子阶段仍须按 ACK build-id/符号绑定 |
| GOATScaler SLS 导出 | E01 新节点运行 10/10 归因通过 | 是 | 按实验窗口、task ID、Pod UID、Node/instance 关联；task-ID Precision/Recall/F1 均为 1 |
| 直接持续 SLS Consumer | 未实现 | 否 | E01 当前使用运行结束时的真实 SLS 查询导出 hook |
| ECS OpenAPI 轮询器 | 未实现 | 否 | 是否需要取决于 GOATScaler 日志完整性 |
| 自动应用调优 patch | 不实现 | 不适用 | 只生成建议，避免改变业务语义 |

## 不应误解的地方

“公式已实现”不等于“原子输入已采集”。例如 `H_i`、Gang barrier 和 GPU reshape 都需要对应采样器或业务埋点。工程通过接口和事件类型预留了路径，但不会用假数据填充。
