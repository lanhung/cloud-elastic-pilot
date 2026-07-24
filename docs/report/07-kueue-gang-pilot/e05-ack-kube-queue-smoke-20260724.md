# E05 ACK Kube Queue 冒烟结果（2026-07-24）

## 结论

E05 的 1×4 ACK 冒烟通过，范围仅用于验证安装、准入、Indexed Job barrier、事件
完整性和清理流程，不作为正式统计实验。

```text
result: PASS (4/4 cells)
run_id: e05-20260724081915-36d6
chart: ack-kube-queue-1.26.3
queue admission: whole Job n
application barrier: k-of-n
```

本地完整 artifact：

```text
artifacts/e05-kube-queue-gang-pilot-20260724081915-36d6
```

## 版本与环境

- ACK Managed Kubernetes：1.36.1
- Region：`cn-wulanchabu`
- Helm release：`kube-queue/ack-kube-queue`
- E05 image source commit：`b4cdfd644aa0e934ce04c642602eb94f1889276e`
- E05 image digest：
  `sha256:516cf7258f61e4ec3afc70f844080300396bcf888b994e865f1fb9a4cd144339`
- 固定节点：`cn-wulanchabu.10.170.108.83`
- 随机区组：1
- cell：4

## Cell 结果

| Job | n | 应用 k | QueueUnit 准入成员 | 第 k 个 Ready 延迟 | 第 n 个 Ready 延迟 | 第 k 个 Ready → 首 useful work |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `e05-001-n2-k1` | 2 | 1 | 2 | 1.0 s | 1.0 s | 0.4765 s |
| `e05-002-n2-k2` | 2 | 2 | 2 | 1.0 s | 1.0 s | 0.4613 s |
| `e05-003-n4-k4` | 4 | 4 | 4 | 1.0 s | 1.0 s | 0.7908 s |
| `e05-004-n4-k2` | 4 | 2 | 4 | 1.0 s | 10.0 s | 0.9762 s |

四个 QueueUnit 都按完整 `n` 请求和准入，没有把应用 `k` 当作 ACK 部分准入。
`n=4,k=2` 中一个成员较晚 Ready，但首批成员仍按应用 barrier 策略开始 useful
work；这是功能性证据，不做性能或显著性解释。

## 原子事件 Gate

共导出 72 条精确应用源时间事件：

| Cell | rank 数 | 事件数 | 每 rank 事件类型数 |
| --- | ---: | ---: | ---: |
| n=2, k=1 | 2 | 12 | 6 |
| n=2, k=2 | 2 | 12 | 6 |
| n=4, k=4 | 4 | 24 | 6 |
| n=4, k=2 | 4 | 24 | 6 |

每个 rank 均具有：

- `APPLICATION_LISTENING`
- `READINESS_PROBE_FIRST_SUCCESS`
- `GANG_BARRIER_ENTER`
- `GANG_BARRIER_EXIT`
- `USEFUL_WORK_STARTED`
- `USEFUL_WORK_FINISHED`

额外 Gate：

- 4/4 Job 的 `status.succeeded == spec.completions`；
- 所有容器 restart count 为 0；
- 所有 Pod 使用冻结的 E05 image digest；
- QueueUnit `lastAllocateTime` 存在，准入时间不是观察值 fallback；
- 每个 Job 删除后所属 QueueUnit 均被回收。

## 冒烟中发现并修复的 ACK 差异

正式通过前的预运行暴露了三个适配边界：

1. ElasticQuotaTree 自动生成的 Queue 位于 `kube-queue` 安装 namespace；
2. ACK kubelet 要求 distroless workload 显式使用数字 UID/GID `65532`；
3. Job 完成时 QueueUnit 会把 `podSet.count` 从初始 `n` 收缩为 0，因此 admission
   汇总必须保留历史最大请求，同时使用最新状态。

对应修复已加入 runner、manifest 和 QueueUnit 采集测试。

## 清理

运行结束后复查：

- 无 E05 ElasticQuotaTree；
- 无 E05 Queue；
- 无 E05 QueueUnit；
- 无 `hooke-e05-kube-queue-lock` Lease；
- 无 E05 实验 namespace。

因此冒烟没有在 ACK 集群中留下实验资源。

## 口径限制

本次只有一个随机区组，并且 QueueUnit/Pod Condition 时间为秒级边界。表中时延只
用于确认事件顺序和计算链可运行，不能用于估计分布、比较 k 策略或形成调优结论。
