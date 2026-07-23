配置优先级为命令行参数（存在时）> 环境变量 > 示例配置文件。生产环境中的 MySQL DSN 和 Token 必须来自 Kubernetes Secret，不应提交到仓库。

E01 四层基线先复制 `four-layer-baseline.env.example` 为
`four-layer-baseline.env`。真实配置已被 `.gitignore` 排除；先运行
`make e01-ack-check`，通过后才运行 `make e01-ack`。

E01 smoke 镜像可先用
`make e01-images SMALL_PADDING_MIB=64 LARGE_PADDING_MIB=512` 在本地
构建。推送必须显式运行
`make e01-images-push IMAGE_REPOSITORY=<same-region-acr-repository>`；脚本会
输出可直接填入 E01 配置的两个不可变 digest，并拒绝从 dirty worktree
推送。默认元数据写入已被 Git 忽略的 `dist/e01-images.env`；E01 预检会
校验其中的构建提交和两个 digest，并将副本保存到本次实验 artifact。

当前 ACK hook 可直接配置为：

```bash
CACHE_RESET_HOOK="scripts/e01-cache-hook.py"
CACHE_VERIFY_HOOK="scripts/e01-cache-hook.py"
ACK_EVENTS_EXPORT_HOOK="scripts/export-goatscaler-events.py"
RUNTIME_EVENTS_EXPORT_HOOK="scripts/export-runtime-journal-events.py"
E01_APP_EVENT_MODE="log"
```

缓存和运行时 hook 会创建短生命周期的特权 helper Pod，进入目标节点的 host
namespace 调用节点自带的 `crictl`、`ctr` 与 `journalctl`。因此还必须指定一个
目标节点可拉取、包含 `nsenter`、且最好已缓存的 `E01_HOST_HELPER_IMAGE`。
GOATScaler hook 需要配置对应集群控制面日志的 `ACK_SLS_REGION`、
`ACK_SLS_PROJECT` 和 `ACK_SLS_LOGSTORE`。`log` 应用事件模式不要求 ACK Pod
能够回连操作者机器；`sdk` 模式才要求可路由的 ingester URL 和鉴权 token。

E02 先复制 `node-warm-pool.env.example` 为 `node-warm-pool.env`。E02 使用五个
随机配对区组，每个区组包含一次 `cold-node` 和一次 `warm-node`。两种变体使用
同一不可变小镜像、相同资源 request/limit 和冷镜像缓存；只有节点池是否已经
保留一个 Ready 节点不同。先运行 `make e02-ack-check`，确认只读预检通过后，
再显式设置 `CONFIRM_E02_POOL_MUTATION=yes` 运行 `make e02-ack`。
配对主指标使用操作者主机同一 `CLOCK_MONOTONIC` 上从 scale 请求到 Deployment
rollout 成功的时长；跨 Kubernetes/节点时钟的 trace total/node/overlap 只保留为
审计原值，不进入配对结论。

默认的 `E02_NODE_POOL_CONTROL_HOOK=scripts/ack-node-pool-control.sh` 需要本机安装
阿里云 CLI、`jq` 和 Python 3。它先用 `DescribeClusterDetail` 将 CLI 的 cluster、
region 和 API Server 与当前 kube context 精确交叉绑定，再查询或修改节点池。
凭证使用 CLI profile 或 RAM role；`check` 只调用两个查询接口。也可以替换为满足
相同契约的环境适配器。编排器调用：

```text
--action check
--action snapshot
--action set-min --min-size 0|1
--action restore --snapshot <snapshot.json>
```

每次调用还会传入 `--cluster-id`、`--node-pool-id`、精确的节点池名称和资源组、
当前 kube API Server、selector、taint 和 `--evidence`。Hook 必须原子写入指定
evidence 文件，并满足
以下 JSON 契约：

```json
{"action":"check","cluster_id":"...","node_pool_id":"...","node_pool_name":"...","resource_group_id":"...","region_id":"...","api_server":"https://...","min_size":0,"max_size":1,"auto_scaling_enabled":true,"nodepool_type":"ess","is_default":false,"selector":{"key":"node.alibabacloud.com/nodepool-id","value":"..."},"taint":{"key":"hooke.io/experiment","value":"elastic","effect":"NoSchedule"},"observed_at":"..."}
{"action":"snapshot","cluster_id":"...","node_pool_id":"...","node_pool_name":"...","resource_group_id":"...","region_id":"...","api_server":"https://...","min_size":0,"max_size":1,"auto_scaling_enabled":true,"nodepool_type":"ess","is_default":false,"selector":{"key":"node.alibabacloud.com/nodepool-id","value":"..."},"taint":{"key":"hooke.io/experiment","value":"elastic","effect":"NoSchedule"},"observed_at":"..."}
{"action":"set-min","cluster_id":"...","node_pool_id":"...","node_pool_name":"...","resource_group_id":"...","region_id":"...","api_server":"https://...","requested_min_size":1,"observed_min_size":1,"observed_max_size":1,"changed":true,"task_id":"...","task_state":"success","auto_scaling_enabled":true,"nodepool_type":"ess","is_default":false,"selector":{"key":"node.alibabacloud.com/nodepool-id","value":"..."},"taint":{"key":"hooke.io/experiment","value":"elastic","effect":"NoSchedule"},"observed_at":"..."}
{"action":"restore","cluster_id":"...","node_pool_id":"...","node_pool_name":"...","resource_group_id":"...","region_id":"...","api_server":"https://...","observed_min_size":0,"observed_max_size":1,"prior_mutation_uncertain":false,"task_id":"...","task_state":"success","auto_scaling_enabled":true,"nodepool_type":"ess","is_default":false,"selector":{"key":"node.alibabacloud.com/nodepool-id","value":"..."},"taint":{"key":"hooke.io/experiment","value":"elastic","effect":"NoSchedule"},"observed_at":"..."}
```

`check` 必须严格只读。内置 adapter 会在云修改请求发出前原子记录意图，强制保存
`task_id` 并用 `DescribeTaskInfo` 等待终态；restore 总会提交一个恢复任务作为顺序
栅栏。若请求是否被 ACK 接受无法证明，会完成尽可能安全的恢复但保留 Lease，要求
人工核验。编排器还会验证 Kubernetes 实态稳定并做最终云端复读。不要用
`kubectl delete node` 代替节点池/ECS 缩容。云凭证应由 CLI profile、RAM role 或
外部 credential 文件提供，不能写入 E02 配置或 evidence。E02 只接受精确名称和
资源组下的非默认 ESS 专用池、标准 ACK nodepool-id selector 和精确的
`NoSchedule` 实验 taint；当前 `min` 必须为 0 或 1。
该池必须为空载专用池：缩到 `min=0` 前，编排器会枚举目标节点上的全部 Pod，
只允许 DaemonSet 或静态镜像 Pod，发现任何其他活动工作负载都会拒绝缩容。

E03 先复制 `image-cache-concurrency.env.example` 为
`image-cache-concurrency.env`。镜像构建器先用零 padding 镜像校准基础体积，再为
100、500、1024 MiB 三个总大小目标各生成 4 个不同 digest；同档镜像共享应用层，
但确定性不可压缩 padding 层不同，避免把
同一 digest 的 containerd 合并请求误当成 2/4 路真实下载。使用：

```bash
make e03-images-push \
  IMAGE_REPOSITORY=<same-region-acr-repository>
make e03-ack-check
```

只读预检通过后，才设置 `CONFIRM_E03_EXECUTION=yes` 执行 `make e03-ack`。
每个重复包含 27 个 cell：existing 节点上的 cold/warm，以及 fresh new 节点上的
cold，分别交叉三档尺寸与并发 1/2/4。`new+warm` 被排除，因为完成预热后该节点
已不再是 new 条件。existing cell 使用精确 `kubernetes.io/hostname` 固定到同一
节点；new cell 要求弹性池运行前为 0，运行中只新增一个节点，所有批量 Pod 必须
落在该节点。

E03 不把“同时创建 4 个 Pod”直接等同于 4 路拉取。runner 为每个并发槽使用不同
digest、并行提交 Deployment patch，并从精确 `IMAGE_PULL_START/END` 区间计算
实际最大并发；实际值达不到请求值时 fail-closed。默认
`E03_REQUIRE_UNPACK_SUBSTAGE=false` 只形成 pull-total pilot。只有配置的运行时
hook 能输出与 ACK containerd build-id 绑定的真实
`IMAGE_UNPACK_START/END` 时才可打开该 Gate；严格模式会分别输出 download、
unpack 和 image-total 时延，缺失端点不会用近似事件补齐。
并发 2/4 的目标节点还必须允许并行镜像拉取；若 kubelet/运行时实际串行，结果会
按观测到的拉取区间失败，而不会把请求并发数当作实际并发数。
