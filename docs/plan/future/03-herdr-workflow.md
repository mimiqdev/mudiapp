# 3. Herdr 工作流

**出口：** 用户可以从 App 首页找到 agent，并进入对应 terminal。

- 钉住 Herdr CLI 契约（`session list --json`、`terminal session control` 的命令、JSON 和 attach 语义）
- 连接 Host 后自动 discovery，展示 session、workspace、tab、pane 和 agent state
- 从 Herdr browser 直接 attach 到目标 pane
- 单个 Herdr session 直接进入其 pane browser；多个 session 先展示 session picker
- 提供显式的上次 pane 恢复入口，不因 session 数量自动 attach pane
- 避免自动 takeover 已被其他客户端控制的 terminal
- 处理 target 刷新、结束和消失等状态
