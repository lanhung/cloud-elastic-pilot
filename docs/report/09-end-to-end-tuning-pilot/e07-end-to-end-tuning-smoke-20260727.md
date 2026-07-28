# E07 ACK 端到端累积调优冒烟结果（2026-07-27）

## 结论

E07 的固定 `1×5` 累积冒烟在真实 ACK 集群通过，5 个 cell 全部 PASS。它证明了
fresh Node 扩容、KEDA scale-to-zero、direct/ACK Queue Job、应用 k-of-n barrier、
Argo 串并行 DAG 和最终自动缩容能够在同一条流水线中闭环。

```text
result: PASS (5/5 cells)
run_id: e07-20260727051226-63e4
scope: smoke
statistical conclusion: false
```

本地完整 artifact：

```text
artifacts/e07-end-to-end-tuning-smoke-20260727051226-63e4
```

本次不是正式实验，不把 `5s` cooldown、`k=1` 或单次耗时解释为最优参数或稳定
收益。

## 环境与固定输入

- ACK Managed Kubernetes：`1.36.1`
- Region：`cn-wulanchabu`
- 节点池：`np382116533c5940c48ff67e52ad8b6a26`，`min=0,max=5`
- 基线物理节点：4
- KEDA Helm：`2.20.1`
- ACK Kube Queue Helm：`1.26.3`
- ACK Argo Workflow Chart：`3.5.15`
- workflow-controller：`v3.5.13` 前缀
- KEDA 负载：12 条消息，`λ=1/s`，每条处理 2 秒
- ACK Queue 临时配额：`cpu=1,memory=2Gi`

四个工作镜像均使用同 Region ACR 不可变 digest：

- KEDA worker：
  `sha256:8761ff2e4d116452057bb23b36bb935728125a019749b1b7fa93b57195f71725`
- Redis：
  `sha256:06ca86a2130235868e8688e47988030cfb0b3560970349e3a23a2f4a62f6c594`
- Gang worker：
  `sha256:516cf7258f61e4ec3afc70f844080300396bcf888b994e865f1fb9a4cd144339`
- Argo worker：
  `sha256:7cee4d7ad9bf6dcfbd13822aab434f674b5e007905982075cfe5c387eac57df9`

## Cell 结果

| Cell | Node | KEDA cooldown | Job admission | n/k | Argo | E2E |
|---|---|---:|---|---:|---|---:|
| B0 | cold | 30s | direct | 2/2 | baseline | 238.215s |
| B1 | warm | 30s | direct | 2/2 | baseline | 130.624s |
| B2 | warm | 5s | direct | 2/2 | baseline | 106.581s |
| B3 | warm | 5s | ACK Queue whole-Job | 2/1 | baseline | 108.989s |
| B4 | warm | 5s | ACK Queue whole-Job | 2/1 | tuned | 97.460s |

每个 E2E 边界均包含 KEDA scale-to-zero 等待。B0 还包含真实 Node provisioning，
因此只用 B0/B1 做 cold/warm 激活检查，不要求五个耗时单调下降。

| Cell | Node provisioning | 最后一条处理完成→scale-to-zero | QueueUnit 最终采样状态 | Workflow | B/C overlap | 关键路径 |
|---|---:|---:|---|---:|---:|---:|
| B0 | 94.217s | 28.341s | 不适用 | 70s | 0s | 6 |
| B1 | 0s | 28.327s | 不适用 | 60s | 0s | 6 |
| B2 | 0s | 4.267s | 不适用 | 60s | 0s | 6 |
| B3 | 0s | 2.196s | Running | 60s | 0s | 6 |
| B4 | 0s | 4.280s | Running | 50s | 6s | 5 |

`Running` 是 QueueUnit 已经过 `Dequeued` 后的 post-admission 状态；冻结的
QueueUnit 时间线同时保存了 `Dequeued → Running`。表中的 scale-to-zero 间隔从
最后一条应用完成事件起算，KEDA cooldown 自队列变空起算，两者不要求相等。

## Gate 证据

### Fresh Node

预检计算得到：

```text
当前节点最大 request headroom: 965.863Mi
anchor request:                 1024Mi
fresh Node 所需:                1328Mi
fresh Node 保守 headroom:       1349.859Mi
```

anchor 不能落到四个基线节点，但能与阶段峰值和安全余量一起落到新节点。ACK
实际拉起 `cn-wulanchabu.10.87.16.211`，该 name/UID 不在基线集合；B0–B4 的所有
实验 Pod 均固定到该节点。B0 相比 B1 多 `107.591s`，其中 Node provisioning 为
`94.217s`。

### KEDA

- 5/5 cell 的初始 Deployment 都为 0 副本；
- 每个 cell 均观察到 external metric `0→正值→0`、HPA 正 desired replica、
  worker Ready、ScaledObject Active→Inactive 和最终 scale-to-zero；
- 每个 cell 的 12 条消息生命周期均完整；
- 共保存 551 条去重后的精确应用源时间事件；
- worker Pod 在缩容删除前持续原子归档日志和身份快照，不依赖事后按 Pod 名读取。

### ACK Queue 与应用 barrier

- B0–B2 使用 direct Job，未产生 QueueUnit；
- B3/B4 的 QueueUnit 均按完整 `n=2` 申请，不存在 `minCount` 部分准入；
- 两个 ACK cell 均保存 `Dequeued → Running` 状态，`lastAllocateTime` 存在；
- 两个 rank 均在 Dequeued 后 1 秒 Ready；
- `k=1` 只由应用 barrier 实现，不改变 ACK whole-Job 准入成员数；
- 5 个 Job 共保存 60 条精确应用事件，readiness、barrier 和 useful work 事件完整。

### Argo

- 5/5 Workflow 均为 `Succeeded`；
- 每个 cell 的 A–F 六个阶段各有 start/finish，合计 60 条精确应用事件；
- B0–B3 的 baseline B/C overlap 均为 0，关键路径长度为 6；
- B4 的 tuned DAG 产生 6 秒 B/C 重叠，关键路径长度变为 5；
- B3/B4 的 Workflow 时长为 60/50 秒，但单次差值不作性能外推。

聚合结果中的四个累积激活检查全部为 `true`：warm Node、短 KEDA cooldown、
ACK whole-Job + 应用 `k=1`、并行 Argo DAG。

## 适配中发现并固化的边界

1. ACK Marketplace Chart `1.26.3` 的 job-extensions command 需要固定为镜像实际
   入口 `/usr/bin/kube-queue-controllers`；仓库安装器会校验 Chart SHA-256 后
   在临时目录修正。
2. ACK ElasticQuota 按 Namespace 统计全部 Pod request，包含 `1024Mi` anchor；
   E07 临时配额因此使用 `2Gi`，不能只按两个 Gang Pod 计算。
3. Deployment worker 的 Pod 直接 owner 是 ReplicaSet；事件导出使用冻结的
   ReplicaSet→Deployment owner-chain 证据。
4. KEDA 缩到 0 时 Pod 可能先于最终采集被删除；runner 持续保存 worker 日志和
   Pod 身份，并用原子文件替换避免失败读取截断已有日志。
5. QueueUnit `Running` 表示已经通过 Dequeued 准入，不应被当作未准入状态。
6. 清理 Gate 同时等待 Kubernetes 目标 Node 消失和 ESS
   `total/pending/removing/active` 回到基线，避免云端仍在移除时开始下一轮。

## 清理

runner 没有执行 `kubectl delete node`。删除实验工作负载后，ACK 在
`650.733s` 内自动移除 `.211`。最终证据为：

```text
physical Nodes: 4
target Node present: false
ESS total/pending/removing/active: 4/0/0/4
```

复查不存在本 run 的 Namespace、Lease、ElasticQuotaTree 或 QueueUnit，集群已
恢复到运行前基线。

## 口径限制

本次每个配置只有一次、顺序固定、没有随机区组、重复、置信区间或顺序效应分析。
E2E 包含不同控制器的轮询和清理边界，只用于证明累积 patch 已真实激活、证据链
完整并可清理。若要形成调优结论，仍需另行执行正式实验设计。
