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


## 用户追加：Figma UI polish（ui-polish 分支）

**出口：** 按 2026-10-03 用户提供的 Figma `Bs8ZxjukT714hydSC9WejI` 实现非 Agent 的明暗界面；保留现有 SSH/Mosh/Herdr wire 与会话语义。此独立分支不归档 Phase 10，不合并、不推送。

**范围内：** 设计色彩/字体/原始图标；主机列表及连接反馈；主机编辑；Pane Picker 的搜索、状态筛选、项目分组及本地收藏/最近使用；终端导航、可滚动快捷栏、Ctrl/反向 Tab、compose/history；可拖动/锁定 D-Pad；拇指快捷弧及槽位/左右手/触感/练习设置；现有重连状态的呈现。

**不在本轮：** Pi/Agent 面板、工具协议适配；跨 Host 会话实现；future 项目；远端协议与连接生命周期变更。

**自动化（先红后绿）：**
- `UIPolishTests.testHostsUseFigmaCanvasInBothAppearancesAndKeepHostAction`：明暗真实渲染使用设计 canvas，主机入口仍传递正确 Host。
- `UIPolishTests.testPickerOffersSearchAndStateFiltersWithoutLosingCurrentPane`：真实 Picker 展示搜索与状态筛选，当前 pane 身份标记保留。
- `UIPolishTests.testShortcutBarHasScrollableHistoryComposeAndPinnedNavigation`：历史/compose 可用，跳转/键盘固定可达。
- `UIPolishTests.testDPadLockKeepsPositionButDoesNotDisableKeys`：锁定禁止拖动，方向键仍可用。
- `UIPolishTests.testDoubleTapDragIsInstalledWithoutReplacingTextSelection`：双击拖选手势安装且不取代单指文本选择。
- `UIPolishTests.testArcPreferencesRoundTripAndOldPreferencesRemainCompatible`：槽位、左右手和触感可保存，旧设置解码兼容。
- `UIPolishRenderTests.testHostLargeTitleRemainsVisibleInBothAppearances`：真实渲染中原生大标题在明暗模式均可见，避免导航背景遮挡。
- 补充 `UIPolishInteractionTests` 覆盖搜索/筛选的 pane 身份、收藏/最近使用持久化、快捷弧边缘几何/返回原点取消/真实输入、D-Pad 自定义角键、compose bracketed paste。
- 回归：`make test-core`、Mudi XCTest（模拟器）；仅更新被新设计明确替代的旧外观合同。

**手工：** 对照 Figma 核对主机、编辑、Picker、终端、拇指弧、D-Pad 的明暗渲染；iPhone 与 iPad 检查可达范围、滚动与键盘空间。真实主机/设备交互出口保留待用户验收。

**切片：** 合同/红测 → 设计系统与资源 → 主机/Picker/编辑 → 终端与输入浮层 → 模拟器验证。


**验证记录（2026-10-03）：**
- 先跑红 6 项 UI 合同，再实现；新增真实输入、持久化、几何、后台颜色解析、D-Pad 角键及原生标题可见性覆盖。
- `make test-core`：13 项通过；日志 `/tmp/mudi-build-core.log`。
- iPhone 17 Pro / iOS 27 模拟器全量 XCTest：353 项通过、0 失败、0 跳过；`/tmp/mudi-build/UIPolish-Verified2.xcresult`。
- iPad Pro 11 / iOS 27 模拟器 UI、交互、渲染、快捷栏及输入空间检查：32 项通过、0 失败；`/tmp/mudi-build/UIPolish-iPadVerified.xcresult`。
- 核对 41 个原始 SVG 的编译尺寸，以及主机、编辑、Picker、终端、D-Pad、拇指弧和设置的 14 张明暗渲染；预览位于 `/tmp/mudi-build/ui-preview/`。
- 原生大标题被导航背景遮挡的问题已修复并有像素断言；既有地址竞速测试补充了 fake clock 注册同步，保持原有预算及结果合同。
- 真机与真实 Host 交互尚未验收；此记录不代表 Phase 10 手工出口完成，Agent 工具适配仍暂缓。

**用户反馈修正（2026-10-03）：** D-Pad 删除/清除角键采用与方向键相同的单层轮廓，取消额外虚线；拇指快捷弧全部保持等大，选中仅通过颜色和标签反馈。先跑红选中前后目标几何稳定测试，再移除放大；角键自定义与终端输入合同沿用现有覆盖。

- 修正验证：Pro Max 相关 UI/交互/明暗渲染 20 项通过，Core 13 项通过；选中前后所有目标的可见位置与尺寸保持一致。结果 `/tmp/mudi-build/UIPolish-Uniform-Green.xcresult`，新截图 `/tmp/mudi-build/ui-preview-uniform/`。

**Figma 原则 review 修复（2026-10-03）：** 用户确认修复 review 中的 7 项差距。以 Implementation Notes `172:2976` 与新版 Composer 明暗画面为准；Agent 工具继续暂缓。

- Compose 改为键盘上方的实色 inline 卡片，取代快捷栏；原生 UITextView 自动增高至 6 行后内部滚动，保留中文输入及系统键盘能力。工具栏从左侧起始并可滚动，清空置末尾，听写入口与发送固定；超过 20 行先显示行数并要求第二次确认，修改正文后重新确认；原生长按菜单提供回车、括号粘贴和本地草稿选项。
- D-Pad 以安全区域定位、保存相对位置，重新打开、旋转和窄窗口变化后重算边界；短窗口内方向键可以滚动。视觉轮廓沿用用户已确认的单层样式，拖动/锁定及快捷弧选中均不放大目标。
- 快捷栏顺序为 Esc、Tab、Ctrl、D-Pad、Compose、Paste、History；普通快捷栏与 Composer 在可用宽度内滚动，Picker/键盘或听写/发送保持固定。按钮提供独立的至少 44pt 点击区域；可见图标沿用 Figma 原始尺寸。
- UI 字体使用 Dynamic Type，主机地址、连接错误和 Pane 上下文允许换行；临时浮层沿用原生 Liquid Glass/旧系统 blur，并应用对应明暗模式的 tint、描边和阴影。
- 新增红测覆盖 inline Compose 与长文确认、候选栏高度/网格预留、44pt 区域、快捷栏顺序、D-Pad 位置保存与短窗口边界、字体缩放、浅色浮层选中/取消后的轮廓，以及 Compose 在输入被阻止或 terminal 停止后释放键盘焦点。地址竞速旧测试补齐 fake clock 的计时器注册同步；D-Pad 拖动旧测试隔离已保存的位置，底部留白断言按设备布局策略计算。

**本轮验证：**
- `make test-core`：13 项通过；`/tmp/mudi-build/principles-core.log`。
- iPhone 17 Pro Max / iOS 27 全量 XCTest：361 项通过、0 失败、0 跳过；`/tmp/mudi-build/UIPolish-Principles-Complete.xcresult`。
- iPad Pro 11-inch (M5) / iOS 27 相关 UI、浮层、键盘空间、尺寸变化及交互回归：55 项通过、0 失败、0 跳过；`/tmp/mudi-build/UIPolish-Principles-iPadComplete.xcresult`。
- 51 个原始 Figma SVG 编译尺寸检查通过；核对 19 张明暗/大字号渲染，另抓取 4 张包含真实系统键盘的 Pro Max Compose 屏幕。预览位于 `/tmp/mudi-build/ui-preview-principles/`。
- 中文候选栏高度及短窗口边界通过注入几何验证；真实 Host、真机输入、系统听写与硬件键盘手工出口仍待验收。此记录不代表 Phase 10 手工出口完成。

**新版拇指弧与 App 图标（2026-10-04）：** 用户确认按新版 Figma 普通 32pt、选中 38pt；此决定替代此前「所有圆等大」的反馈合同。以 Thumb Arc 67:2278、设置 56:1183 / 73:2754 和 Implementation Notes 中的方向选择规则为准。

- 双击后拖动按方向选中，无需移动到按钮；120° 均分扇区不可见，外侧容错 15°、边界滞回 4°。触发距离短／中／长为 22／28／36pt，旧设置默认中；进入 18pt 取消圈后取消，离开扇区不执行操作。选中放大围绕固定中心、橙色 glow 与外侧原生 Liquid Glass 标签，普通标签半径 110pt；边缘旋转布局及方向扇区，极端角落将视觉标签移入可见范围，触摸起点保留。
- 同步预览、练习文案与触发距离的原生分段设置；保留单指长按文本选择、默认槽位与现有真实输入路径。
- 使用 Figma 最终 C3-a 的默认 188:3263、深色 188:3292、系统着色 188:3321 三张 1024×1024 PNG，原始导出像素均不透明，仅移除多余 alpha 通道；三种外观均编译到 AppIcon。更新 36pt 取消圈、4pt 起点及四个 12.1905pt 原始弧上 SVG，保留设置页原尺寸图标；55 个 SVG 尺寸按 actool 的显示像素取整规则验证。
- 先跑红四项方向选择／触发距离／防抖／尺寸合同，再实现；补充左右手与边缘旋转、离开扇区后的激活状态、真实短／中／长控件及持久化测试。

**本轮验证：**

- Pro Max 相关 UI 32 项通过；/tmp/mudi-build/ThumbArc-Icon-Green5.xcresult。
- iPhone 17 Pro Max / iOS 27 全量 XCTest：368 项通过、0 失败、0 跳过；/tmp/mudi-build/ThumbArc-Icon-ProMax-Complete.xcresult。
- iPad Pro 11-inch (M5) / iOS 27 UI、方向弧、设置、输入空间及紧凑窗口回归：45 项通过、0 失败；/tmp/mudi-build/ThumbArc-Icon-iPad-Complete.xcresult。
- make test-core：13 项通过；/tmp/mudi-build/arc-icon-core.log。
- 核对 Pro Max 明暗弧、预览和手势设置的真实渲染，截图 /tmp/mudi-build/arc-icon-final-preview/；模拟器和真机 Assets.car 均含 Any、Dark、Tinted 三套图标。真机构建成功，已更新安装到 Mimikyu 并启动成功；安装日志 /tmp/mudi-build/arc-icon-device-install.json，启动日志 /tmp/mudi-build/arc-icon-device-launch.json。
- 本轮不归档 Phase 10、不合并、不推送，Agent 工具适配仍暂缓；设备安装不等同于真实 Host 手工出口验收。

**PR 评审（2026-10-04）：** 用户确认创建 UI polish PR，授权推送评审分支 users/agent/ui-polish-pr。此分支仅整理四个 UI 提交，保留远端 main 的原 Phase 10 计划；产品、测试和项目配置与已验证的 ui-polish 6f03738d 一致。本轮不合并、不归档，Agent 工具适配继续暂缓。
