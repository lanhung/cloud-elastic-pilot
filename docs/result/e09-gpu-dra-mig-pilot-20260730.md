# E09 ACK 两 A100 GPU/DRA/MIG 小规模交叉 Pilot 结果（2026-07-30）

## 结论

E09 在真实 ACK 集群完成两张 A100 的小规模交叉对照，执行与清理 Gate 均为
PASS：

```text
result: PASS
scope: two-A100 crossover small-scale pilot
run_id: 01KYRV3TMGRAJ5Y83G4RRSAF9Q
accepted artifact: artifacts/e09-gpu-dra-mig-pilot-20260730T062414Z
runtime commit: c822ce7549dd97e2a982b64a0b4237b43b1b08c0
demand epochs: 12
strategy batches: 24
```

在本次受控七 Claim 突发中：

| 请求 profile | 静态均衡首波容量 | 动态同构首波容量 | 动态/静态 |
|---|---:|---:|---:|
| `1g.10gb` | 2 | 7 | 3.500× |
| `3g.40gb` | 1 | 2 | 2.000× |

所有 24 个策略批次的首波 CUDA 成功数都严格等于当时 NVIDIA DRA
`ResourceSlice` 发布的目标 profile inventory。两张物理 A100 都分别承担过
`static-balanced` 和 `dynamic-homogeneous`，结论没有依赖单一节点。

动态策略的 profile mismatch 概率 `ρ=0.5`，平均 MIG 重构时间
`D=24.609735 s`，同一 Period 内平均重构请求间隔
`T_avg=112.045833 s`。按冻结公式
`max(0, 1 - ρD/T_avg)` 得到：

- 以 MIG Manager reshape finish 为边界：`0.890180`；
- 以 demand request 到首次 CUDA 成功为替代重构边界：`0.833494`。

这些 bound 只描述本次固定序列，不是生产收益预测，也不能替代后续正式统计实验。

## 环境与固定输入

- ACK Managed Kubernetes：`v1.36.1-aliyun.1`
- Region：`cn-wulanchabu`
- ECS：`ecs.gn7e-c16g1.4xlarge`
- GPU 节点：
  - `cn-wulanchabu.10.148.129.4`
  - `cn-wulanchabu.10.148.129.5`
- 每节点 GPU：`1 × NVIDIA A100-SXM4-80GB`
- NVIDIA driver：`580.126.09`（ACK 预装）
- GPU Operator：`v26.3.3`
- NVIDIA DRA driver：`v0.4.1`
- DRA API：`resource.k8s.io/v1`
- source profile：`all-disabled`
- MIG strategy：`mixed`
- 静态 geometry：`all-balanced`
- 动态 geometry：
  - `1g.10gb → all-1g.10gb`
  - `3g.40gb → all-3g.40gb`
- 每个 Period 的需求序列：
  `1g, 1g, 3g, 3g, 1g, 3g`
- 每个 demand epoch：两种策略各并发创建 7 个 Claim/Pod
- admission window：`25 s`
- CUDA hold：`45 s`

运行时不可变镜像：

- stack：
  `sha256:c509dd4d4ede36c67d4aacf84e78e6939eb325ae93cf40bcf2a7ea26d6c35719`
- CUDA probe：
  `sha256:feb5690310143e7b81bec785e3c28254c02b738c7244077ff8de65fe7ff0cc4d`

artifact 中 `git-status.txt` 为空，镜像 metadata 与 runtime commit 一致。
接受运行从北京时间 `14:24:15` 开始，于 `14:44:07` 完成并通过恢复 Gate。

## 交叉对照与容量

两个 Period 的角色如下：

| Period | `.129.4` | `.129.5` |
|---|---|---|
| 1 | `static-balanced` | `dynamic-homogeneous` |
| 2 | `dynamic-homogeneous` | `static-balanced` |

每个策略/profile 共执行 6 个批次，首波 CUDA 成功总数为：

| 策略/profile | 批次 | 单批发布容量 | 首波 CUDA 成功总数 |
|---|---:|---:|---:|
| static / `1g.10gb` | 6 | 2 | 12 |
| dynamic / `1g.10gb` | 6 | 7 | 42 |
| static / `3g.40gb` | 6 | 1 | 6 |
| dynamic / `3g.40gb` | 6 | 2 | 12 |

`all-balanced` 实际发布 `2 × 1g.10gb`、`1 × 2g.20gb` 和
`1 × 3g.40gb`；动态同构 geometry 分别发布 7 个 `1g.10gb` 或 2 个
`3g.40gb`。首波成功数没有超过 inventory，也没有因设备在 25 秒观察窗口内复用
而重复计数。

## 时延

从共同 demand request 到每个批次首次 CUDA 成功：

| 策略/profile | mean | p50 | p95 | max |
|---|---:|---:|---:|---:|
| static / `1g.10gb` | 6.762 s | 6.736 s | 7.045 s | 7.091 s |
| dynamic / `1g.10gb` | 17.273 s | 7.543 s | 38.290 s | 38.623 s |
| static / `3g.40gb` | 6.700 s | 6.704 s | 6.838 s | 6.861 s |
| dynamic / `3g.40gb` | 27.423 s | 35.886 s | 40.388 s | 40.399 s |

动态 geometry 已经 Ready 后到首次 CUDA 的均值为：

- `1g.10gb`：`7.250 s`
- `3g.40gb`：`6.950 s`

这与静态策略约 `6.7 s` 的量级接近。动态策略较长的 request-to-CUDA 尾部主要
来自 mismatch epoch 的 MIG 重构，而不是 geometry Ready 后的 DRA/CUDA 分配。

mismatch epoch 的重构数据：

| 指标 | mean | p50 | p95 | max |
|---|---:|---:|---:|---:|
| reshape request → finish | 24.610 s | 24.657 s | 27.409 s | 27.942 s |
| reshape request → first CUDA | 37.313 s | 38.044 s | 39.838 s | 40.379 s |

## Gate 证据

- 两个节点的型号、架构、driver、source profile 和整卡 DRA inventory 等价；
- 每个策略都在两个不同 providerID 的物理节点上执行；
- 同一 demand epoch 的两种策略共享 profile 和 request source time；
- planned mismatch pattern
  `match, match, mismatch, match, mismatch, mismatch`
  与每个 Period 的 Node 实际 profile 一致；
- 每个成功 Pod 都运行在指定 hostname，只看到一个正确 profile 的 MIG CUDA
  device，并实际完成
  `cudaMalloc/cudaMemset/cudaDeviceSynchronize`；
- Claim UID、Pod UID、DRA `(driver,pool,device)`、ResourceSlice
  UUID/parentUUID 与 CUDA identity 完成闭环；
- admission cutoff 时计入首波的 Pod 仍持有 Claim；
- 每批首波 CUDA 数严格等于该节点、该 profile 的冻结 inventory；
- 每批 Pod/Claim 清空后才允许下一次 reshape。

## 首次诊断运行

在接受运行之前有一次未进入正式批次的诊断运行：

```text
run_id: 01KYRTJ5FJA17ZSH1SKNJ82TMH
artifact: artifacts/e09-gpu-dra-mig-pilot-20260730T061436Z
```

该运行在预热完成后被安全闸门中止。根因是 runner 使用了双反斜杠 JSONPath，
把真实的 `nvidia.com/mig.config` 读成空字符串，误报
`dynamic profile state diverged from the frozen plan`。脚本立即删除 workload，
将两节点恢复为 `all-disabled`，恢复两个 ACK GPU 客户端 DaemonSet 并释放 Lease；
没有把这次运行的数据计入结果。

修复改为从完整 Node JSON 使用 `jq` 精确读取 label，提交为
`c822ce7549dd97e2a982b64a0b4237b43b1b08c0`。修复后通过 Bash 语法检查、
E09 单元测试和全部 102 个脚本测试，并重新构建不可变镜像、再次通过只读预检，
随后完成上述接受运行。

## 清理与成本状态

实验自身的 cleanup/restoration Gate 为 PASS：

- workload Namespace 已删除；
- 全局实验 Lease 已释放；
- 两个节点均恢复为 `all-disabled/success`；
- 每个节点的 DRA `ResourceSlice` 均重新发布为一个完整 `gpu-0`；
- 没有遗留旧 `nvidia.com/gpu` allocatable；
- ACK GPU exporter 和 accelerator health monitor 均恢复为 `2/2 Ready`。

报告落盘时，GPU 节点池仍为 `desired=2,total=2,healthy=2`。runner 按设计不修改
ACK 节点池规模；完成核验后需手动缩到 `0`，否则两台 A100 ECS 会继续计费。
ACK API 的 `inventory_health_status` 仍显示 `UnHealthy`，但节点
`Ready=True`、NVIDIA 组件 `Ready`、DRA inventory、全部 CUDA Gate 和最终恢复
均已独立通过；该字段未作为实验成功证据。

## 口径限制与下一步

本次仍只有两张 A100、每个策略/profile 六次重复，并使用固定需求序列和七 Claim
合成突发。它证明了：

- 两节点角色互换下的 MIG/DRA/CUDA 功能与容量结果可重复；
- 静态均衡 geometry 提供约 6.7 秒的稳定首次 CUDA 时延；
- 动态同构 geometry 在本次 profile 上提供 2.0× 至 3.5× 首波容量，但
  mismatch epoch 需承担约 24.6 秒的平均 MIG 重构成本。

它不证明长期稳定性、真实生产到达分布、p99、跨更多节点的一致性，也不能据此确定
生产环境的最优切换策略。正式实验应扩大节点、随机化或重放真实 demand epoch，
增加重复次数，并把失败率、p95/p99、GPU 利用率和成本纳入预注册分析。
