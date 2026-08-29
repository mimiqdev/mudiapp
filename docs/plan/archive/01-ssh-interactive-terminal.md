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

## 测试

先把这一节落地成会失败的自动化测试，再做下面的切片。真 sshd / 真机键盘不自动化。

### 自动化

不连真实 sshd。用 fake PTY / fake SSH 测会话缝，并保住现有测试。

- `Host` Codable round-trip 不包含 password 或 PEM 字段
- 认证失败时会话返回可展示的错误
- 连接成功后，`send` 的字节到达 fake PTY
- `resize` 把 rows/cols 传到 fake PTY
- 断开后，UserDefaults、Keychain 和 App 沙盒文件里读不到本次密码或 PEM
- `make test-core` 通过
- 现有 `RootViewTests` 通过

### 手工（出口，自动化全绿之后）

- 打开 macOS Remote Login。模拟器可先连 `127.0.0.1:22`；归档前必须用真机连开发机的局域网地址（不要用 localhost）
- 真机弹出系统软件键盘，输入一条命令（例如 `echo hello`），terminal 里能看到输出
- 弹出软件键盘或旋转后，远端 `stty size` 会变
- 杀掉 App 再开，表单是空的

## 切片

自动化测试已在仓库里且失败之后，才做这些：

1. 连接表单 + 可见错误；用密码或 PEM 经 Citadel 建立 SSH 并申请 PTY
2. PTY 接到 SwiftTerm，系统键盘可交互
3. terminal 尺寸变化时把 rows/cols 发给远端

## 完成后

归档为 `archive/01-ssh-interactive-terminal.md`，将 `future/02-ssh-vertical-slice.md` 提升为 `active_plan.md`。提升后先填 测试，确认后再写 切片。
