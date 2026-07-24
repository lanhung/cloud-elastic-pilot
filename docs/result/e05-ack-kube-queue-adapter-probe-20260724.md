# E05 ACK Kube Queue 1.26.3 适配探针结果（2026-07-24）

## 环境

- ACK Managed Kubernetes：1.36.1
- Region：`cn-wulanchabu`
- Helm release：`kube-queue/ack-kube-queue`
- Chart/App：`ack-kube-queue 1.26.3`
- Queue API：`scheduling.x-k8s.io/v1alpha1`
- 配额 API：`scheduling.sigs.k8s.io/v1beta1 ElasticQuotaTree`

安装后 `kube-queue-controller` 与 `job-extensions` 均达到 Available。
Chart 渲染的 `job-extensions` 命令为 `/manager`，而该版本镜像中的实际入口为
`/usr/bin/kube-queue-controllers`；按启动错误修正 Deployment 后 Pod 正常运行。

## 原生 Indexed Job 探针

提交参数：

- Batch Job `spec.suspend=true`
- `completionMode=Indexed`
- `parallelism=4`
- `completions=4`
- 每个 worker request：`cpu=10m,memory=8Mi`

Job extension 自动生成 QueueUnit：

```text
spec.podSet[0].count = 4
spec.podSet[0].minCount = absent
spec.request.cpu = 40m
spec.request.memory = 32Mi
```

这证明默认原生 Job 是完整 n=4 请求。

## minCount 反证

API Server 接受给该临时 QueueUnit 写入：

```text
spec.podSet[0].minCount = 2
```

随后把实验叶子 ElasticQuotaTree 上限设置为仅能容纳两个 worker：

```text
cpu = 20m
memory = 16Mi
```

Queue controller 仍按完整请求拒绝 QueueUnit，状态消息报告：

```text
Insufficient quota(memory): request 32Mi, max 16Mi
```

因此在当前 Chart 1.26.3、原生 Batch Job extension 和 controller 配置下，
`minCount=2` 没有把 Quota 请求从 4 个成员缩减到 2 个成员。CRD schema 中存在
该 Alpha 字段，不等于已启用对应 PartialAdmission feature gate。

## 对 E05 的决定

E05 不再使用“ACK 原生 k-of-n 部分准入”表述：

- ACK QueueUnit 的 `queue_admission_members` 固定为完整 `n`；
- `k` 由 E05 worker 的真实应用 barrier 实现；
- 第 k/第 n 个启动统计来自逐 Pod `Ready=True`；
- QueueUnit `podState.running` 只作运行状态证据，不代替 Ready；
- 准入起点使用 `ACK_QUEUE_UNIT_DEQUEUED`；
- runner 发现 QueueUnit `count != n` 或出现 `minCount` 时 fail-closed。

若后续 ACK Kube Queue 版本启用真正的 PartialAdmission，必须另建版本化实验，不
修改本结果的 `whole-job` 历史口径。

## 清理确认

探针完成后删除了临时 Job、QueueUnit、Queue、namespace 和 ElasticQuotaTree。
复查时集群中不存在探针遗留的 ElasticQuotaTree、QueueUnit 或 Queue。
