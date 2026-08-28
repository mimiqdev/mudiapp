# Active plan — SSH 可交互 terminal

**出口：** 在真机上通过 SSH 打开一个可交互的远端 shell。模拟器可以先打通，不能代替真机验收。

## 范围内

- 验收路径是 **连接表单 → SSH 交互 shell**，不经过 Herdr browser。现有三栏导航和 Preview 数据可以留着，但不是本步出口。
- 不持久化的表单：hostname、port、username，外加 **密码或 PEM 私钥（有一种能登上即可）**。
- 凭据只在本次连接过程中持有，不写入 `Host`，不进 Keychain，不进日志。
- Citadel：登录、申请 PTY、交互 shell、双向字节流。未知 host key 本步直接接受，不做指纹 UI。
- SwiftTerm 显示输出；系统软件键盘把输入写回 PTY；尺寸变化同步到远端。
- 连接失败时界面上显示错误即可，不做重连状态机。
- SSH 会话接口本步只覆盖 connect / send / resize / disconnect。对象是 shell，不是 pane。
- 为跑真机补上开发者签名（`DEVELOPMENT_TEAM`）。不包含 TestFlight 或正式 bundle id。

## 不在本步

- Host 保存、Keychain、host key 校验 UI、连接状态机、手动重连（阶段 2）
- 实现 `TerminalTransport.attach(to:)`（阶段 3）
- Herdr discovery / `terminal session control`（阶段 3）
- shortcut bar 接线、外接键盘、字体和主题（阶段 4）
- Mosh、Auto transport、GhosttyKit、libmoshios（阶段 5）

## 切片

1. 连接表单 + 可见错误；用密码或 PEM 经 Citadel 建立 SSH 并申请 PTY
2. PTY 接到 SwiftTerm，系统键盘可交互
3. terminal 尺寸变化时把 rows/cols 发给远端

## 验证

- 打开 macOS Remote Login。模拟器可先连 `127.0.0.1:22`；归档前必须用真机连开发机的局域网地址（不要用 localhost）
- 真机弹出系统软件键盘，输入一条命令（例如 `echo hello`），terminal 里能看到输出
- 弹出软件键盘或旋转后，远端 `stty size` 会变
- 杀掉 App 再开，表单是空的
- `make test-core` 通过

## 完成后

归档为 `archive/01-ssh-interactive-terminal.md`，将 `future/02-ssh-vertical-slice.md` 提升为 `active_plan.md`，并补全切片和验证。
