# E08 ACK 采集器开销冒烟结果（2026-07-27）

## 结论

E08 的固定 `collector-off → 10% → 100%` 两 Worker 低速冒烟在真实 ACK
集群通过，3 个 cell 全部 PASS。它证明了采集器模式切换、Pod 级确定性采样、
双节点 node-agent、MySQL 事件持久化、队列/投递无丢失 Gate 和 Metrics API
资源采样能够闭环。

```text
result: PASS (3/3 cells)
scope: two-worker-low-rate-smoke
accepted artifact: artifacts/e08-collector-overhead-smoke-20260727T080425Z
runtime commit: a2cb6b5129d825ce5c62ef44d00cf7215fb0eed8
formal statistics: not executed
```

本次不是正式开销实验。单次固定顺序、50 Pod/cell 的数据不能用于声称生产环境
开销、统计等价或最优采样率；KS 检验、置信区间、高启动速率和 8/16 节点对比均
未执行。

## 环境与固定输入

- ACK Managed Kubernetes：`v1.36.1-aliyun.1`
- Region：`cn-wulanchabu`
- 节点池：`np382116533c5940c48ff67e52ad8b6a26`
- 目标节点规格：`ecs.u2i-c1m1.xlarge`
- 目标节点：
  - `cn-wulanchabu.10.200.101.87`，Zone `cn-wulanchabu-c`
  - `cn-wulanchabu.10.87.16.202`，Zone `cn-wulanchabu-b`
- 每个 cell：50 个 Indexed Job Pod，`parallelism=2`，每个工作阶段 5 秒
- 工作 Pod request：`25m CPU / 32Mi`
- node-agent request：`20m CPU / 32Mi`
- Metrics API：Ready
- 数据库：隔离的临时 MySQL，固定在非目标节点
  `cn-wulanchabu.10.87.16.204`

所有 E08 组件和工作负载使用同一个不可变镜像：

```text
crpi-rde6dbx17y795odv.cn-wulanchabu.personal.cr.aliyuncs.com/hooke-lab/cloud-elastic-pilot@sha256:cc1541c8fe8065465bed190679a94c41350ccc775e8368d2a8da78b68ab19cd8
```

artifact 中的 `git-status.txt` 为空，`git-commit.txt` 与镜像 revision 均为
`a2cb6b5129d825ce5c62ef44d00cf7215fb0eed8`。

## 容量预检

最终运行前按节点 `allocatable - 活跃 Pod requests` 计算可调度余量，并为每个
目标节点预留一个 node-agent 和一个并行工作 Pod：

| Node | 可用 CPU | 可用内存 | E08 每节点新增需求 | Gate |
|---|---:|---:|---:|---|
| `.87` | 2345m | 325.86Mi | 45m / 64Mi | PASS |
| `.202` | 2525m | 203.86Mi | 45m / 64Mi | PASS |

该检查在 namespace、Lease、Secret 或 Helm release 创建前执行，因此
`--check-only` 保持只读。

## Cell 结果

| 模式 | Run ID | Pod | 节点分布 | 应用事件 | controller 事件 | 完整轨迹 |
|---|---|---:|---:|---:|---:|---:|
| collector-off | `01KYH9NP1YVXD81DZ05KB9Z35E` | 50 | 25/25 | 100 | 0 | 0/50 |
| collector-on-10-percent | `01KYH9Y4ECPDHA8HAPC9FF5CEE` | 50 | 25/25 | 100 | 42 | 6/50（12%） |
| collector-on-100-percent | `01KYHA6R41PAFBYG4KR6VZ4T7N` | 50 | 25/25 | 100 | 350 | 50/50（100%） |

150/150 个工作 Pod 均为 `Succeeded`，镜像 digest 一致且总重启数为 0。每个
Pod 都持久化了 `USEFUL_WORK_STARTED` 和 `USEFUL_WORK_FINISHED`。

- off 档没有 controller 或 node-agent Pod，也没有 controller 事件；
- 10% 档同时观察到保留和淘汰，且完整轨迹率严格位于 0% 与 100% 之间；
- 100% 档的每个 Pod 都具有 `POD_CREATED`、`POD_SCHEDULED` 和
  `CONTAINER_STARTED` 完整轨迹。

## 队列与持久化 Gate

| 模式 | kept | sampled out | enqueued | sent | queue full | invalid | delivery error | 最终 depth |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| off | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 10% | 72 | 400 | 72 | 72 | 0 | 0 | 0 | 0 |
| 100% | 475 | 0 | 475 | 475 | 0 | 0 | 0 | 0 |

两个 collector-on cell 均满足 `kept = enqueued = sent`，未观察到队列满、
非法事件、投递错误或结束时未 drain 的队列。

事件从 observed 到 MySQL ingest 的延迟为：

| 模式 | 样本 | p50 | p95 | max |
|---|---:|---:|---:|---:|
| off | 100 | 4.342ms | 95.532ms | 104.489ms |
| 10% | 148 | 7.337ms | 402.463ms | 482.494ms |
| 100% | 500 | 194.953ms | 465.005ms | 498.403ms |

这些值只描述本次低速冒烟的持久化路径，不作为性能回归阈值或生产容量结论。

## Collector 资源采样

下表是 Metrics API 全过程样本的均值/最大值；CPU 单位为 mCPU，内存为 MiB：

| 模式 | 组件 | 样本 | CPU mean/max | 内存 mean/max |
|---|---|---:|---:|---:|
| 10% | controller | 196 | 0.942 / 1.744 | 17.32 / 18.90 |
| 10% | node-agent（两节点合并） | 392 | 0.004 / 0.029 | 2.05 / 2.16 |
| 100% | controller | 192 | 1.507 / 3.280 | 16.60 / 19.04 |
| 100% | node-agent（两节点合并） | 384 | 0.045 / 0.364 | 2.20 / 2.28 |

两个 on cell 都在两台目标节点上取得 node-agent 样本。off cell 的 controller
和 node-agent 样本数均为 0。

当前 collector 基于 Kubernetes informer，没有 eBPF ring buffer。因此报告明确
记录 `ring_buffer_supported=false`，不使用 ingest queue 数值伪造
ring-buffer submitted/lost 指标。

## 适配中发现并固化的边界

最终 accepted run 之前的调试运行不计入结果：

1. Helm migration 是 pre-install/pre-upgrade hook，不能引用尚未创建的 release
   ServiceAccount；migration 改为不挂载 Kubernetes API token。
2. ACK 的 `runAsNonRoot` 校验不能依赖镜像中的命名用户解析；运行镜像固定使用
   数字身份 `65532:65532`。
3. run ID 校验改用 Bash ULID 正则，避免 jq 正则转义误拒绝有效 ULID。
4. `20260727T074442Z` 调试运行的 off cell 通过，但原目标节点 `.86` 在
   node-agent 启动前只剩约 `57.86Mi` request headroom；再扣除 node-agent 的
   `32Mi` 后，无法放置 request 为 `32Mi` 的工作 Pod，导致 10% cell 全部落到
   另一节点并被“双节点覆盖”Gate 正确拒绝。随后新增真实 request headroom
   预检；原组合会在任何集群写入前失败，最终改用通过容量 Gate 的
   `.87 + .202`。

前三项失败发生在工作负载前；第四项没有生成聚合 PASS。唯一用于本报告的结果是
`artifacts/e08-collector-overhead-smoke-20260727T080425Z`。

## 清理

runner 完成后复查不存在 E08 Helm release、system/workload namespace、Lease、
ClusterRole 或 ClusterRoleBinding。仅为本次冒烟创建的临时 MySQL namespace
`hooke-e08-db` 也已删除，集群中不存在 `hooke-e08*` namespace。

本次未删除 Node、未修改节点池期望容量，也没有遗留数据库凭据到仓库或 artifact。

## 口径限制

本次每个模式只有一个 cell，顺序固定且未随机化；节点跨两个可用区，工作负载速率
低，未做重复、KS 检验、bootstrap 置信区间或顺序效应分析。资源值证明采样链路
可用，不证明 collector 对业务启动延迟没有影响。正式开销结论仍需按协议扩展到
8/16 节点、高 Pod starts/min 和重复随机区组。
