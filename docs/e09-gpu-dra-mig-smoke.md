# E09 单 A100 GPU/DRA/MIG 冒烟

E09 是独立于 CPU Gate 的单卡功能冒烟。它验证一张完整物理 A100 上的真实链路：

```text
MIG Manager profile 请求
  → pending/rebooting
  → success
  → 重启 A100 上的 NVIDIA DRA kubelet plugin
  → resource.k8s.io/v1 ResourceClaim
  → scheduler allocation + Pod UID reservation
  → CUDA malloc/memset/synchronize
  → FIRST_CUDA_SUCCESS
```

它不自动创建 ACK 集群、GPU 节点、GPU Operator 或 DRA driver。先完成代码和镜像，
等 GPU 集群存在后运行只读预检，避免为了开发阶段长期保留 A100。

## 实验边界

- 一张完整物理或 PCIe passthrough A100 足够做本功能冒烟；预切好的 vGPU 不接受。
- 单卡不能证明多节点调度、通用性、吞吐、干扰、p95/p99 或弹性收益。
- MIG geometry 由 NVIDIA MIG Manager 根据 Node label 改变；DRA 随后分配已经发布
  的设备。PASS 不得表述为“DRA 自己动态重构了 MIG”。
- `ResourceClaim.status.allocation` 只证明已分配，不等于 kubelet 已准备设备。
  `RESOURCE_CLAIM_PREPARED` 仅在每个已分配设备都有显式 `Ready=True` condition
  时生成。driver 不报告该 condition 时，以真实 `FIRST_CUDA_SUCCESS` 作为
  “prepared 不晚于此时”的上界，不能伪造精确 prepared 时间。
- NVIDIA 当前 A100 已知约束是：MIG 改动后 DRA kubelet plugin 不会被 MIG Manager
  自动驱逐。runner 因此强制删除并等待该节点上的 plugin 以新 UID Ready。

## 代码组成

| 文件 | 作用 |
|---|---|
| `internal/kube/dra.go` | DRA v1/fallback watch、语义事件、Claim→Pod→设备关联、MIG label 状态机 |
| `examples/e09-gpu-dra-mig/main.cu` | 真实 CUDA 内存操作与源时间事件 |
| `scripts/e09-gpu-dra-mig.py` | 清单渲染、只读环境 Gate、最终 fail-closed 汇总 |
| `scripts/ack-gpu-dra-mig-smoke.sh` | ACK 预检、隔离 Hooke、reshape、plugin restart、Claim/Pod、恢复与 artifact |
| `scripts/build-e09-images.sh` | 构建 collector stack 与 CUDA probe 两个不可变镜像 |
| `configs/gpu-dra-mig.env.example` | 无凭证示例配置 |

collector 优先选择 `resource.k8s.io/v1`，仅为读取旧证据保留 `v1beta2/v1beta1`
fallback。E09 runner 则严格要求 Kubernetes 1.34.2+ 和 `resource.k8s.io/v1`，
不会把旧版 API 与本次结果混合。

## 原子事件与精度

| 事件 | 事实来源 | 精度 |
|---|---|---|
| `DRA_DEVICECLASS_AVAILABLE` | DeviceClass informer | API 对象 |
| `DRA_RESOURCESLICE_PUBLISHED` | ResourceSlice informer；白名单保留 device name/UUID/type/profile | 创建时间或明确的 spec 观察时间 |
| `RESOURCE_CLAIM_CREATED` | `metadata.creationTimestamp` | API Server |
| `RESOURCE_CLAIM_ALLOCATED` | `status.allocation.allocationTimestamp`；缺失时为观察时间 | 精确字段或 `approximate=true` |
| `RESOURCE_CLAIM_RESERVED` | `status.reservedFor` 的 Pod UID | `approximate=true` 的状态观察 |
| `RESOURCE_CLAIM_PREPARED` | 所有 allocated device 的 `Ready=True` condition | condition 时间；缺时间则近似 |
| `MIG_RESHAPE_REQUESTED` | runner 与 profile label 同一 patch 中的 UTC annotation | 源时间 |
| `MIG_RESHAPE_STARTED` | `nvidia.com/mig.config.state=pending/rebooting` | label 观察，近似 |
| `MIG_RESHAPE_FINISHED` | `nvidia.com/mig.config.state=success` | label 观察，近似 |
| `MIG_RESHAPE_FAILED` | `nvidia.com/mig.config.state=failed` | label 观察，近似 |
| `FIRST_CUDA_SUCCESS` | `cudaDeviceSynchronize()` 成功返回后的进程源时间 | 精确应用边界 |

事件 payload 只保存白名单字段，不复制完整 ResourceClaim、ResourceSlice 或
DeviceClass。最终对象和原始组件日志单独保存在本次 artifact。

## 建群后的前置条件

1. ACK Kubernetes 至少 1.34.2，并能读取
   `resourceclaims/resourceslices/deviceclasses.resource.k8s.io/v1`。
2. 一个固定 CPU pool 承载 Hooke controller/ingester；一个专用、无租户 Pod 的
   A100 Worker 承载 GPU 冒烟。
3. GPU Worker 有稳定 `providerID`、`nvidia.com/mig.capable=true` 和保护性
   `NoSchedule` taint；Runner 会拒绝含活动非 DaemonSet Pod 的目标节点。
4. GPU Operator、MIG Manager、NVIDIA driver 和 NVIDIA DRA kubelet plugin 已经
   Ready；driver 可以由 GPU Operator 管理，也可以由 ACK 预装在宿主机。
   `gpu.nvidia.com` ResourceSlice 非空，`mig.nvidia.com` DeviceClass 存在。
   旧的 NVIDIA Device Plugin 必须在目标节点关闭，不能同时暴露
   `nvidia.com/gpu` 或 `nvidia.com/mig-*` allocatable。
5. GPU Worker 带 `nvidia.com/dra-kubelet-plugin=true`，DRA chart 使用同一个
   Node selector。Operator 管理 driver 时，其 driver manager 容器还必须带
   `NODE_LABEL_FOR_GPU_POD_EVICTION=nvidia.com/dra-kubelet-plugin`；ACK 预装
   driver 时设置 `E09_DRIVER_MODE=preinstalled`，并要求 Node 上有
   `nvidia.com/cuda.driver-version.full`。
6. MySQL 8.0+ 可从 ACK Pod 访问；同 Region ACR 可拉取两个 E09 digest。
7. source MIG profile 当前为 `success`。40 GB A100 常见 target 是
   `all-1g.5gb`，80 GB A100 常见 target 是 `all-1g.10gb`，但必须以本集群
   MIG Manager 的实际 ConfigMap 为准，不能只按本文猜测；MIG strategy 必须是
   `single` 或 `mixed`。
8. 本地执行端使用支持 `--rollback-on-failure` 的 Helm 4；其版本会写入 artifact。

runner 不安装或升级 NVIDIA 组件。实际版本、镜像 digest、Node、DeviceClass、
ResourceSlice、`nvidia-smi -L`、MIG Manager 日志和可选 DCGM 快照都会冻结到
artifact。

截至 2026-07-29，本实验锁定的官方安装契约是 GPU Operator `v26.3.3` 和
NVIDIA DRA driver `v0.4.1`。ACK 的安装参数仍需按实际 OS、driver 来源和
containerd 配置调整，但以下契约不能省略：

```text
GPU Operator: devicePlugin.enabled=false
GPU Operator: driver.manager.env NODE_LABEL_FOR_GPU_POD_EVICTION=nvidia.com/dra-kubelet-plugin
GPU Operator: mig.strategy=single 或 mixed
DRA driver:   gpuResourcesEnabledOverride=true
DRA driver:   kubeletPlugin.nodeSelector nvidia.com/dra-kubelet-plugin=true
DRA driver:   nvidiaDriverRoot=/run/nvidia/driver（Operator 管理 driver 时）
DRA driver:   nvidiaDriverRoot=/（ACK 预装 driver 时）
GPU Operator: driver.enabled=false、toolkit.enabled=false（ACK 同时预装 driver/toolkit 时）
```

新装 `v0.4.1` chart 的默认 kubelet-plugin selector 是
`dra-driver-nvidia-gpu-component=kubelet-plugin`。从 v25.x 升级并保留
`nameOverride=nvidia-dra-driver-gpu` 时，配置文件中应改成
`nvidia-dra-driver-gpu-component=kubelet-plugin`。

## 构建不可变镜像

CUDA devel/runtime base 必须先解析为同一目标平台的
`repository@sha256:<digest>`。构建器拒绝 mutable tag，也拒绝从 dirty worktree
推送：

```bash
export E09_STACK_IMAGE_REPOSITORY=<same-region-acr>/hooke/e09-stack
export E09_PROBE_IMAGE_REPOSITORY=<same-region-acr>/hooke/e09-probe
export E09_CUDA_DEVEL_IMAGE='nvcr.io/nvidia/cuda@sha256:<devel-digest>'
export E09_CUDA_RUNTIME_IMAGE='nvcr.io/nvidia/cuda@sha256:<runtime-digest>'

make e09-images-push
```

`dist/e09-images.env` 会记录源码 commit、平台、两个输出 digest 和两个 CUDA base
digest。runner 要求这些值与当前干净 `HEAD` 完全一致。

## 配置与只读预检

```bash
cp configs/gpu-dra-mig.env.example configs/gpu-dra-mig.env
$EDITOR configs/gpu-dra-mig.env
make e09-ack-check
```

`e09-ack-check` 只做读取和 `nvidia-smi -L` 查询，不创建 Namespace/Lease，不 patch
Node，也不删除 DRA Pod。它验证：

- kube context、API Server、Kubernetes minor 和 Git/image identity；
- 恰好一张完整 A100、架构、providerID、MIG source profile 和保护性 taint；
- GPU 节点上没有活动租户 Pod；
- Operator driver Pod 或 ACK 预装 driver label、MIG Manager、DRA plugin 就绪；
- DRA 节点 selector、适用时的 driver-manager 驱逐标签一致，旧 Device Plugin 不存在；
- DeviceClass/ResourceSlice 和必要操作者 RBAC；
- 隔离 Namespace、Helm release 和 Lease 均不存在。

只有预检 PASS 后，才同时设置：

```text
CONFIRM_E09_EXECUTION=yes
CONFIRM_MIG_RECONFIGURATION=yes
```

再运行：

```bash
make e09-ack
```

两个确认分别授权隔离实验资源和真实 MIG geometry 改动，缺一则退出。

## 执行与恢复

执行阶段先创建 Lease 和隔离 Hooke release，再创建一个 run。Controller 在固定
CPU pool 上启动并形成 DeviceClass/ResourceSlice 初始证据，随后 runner：

1. 冻结 Node 原始对象和 source profile；
2. 原子 patch target profile、run ID、request ID 和 UTC request time；
3. 观察 `pending/rebooting → success`，失败或超时立即 fail；
4. 捕获 MIG Manager 日志并强制重启 A100 上的 DRA kubelet plugin；
5. 等待该 Node 的 ResourceSlice 再次非空，并保存 `nvidia-smi -L`；
6. 创建 `resource.k8s.io/v1` ResourceClaim，冻结 Claim UID；
7. 创建只消费该 Claim 的 CUDA Pod，冻结 Pod UID；
8. 导入 Pod stdout 中的 `FIRST_CUDA_SUCCESS`，再从 MySQL 导出完整原子事件；
9. 按 Claim UID、Pod UID、allocation `(driver,pool,device)`、ResourceSlice
   device UUID 和 CUDA UUID 生成报告；
10. 删除实验 Pod/Claim，恢复原 MIG profile，再次重启 DRA plugin。

`E09_RESTORE_MIG_PROFILE=true` 是默认安全值，成功和失败都会恢复。恢复或 plugin
重启无法确认时，runner 返回失败并保留 Lease，要求人工核验；不会静默宣称清理
成功。如果 workload Namespace 删除未得到确认，runner 不会对可能仍在使用中的
GPU 执行 profile 恢复，而是保留 target profile、Hooke 诊断资源和 Lease。
失败退出时还会先 best-effort 停止 run、导出当时已持久化的 MySQL 事件，并冻结
退出时 Node、MIG Manager 日志和 DRA Pod 状态。

## PASS Gate

- Node 真实经过 target profile 的非 success 状态并最终 `success`；
- A100 DRA plugin 的 Pod UID 在 reshape 后发生变化且重新 Ready；
- 单 A100 的 post-reshape pool 完整且只有一个 ResourceSlice，其中发布 MIG
  device；`nvidia-smi -L` 也出现 MIG device；
- ResourceClaim 有真实 allocation result，并按精确 Pod UID `reservedFor`；
- allocation `(driver,pool,device)` 存在于 reshape 后 ResourceSlice，且其
  `uuid` 属性与 CUDA 实际 UUID 一致；
- Pod container 的 `resources.claims` 与同名 `spec.resourceClaims` 一致；
- CUDA Pod 在精确 target hostname 一次成功、无重启；
- `FIRST_CUDA_SUCCESS` 带相同 Claim UID、Pod UID、DeviceClass 和合法 CUDA UUID；
- MIG、reshape 后 ResourceSlice、Claim、Pod、CUDA 必需事件全部从 MySQL
  回读且因果顺序成立；
- 没有 `MIG_RESHAPE_FAILED`；
- source MIG profile 和 DRA plugin 最终恢复成功。

如果 driver 没有填充 `ResourceClaim.status.devices[].conditions`，
`RESOURCE_CLAIM_PREPARED` 可以缺失，但 `FIRST_CUDA_SUCCESS` 不能缺失。报告会明确
写成 upper bound，而不是把 allocation 时间冒充 prepared 时间。

## Artifact

输出目录为：

```text
artifacts/e09-gpu-dra-mig-smoke-<UTC>/
```

至少包含 kube/version/API、Git 和镜像锁、Node 前后/恢复对象、MIG 状态观察、
MIG Manager 日志、DRA plugin 新旧 Pod、DeviceClass/ResourceSlice、Claim/Pod
最终对象、`nvidia-smi`、CUDA stdout、应用 NDJSON、MySQL 事件 NDJSON、
`summary.json` 和 `report.md`。配置中的 DSN 不会复制到 artifact。

## 版本依据

- [Kubernetes Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [Kubernetes ResourceClaim v1 API](https://kubernetes.io/docs/reference/kubernetes-api/resource/resource-claim-v1/)
- [NVIDIA GPU Operator：DRA Driver](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/dra-intro-install.html)
- [NVIDIA GPU Operator with MIG](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-mig.html)
- [NVIDIA DRA Driver 安装与 v1 示例](https://dra-driver-nvidia-gpu.sigs.k8s.io/docs/install/)

以上文档会变化。正式 run 必须以 artifact 中锁定的 ACK、Kubernetes、GPU
Operator、DRA driver、driver/firmware 和镜像 digest 为准。
