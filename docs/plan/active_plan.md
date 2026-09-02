# Active plan — 统一 Herdr Pane Picker

**出口：** 不再经过独立 Herdr 页面；点 Host 或在 terminal 切换 pane 都使用同一个 Pane Picker。

阶段 5 已建立 SSH bootstrap / Mosh Host 上下文。本步只统一 Herdr 选择与切换导航，不改 transport 或官方控制协议。

## 范围内

- 点 Host 后建立连接并弹出 Pane Picker；加载、空状态和失败都在弹层内
- 按 session / workspace 展示 pane、agent 名和状态
- Picker 可见时刷新官方 Herdr 状态，关闭后停止刷新，并提供手动刷新
- 选 pane 直接 takeover；普通 terminal 作为明确选项
- terminal 工具栏提供切换入口，复用同一个 Picker 和选择逻辑
- Picker 内切换 pane 时释放旧 control，再 takeover 新 pane
- 切换、打开或关闭 terminal 内 Picker 时保持 SSH bootstrap / Mosh，不重复连接
- 从 Host 首次打开 Picker 后未选择就关闭：断开该 Host
- 从 terminal 打开 Picker 后关闭：留在当前 pane
- 返回 Host 列表或 Disconnect：关闭 SSH / Mosh
- iPhone 使用 sheet，iPad 使用 popover

## 不在本步

- 改 Herdr discovery / takeover 命令或 JSON
- 网络切换和发布验收（阶段 9）
- 首次本地网络权限与通用 UX polish（阶段 7）
- terminal 字体与配色（阶段 8）
- Chat UI、通知、Live Activity

## 测试

先写自动化测试并确认失败，再实现。sheet / popover 外观和真机切换手工验收。

### 自动化

- 点 Host 成功连接后呈现 Picker，而不是独立 Herdr 页面
- Picker 按真实 snapshot 保留 session / workspace / pane 归属和 agent 状态
- Picker 刷新使用官方 discovery 结果，pane ID 不串状态；关闭后停止刷新
- 从 Host 打开的 Picker 未选择即关闭，会断开 Host
- 从 terminal 打开的 Picker 关闭后仍附着当前 pane
- 从当前 pane 选择另一 pane，先 release 旧 control，再 takeover 新 pane
- 普通 terminal 选项不 attach pane
- RootViewModel 使用同一 Picker state machine；Host 关闭断开，失败切换恢复旧 terminal 且 Picker 刷新继续
- `make test-core` 和 Mudi XCTest 通过

### 手工（出口）

- iPhone 点 Host 后直接看到 Picker，能进 pane 或普通 terminal
- terminal 内打开同一 Picker 并切换 pane，不重新连接 Host
- 状态会刷新，不再保留进入页面时的旧快照
- iPad 以 popover 呈现且可操作

## 切片

- 以生产 `HerdrPanePickerCoordinator` 和 `PanePickerView` 统一 Host/terminal 选择、刷新与 release 顺序。
- `RootViewModel` 在连接后呈现 picker overlay，terminal toolbar 复用该入口，并保留 SSH/Mosh 会话上下文。

## 完成后

归档为 `archive/06-herdr-pane-picker.md`，将 `future/07-ux-polish.md` 提升为 `active_plan.md`。
