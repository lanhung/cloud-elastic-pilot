# E07：ACK 端到端累积调优冒烟

## 1. 范围

E07 当前只做一次 `1×5` 累积功能冒烟，用于证明 Node、KEDA、ACK Kube Queue、
应用 gang barrier 和 Argo Workflow 能在同一条真实 ACK 流水线中连续工作。它
不是正式实验，不做随机重复、置信区间或“最优参数”结论。

五个单元固定为：

| Cell | Node | KEDA cooldown | Job admission | n/k | Argo |
|---|---|---:|---|---:|---|
| B0 | cold | 30s | direct | 2/2 | serial |
| B1 | warm | 30s | direct | 2/2 | serial |
| B2 | warm | 5s | direct | 2/2 | serial |
| B3 | warm | 5s | ACK Queue whole-Job | 2/1 | serial |
| B4 | warm | 5s | ACK Queue whole-Job | 2/1 | parallel |

`k` 不是 ACK Queue 的部分准入参数。Chart 1.26.3 的 QueueUnit 必须申请完整
`n=2`；`k` 只由应用 worker 的 barrier 实现。报告中不会把 5 秒 cooldown 或
`k=1` 称为最优值。

## 2. Fresh Node 证明

runner 不修改节点池 `min/max`，也不执行 `kubectl delete node`。只读预检先从
ACK API 核对目标 ESS 节点池为 `min=0,max=5` 且自动扩缩开启，再按 Kubernetes
scheduler request 计算：

```text
anchor request > 每个当前节点的可用 request headroom

anchor request + phase peak + safety
  <= 新节点 allocatable - DaemonSet requests
```

默认 anchor 请求 `1024Mi`，在隔离 Namespace 创建后只能触发第五个物理节点。
B0 的起点是 anchor 创建，因而包含真实 Node provisioning；anchor 绑定的精确
`kubernetes.io/hostname` 必须不在 baseline Node UID/name 集合中。B1–B4 全部
固定到该节点。结束时删除 Namespace，让 ACK 自动缩容，并等待这个精确 Node
消失；随后还要从 ESS 复核 `total/pending/removing/active` 已回到 baseline，
避免 Kubernetes Node 先消失但云端实例仍在移除时触发下一次
`IncorrectCapacity.NoChange`。不以删除 Kubernetes Node 对象代替云端缩容。

## 3. 控制器前置条件

- KEDA Helm `2.20.1`，operator、metrics server 和 external metrics API Ready；
- ACK Kube Queue Helm `1.26.3`，QueueUnit/Queue/ElasticQuotaTree CRD Established；
- ACK Argo Workflow Helm `3.5.15`，实际 controller 版本前缀 `v3.5.13`；
- E04/E05/E06 worker 和 Redis 都使用同 Region ACR 的不可变 digest。

ACK Marketplace 的 `ack-kube-queue-1.26.3.tgz` 会为 `job-extensions` 渲染
`/manager`，但其固定镜像的实际入口为
`/usr/bin/kube-queue-controllers`。使用仓库内的版本限定安装器：

```bash
scripts/install-ack-kube-queue-1263.sh \
  --context <ack-kube-context> \
  --check-only

scripts/install-ack-kube-queue-1263.sh \
  --context <ack-kube-context>
```

安装器下载用户指定的 Chart URL，验证固定 SHA-256，只在临时目录修正这一条
command，检查渲染镜像后再执行原子 Helm upgrade/install。E07 预检会复核 release
Chart 版本、两个 Deployment Ready，以及修正后的实际 command。

## 4. 配置和执行

```bash
cp configs/end-to-end-tuning.env.example configs/end-to-end-tuning.env
$EDITOR configs/end-to-end-tuning.env

make e07-ack-check
CONFIRM_E07_EXECUTION=yes make e07-ack
```

`--check-only` 只读检查 kube context/API Server、ACK 节点池、Helm release、CRD、
权限、历史镜像 metadata/digest 和容量不等式；不创建 Lease、Namespace、Pod 或
配额树。

实际执行时：

1. 创建 E07 Lease、隔离 Namespace 和最小 Argo executor RBAC；
2. 用 anchor 拉起并锁定一个 fresh physical Node；
3. 每个 cell 串行执行 KEDA → gang Job → Argo Workflow；
4. B0–B2 的 Job 显式 `suspend=false`，且不得生成 QueueUnit；
5. B3 首次创建 ElasticQuotaTree，B3/B4 的 suspended Job 由 ACK Queue 准入；
6. 每个阶段保存 Pod/CR 快照、容器日志和精确应用 source timestamp；
7. 每个 cell 独立 fail-closed 校验后再进入下一个；
8. 删除树、Namespace 和 Lease，等待 anchor Node 自动缩容；
9. 输出 JSON、TSV 和 Markdown 汇总。

## 5. Gate

每个 cell 必须同时满足：

- KEDA 初始 `replicas=0`，external metric 出现 `0→正值→0`；
- HPA 出现正 desired replica、worker Ready，四条消息生命周期全部完整；
- 最终 ScaledObject Inactive 且 Deployment scale-to-zero；
- gang 的两个 Indexed Pod 全部成功、固定到目标节点并使用精确 digest；
- direct cell 没有 QueueUnit；ACK cell 的 QueueUnit 申请完整 `n`，无
  `minCount` 部分准入；
- 每个 rank 的 readiness、barrier enter/exit、useful work start/finish 完整；
- Argo 六个 Pod 和 12 个应用事件完整；
- baseline B/C 不重叠、B4 B/C 重叠且关键路径长度从 6 变为 5。

聚合 Gate 只要求 B0（含 provisioning）慢于 B1，并检查 B2/B3/B4 的 patch
确实激活。它不要求五个 E2E 时间单调下降。每个单元的 KEDA phase 要等到
scale-to-zero，因此报告 E2E 包含 cooldown；这是本冒烟编排边界，不是普通用户
请求延迟。

## 6. Artifact

```text
artifacts/e07-end-to-end-tuning-smoke-<UTC>-<suffix>/
├── run-metadata.json
├── nodepool.json
├── provisioning-evidence.json
├── schedule.tsv
├── cells/
│   └── <sequence>-bN/
│       ├── cell-config.json
│       ├── keda-*.json / *.ndjson
│       ├── gang-*.json / *.ndjson
│       ├── argo-*.json / *.ndjson
│       ├── timing.json
│       └── summary.json
├── summary.json
├── summary.tsv
└── report.md
```

失败时本地 evidence 始终保留；Kubernetes 资源是否保留由 cleanup 配置控制。
