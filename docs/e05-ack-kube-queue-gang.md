# E05：ACK Kube Queue 整 Job 准入与应用层 k-of-n Barrier

## 1. 当前结论

本分支适配的是 ACK Kube Queue Chart `1.26.3`，不是上游 Kueue 的
`Workload/ClusterQueue/LocalQueue/ResourceFlavor` API。

在当前 ACK 集群和该版本中，Kubernetes Indexed Job 的实际语义是：

```text
QueueUnit 申请并获准 n 个 Pod 的全部资源
                     │
                     ▼
QueueUnit Dequeued → Job spec.suspend=false → 创建 n 个 Pod
                                                    │
                                                    ▼
                                 应用 worker 达到 k 个后释放 barrier
```

因此必须分开记录：

- `queue_admission_members=n`：ACK Kube Queue 的整 Job 配额准入；
- `application_barrier_minimum=k`：业务允许开始有效工作的成员阈值；
- `k=n` 与 `k=ceil(n/2)` 比较的是应用 barrier 策略，不是 ACK 原生部分准入。

QueueUnit CRD 虽然包含 `spec.podSet[].minCount` 字段，但对自动生成的原生
Batch Job QueueUnit 写入该字段后，`ack-kube-queue 1.26.3` 的配额判断仍使用完整
`spec.request`。E05 runner 会验证 QueueUnit 的 Pod 总数等于 `n`，并在出现
`minCount` 时 fail-closed，防止把未生效字段误当作实验处理。

## 2. Helm 安装和健康检查

使用用户指定的阿里云 Chart 仓库：

```bash
helm repo add aliyunhub \
  https://aliacs-app-catalog.oss-cn-hangzhou.aliyuncs.com/charts-incubator/
helm repo update aliyunhub

helm upgrade --install ack-kube-queue aliyunhub/ack-kube-queue \
  --version 1.26.3 \
  --namespace kube-queue \
  --create-namespace
```

等价的固定包地址是：

```text
https://aliacs-app-catalog.oss-cn-hangzhou.aliyuncs.com/charts-incubator/ack-kube-queue-1.26.3.tgz
```

安装后检查：

```bash
helm list -n kube-queue
kubectl -n kube-queue get deploy,pod
kubectl api-resources --api-group=scheduling.x-k8s.io
kubectl get crd \
  queueunits.scheduling.x-k8s.io \
  queues.scheduling.x-k8s.io \
  elasticquotatrees.scheduling.sigs.k8s.io
```

当前集群的 `job-extensions` 镜像入口是
`/usr/bin/kube-queue-controllers`。如果 Chart 1.26.3 渲染出的 Deployment
使用 `/manager` 且 Pod 日志明确显示入口不存在，可修正该 Deployment：

```bash
kubectl -n kube-queue patch deployment job-extensions --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/command/0","value":"/usr/bin/kube-queue-controllers"}]'
kubectl -n kube-queue rollout status deployment/job-extensions
```

这是 Chart 与镜像的版本匹配修正；再次执行 Helm upgrade 后要重新核验渲染结果。
不要在没有看到对应启动错误时盲目 patch。

## 3. E05 已实现的适配

### 3.1 采集器

`hooke-controller` 同时兼容两套后端：

- 上游 Kueue：`kueue.x-k8s.io/v1beta1 Workload`；
- ACK Kube Queue：`scheduling.x-k8s.io/v1alpha1 QueueUnit`。

ACK 路径记录：

- `ACK_QUEUE_UNIT_CREATED`
- `ACK_QUEUE_UNIT_ENQUEUED`
- `ACK_QUEUE_UNIT_RESERVED`
- `ACK_QUEUE_UNIT_DEQUEUED`
- `ACK_QUEUE_UNIT_RUNNING`
- `ACK_QUEUE_POD_STATE_CHANGED`
- `ACK_QUEUE_ALL_PODS_RUNNING`
- `ACK_QUEUE_JOB_UNSUSPENDED`
- `ACK_QUEUE_JOB_FINISHED` / `ACK_QUEUE_JOB_FAILED`

QueueUnit 事件通过 owner reference/consumer reference 改写为所属 Job UID，因而可与
Pod、Job 和应用事件稳定关联。`Dequeued` 优先使用
`status.lastAllocateTime`；缺失服务端时间时才使用观察时间，并明确标记
`approximate=true`。

`QueueUnit.status.podState.running` 只表示 Pod 处于 Running，不等于 Kubernetes
`Ready=True`。第 k 个 Ready 必须来自逐 Pod Condition。

### 3.2 E05 worker

`cmd/e05-gang-worker` 运行于 Indexed Job：

1. 每个 Pod 从
   `batch.kubernetes.io/job-completion-index` 获取 rank；
2. Headless Service 设置 `publishNotReadyAddresses=true`；
3. worker 的 `/readyz` 首次被 kubelet 成功探测后，才允许加入 barrier；
4. worker 通过 Service DNS 发现 rank 0；
5. rank 0 幂等记录成员，达到 `k` 时释放 barrier；
6. 迟到成员加入已释放的 barrier 后可立即继续；
7. 每个 rank 写出精确源时间的 readiness/barrier/useful-work 事件；
8. rank 0 在所有 `n` 个成员加入前保持协调服务，另有超时保护。

该 Gate 证明成员已返回成功 readiness probe；Pod `Ready=True` 是否已经持久化到
API Server 仍以 Pod Condition Watch 为准，两者分别保存，不能互相覆盖。

应用事件默认先持久化到容器 stdout，实验结束后再根据冻结的 Pod UID、owner UID、
Container ID 和 image digest 导出，避免实验 Pod 必须回连操作者本机。

## 4. 集群级配额注意事项

ACK 当前只允许 `kube-system` 中存在一个 `ElasticQuotaTree`。E05 runner：

- 只在集群完全没有 ElasticQuotaTree 时继续；
- 不覆盖、不共享现有树；
- 使用固定名称的 Lease 防止两个 E05 runner 并发；
- 创建一个仅绑定本次 namespace 的临时树；
- 等待 ACK controller 在 `kube-queue` 安装 namespace 创建对应叶子 Queue；
- 每次只运行一个 Job，`kube-queue/max-jobs=1`；
- 按配置在成功或失败后删除本次 tree、namespace 和 Lease。

如果集群已有生产配额树，应停止使用内置 runner，并先设计由管理员管理的独立实验
叶子配额；不能为了实验删除生产树。

## 5. 运行准备

提交代码后，从干净 worktree 构建并推送同 Region ACR：

```bash
make e05-image-push \
  IMAGE_REPOSITORY=<cn-wulanchabu-same-region-acr-repository>
```

复制配置并填写真实值：

```bash
cp configs/kube-queue-gang.env.example configs/kube-queue-gang.env
$EDITOR configs/kube-queue-gang.env
```

至少确认：

- kube context、API Server 和 cluster ID 精确匹配；
- Helm release 为 `ack-kube-queue-1.26.3` 且两个 Deployment 可用；
- `E05_APP_IMAGE` 是构建脚本产出的不可变 digest；
- selector 只指向已有 Ready CPU 节点，不触发 Node 扩容；
- 节点能容纳 `4 × worker request`；
- `E05_QUOTA_CPU/MEMORY` 不小于 `4 × worker request`；
- 集群不存在其他 ElasticQuotaTree；
- 正式运行前没有其他 E05 Lease。

先执行只读预检：

```bash
make e05-ack-check
```

通过后才设置：

```bash
CONFIRM_E05_EXECUTION="yes"
make e05-ack
```

默认 Pilot 是 5 个随机区组，每个区组包含：

| n | k | QueueUnit 准入 | 应用 barrier |
|---:|---:|---:|---:|
| 2 | 2 | 2 | 2 |
| 2 | 1 | 2 | 1 |
| 4 | 4 | 4 | 4 |
| 4 | 2 | 4 | 2 |

## 6. Artifact 与 Gate

每个 cell 保存：

- 提交的 Service/Job manifest；
- QueueUnit、Job、Pod 的连续 API 快照；
- Job、Pod 和 QueueUnit 终态；
- 每个 rank 的原始 stdout；
- 由冻结身份归一化的 application event NDJSON；
- 第 k/第 n 个 Pod Ready、首次 useful work 和准入语义摘要。

以下任一情况使 cell 失败：

- QueueUnit 请求的成员数不等于 `n`；
- QueueUnit 出现原生 `minCount`；
- 任一 rank 缺少 Ready；
- 任一 rank 缺少 barrier enter/exit 或 useful-work 起止；
- Job 未完成；
- QueueUnit 没有随 Job 删除；
- 采样器或日志身份校验失败。

`barrier_after_kth_ready_seconds` 跨 Kubernetes API Server 与应用节点时钟计算。
正式统计前必须验证时钟同步和不确定度；负的小量值可能来自 readiness probe 到
Pod Condition 持久化的观察差，而不能解释为负 barrier 成本。

## 7. 版本化边界

ACK Kube Queue 的 QueueUnit API、状态字段和控制器行为不是上游 Kueue API 的同义
替代。升级 Chart 后，至少重新验证：

- 自动 QueueUnit 的 `podSet/count/request`；
- Enqueued、Reserved、Dequeued、Running 状态和时间字段；
- Job `spec.suspend` 解挂行为；
- `minCount` 是否开始真正影响配额；
- ElasticQuotaTree 单例和自动 Queue 创建行为；
- `job-extensions` 镜像入口。

若未来版本真正支持原生部分准入，应新增独立实验变体和事件字段，不得悄悄改变本
版本 `queue_admission_policy=whole-job` 的历史口径。

本次版本探针的输入、反证和清理记录见
[`result/e05-ack-kube-queue-adapter-probe-20260724.md`](result/e05-ack-kube-queue-adapter-probe-20260724.md)。
