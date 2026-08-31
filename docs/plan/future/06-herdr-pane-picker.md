# 6. 统一 Herdr Pane Picker

**出口：** 不再经过独立 Herdr 页面；点 Host 或在 terminal 切换 pane 都使用同一个 Pane Picker。

- 点 Host 后建立 Host 连接并弹出 Pane Picker；加载中、空状态和失败都在弹层内呈现
- Picker 按 session / workspace 展示 pane、agent 名和实时状态；打开时刷新官方 Herdr 状态
- 选 pane 立即 takeover；普通 terminal 也作为一个明确选项
- terminal 工具栏提供切换入口，复用完全相同的 Picker 和选择逻辑
- 切换、打开或关闭 terminal 内的 Picker 时保持当前 SSH bootstrap / Mosh session，不重复连接
- 从 Host 首次打开 Picker 后若未选择就关闭，取消并断开该 Host；从 terminal 打开后关闭则留在当前 pane
- 返回 Host 列表或 Disconnect 时才明确关闭 SSH / Mosh
- iPhone 使用 sheet，iPad 使用 popover；不是系统单行 `Picker`
- 不改变 Herdr 官方 discovery / takeover 协议，不自编状态或 JSON
