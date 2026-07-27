# Hooke ACK Reproducer

面向阿里云 ACK 的 Hooke 论文复现实验工程。该仓库实现 CPU 冒烟阶段需要的自研部分：

- Kubernetes/ACK 事件归一化与原子事件模型；
- Pod、Node、Deployment、HPA、KEDA、上游 Kueue、ACK QueueUnit、Argo 的只读监听；
- MySQL 幂等写入、实验运行管理和消费游标；
- ACK 控制面/SLS 日志的配置化归一化适配器；
- Node/Image/Pod/App 轨迹关联；
- GOATScaler task-ID、Kubernetes-only 与时间窗口归因对照；
- 层弹性、资源跟踪、KEDA、Gang、Workflow 和 GPU 规则计算库；
- 应用侧 readiness、首请求、barrier、artifact 等事件 SDK；
- Helm、Docker Compose、RBAC、NetworkPolicy、CI、单元测试和冒烟运行手册。

## 工程边界

本仓库不会伪造 NodeClaim、ECS 或 ACK 扩容事件。第一轮冒烟使用真实 Kubernetes 状态与 Event；严格的 ACK Node 层起点通过 `hooke-ack-adapter` 接收真实 GOATScaler/SLS/ECS 事件。

containerd `Pull/Unpack` 与 kubelet `SyncPod` 的精确 eBPF uprobe 需要先锁定 ACK 节点上的 containerd/kubelet build-id 和符号表，本仓库不会放入硬编码符号的伪探针。E01 已提供另一条真实来源：从 ACK 节点 journal 提取带 RFC3339Nano 源时间的 CRI `RunPodSandbox`、`PullImage`、`CreateContainer`、`StartContainer` 记录，并用 kubelet 的明确缓存判定补齐热缓存事件。没有真实 CNI 边界时不会制造 CNI 事件；仅由 Kubernetes Event/Status 得到的替代事件仍明确标记为 `approximate=true`。

## 服务

| 组件 | 作用 |
|---|---|
| `hooke-ingester` | 校验、去重并批量写入原子事件；管理实验运行 |
| `hooke-controller` | 监听 Kubernetes 核心对象及可选 CRD |
| `hooke-node-agent` | 每节点健康、时钟与运行环境采样；为后续 eBPF 承载进程 |
| `hooke-ack-adapter` | 把真实 ACK/SLS 日志按配置映射为标准事件 |
| `hooke-correlator` | 构建 Pod 轨迹并计算派生指标 |
| `hooke-migrate` | 执行 MySQL schema |
| `hookectl` | 创建/停止实验、触发计算、输出报告 |
| `sdk/go/hooke` | 应用、负载器和 Gang/Workflow 埋点 SDK |

## 本地快速开始

推荐先使用一键脚本，让本地采集组件通过默认 kubeconfig 监听 ACK：

```bash
cp configs/smoke.env.example configs/smoke.env
$EDITOR configs/smoke.env

./scripts/ack-first-smoke.sh --config configs/smoke.env --check-only
./scripts/ack-first-smoke.sh --config configs/smoke.env
```

详细说明见 [`docs/one-command-smoke.md`](docs/one-command-smoke.md)。需要把全部组件部署到 ACK 时，再按 `docs/smoke-runbook.md` 和 Helm Chart 执行。

第一轮 Gate-S 通过后，可运行 A01 task-ID 归因 Pilot：

```bash
cp configs/attribution-pilot.env.example configs/attribution-pilot.env
$EDITOR configs/attribution-pilot.env
make attribution-ack-check
make attribution-ack
```

实验分组、Ground Truth 和验收条件见
[`docs/plans/a01_goatscaler_attribution_pilot.md`](docs/plans/a01_goatscaler_attribution_pilot.md)。

E04 KEDA scale-to-zero 已完成首轮 ACK 1×2 冒烟：60/300 秒两个 cooldown
cell 均 PASS，24/24 条消息链完整，结果见
[`docs/result/e04-keda-scale-to-zero-smoke-20260724.md`](docs/result/e04-keda-scale-to-zero-smoke-20260724.md)。
完整 5×2 Pilot 尚未执行。继续运行前先阅读
[`docs/e04-keda-scale-to-zero.md`](docs/e04-keda-scale-to-zero.md)，构建不可变
producer/worker 镜像并完成只读预检：

```bash
cp configs/keda-scale-to-zero.env.example configs/keda-scale-to-zero.env
$EDITOR configs/keda-scale-to-zero.env
make e04-image-push IMAGE_REPOSITORY=<same-region-acr-repository>
make e04-ack-check
```

E05 已适配 ACK Kube Queue 1.26.3 的 QueueUnit/ElasticQuotaTree API，并实现
Indexed Job 的真实应用层 k-of-n barrier。该版本按完整 `n` 做整 Job 配额准入，
`k` 只控制应用 barrier。准备和运行方式见
[`docs/e05-ack-kube-queue-gang.md`](docs/e05-ack-kube-queue-gang.md)：

```bash
cp configs/kube-queue-gang.env.example configs/kube-queue-gang.env
$EDITOR configs/kube-queue-gang.env
make e05-image-push IMAGE_REPOSITORY=<same-region-acr-repository>
make e05-ack-check
```

E05 已完成 1×4 ACK 冒烟，四个 `(n,k)` cell 全部通过，结果见
[`docs/result/e05-ack-kube-queue-smoke-20260724.md`](docs/result/e05-ack-kube-queue-smoke-20260724.md)。

E06 Argo Workflow 关键路径适配见
[`docs/e06-argo-workflow.md`](docs/e06-argo-workflow.md)。1×2 串行/并行配对冒烟
已通过，结果见
[`docs/result/e06-argo-workflow-smoke-20260727.md`](docs/result/e06-argo-workflow-smoke-20260727.md)；
尚未执行每版 30 次的正式实验：

```bash
cp configs/argo-workflow.env.example configs/argo-workflow.env
$EDITOR configs/argo-workflow.env
make e06-image-push IMAGE_REPOSITORY=<same-region-acr-repository>
make e06-ack-check
CONFIRM_E06_EXECUTION=yes make e06-ack
```

E07 把上述能力接成一条固定 `1×5` 的累积冒烟流水线。B0 用容量 anchor 触发
fresh ACK Node，B1–B4 复用同一物理节点；随后依次激活短 KEDA cooldown、ACK
Queue 整 Job 准入/应用 k-of-n barrier 和并行 Argo DAG。候选值只做功能验证，
不解释为最优参数：

```bash
cp configs/end-to-end-tuning.env.example configs/end-to-end-tuning.env
$EDITOR configs/end-to-end-tuning.env
make e07-ack-check
CONFIRM_E07_EXECUTION=yes make e07-ack
```

协议、容量证明、Gate 和 artifact 见
[`docs/e07-end-to-end-tuning.md`](docs/e07-end-to-end-tuning.md)。
固定 `1×5` ACK 冒烟已 5/5 PASS，结果见
[`docs/result/e07-end-to-end-tuning-smoke-20260727.md`](docs/result/e07-end-to-end-tuning-smoke-20260727.md)；
正式统计实验尚未执行。

E08 已实现固定 `collector-off → 10% → 100%` 的两 Worker 低速冒烟，
包括 Pod 级确定性采样、collector 队列/投递指标、Metrics API 资源采样和
MySQL 证据导出。当前采集器没有 eBPF ring buffer，因此不会伪造相应计数；
正式 KS/CI 也不在冒烟阶段执行：

```bash
cp configs/collector-overhead.env.example configs/collector-overhead.env
$EDITOR configs/collector-overhead.env
make e08-image-push IMAGE_REPOSITORY=<same-region-acr-repository>
make e08-ack-check
# 将 configs/collector-overhead.env 中的 CONFIRM_E08_EXECUTION 改为 yes
make e08-ack
```

准备条件、Gate 和 artifact 见
[`docs/e08-collector-overhead.md`](docs/e08-collector-overhead.md)。当前状态是
代码、本地多二进制镜像构建与 ACK 只读预检已通过，真实三档冒烟尚未执行。

## 数据原则

1. 原子事件只追加，不在采集层计算 p99、弹性分数或调优建议。
2. 关联优先使用 GOATScaler task ID、UID、Provider ID、Container ID 和 Image Digest；名称仅用于展示或有明确低置信标记的降级关联。
3. 同时保存事件时间和观察时间。
4. 任何近似事件必须带 `approximate=true` 及 `precision` 属性。
5. 派生结果保存计算版本、输入范围和样本数，保证可复算。
