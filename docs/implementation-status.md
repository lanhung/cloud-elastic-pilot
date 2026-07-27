# 实现状态

| 模块 | 状态 | 可用于第一轮冒烟 | 说明 |
|---|---|---:|---|
| 原子事件模型/校验/hash | 已实现 | 是 | source/event/observed/ingest 四时间、时钟偏移/不确定度、近似标记 |
| Ingester/MySQL 批量幂等写入 | 已实现 | 是 | `INSERT IGNORE` + `event_hash` |
| 实验运行 API/CLI | 已实现 | 是 | create/stop/get |
| Pod/Node/Event/Deployment/HPA watcher | 已实现 | 是 | 只读 Informer |
| KEDA/上游 Kueue/ACK QueueUnit/Argo 动态 watcher | 已实现 | 是 | CRD 存在时自动启动；ACK QueueUnit 按 Job UID 关联 |
| ACK 日志配置化适配器 | 已实现 | 是 | HTTP/NDJSON；需用真实日志配置字段 |
| 应用埋点 SDK | 已实现 | 是 | readiness、首请求及通用事件 |
| Pod 轨迹关联 | 已实现 | 是 | 精确来源优先；PodSandbox/CNI 子阶段；事件 ID 可追溯 |
| GOATScaler task-ID 归因 | A01 完成：G1/G2/G3 核心与无丢批干净重复均 5/5；G1/G2 task-ID F1=1，G3 task-ID F1=1、时间窗口 F1=0.667 | 是 | Pod annotation ↔ Node label；新增节点差集、唯一 Pod 与服务日志 Gate；与 K8s-only/时间窗口对照 |
| 层弹性和瓶颈 | 已实现 | 是 | 可写 MySQL |
| 资源供需 `H_i` | 公式已实现 | 需补采样器 | 输入点结构已定义 |
| KEDA Rule 2 | 公式、E04 聚合与 cooldown 反解已实现；1×2 冒烟计算链 PASS | 是 | 按 λ、冷启动、busy period 和 τ 计算；缺失原子事件 fail-closed；正式统计 Pilot 待执行 |
| Gang Rule 3 | 公式、ACK QueueUnit 采集、E05 Indexed Job barrier 与随机区组 runner 已实现；1×4 ACK 冒烟 4/4 PASS | 是（冒烟） | ACK 1.26.3 为整 Job `n` 准入，72/72 应用事件完整；结果见 `docs/result/e05-ack-kube-queue-smoke-20260724.md`；`k` 是应用 barrier |
| Workflow critical path | Argo CR/Node/Edge 采集、确定性拓扑排序、弹性乘积及 MySQL metric 接线已实现；E06 真实 ACK runner 计算链 PASS | 是（冒烟） | 非法/空图 fail-closed；按 Workflow UID 保存边和 predicted/measured/error；部署态 controller→MySQL→correlator 链路未纳入本次冒烟 |
| GPU Rule 4 | 公式已实现 | 否 | GPU 采集后使用 |
| 四层时间线/DAG | 已实现 | E01 pilot | 覆盖并集、重叠、未归因、关键路径贡献；不假设层时延可加 |
| E01 四单元编排 | Pilot 已完成：20/20 PASS | 是 | 4 cells × 5 随机顺序；digest/cache/精确事件 Gate 全部通过，结果见 `docs/result/e01-four-layer-baseline-pilot-20260722.md` |
| E02 Node/warm-pool 编排 | 1×1 配对冒烟完成：2/2 PASS | 是 | cold/warm E2E 为 112.382/14.661 秒，减少 86.95%；精确轨迹和恢复 Gate 通过，节点清理使用受控 API 人工 fallback；结果见 `docs/result/e02-node-warm-pool-smoke-20260723.md` |
| E03 镜像缓存/并发编排 | pull-total 冒烟完成：27/27 PASS | 是 | 63/63 完整精确轨迹；cold 实际并发全部达到 1/2/4，warm 0 下载；9 次 new-node task-ID Precision/Recall=1；补充 Kubernetes+ESS 双重清零 Gate；结果见 `docs/result/e03-image-cache-concurrency-smoke-20260723.md`，download/unpack 拆分仍需 build-id 绑定探针 |
| E04 KEDA scale-to-zero 编排 | 1×2 冒烟完成：2/2 PASS | 是 | 24/24 消息链完整，60/300 秒均完成 Active→Inactive 与 scale-to-zero，metric 请求错误为 0；KEDA condition/cooldown 为近似观察口径；完整 5×2 Pilot 待执行，结果见 `docs/result/e04-keda-scale-to-zero-smoke-20260724.md` |
| E06 Argo Workflow 编排 | 1×2 配对冒烟完成：2/2 PASS | 是（冒烟） | baseline 71 秒、tuned 60 秒；B/C 重叠 0→8 秒，关键路径 6→5，24/24 应用事件完整；结果见 `docs/result/e06-argo-workflow-smoke-20260727.md`；正式统计 Pilot 待执行 |
| E07 端到端累积调优编排 | 1×5 ACK 冒烟完成：5/5 PASS | 是（冒烟） | 单一 fresh Node 串联 KEDA→direct/ACK Queue Job→Argo；B0–B4 E2E 为 238.215/130.624/106.581/108.989/97.460 秒，B4 B/C 重叠 6 秒、关键路径 6→5；自动缩容与 ESS 基线恢复通过；结果见 `docs/result/e07-end-to-end-tuning-smoke-20260727.md`，正式统计实验待执行 |
| E08 采集器开销编排 | 三档两 Worker 低速 ACK 冒烟完成：3/3 PASS | 是（冒烟） | 150/150 Pod 成功并双节点均衡；10%/100% 完整轨迹率 12%/100%，`kept=enqueued=sent` 且丢失/错误为 0；Metrics API controller/node-agent 资源采样与 request headroom 预检通过；结果见 `docs/result/e08-collector-overhead-smoke-20260727.md`；informer collector 无 eBPF ring buffer，正式 KS/CI 待 8/16 节点实验 |
| ACK CRI/应用事件导出 | E01 pilot 20/20 精确主层轨迹 | 是 | containerd CRI RFC3339Nano、kubelet 明确缓存判定、应用源时间日志；sandbox 20/20 精确，不伪造缺失的 CNI 边界 |
| eBPF containerd/kubelet | 接口/契约及真实 NDJSON 导入已建 | 否 | Pull/Unpack 等更细子阶段仍须按 ACK build-id/符号绑定 |
| GOATScaler SLS 导出 | E01 新节点运行 10/10 归因通过 | 是 | 按实验窗口、task ID、Pod UID、Node/instance 关联；task-ID Precision/Recall/F1 均为 1 |
| 直接持续 SLS Consumer | 未实现 | 否 | E01 当前使用运行结束时的真实 SLS 查询导出 hook |
| ECS OpenAPI 轮询器 | 未实现 | 否 | 是否需要取决于 GOATScaler 日志完整性 |
| 自动应用调优 patch | 不实现 | 不适用 | 只生成建议，避免改变业务语义 |

## 不应误解的地方

“公式已实现”不等于“正式 Pilot 已完成”。例如 `H_i` 和 GPU reshape 仍需要对应
采样器或业务埋点；E06 已取得 1×2 真实 ACK 冒烟证据，但每版 30 次的正式 Pilot
尚未执行。工程不会用配置字段或假数据替代真实准入、barrier 或 Workflow 事件。
