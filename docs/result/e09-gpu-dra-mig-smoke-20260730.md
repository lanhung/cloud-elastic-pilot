# E09 ACK 单 A100 GPU/DRA/MIG 冒烟结果（2026-07-30）

## 结论

E09 在真实 ACK 集群完成单 A100 功能链路，修正终态 Claim 取证后，对冻结 artifact
重放 fail-closed Gate 为 PASS：

```text
result: PASS (artifact revalidation)
scope: single-A100 functional smoke
run_id: 01KYRM04X70N6E7W1TPXKPSHZH
accepted artifact: artifacts/e09-gpu-dra-mig-smoke-20260730T041935Z
runtime commit: 1c7f2ae934e93a5108833b2c93c6f4a6c9d2d363
validator commit: addbd36975878e536206da5e97590c8fabb5755e
formal statistics: not executed
```

真实链路经过：

```text
all-disabled
  → MIG Manager all-1g.10gb/success
  → 7 个 MIG ResourceSlice device
  → resource.k8s.io/v1 ResourceClaim allocation/reservation
  → 指定 Pod 看到单个 1g.10gb CUDA device
  → cudaMalloc/cudaMemset/cudaDeviceSynchronize 成功
  → all-disabled/success 恢复
```

原始 `make e09-ack` 在所有 GPU 操作成功后返回非零，原因是 terminal Pod 结束后
DRA controller 已清空 Claim 的临时 allocation/reservation，而旧 validator
只读取终态对象。MySQL 中同一 Claim/Pod UID 的 allocation/reservation 事件、
ResourceSlice、Pod 终态和 CUDA stdout 均已冻结。修复后的 validator 使用这些
持久化事件重放同一份不可变输入并 PASS；为控制 A100 成本，没有为 runner 的
取证时序缺陷重复执行 GPU 操作。

## 环境与固定输入

- ACK Managed Kubernetes：`v1.36.1-aliyun.1`
- Region：`cn-wulanchabu`
- GPU 节点：`cn-wulanchabu.10.148.129.3`
- ECS：`ecs.gn7e-c16g1.4xlarge`
- GPU：`NVIDIA A100-SXM4-80GB`
- NVIDIA driver：`580.126.09`（ACK 预装）
- GPU Operator：`v26.3.3`
- NVIDIA DRA driver：`v0.4.1`
- DRA API：`resource.k8s.io/v1`
- source/target MIG profile：`all-disabled → all-1g.10gb`
- MIG strategy：`single`

运行时不可变镜像：

- stack：
  `sha256:4b6c0754f4cf66fddda5fa641746f072d6bc82d743f505cbb6f4f69f7d790509`
- CUDA probe：
  `sha256:736decb9d330fac473b76706086a1903bdfd06a7778055a8b5f35bdc964c58f3`

artifact 中 `git-status.txt` 为空，镜像 metadata 与 runtime commit 一致。

## Gate 证据

### MIG 与 DRA inventory

- 预检只发现一张完整 A100，没有活动租户 Pod，也没有旧
  `nvidia.com/gpu` Device Plugin allocatable；
- MIG Manager 到达 `all-1g.10gb/success`；
- `nvidia-smi -L` 列出 7 个 `MIG 1g.10gb` device；
- reshape 后 DRA kubelet plugin 使用新 Pod UID 恢复 Ready；
- 单一 `gpu.nvidia.com` ResourceSlice 发布 7 个 `type=mig`,
  `profile=1g.10gb` device。

### Claim、Pod 与 CUDA

ResourceClaim `7474ab10-c065-403d-bf4d-63120831eccc` 精确分配：

```text
gpu.nvidia.com/
cn-wulanchabu.10.148.129.3/
gpu-0-mig-1g10gb-19-6
```

`RESOURCE_CLAIM_RESERVED` 和 `POD_SCHEDULED` 都关联 Pod
`f68388e6-fb04-43c7-ac63-ba23e3fef3f8` 及同一 DRA device。Pod 在目标 GPU
节点 `Succeeded`，退出码为 0，重启数为 0。

`FIRST_CUDA_SUCCESS` 记录：

- 可见 CUDA device 数：`1`
- device name：`NVIDIA A100-SXM4-80GB MIG 1g.10gb`
- 可见显存：`10,200,547,328` bytes
- 实际验证显存：`4096` bytes
- compute capability：`8.0`

该 CUDA 版本返回父 GPU UUID，而 ResourceSlice 同时发布所分配 MIG device 的
`parentUUID` 和 `profile`。Gate 因此要求分配的精确 device 为 MIG、父 UUID
一致、CUDA 只见一个设备且名称包含相同 `1g.10gb` profile；不会把任意父 GPU
UUID 当作精确 MIG UUID。

## 时间

| 边界 | 时间 |
|---|---:|
| reshape request → finish | 60.635228600 s |
| Claim create → allocation | 1.000000000 s |
| allocation → first CUDA success | 12.849772383 s |
| reshape request → first CUDA success | 82.673095608 s |

driver 未发布 allocated-device `Ready=True` condition，因此 preparation 仍按
`FIRST_CUDA_SUCCESS` 记为上界，不把 allocation 时间冒充 prepared 时间。

## 适配中发现并固化的边界

1. ACK 原预装 driver `535` 不满足本次 DRA/CUDA 组合，GPU 节点改为 ACK 官方
   `580.126.09` driver 后通过。
2. ACK 已预装 NVIDIA toolkit；再次让 GPU Operator 改写 containerd 会形成
   runtime 递归。最终关闭 Operator driver/toolkit/device-plugin，并用
   `RuntimeClass/runc` 运行 Operator 组件。
3. ACK GPU exporter、accelerator health monitor 和
   `nvidia-persistenced.service` 会占用 A100，阻止 MIG reset。前两者在 reshape
   窗口临时退出目标节点，后者加入 MIG Manager `gpuClientsConfig`，结束后均恢复。
4. MIG 恢复可能在一次轮询内完成，不能强制要求恢复阶段再次观察中间状态；
   最终 profile/state 与 DRA plugin Ready 才是恢复 Gate。
5. terminal Pod 会触发 Claim 释放。最终 Gate 允许使用已从 MySQL 回读的
   allocation/reservation 事件，但若终态对象仍有状态，则两种证据必须一致。

## 清理

- Node 在释放前恢复为 `all-disabled/success`；
- DRA plugin 恢复 Ready，并重新发布整卡 `gpu-0`；
- ACK GPU exporter 和 health monitor 的临时 node selector 已撤销；
- E09 workload/system Namespace、Helm release 和 Lease 均不存在；
- GPU 节点池已缩为 `desired=0,total=0`，对应 ECS 实例已释放；
- 临时 `emptyDir` MySQL Namespace `hooke-e09-db` 已删除；
- CPU 集群、GPU Operator 和 DRA driver 保留，便于后续复用。

## 口径限制

本次只有一张 A100、一次 reshape 和一次 Claim/CUDA probe。它证明功能集成与安全
恢复，不证明多节点弹性、并发隔离、长期稳定性、p95/p99、最优 MIG profile，
也不计算 `ρ`、`T_avg` 或正式 GPU elasticity bound。MIG geometry 由 MIG Manager
改变，DRA 只分配 reshape 后发布的设备。
