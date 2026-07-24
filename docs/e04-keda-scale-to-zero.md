# E04 KEDA scale-to-zero Pilot

## 当前状态

E04 已于 2026 年 7 月 24 日在真实 ACK 上完成首轮 1×2 冒烟：
60/300 秒两个 cooldown cell 均 PASS，24/24 条消息链完整，external metric、
ScaledObject、HPA、worker Ready 和 scale-to-zero 证据齐全。结果见
[`docs/result/e04-keda-scale-to-zero-smoke-20260724.md`](result/e04-keda-scale-to-zero-smoke-20260724.md)。

当前结论只覆盖每个 cooldown 1 次的链路冒烟；下述 5 个随机配对区组的完整 Pilot
尚未执行。ACK KEDA 2.20.1 的 Active/Inactive condition 不提供
`lastTransitionTime`，因此对应转换和 cooldown 保留 approximate 质量标记。

## Pilot 设计

```text
producer Job → Redis list → KEDA ScaledObject → worker Deployment
```

固定参数：

| 参数 | Pilot 值 |
|---|---:|
| 到达率 λ | 1 message/s |
| cooldownPeriod | 60 s、300 s |
| pollingInterval | 5 s |
| minReplicaCount | 0 |
| maxReplicaCount | 4 |
| 每个 cell 重复 | 5 |
| 调度顺序 | 5 个随机配对区组 |

两个 cooldown cell 使用相同镜像 digest、节点池、资源、消息数、处理时长和采样
间隔。Redis、producer 和 worker 全部固定到已有 Ready CPU 节点池，使 E04 只测
KEDA scale-to-zero 控制链路，不混入 Node 扩容。

## 实现组成

| 文件 | 作用 |
|---|---|
| `cmd/keda-redis-app` | 同一镜像内的 producer/worker；写入带源时间的结构化事件 |
| `internal/redisresp` | E04 所需的最小 RESP2 客户端，不引入额外 Redis SDK |
| `internal/kube/collector.go` | ScaledObject Active/Inactive、KEDA HPA 指标和 scale-to-zero 变化采集 |
| `scripts/export-application-events.py` | 用冻结的 Pod/Container 身份校验并导出应用日志事件 |
| `scripts/e04-keda-scale-to-zero.py` | 生成 schedule/manifest、采样 external metric、校验 run、汇总 Rule 2 |
| `scripts/ack-keda-scale-to-zero.sh` | ACK 一键只读预检和实验编排 |
| `scripts/build-e04-image.sh` | 构建并推送 producer/worker 不可变镜像 |
| `configs/keda-scale-to-zero.env.example` | 全部冻结参数和安全确认项 |

## 时间边界与精度

| 边界 | 来源 | 精度 |
|---|---|---|
| 消息成功入队 | producer 在 `RPUSH` 成功后写出的 `MESSAGE_ENQUEUED` | 应用进程源时间 |
| 消息成功出队 | worker 的 `BLPOP` 成功返回后写出的 `MESSAGE_DEQUEUED` | 应用进程源时间 |
| 处理开始/结束 | worker 写出的 `MESSAGE_PROCESSING_STARTED` / `MESSAGE_PROCESSED` | 应用进程源时间 |
| 队列深度 | producer/worker 的 Redis `LLEN` 采样 | 应用观察时间 |
| KEDA metric value | external metrics API 轮询 | 观察采样，保留 source/observed time |
| ScaledObject Active/Inactive | ScaledObject condition watch | condition transition time；缺失时明确标为 approximate |
| HPA desired/current | KEDA 生成的 HPA status watch | HPA status observation |
| worker Ready | Kubernetes Pod condition | Kubernetes condition time |
| scale-to-zero | worker Deployment `spec.replicas` 从正数变为 0 | Deployment spec transition observation；runner 另行确认实际副本全部归零 |

stdout 只是应用事件载体。导出器在 Pod 删除前冻结 Pod UID、Container ID、Node 和
日志，并校验 cluster/run/Pod/Container 关联；不会用日志抓取时间替代进程写出的
`source_time_ns`。

## 构建与配置

提交 E04 代码后，从干净 worktree 构建并推送镜像：

```bash
make e04-image-push \
  IMAGE_REPOSITORY=<same-region-acr-repository>
```

脚本拒绝从 dirty worktree 推送，输出的 `dist/e04-image.env` 包含源码 commit 和
不可变 `repository@sha256:...`。Redis 镜像也必须使用不可变 digest。

复制并填写配置：

```bash
cp configs/keda-scale-to-zero.env.example configs/keda-scale-to-zero.env
$EDITOR configs/keda-scale-to-zero.env
```

至少需要核对 ACK API Server、kube context、KEDA namespace、固定节点 selector、
应用镜像 digest、Redis 镜像 digest 和本地 MySQL 配置。真实配置文件与运行
artifact 已被 Git 忽略。

## 运行

先执行只读预检：

```bash
make e04-ack-check
```

预检确认目标 kube context/API Server、RBAC、KEDA operator、metrics APIService、
external metric、固定节点容量和镜像来源。通过后才显式设置执行确认：

```bash
CONFIRM_E04_EXECUTION=yes make e04-ack
```

执行阶段会获取 Kubernetes Lease；每个 cell 使用独立 namespace、run ID、Redis
密码、队列 key 和 completion key。Redis 密码仅写入临时 Secret，不进入 artifact
或日志。本地 controller 使用只包含已确认目标 context 的临时 minified kubeconfig，
退出时删除，避免它与带 `--context` 的 `kubectl` 指向不同集群。namespace 清理
使用 UID 与 run ID 双重校验。

## Fail-closed Gate

每个 run 必须同时满足：

1. ScaledObject 配置与冻结的 run config 完全一致；
2. 初始 worker Deployment 的期望/当前/Ready/Available 副本均为 0；
3. 初始 external metric 存在 0 样本，采样过程无错误且最大采样间隔不超限；
4. 每个消息都有唯一且有序的 enqueue、dequeue、processing-start、processed 链；
5. 实际到达率位于配置容差内；
6. 队列深度出现正值并最终回到 0；
7. ScaledObject 先出现 Active，再出现 Inactive；
8. KEDA metric 出现 `0 → 正值 → 0`；
9. KEDA 生成的 HPA 出现正 desired replicas；
10. 至少一个 worker Pod 达到 Ready；
11. busy period 结束后才出现 scale-to-zero；
12. 观测 cooldown 与配置值一致且没有跨 run、跨 Pod 或跨容器事件。

任一 Gate 失败时该 run 不进入 Rule 2 汇总，不用缺失事件或近似时间补值。

## 产物与汇总

成功执行后，artifact 位于：

```text
artifacts/e04-keda-scale-to-zero-pilot-<UTC>/
├── schedule.tsv
├── run-index.tsv
├── observations.tsv
├── summary.json
└── runs/<sequence>-<cell>/
    ├── run-config.json
    ├── base-manifest.json
    ├── producer-manifest.json
    ├── application-pods.json
    ├── application-logs/
    ├── keda-metric-captures.ndjson
    ├── events.ndjson
    └── observation.json
```

`summary.json` 按 cooldown 汇总 `λ`、平均冷启动 `μ_s`、平均 busy period
`E[V]` 和 KEDA Rule 2 预测值，并反解满足目标弹性的最小 `τ*`。
Pilot 完成后再从 artifact 生成带日期的 `docs/result/e04-...md` 实验报告。
