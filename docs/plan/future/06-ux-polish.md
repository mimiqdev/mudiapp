# 6. 初次使用与体验打磨

**出口：** 第一次打开 App 时，权限和关键提示出现在填写连接信息之前；用户不会在点 Connect 之后才被系统对话框打断并看到一次失败。

- 首次启动说明为何需要本地网络权限，再主动触发 iOS 的本地网络授权（不是定位）
- 授权完成后再进入连接表单 / Host 列表，避免第一次 SSH 和系统弹窗抢跑
- 收集并打磨同类初次使用摩擦（权限、空白状态、失败文案），不包含 Herdr 工作流或 Mosh
- Settings 里从 Dark/Light 切回 System 时，已打开的 Settings sheet 不会马上跟系统外观；关掉再开才对。SwiftUI `preferredColorScheme(nil)` 刷新不了已 present 的 sheet，以后再找办法
