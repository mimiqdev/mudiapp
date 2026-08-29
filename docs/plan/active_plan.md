# Active plan — SSH Terminal Vertical Slice

**出口：** 用户可以保存一台 Host，并通过 SSH 完成日常 terminal 操作。

阶段 1 已提供：一次性表单 → Citadel PTY → SwiftTerm → resize。本步把它变成可保存、可信任、可重连的 SSH 日常路径。不要重做 PTY 管道。

## 范围内

- 保存 Host 的非敏感配置（display name、hostname、port、username、preferred transport）
- 删除 Host：同时清掉该机的 Keychain 凭据和已记住的 host key。这是正式功能，不是隐藏测试模式
- 密码或 PEM 进 Keychain，不进 `Host`、UserDefaults、日志
- 首次连接展示 host key fingerprint；用户接受后记住并 **继续这一次连接**，不要退回列表再点一次 Connect。拒绝则中止。之后校验，不匹配则拒绝并显示错误
- 连接状态：connecting / connected / failed / disconnected；失败可见
- 手动重连（不要自动重连风暴）
- 继续用现有 `SSHClient` / `SSHShellSession` / SwiftTerm 缝，便于以后换 Mosh

## 不在本步

- Herdr discovery / `terminal session control` / `attach(to:)`（阶段 3）
- shortcut bar、外接键盘、字体主题（阶段 4）
- Mosh、Auto transport、GhosttyKit（阶段 5）
- 首次启动预申请本地网络权限、Connect 前的权限说明（阶段 6）
- TestFlight、正式 bundle id
- 重写 Citadel PTY 或 SwiftTerm 接线，除非为接 Keychain / host key 所必需

## 测试

先把自动化测试落地成会失败，再做切片。真机 TOFU / 重连不自动化。

### 自动化

- 保存后再读，Host 列表恢复；编码后仍无 password / PEM 字段
- 删除 Host 后，列表里没有它，Keychain 替身和记住的 fingerprint 也读不到
- 凭据只出现在 Keychain 测试替身里，UserDefaults 和 Host 文件读不到
- 未知 host key：第一次接受并记录 fingerprint，同一次 connect 进入 connected；拒绝则不建立会话。同 host 换了 key 则失败且可展示错误
- 会话能进入 connecting → connected，以及 failed / disconnected
- disconnected 或 failed 之后，手动 reconnect 会再次 connect
- `make test-core` 通过

### 手工（出口，自动化全绿之后）

- 保存一台 Host，划掉 App 再开，Host 还在，不必重填 hostname
- 删除该 Host 后再开，列表里没有它，再连需要重新填凭据、重新确认 fingerprint
- 用已保存凭据连上，不必再输入密码
- 首次连接弹出 fingerprint，点接受后直接进入 shell，不用再点连接；再连同一台不再弹同样的确认
- 断开或失败后点重连，能回到可交互 shell
- 真机仍能完成阶段 1 的键盘输入和 `stty size` 变化

## 切片

自动化测试已在仓库里且失败之后，才做这些：

1. Host 持久化 + Keychain 凭据 + 删除 Host（替换一次性表单作为主路径）
2. Host key TOFU：展示 fingerprint；接受则继续本次连接，拒绝则中止；记住；不匹配则拒绝
3. 连接状态 + 可见错误 + 手动重连

## 完成后

归档为 `archive/02-ssh-vertical-slice.md`，将 `future/03-herdr-workflow.md` 提升为 `active_plan.md`。提升后先填 测试，确认后再写 切片。
