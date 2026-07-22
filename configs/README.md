配置优先级为命令行参数（存在时）> 环境变量 > 示例配置文件。生产环境中的 MySQL DSN 和 Token 必须来自 Kubernetes Secret，不应提交到仓库。

E01 四层基线先复制 `four-layer-baseline.env.example` 为
`four-layer-baseline.env`。真实配置已被 `.gitignore` 排除；先运行
`make e01-ack-check`，通过后才运行 `make e01-ack`。
