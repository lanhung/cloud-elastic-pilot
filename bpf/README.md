# 精确 eBPF 探针阶段

此目录故意不包含硬编码到某个 containerd/kubelet 版本的 uprobe。Go 二进制的函数符号、内联和 ABI 会随 ACK 节点镜像及 containerd/kubelet build-id 改变。错误的探针可能无声地产生错误时间戳，反而破坏论文复现。

## 实现前置检查

在实际 ACK 节点上采集：

```bash
containerd --version
kubelet --version
readelf -n /usr/bin/containerd | grep 'Build ID'
readelf -n /usr/bin/kubelet | grep 'Build ID'
go tool nm /usr/bin/containerd | grep -E 'image.*Pull|PullImage'
go tool nm /usr/bin/kubelet | grep -E 'SyncPod|syncPod'
```

然后为每个 build-id 建立版本化 offset/symbol manifest，并实现：

- `IMAGE_PULL_START`
- `IMAGE_UNPACK_END`
- `SYNC_POD_START`
- ring-buffer lost counter
- monotonic/realtime clock mapping
- container/image/pod 关联

探针输出必须转换为 `internal/probe.Event`，再由 node-agent 转成统一 `event.Event`。在探针完成之前，Kubernetes Event/Status 事件会带 `approximate=true`，不会被误标成论文精确口径。
