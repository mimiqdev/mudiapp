# Active plan — 初次使用与终端体验打磨

**出口：** 首次权限流程不打断连接；常用 terminal 输入能通过紧凑的触屏交互完成。

阶段 6 已统一 Herdr Pane Picker 导航。本步只打磨首次使用流程与 terminal 触屏交互，不改 Herdr/Mosh 协议。

## 范围内

- 首次启动说明为何需要本地网络权限，再主动触发 iOS 的本地网络授权（不是定位）
- 授权完成后再进入连接表单 / Host 列表，避免第一次 SSH 和系统弹窗抢跑
- 收集并打磨同类首次使用摩擦（权限、空白状态、失败文案）
- Shortcut bar 保持单行、单页（废弃两页模型），键位固定为：
  - `Esc`、`Tab`、`Ctrl`（latch）、方向按钮、粘贴、收键盘（固定）
  - 短标签、SF Symbols、较小字体
  - 不放"复制"键：复制由文字选择流程负责；粘贴保留快捷键
- 方向按钮弹出悬浮 D-pad（可遮挡 terminal 内容）：
  - 四方向键 + 中心 Enter + PgUp/PgDn
- Ctrl latch：点一下变选中态并弹出常见组合键按钮 `C D L A E U K W`：
  - 点组合键 → 发送对应 Ctrl 控制字节 → 解除 latch 并收起弹出
  - latch 后直接敲键盘字符：沿用现有修饰键行为
- 研究触屏定位远端 terminal 光标：mouse-reporting 程序发送 mouse event；普通 shell 只在能可靠取得 SwiftTerm grid cursor 时按列发送方向键，否则提供相对拖动，不猜位置
- Settings 里从 Dark/Light 切回 System 时，已打开的 Settings sheet 不刷新的问题（SwiftUI `preferredColorScheme(nil)` 刷新不了已 present 的 sheet）

## 不在本步

- 改 Herdr discovery / takeover / workspace 命令或 JSON
- 网络切换与发布验收（阶段 9）
- terminal 字体与配色（阶段 8）
- Pane Picker 的布局与导航行为（阶段 6 已定）
- Chat UI、通知、Live Activity

## 测试

先写自动化测试并确认失败，再实现。权限弹窗、D-pad 悬浮交互与触屏光标定位以真机手工验收。

### 自动化

- 首次启动且未授予本地网络权限时，呈现权限说明页而不是 Host 列表；授权后进入 Host 列表；已授权或后续启动不受影响（状态持久化）
- Shortcut bar 单行单页，键位恰好为 Esc、Tab、Ctrl、方向、粘贴、收键盘，高度与现有单行一致
- 方向按钮切换 D-pad 悬浮层显隐；D-pad 含上/下/左/右/中心 Enter/PgUp/PgDn，各键经现有 terminal input 路径发送正确字节
- Ctrl latch：选中态弹出 C/D/L/A/E/U/K/W 组合按钮；点组合键发送对应控制字节（C=0x03、D=0x04、L=0x0C、A=0x01、E=0x05、U=0x15、K=0x0B、W=0x17）并解除 latch、收起弹出；未 latch 时无弹出
- 键发送复用现有 terminal.input 路径，不新增协议
- `make test-core` 和 Mudi XCTest 通过

### 手工（出口）

- 删除重装后首次连接，先看到权限说明，授权后顺利完成首次 SSH
- D-pad 悬浮层打开/关闭、各键在远端生效，收键盘按钮始终可用
- Ctrl latch 弹出组合键，发送与解除行为正确
- 触屏光标定位在 mouse-reporting 程序与普通 shell 下的行为符合预期

## 切片

- Root 启动流程插入一次性权限引导（状态持久化），连接入口在授权后开放。
- `MudiTerminalShortcutBar` 改单页六键模型 + D-pad 悬浮层 + Ctrl 组合键弹出，键发送复用现有 input 路径。
- 光标定位先做 mouse-reporting 探测与发送，普通 shell 视 SwiftTerm cursor 可得性决定方向键方案。

## 完成后

归档为 `archive/07-ux-polish.md`，将 `future/08-terminal-appearance.md` 提升为 `active_plan.md`。
