# 初步开发计划

这份计划只定义开发顺序和阶段目标。具体任务、工期和版本号在对应阶段开始前再拆分。

## 1. 技术验证与工程基础

- 建立 iPhone / iPad 共用的应用骨架、领域模型和依赖边界。
- 对比 SwiftTerm 与 GhosttyKit 的渲染、软键盘、外接键盘、selection 和 resize 行为，确定 V1 terminal engine。
- 使用 Citadel 打通 SSH 登录、PTY、双向数据和窗口尺寸同步。
- 打通 Herdr session 自动发现和 `terminal session control` attach，验证无需 hook 的基础流程。
- 对比未安装与已安装 agent integration 时的 state 和 session identity 精度。
- 使用 swift-mosh 验证 SSH bootstrap、UDP transport、真实 `mosh-server` 互操作和网络 roaming。
- 以 Blink 的 libmoshios 实现作为兼容性与成熟度对照，保留必要时切换方案的空间。

阶段出口：在真机上通过 SSH 打开一个可交互 terminal，关键技术风险已有结论。

## 2. SSH Terminal Vertical Slice

- 完成 Host 配置、凭据存储和 host key 验证。
- 将 SSH session 接入选定的 terminal adapter。
- 支持基本连接状态、错误处理和手动重连。
- 建立连接层与 terminal UI 之间的稳定接口，为 Mosh 留出替换空间。

阶段出口：用户可以保存一台 Host，并通过 SSH 完成日常 terminal 操作。

## 3. Herdr 工作流

- 连接 Host 后自动 discovery，展示 session、workspace、tab、pane 和 agent state。
- 支持从 Herdr browser 直接 attach 到目标 pane。
- 单个 Herdr session 直接进入其 pane browser；多个 session 先展示 session picker。
- 提供显式的上次 pane 恢复入口，不因 session 数量自动 attach pane。
- 避免自动 takeover 已被其他客户端控制的 terminal。
- 处理 target 刷新、结束和消失等状态。

阶段出口：用户可以从 App 首页找到 agent，并进入对应 terminal。

## 4. 移动端完整交互

- 完善 terminal shortcut bar、modifier、选择、复制和粘贴。
- 补齐外接键盘、鼠标和触控板的基础行为。
- 实现 Host、Herdr target 和界面位置恢复。
- 完成字体、主题、Dynamic Type 边界和基础无障碍检查。

阶段出口：PRD 中的纯触屏主流程可以完整执行。

## 5. Mosh、韧性与发布准备

- 完成 Mosh transport，并实现 Auto / Mosh / SSH transport 选择。
- 验证网络切换、短暂断网、前后台切换和 session 恢复。
- 根据技术验证结果确定继续使用 swift-mosh，或切换到 libmoshios 并完成 GPL 履约。
- 补齐安全审查、日志脱敏、性能、崩溃恢复和真机测试。
- 准备 TestFlight 所需的签名、隐私说明、许可文本和发布材料。

阶段出口：V1 成功标准通过真机验收，可以进入外部测试。
