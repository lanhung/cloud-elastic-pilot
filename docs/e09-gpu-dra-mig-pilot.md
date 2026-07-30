# E09 两张 A100 GPU/DRA/MIG 小规模 Pilot

本 Pilot 是单卡功能冒烟之后、正式统计实验之前的两卡交叉对照。它回答三个有限问题：

1. 固定混合 MIG geometry 与按需求切换的同质 geometry，能否在同一批
   `ResourceClaim` 上得到可重复、可核验的首波承载量；
2. 动态策略的 profile mismatch 概率 `ρ`、重构代价 `D` 和平均重构间隔
   `T_avg` 能否从真实 MIG Manager、DRA allocation 和 CUDA 时间边界计算；
3. 策略交换物理节点后，结论是否仍成立，而不是某一台 A100 的个体差异。

它仍不是完整正式实验：只有两张卡、每个策略/profile 六次重复，需求序列和突发量
都是受控合成输入。

## 对照设计

两张相同的 `NVIDIA A100-SXM4-80GB` 分别记为 Node A 和 Node B：

| Period | Node A | Node B |
|---|---|---|
| 1 | `static-balanced` | `dynamic-homogeneous` |
| 2 | `dynamic-homogeneous` | `static-balanced` |

`static-balanced` 在整个 Period 保持 `all-balanced`，A100 80 GB 的冻结 inventory
应包含：

- `2 × 1g.10gb`
- `1 × 2g.20gb`
- `1 × 3g.40gb`

`dynamic-homogeneous` 根据需求 epoch 在以下 geometry 间切换，仅在当前 profile
不匹配时 reshape：

- `1g.10gb → all-1g.10gb`，应发布 7 个设备；
- `3g.40gb → all-3g.40gb`，应发布 2 个设备。

每个 Period 使用相同的六个需求 epoch：

```text
1g.10gb, 1g.10gb, 3g.40gb, 3g.40gb, 1g.10gb, 3g.40gb
```

初始动态 geometry 在计量窗口外设置为 `1g.10gb`，因此每个 Period 的动态
mismatch pattern 固定为：

```text
match, match, mismatch, match, mismatch, mismatch
```

每个 epoch 同时创建 7 个带 profile CEL selector 的
`resource.k8s.io/v1 ResourceClaim` 和 7 个指定物理节点的 Pod。CUDA probe 在
`FIRST_CUDA_SUCCESS` 后继续占用 Claim 45 秒；runner 在 Pod 批量创建后 25 秒
冻结 Pod、Claim 和 ResourceSlice。这样在同一设备释放并被下一批 Pod 复用前，
首波 CUDA 成功数必须严格等于该 geometry 发布的目标 profile 数量。

默认预期不是硬编码成结果，而是 Gate：

| 请求 profile | 固定组理论首波 | 动态组理论首波 |
|---|---:|---:|
| `1g.10gb` | 2 | 7 |
| `3g.40gb` | 1 | 2 |

runner 会从当次 `ResourceSlice` 重新计算容量；实际 CUDA 数与 inventory 不一致
时直接失败。

## 关键口径

- profile selector：
  `device.attributes['gpu.nvidia.com'].profile == "<requested-profile>"`；
- `request_time`：同一 demand epoch 两种策略共享的本地源时间；
- `reshape_requested/finished`：Node profile patch 和 MIG Manager
  `success` label 观察时间；
- `profile_ready`：reshape 成功后，目标节点 DRA kubelet plugin 使用新 UID
  Ready 且目标 ResourceSlice 完整的时间；
- `FIRST_CUDA_SUCCESS`：真实
  `cudaMalloc/cudaMemset/cudaDeviceSynchronize` 完成后的进程源时间；
- `ρ`：发生 profile mismatch 的 demand epoch / 全部动态 demand epoch。
  每个 epoch 的 batch size 相同，因此本 Pilot 的 request-weighted `ρ` 与
  epoch `ρ` 相同；
- `D`：mismatch epoch 的 `reshape_finished - reshape_requested`；
- `T_avg`：同一 Period 内连续 reshape request 的平均间隔，不跨角色交换边界；
- GPU elasticity bound：`max(0, 1 - ρD/T_avg)`。

报告还给出从 demand request 到首次 CUDA 的替代 `D` 与 bound。两种口径都只
描述这条受控序列，不能外推为生产收益。

## 前置条件

1. Kubernetes `>=1.34.2`，使用稳定的 `resource.k8s.io/v1`；
2. 两个不同 providerID 的专用 A100 80 GB Worker，每个恰好一张完整 GPU，
   source profile 均为 `all-disabled/success`；
3. GPU Operator、MIG Manager 和 NVIDIA DRA driver 延续单卡冒烟已验证版本，
   ACK 预装 driver 仍为 `580.126.09`；
4. GPU Operator 必须改为 `mig.strategy=mixed`。`all-balanced` 同时包含多种
   MIG profile，不能继续用单卡冒烟的 `single` 口径；
5. 旧 NVIDIA Device Plugin 在两节点上关闭；
6. DRA plugin 只选择
   `nvidia.com/dra-kubelet-plugin=true` 的 GPU 节点；
7. 两节点没有活动租户 Pod，并保留 `nvidia.com/gpu:NoSchedule`；
8. 至少一个带 `hooke.io/pool=fixed-cpu` 的 Ready CPU 节点承载集群和 NVIDIA
   控制组件。本 Pilot 不部署 MySQL/Hooke release，因而无需为实验控制面单独增加
   CPU 节点；
9. `ack-prometheus-gpu-exporter`、`ack-accel-health-monitor` 和
   `nvidia-persistenced.service` 的处理延续冒烟结论。前两个 DaemonSet 由 runner
   临时移出所有节点，后者必须已列入 MIG Manager `gpuClientsConfig`。

GPU Operator 的 mixed strategy 应在付费 GPU 节点扩容前调整并检查。runner
不会安装或升级 NVIDIA 组件。

## 构建与配置

CUDA probe 新增冻结的 hold 时间，因此必须在代码提交后重建镜像：

```bash
make e09-images-push
```

然后准备无凭证配置：

```bash
cp configs/gpu-dra-mig-pilot.env.example configs/gpu-dra-mig-pilot.env
$EDITOR configs/gpu-dra-mig-pilot.env
make e09-pilot-ack-check
```

只读预检要求两张 A100 已经存在，但不会创建 Namespace/Lease、patch Node、
删除 DRA Pod或移动 ACK DaemonSet。

预检 PASS 后才同时设置：

```text
CONFIRM_E09_PILOT_EXECUTION=yes
CONFIRM_MIG_RECONFIGURATION=yes
```

再运行：

```bash
make e09-pilot-ack
```

## 执行与恢复

执行阶段：

1. 创建全局 Lease 和独立 workload Namespace；
2. 冻结两节点、DRA inventory、镜像/Git identity 和 ACK GPU 客户端
   DaemonSet selector；
3. 临时给两个 ACK DaemonSet 增加不可能匹配的 node selector，并确认其 Pod
   已离开两张 A100；
4. 设置 Period 1 geometry，预热不可变 CUDA probe；
5. 按需求序列执行固定组和动态组；固定组 batch 与动态 reshape 并行启动，共享
   同一 request time；
6. 清空所有 Pod/Claim 后交换物理节点角色，执行 Period 2；
7. fail-closed 聚合容量、时延、`ρ/D/T_avg` 和两个 bound；
8. 删除 workload Namespace，依次恢复两节点 `all-disabled/success`、重启 DRA
   plugin、验证整卡 ResourceSlice，最后恢复 ACK DaemonSet selector。

任何情况下都先确认 Pod/Claim 已删除，才允许恢复 MIG geometry。如果 workload
删除、任一 A100 恢复或 DaemonSet selector 恢复无法确认，runner 返回失败并保留
Lease；不会用“best effort”冒充安全清理完成。

runner 不操作 ACK GPU 节点池 desired size。报告和恢复完成后，应立即把 GPU
节点池缩到 0，避免继续计费。

## PASS Gate

- 两张物理 A100 型号、driver、架构和 source inventory 一致；
- 每个策略都在 Node A、Node B 上执行过；
- 每个 demand epoch 的两种策略共享 profile 和 request time；
- 每个成功 Pod 在精确目标 hostname 上运行，且看到一个正确 profile 的 MIG
  CUDA device；
- Claim UID、Pod UID、DRA `(driver,pool,device)`、ResourceSlice UUID/parentUUID
  与 CUDA identity 闭环；
- admission cutoff 时成功 Pod 仍为 Running，防止同一设备在窗口内重复计数；
- 首波 CUDA 成功数严格等于目标 profile 的当次 ResourceSlice inventory；
- planned mismatch 与 Node 实际 profile 一致；match epoch 不得发生 reshape，
  mismatch epoch 必须有有效 request/finish 时间；
- `ρ`、`D`、`T_avg` 和 bound 都由真实 trial 输入计算；
- 所有 workload 已删除，两节点恢复 source profile/full-GPU DRA inventory，
  ACK GPU 客户端 selector 恢复。

## Artifact

输出目录：

```text
artifacts/e09-gpu-dra-mig-pilot-<UTC>/
```

其中包含冻结 plan、两 Period 的 setup/reshape、每批 Claim/Pod manifest、
admission observation、cutoff 对象、CUDA 日志、逐批 summary、总
`summary.json`/`report.md`、节点恢复和 DaemonSet selector 恢复证据。

## 依据

- [Kubernetes：使用 DRA 分配设备](https://kubernetes.io/docs/tasks/configure-pod-container/assign-resources/allocate-devices-dra/)
- [Kubernetes ResourceClaim v1](https://kubernetes.io/docs/reference/kubernetes-api/resource/resource-claim-v1/)
- [NVIDIA GPU Operator with MIG](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-mig.html)
- [NVIDIA A100 supported MIG profiles](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/supported-mig-profiles.html)
