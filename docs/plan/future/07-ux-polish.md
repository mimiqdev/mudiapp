# 7. 初次使用与终端体验打磨

**出口：** 首次权限流程不打断连接；常用 terminal 输入能通过紧凑的触屏交互完成。

- 首次启动说明为何需要本地网络权限，再主动触发 iOS 的本地网络授权（不是定位）
- 授权完成后再进入连接表单 / Host 列表，避免第一次 SSH 和系统弹窗抢跑
- 收集并打磨同类首次使用摩擦（权限、空白状态、失败文案），不改变 Herdr 或 Mosh 协议
- shortcut bar 保持单行高度，分两页；可左右滑动或点小标记切换
- 第一页暂定：Esc、Tab、Ctrl、Alt、方向键；第二页：PgUp/PgDn、复制、粘贴、全选、Mouse
- 使用短标签、SF Symbols 和较小字体；收键盘按钮固定，具体常用键顺序等用户使用后再定
- 研究触屏定位远端 terminal 光标：mouse-reporting 程序发送 mouse event；普通 shell 只在能可靠取得 SwiftTerm grid cursor 时按列发送方向键，否则提供相对拖动，不猜位置
- Settings 里从 Dark/Light 切回 System 时，已打开的 Settings sheet 不会马上跟系统外观；关掉再开才对。SwiftUI `preferredColorScheme(nil)` 刷新不了已 present 的 sheet，以后再找办法
