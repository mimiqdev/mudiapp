# Active plan — Phase 10：多 Host 会话与连接 UX

**出口：** Hosts 成为会话列表：多个 Host 可同时保有独立 SSH/Mosh 会话，但任一时刻只呈现一个 terminal；普通 Back 回 Hosts 只隐藏当前呈现，不断开会话；重新进入恢复该 Host 的 terminal 或 Picker 上下文；只有对明确指定 Host 的显式断开操作才关闭它。下列测试合同与会话行为已由用户确认：先写并运行预期失败的自动化测试，再实现产品代码。

## 范围内

- Host 行连接反馈：连接尝试开始即显示 connecting；默认 5 秒后才显示 Cancel；取消仅撤销拥有该尝试的 Host，并有界清理已开启的资源。
- Host 多地址按保存顺序竞速：首地址有 **2 秒 preferred exclusive window**；首地址提前失败则立即启动备选，否则 2 秒后开始；后续备选每 **500 ms** stagger 启动。全序列共用从首地址开始的 **30 秒网络建立预算**（包含 DNS，不因备选重置）。首个网络连接成功者获胜，关闭失败/落败/迟到的 socket，并将获胜 socket 直接交 SSH 认证复用，不得二次拨号。认证、TOFU/主机密钥提示在网络竞速之外；认证失败、密钥不匹配或拒绝信任不能靠换地址绕过。
- 多 Host 会话按 Host 身份隔离：SSH bootstrap、SSH/Mosh terminal、Herdr workflow、连接/失败/取消状态及 Picker/terminal 导航上下文互不覆盖；Hosts 可进入已有会话，屏幕上始终只有一个可见 terminal。连接中和已连接的 Host 合计最多 3 台；第 4 台明确提示达到上限，不自动断开任何现有会话；失败、取消或明确断开后释放名额。
- 普通 Back（包括从 terminal 或 Host-origin Picker 回 Hosts）不释放 SSH/Mosh 或 Herdr pane；再次进入同一 Host 恢复此前的 Picker、普通 terminal 或已附着 pane 上下文，不新建连接。Picker 与 terminal 之间的正常选择/返回仍按当前 pane 身份工作。
- 显式 Host 断开只清理该 Host：停止该 Host 的 Picker/Herdr 工作、attached pane 数据面及 SSH bootstrap；其它 Host 保持连接。Pane 级 Leave/切换与 Host 级断开分开验证：前者只释放该 pane 的控制/数据会话，不能断开 Host 或其它 Host。
- App 进入后台或设备锁屏后开始计时；持续 10 分钟则断开所有保留的 Host 会话并记录闲置断开原因，重新进入前台则取消本次计时。前台阅读或操作终端不因闲置断开；此步采用固定 10 分钟，不额外引入可调设置。
- App 进程被结束后不自动恢复内存中的连接；重新打开时提示「之前的连接已断开」并提供重连。普通后台/锁屏（未到 10 分钟）不是进程结束，不应出现该提示。

## 不在本步

- Herdr wire protocol 变更及无关产品功能。
- 改变 Herdr discovery、refresh 或 pane attach 错误语义：当前这类操作错误由 Picker 显示并可重试，不等同 Host transport 断开；不得改成 Host fatal disconnect，除非另经用户确认。
- 跨 Host 凭据/信任共享、进程结束后自动恢复连接、闲置时长设置与无关 Hosts 界面改造不在本步。跨 Host 凭据不自动共享；单个 Host 原有信任与凭据语义保持不变。
- 返回后重进同一 terminal 须恢复原画面与滚动历史，不只恢复连接和 pane 身份；后台期间的输出不能因视图卸载而丢失。不得以重连或清空屏幕冒充恢复。

## 测试

**合同状态：用户已确认。** 先新增/调整自动化测试并确认按预期失败，再开始实现。测试使用注入的 SSH、Mosh、Herdr、网络与时钟替身；不以调用顺序代替会话身份及资源所有权断言。

### 自动化

- `testHostsOwnIndependentLiveSessionsAndOnlyOneTerminalIsPresented`：A/B 同时连接，SSH/Mosh transport、bootstrap、terminal、workflow 和 navigation state 各属其 Host；进入另一 Host 只切换可见 terminal，不关闭前一 Host；返回并重进复用同一 session identity，不重新连接。
- `testSessionCapCountsConnectingAndConnectedAndNeverEvicts`：连接中与已连接总计最多 3 台；第 4 台明确提示满额而不触碰前三台；失败、取消或断开释放名额后可以再连。
- `testConcurrentConnectCancelAndLateCompletionAreHostIsolated`：两 Host 连接并行时取消/重试其中一条；只清理该 Host 的尝试及迟到 SSH/Mosh 资源，另一条状态和 session 不变；旧回调不能覆盖新尝试或当前选择。
- `testFatalHostTransportFailureCleansOnlyOwner`：覆盖网络竞速全败、SSH/认证或主机密钥拒绝、必须使用 Mosh 时 bootstrap/first-contact 失败，以及已建立 terminal 在现有恢复失败后的致命 SSH/Mosh 关闭；只清理该 Host 的 socket/channel、transport、workflow 与 Picker refresh，不留半开会话，仍存活的 Host 不受影响。Auto Mosh fallback 成功不是 fatal failure。
- `testRecoverableHerdrErrorsKeepHostConnectedAndPickerRetryable`：初次 discovery 失败时保留 Host-Origin Picker、显示局部错误并允许 refresh 重试；refresh 失败保留最近成功的 snapshot/当前 pane 和 Host transport，显示错误，后续手动或定时 refresh 成功可恢复。pane attach/select 操作失败依现有 Picker 错误态显示并可重试，保留 Host transport；若原 pane 恢复成功则仍标为当前 pane。上述错误均不置 Host failure/disconnected、不执行 Host teardown，且不影响其它 Host。
- `testBackAndPickerDismissalPreserveSessionAndReentryRestoresContext`：从 Host Picker、普通 terminal、attached terminal 及 terminal-origin Picker 回 Hosts；不触发 SSH/Mosh disconnect 或 pane Leave；重进恢复该 Host 原有导航状态、selected session/current pane 身份。
- `testReentryRestoresTerminalPixelsScrollbackAndBackgroundOutput`：切换 Host、返回 Hosts、短时后台后重新进入，原画面、滚动历史和期间收到的输出仍可查看；切换显示不新建 SSH/Mosh 会话。
- `testExplicitDisconnectClosesOnlyNamedHostAndReconnectUsesFreshIdentity`：显式断开 A 关闭 A 的资源并清理 attached pane daemon（若有），B 仍可输入/输出；再次连接 A 创建新 session identity，不复用已关闭资源。断开操作必须显式携带 Host 身份。
- `testPaneLeaveReleasesPaneButKeepsItsHostAndSiblingHostsConnected`：Pane Leave/切换只结束该 pane 控制/数据面；Host SSH bootstrap 及其它 Host 不断开。保留 `Phase9MoshLeaveTests` 对 captured daemon PID 先 TERM、再关闭本地 PTY 的断言。
- `testBackgroundForegroundRetainsHostOwnershipAndRestoresSelection`：未满 10 分钟的正常 scene background/foreground 不触发闲置断开；两个 Host 的 model/session identity 不互换或被误清理，当前 Picker/terminal 恢复；attached SSH 控制沿用现有 suspend/resume 与 Phase 9 单次透明恢复语义，路径真实中断只影响拥有该连接的 Host。
- `testBackgroundIdleTimeoutClosesAllAndForegroundCancelsTimer`：注入时钟验证后台/锁屏持续满 10 分钟断开所有保留 Host 并标明闲置原因；此前回前台取消计时，前台即使超过 10 分钟也不因闲置断开；计时到期与重进竞态不会影响新建会话。
- `testRelaunchExplainsPreviousSessionsEnded`：之前有连接而 App 进程结束后再次启动，显示「之前的连接已断开」与重连入口，不声称远端进程必然退出；无旧会话和普通后台恢复不出现误报。
- `testHostRowsReportEachHostsOwnConnectingConnectedAndFailureState`：并行连接、单 Host 失败/取消、返回 Hosts 与显式断开时，connecting/connected/failure/cancel 只标记对应行，所有其它行保持各自真实状态。
- 回归基线：单 Host SSH/Mosh connect/disconnect/reconnect；Phase 10 connecting 动画/5 秒取消/取消清理；Host 多地址 2 秒窗口、500 ms stagger、共享 30 秒预算、获胜 socket 复用与地址/端口一致；Picker 刷新、terminal/Picker 往返、当前 pane 高亮与 Host 行状态；Phase 9 网络恢复及 Mosh Leave。
- 更新现有与新合同冲突的断言：`RootViewTests.testRootHostConnectionPresentsPickerAndDismissalDisconnectsHost`、`Phase6PanePickerTests.testDismissingUnselectedHostPickerDisconnectsTheHost`、`Phase7UXPolishTests.testRootTerminalToolbarBackToHostsUsesReturnToHostsSemantics` 不再把普通返回/Picker 关闭当作 Host disconnect；新增显式 Host 断开覆盖。确认后运行 `make test-core` 和 Mudi XCTest（模拟器）。

### 手工（出口）

- 在两台可访问 Host（至少一台 Mosh）上同时连接、切换进入/离开 terminal 与 Picker、回 Hosts 再进入；验证屏幕始终只有一个 terminal，两个远端 shell/Mosh 均未因 Back/Picker 关闭而退出，恢复到正确 Host/pane，原画面、滚动历史及后台期间输出保留。
- 尝试同时连接第 4 台，确认明确提示上限且前三台不被踢下线；断开其中一台后第 4 台可以连接。
- 锁屏/后台持续超过 10 分钟后确认所有 Host 已断开并显示原因；短于 10 分钟返回与前台停留超过 10 分钟均不触发闲置断开。进程被结束并重启后看到旧连接已断开的提示和重连入口。
- 在 A、B 都在线时显式断开 A，确认 A 退出而 B 可继续交互；随后重连 A 并确认新会话可用。
- 两条会话存活时令 App 正常进入后台再回前台；确认不发生隐式断开、选择与行状态不串 Host；如网络确实中断，按 Phase 9 对该 Host 的恢复行为验收。不覆盖强制退出/系统杀进程。
- 单 Host 回归；使用有多个实际可达性的 Host 验证 preferred/备选地址的进度与最终显示地址对应实际 SSH/Mosh 目标，Picker 当前 pane 标记仍跟随 pane 身份。

## 切片

先实现并跑红的自动化测试，再按 Host 会话所有权、最多 3 台的容量控制、Hosts/Picker/terminal 选择及画面/滚动历史恢复、Host 定向断开、后台 10 分钟闲置关闭与进程重启提示分步实现；不扩大到跨 Host 凭据共享、自动重连或 compose。

## 完成后

通过自动化与手工出口并经用户确认后归档为 `archive/10-ux-polish-2.md`；既有下一活动计划仍是 `future/11-release.md`。本轮不修改 archive 或 future 文件。
