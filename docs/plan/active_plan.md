# Active plan — Phase 10：多 Host 会话与连接 UX

**出口：** Hosts 成为会话列表：多个 Host 可同时保有独立 SSH/Mosh 会话，但任一时刻只呈现一个 terminal；普通 Back 回 Hosts 只隐藏当前呈现，不断开会话；重新进入恢复该 Host 的 terminal 或 Picker 上下文；只有对明确指定 Host 的显式断开操作才关闭它。本文是待用户确认的测试合同；确认前不写产品代码或新增/改写红 XCTest。

## 范围内

- Host 行连接反馈：连接尝试开始即显示 connecting；默认 5 秒后才显示 Cancel；取消仅撤销拥有该尝试的 Host，并有界清理已开启的资源。
- Host 多地址按保存顺序竞速：首地址有 **2 秒 preferred exclusive window**；首地址提前失败则立即启动备选，否则 2 秒后开始；后续备选每 **500 ms** stagger 启动。全序列共用从首地址开始的 **30 秒网络建立预算**（包含 DNS，不因备选重置）。首个网络连接成功者获胜，关闭失败/落败/迟到的 socket，并将获胜 socket 直接交 SSH 认证复用，不得二次拨号。认证、TOFU/主机密钥提示在网络竞速之外；认证失败、密钥不匹配或拒绝信任不能靠换地址绕过。
- 多 Host 会话按 Host 身份隔离：SSH bootstrap、SSH/Mosh terminal、Herdr workflow、连接/失败/取消状态及 Picker/terminal 导航上下文互不覆盖；Hosts 可进入已有会话，屏幕上始终只有一个可见 terminal。
- 普通 Back（包括从 terminal 或 Host-origin Picker 回 Hosts）不释放 SSH/Mosh 或 Herdr pane；再次进入同一 Host 恢复此前的 Picker、普通 terminal 或已附着 pane 上下文，不新建连接。Picker 与 terminal 之间的正常选择/返回仍按当前 pane 身份工作。
- 显式 Host 断开只清理该 Host：停止该 Host 的 Picker/Herdr 工作、attached pane 数据面及 SSH bootstrap；其它 Host 保持连接。Pane 级 Leave/切换与 Host 级断开分开验证：前者只释放该 pane 的控制/数据会话，不能断开 Host 或其它 Host。

## 不在本步

- Herdr wire protocol 变更及无关产品功能。
- 尚未确认的 idle 自动断开策略与默认值、同时保留会话的资源上限/达到上限时的行为、强制退出/系统杀进程后的会话恢复策略、跨 Host 凭据/信任共享及并发提示/Hosts UI 设计。不得从当前单会话 UI 或实现自行推导这些产品决策；相关实现前须向用户确认。
- 当前终端渲染器随视图卸载会停止输出消费；“恢复 terminal”合同保证恢复 Host/transport/session 身份与 terminal/Picker/pane 导航上下文，但**本地 VT 画面、未消费输出及 scrollback 是否也必须逐字恢复，仍待用户确认**，确认前不把它当作已保证行为。

## 测试

**合同状态：待用户确认。** 本轮只定义测试，不新增 XCTest、不实现产品代码、不跑设备。用户确认后，先新增/调整自动化测试并确认按预期失败，再开始实现。测试使用注入的 SSH、Mosh、Herdr、网络与时钟替身；不以调用顺序代替会话身份及资源所有权断言。

### 自动化

- `testHostsOwnIndependentLiveSessionsAndOnlyOneTerminalIsPresented`：A/B 同时连接，SSH/Mosh transport、bootstrap、terminal、workflow 和 navigation state 各属其 Host；进入另一 Host 只切换可见 terminal，不关闭前一 Host；返回并重进复用同一 session identity，不重新连接。
- `testConcurrentConnectCancelAndLateCompletionAreHostIsolated`：两 Host 连接并行时取消/重试其中一条；只清理该 Host 的尝试及迟到 SSH/Mosh 资源，另一条状态和 session 不变；旧回调不能覆盖新尝试或当前选择。
- `testFailureAtNetworkSSHTrustHerdrOrMoshStageCleansOnlyOwner`：分别覆盖网络竞速全败、SSH/认证或主机密钥拒绝、Herdr discovery/attach 失败、Mosh bootstrap/first-contact 失败；释放失败 Host 已建立的 socket/channel、Mosh 与 Picker refresh，不留半开会话，仍存活的 Host 不受影响；Auto fallback 只保留实际选中的 transport。
- `testBackAndPickerDismissalPreserveSessionAndReentryRestoresContext`：从 Host Picker、普通 terminal、attached terminal 及 terminal-origin Picker 回 Hosts；不触发 SSH/Mosh disconnect 或 pane Leave；重进恢复该 Host 原有导航状态、selected session/current pane 身份。
- `testExplicitDisconnectClosesOnlyNamedHostAndReconnectUsesFreshIdentity`：显式断开 A 关闭 A 的资源并清理 attached pane daemon（若有），B 仍可输入/输出；再次连接 A 创建新 session identity，不复用已关闭资源。断开操作必须显式携带 Host 身份。
- `testPaneLeaveReleasesPaneButKeepsItsHostAndSiblingHostsConnected`：Pane Leave/切换只结束该 pane 控制/数据面；Host SSH bootstrap 及其它 Host 不断开。保留 `Phase9MoshLeaveTests` 对 captured daemon PID 先 TERM、再关闭本地 PTY 的断言。
- `testBackgroundForegroundRetainsHostOwnershipAndRestoresSelection`：普通 scene background/foreground 不等同显式断开；两个 Host 的 model/session identity 不互换或被误清理，当前 Picker/terminal 恢复；attached SSH 控制沿用现有 suspend/resume 与 Phase 9 单次透明恢复语义，路径真实中断只影响拥有该连接的 Host。进程被系统杀死后的行为不在此测试合同内。
- `testHostRowsReportEachHostsOwnConnectingConnectedAndFailureState`：并行连接、单 Host 失败/取消、返回 Hosts 与显式断开时，connecting/connected/failure/cancel 只标记对应行，所有其它行保持各自真实状态。
- 回归基线：单 Host SSH/Mosh connect/disconnect/reconnect；Phase 10 connecting 动画/5 秒取消/取消清理；Host 多地址 2 秒窗口、500 ms stagger、共享 30 秒预算、获胜 socket 复用与地址/端口一致；Picker 刷新、terminal/Picker 往返、当前 pane 高亮与 Host 行状态；Phase 9 网络恢复及 Mosh Leave。
- 更新现有与新合同冲突的断言：`RootViewTests.testRootHostConnectionPresentsPickerAndDismissalDisconnectsHost`、`Phase6PanePickerTests.testDismissingUnselectedHostPickerDisconnectsTheHost`、`Phase7UXPolishTests.testRootTerminalToolbarBackToHostsUsesReturnToHostsSemantics` 不再把普通返回/Picker 关闭当作 Host disconnect；新增显式 Host 断开覆盖。确认后运行 `make test-core` 和 Mudi XCTest（模拟器）。

### 手工（出口）

- 在两台可访问 Host（至少一台 Mosh）上同时连接、切换进入/离开 terminal 与 Picker、回 Hosts 再进入；验证屏幕始终只有一个 terminal，两个远端 shell/Mosh 均未因 Back/Picker 关闭而退出，恢复到正确 Host/pane。
- 在 A、B 都在线时显式断开 A，确认 A 退出而 B 可继续交互；随后重连 A 并确认新会话可用。
- 两条会话存活时令 App 正常进入后台再回前台；确认不发生隐式断开、选择与行状态不串 Host；如网络确实中断，按 Phase 9 对该 Host 的恢复行为验收。不覆盖强制退出/系统杀进程。
- 单 Host 回归；使用有多个实际可达性的 Host 验证 preferred/备选地址的进度与最终显示地址对应实际 SSH/Mosh 目标，Picker 当前 pane 标记仍跟随 pane 身份。

## 切片

待用户确认本合同及上列产品决策后：先实现并跑红的自动化测试，再按 Host 会话所有权、Hosts/Picker/terminal 选择恢复、Host 定向断开与 scene lifecycle 分片实现；不扩大到未确认的闲置策略、资源上限、进程重启恢复或跨 Host 凭据/UI 决策。

## 完成后

通过自动化与手工出口并经用户确认后归档为 `archive/10-ux-polish-2.md`；既有下一活动计划仍是 `future/11-release.md`。本轮不修改 archive 或 future 文件。
