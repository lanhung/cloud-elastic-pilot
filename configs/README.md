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
