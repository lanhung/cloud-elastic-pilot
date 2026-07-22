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
