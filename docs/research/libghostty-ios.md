# libghostty iOS 调研（Phase 15）

**观察日期：** 2026-10-13
**工作树基线：** `0e5250d37e21f2f7345940a52f4044ed789fc90d`（不含主 checkout 未提交的 Phase 16）

## 结论摘要

- `libghostty`（完整 terminal surface / Metal renderer）和 `libghostty-vt`（VT parser、screen state、host 输入编码等）是两种不同产品。GhosttyKit / libghostty-spm / Termini 是下游包装/预编译分发名称，不是 Ghostty 官方 SwiftPM 产品。`libghostty-vt` frame 可带 selection cell metadata，但 0.2.1 Swift wrapper 不提供 UIKit selection gestures/clipboard UI。
- 官方当前源 `ghostty-org/ghostty@05dcf887ef51ea27821f20979493306ec3a19149` 明确在 `src/build/Config.zig` 拒绝把**完整 Ghostty**构建为 iOS：`only libghostty-vt supports iOS`。`include/ghostty.h` 中存在 iOS enum/API 不能推翻这个 build gate。
- 官方 `libghostty-vt` 不是 Metal/UIKit renderer。它的当前构建脚本可生成 iOS device + simulator 静态库，但 Ghostty README 的兼容平台声明没有列 iOS，且明确说 API signatures 仍在变化；对 Mudi 来说，选它意味着自行实现/维护绘制、UIKit/IME、主题与手势适配，不是直接换一个 view。
- 两个第三方完整 surface 包和一个 VT 包的真实 SPM harness 均成功链接 `arm64-apple-ios17.0` 与 `arm64-apple-ios17.0-simulator`；这只是编译/链接，不是模拟器运行、真机、Metal 性能或交互通过。当前没有 Zig，未从 Ghostty 源码重建任何候选。
- **建议下一步（待用户确认）：** 保持 SwiftTerm 默认，以精确固定的 `Lakr233/libghostty-spm` `GhosttyTerminal` 做单一 opt-in A/B 候选。它有宿主管理 I/O 和 UIKit/IME/selection 包装，也有两种 iOS arm64 slices 的实测链接证据；代价是完整 renderer 来自一个下游维护的、包含大量 iOS patches 的静态库，不是 upstream 官方 iOS 支持。若不接受该 fork/许可/供应链风险，退回“只验证官方 VT engine + Mudi 自有 renderer”的更大项目，不把 parser 包说成 renderer 迁移。

## 官方来源与语义边界

### Ghostty 完整 `libghostty`

- 源码：<https://github.com/ghostty-org/ghostty/tree/05dcf887ef51ea27821f20979493306ec3a19149>
- 当前 main 精确提交：`05dcf887ef51ea27821f20979493306ec3a19149`（提交日期 2026-10-13）；`build.zig.zon` 为 `1.3.2-dev`，最低 Zig `0.16.0`。
- C header：<https://github.com/ghostty-org/ghostty/blob/05dcf887ef51ea27821f20979493306ec3a19149/include/ghostty.h>，包括 app/surface/key/text/preedit/selection 等 C API；官方 LICENSE 是 MIT。
- 决定性证据：<https://github.com/ghostty-org/ghostty/blob/05dcf887ef51ea27821f20979493306ec3a19149/src/build/Config.zig> 对 iOS full build 返回 `UnsupportedTarget`，源码注释为“iOS is not a supported target for the full Ghostty build; only libghostty-vt supports iOS”。当前 `src/build/GhosttyXCFramework.zig` 的官方完整 GhosttyKit XCFramework 目标也只有 macOS。
- README 说明 libghostty 尚无稳定发布版本；完整 C/Swift embedding ABI 没有稳定 ABI 承诺。header 存在、macOS 应用成功、第三方 fork 编出 iOS slices，均不能推导为 upstream 当前支持 iOS。

### 官方 `libghostty-vt`

- 同一官方 commit 中 `src/build/GhosttyLibVt.zig` 有 Apple XCFramework 路径，明确分开 `ios` 与 `ios_simulator`，两者均按 arm64 目标构建（需本机 SDK 可检测）；`Config.osVersionMinLibVt(.ios)` 是 iOS 13。它是 parser/screen/state C library，不包含完整 Metal surface renderer。
- 官方示例：`example/swift-vt-xcframework/`；官方源树此示例是 macOS Swift package，并非 iOS renderer sample。官方 README 把 API 标为 still in flux；C API 没有稳定 ABI 承诺。
- 我未安装 Zig；当前官方源最低 Zig `0.16.0`，因此没有声称完成源码重建。以下 VT 候选的 binary harness 不能替代 source-build/官方 API 兼容性验证。

## 候选比较

本节固定 URL、Git revision、artifact tag/checksum；GitHub `main`/`nightly` 仅用于观察，不作为可复现依赖。

| 候选（固定来源） | 层级 / iOS 声明 | 编译与 slices 实测 | 构建、维护、风险 |
|---|---|---|---|
| Official `libghostty`，`ghostty-org/ghostty@05dcf887…` | 完整 parser + surface + Metal renderer；当前源码明确拒绝 iOS full build | **不支持当前官方 iOS full target** | Zig 0.16 + Xcode/Metal；libghostty C ABI 未承诺稳定。不能直接作为当前 Mudi iOS 依赖 |
| Official `libghostty-vt`，由 [`caelyreth/libghostty-vt-spm`](https://github.com/caelyreth/libghostty-vt-spm/tree/1f5446ec78f38546f1aee8f73067b9a4f7703262)（tag `0.2.1`）包装 | iOS 17+ Swift facade；有 VT state/feed/key/paste/scrollback 编码，frame 带 selection state；**没有 renderer、font shaping、UIKit gestures/IME/clipboard UI** | SPM harness 对 iOS 17 device arm64 + simulator arm64 链接成功；XCFramework metadata/lipo 也核对。macOS package tests 12/12 通过 | Wrapper MIT，绑定 upstream [`GhosttyVt.config`](https://github.com/caelyreth/libghostty-vt-spm/blob/1f5446ec78f38546f1aee8f73067b9a4f7703262/GhosttyVt.config) revision `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`；该发布 artifact 19,631,885 bytes，URL <https://github.com/caelyreth/libghostty-vt-spm/releases/download/0.2.1/GhosttyVtPrebuilt.xcframework.zip>，checksum `ea8f578e1f63e2a7b1cbc89eba71ad305affe2d41131cfc6132ed0a3f04129a2`。最低 wrapper 平台 iOS17；需要 Zig 0.16 才能重建。包最近发布 2026-07-10，当前 main 已到未发布 0.3.0 / commit `428ddb7…`，不可将其未发布代码与 0.2.1 binary 混用 |
| Full `GhosttyTerminal`，[`Lakr233/libghostty-spm`](https://github.com/Lakr233/libghostty-spm/tree/d403978c66870baa422709d1dde385730a4bdaef)（tag `2.2.2026101301`） | 下游 SwiftUI/UIKit `TerminalSurfaceView` + full libghostty Metal/VT/input/selection；README 声明 iOS15+，Xcode26+/Swift6.2+ | harness 对 iOS17 device arm64 + simulator arm64 链接成功；XCFramework metadata/lipo 及两个 target link 均通过 | `Package.swift` binary checksum `188b21d3c3f4f0a19fd71d7f3e6c6edc0e8e30fe04e09181d3db44810e21bf5f`，release URL <https://github.com/Lakr233/libghostty-spm/releases/download/upstream.1e9e14af5df1-2/GhosttyKit.xcframework.zip>（77,433,219 bytes）；包内 `Ghostty.ref=1e9e14af5df14211892f5fc15fd21a49c7d94868`、`Ghostty.build=2`。源构建要求 Zig0.16 + Xcode27 MetalToolchain；16 个下游 patches，其中包含关闭 upstream iOS full-build 拒绝、iOS Metal/IOSurface、host-managed I/O 等。活跃度高，但依赖下游 patch 追随不稳定 C ABI |
| Termini，[`arach/Termini@140238ec0d03ce0ad794765a6ceebcf2445f0894`](https://github.com/arach/Termini/tree/140238ec0d03ce0ad794765a6ceebcf2445f0894)（同仓 hudsonkit/Termini；repo 最新 SemVer tag `0.1.2`，main manifest 使用 GhosttyKit artifact tag `ghosttykit-0.1.6`） | iOS17+/Swift5.9 SwiftUI surface；`TerminiTerminalController` 暴露 remote output、transport write、resize、focus 等适配点 | iOS17 device arm64 + simulator arm64 harness 链接成功；该发布 XCFramework 的 iOS simulator **只有 arm64**（无 x86_64），与 README 的“universal simulator”构建验证文字不一致 | MIT wrapper；release URL <https://github.com/arach/Termini/releases/download/ghosttykit-0.1.6/GhosttyKit.xcframework.zip>，checksum `7265c68e6e2120d8e3ed9bd9299177f6de9312fde492f7923e2af67b23ba1339`，压缩包 137,617,568 bytes。manifest 注释把 artifact 溯源到 upstream [`ghostty-org/ghostty@07d31666e73bce337b9cece60a884c67fe8906f4`](https://github.com/ghostty-org/ghostty/commit/07d31666e73bce337b9cece60a884c67fe8906f4)（2026-06-28）及 patches；build helper 默认不设置 `GHOSTTY_REF`，需显式 `--ref` 才可从源码复现。iOS view 实作 `UIKeyInput`，没有看到 `UITextInput/markedTextRange` 接口；IME 需专项验证 |
| Geistty，[`daiimus/geistty@b816fb33e1c3fdfd02a1eaeb9a8e5c4160495bd7`](https://github.com/daiimus/geistty/tree/b816fb33e1c3fdfd02a1eaeb9a8e5c4160495bd7) | README 声称 iOS17+ full Ghostty Metal/SSH；Ghostty fork [`daiimus/ghostty@21c717340b62349d67124446c2447bf38796540b`](https://github.com/daiimus/ghostty/tree/21c717340b62349d67124446c2447bf38796540b) (`ios-external-backend`) 增加 External backend/tmux viewer/iOS API | 本轮未构建；GhosttyKit 是生成且 gitignored 的产物，README 要求本地 Zig build | App LICENSE 为 MIT；README 自述 AI proof-of-concept / essentially abandonware，README 所称 `v0.1-stable` 未在 `git ls-remote --tags` 找到对应 tag。是一个 downstream fork 的示例，不是 upstream 接入路线；不复制代码 |
| Spectty，[`ocnc/spectty@84a1fa61ed27826ee6cd062d4a729ce436731202`](https://github.com/ocnc/spectty/tree/84a1fa61ed27826ee6cd062d4a729ce436731202) | iOS18+、MIT、SSH+Mosh+Metal；当前 README 的 `SpecttyTerminal` 是自己的 `VTStateMachine`，把 `libghostty-vt`/Metal API 仅描述为未来可替换点 | 本轮未构建；不作为 libghostty 已接入的证据 | 与未来路线参考相关，但最低 iOS18 超出 Mudi17，且“可替换”不等于当前已使用 Ghostty |

**Echo：** 通过 Google grounding 的搜索请求因 API 报“User location is not supported”失败；直接公开 GitHub 搜索也未找到能核对源码、精确 revision 和许可证的 Echo repository。故 future/15 中 Echo 的描述仍标为**未验证**，不采用 App Store/README 宣传作为接入证据。未从这些应用复制代码。

## 可复现的独立 harness 与实际结果

所有 harness 都在 `docs/research/harness/`，不是 Mudi target，也没有修改 `project.yml`、App 默认引擎、网络协议或可见开关。使用 Swift 6.4 / Xcode 27 / iOS 27 SDK；源码包和 binary 下载只进入指定 `/tmp/mudi-build/ghostty-ios-spikes` scratch/cache。

### Full `GhosttyTerminal`

`docs/research/harness/ghostty-terminal/Package.swift` 精确依赖上表的 `d403978…`，并锁定 `DisplayLink` 3.0.1。独立 SwiftUI app 使用 README 公共 API `TerminalViewState`、`InMemoryTerminalSession`、`TerminalSurfaceView`。`InMemoryTerminalSession` 有真实 `receive(Data)`、`sendInput(Data)`、`readViewportText()` 与 resize/write callbacks；UIKit state 的 `inputAccessoryItems=[]` 可关闭 package 自带 accessory，避免与 Mudi 持续显示的快捷栏重复。`TerminalViewState.isSurfaceVisible=false` 可暂停隐藏 surface 绘制而保留 grid/scrollback。需注意：package 注释明确写明**surface 未 attach 前的输出队列超过 1 MiB 会丢最旧 bytes**；连接层应以可观察 backpressure 或保持 surface/session 活跃处理，不能假设 detach 缓冲无限。此接口具备适配 PTY 的方向；本 harness 仅编译链接，不实际连接 PTY/运行 UIKit。

```sh
swift build --package-path docs/research/harness/ghostty-terminal \
  --scratch-path /tmp/mudi-build/ghostty-ios-spikes/ghostty-terminal \
  --cache-path /tmp/mudi-build/ghostty-ios-spikes/cache \
  --config-path /tmp/mudi-build/ghostty-ios-spikes/config \
  --security-path /tmp/mudi-build/ghostty-ios-spikes/security \
  --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
# 将 triple 换为 arm64-apple-ios17.0、SDK 换为 iphoneos，可验证 device slice。
```

实测 simulator 与 device 两次最终重跑均 `SWIFT_BUILD_EXIT=0`。XCFramework `Info.plist` + `lipo -archs`：iOS device `arm64`；iOS simulator `arm64 x86_64`。首次下载时 SwiftPM 输出一次 Keychain credential lookup `-25308` 并返回非零，但 binary 实际下载完成；同一已缓存 artifact 的 simulator 重跑和 device build 均返回 0。没有凭首次不完整状态报通过。

### Termini

`docs/research/harness/termini-ios-build/` pin Termini Git revision `140238…`，最小 SwiftUI app 建立 `TerminiTerminalController` / `TerminiTerminalView`。该包的公开 transport callbacks 有利于保留 Mudi 自有 SSH/Mosh/Herdr，但 IME marked text、键位编码和 view 生命周期仍未验证。

用相同 SwiftPM 参数，`--triple arm64-apple-ios17.0-simulator` 与 `arm64-apple-ios17.0` 的最终构建均 `SWIFT_BUILD_EXIT=0`。实测 XCFramework device `arm64`、simulator `arm64`，**没有**模拟器 x86_64。首次 binary fetch 出现相同 Keychain `-25308` 文本，但 artifact 下载后重复 build 退出码为 0。未运行 iOS simulator app 或物理设备。

### `libghostty-vt`

`docs/research/harness/libghostty-vt/Package.swift` 精确 pin tag `0.2.1` commit。`main.swift` 实际 feed `界` + 24-bit RGB SGR 并断言 width/颜色 cell；`swift run` 在 macOS14 arm64 上退出 0。相同 harness 的 iOS17 simulator/device arm64 build 最终均退出 0。被依赖包自带 macOS tests 实跑 `12 tests, 0 failures`，包括 `testUpdatePreservesUnicodeGraphemesAndWideCells`、`testUpdateResolvesTrueColorBackgrounds`、`testEncodesTerminalInput`、`testResizeProducesAFullFrame`。这证明 VT state API 和该 binary 在 host 上工作、iOS target 可链接；**不证明** iOS renderer/IME/selection UI。

复现 VT tests：先运行 harness `swift build` 让 SwiftPM 下载 package 到 scratch，再执行：

```sh
swift test --package-path /tmp/mudi-build/ghostty-ios-spikes/libghostty-vt/checkouts/libghostty-vt-spm \
  --scratch-path /tmp/mudi-build/ghostty-ios-spikes/libghostty-vt-package-tests \
  --cache-path /tmp/mudi-build/ghostty-ios-spikes/cache \
  --config-path /tmp/mudi-build/ghostty-ios-spikes/config \
  --security-path /tmp/mudi-build/ghostty-ios-spikes/security
```

以上是纯 SwiftPM cross-target build，未运行 `xcodebuild test`、未安装/启动 simulator、未运行物理设备，也未在 Mudi 的 XcodeGen project 做解析。`zig` 不在 PATH，因此没有声称源码构建可复现；未全局安装 Zig/SDK/extension。Xcode 27 的 `metal` 已能由 `xcrun --find metal` 找到，但这不等于以 Zig 编译/测试了渲染器。

## Mudi 迁移面（以本基线源码为准）

- **Surface/adaptor、生命周期：** `Mudi/Features/Terminal/TerminalViewContainer.swift` 中 `ShellTerminalView : SwiftTerm.TerminalView` 绑定 session identity、focus gate、SwiftUI `make/update/dismantleUIView`；`updateSession` 会 stop/start。候选 `TerminalViewState.inputAccessoryItems=[]` 可抑制自身 accessory，留出 Mudi 快捷栏；`isSurfaceVisible=false` 仅停绘制、保留 session/grid/scrollback。其 `InMemoryTerminalSession` 对 surface attach 前的输出缓存有 1 MiB 上限且超限丢最旧数据，须设计背压或保留挂载，不能在后台/重连时默认无限缓存。替换 renderer 不能重复创建/关闭网络 session，也不能因 view 暂时离窗而清空 grid 或抢回键盘焦点。
- **PTY 输入输出/resize：** `Packages/HerdrKit/Sources/HerdrKit/SSHShellSession.swift` 的 bytes `send`、`outputStream`、`resize(columns:rows:)` 是共同接口；SSH channel 在 `Mudi/Infrastructure/SSH/NIOSSHConnection.swift`；VT output feed 在 `TerminalSessionOutput.swift`。可替换的是 terminal adapter，不是 PTY、host-key/TOFU、连接重试或认证。
- **Herdr：** `Mudi/Infrastructure/SSH/HerdrSSHAdapter.swift` 的 NDJSON `terminal.input/resize/scroll/release` 与 `terminal.frame` 不应改 wire schema/attach 语义。保持可见网格尺寸计算和已有 `full` frame 表示。
- **Mosh：** `Mudi/Infrastructure/Mosh/MoshPTYChannel.swift` 从 Traversio snapshot 产出 `.bufferingNewest(1)` 的整帧；`MoshScreenFrameRenderer.swift` 生成 clear+paint+cursor/mode 恢复序列并保留 bell/title 控制信号。新 engine 必须吃 replacement frame、不能把 dropped display 帧误当增量；不能修改 Mosh/SSP/UDP/roaming。
- **快捷输入：** `TerminalShortcutBar*.swift` 的 Esc/Tab/Shift-Tab/Ctrl latch/application cursor/D-pad、`MudiComposerCard.swift` 的 bracketed paste/Enter/history/snippet、`TerminalThumbArc.swift` 的触控动作都当前从 `ShellTerminalView.send/insertText` 进入 PTY。需要将键类与文本/粘贴分开保持真实字节语义，不能靠 UI 文本模拟 Ctrl。
- **IME：** `TerminalComposition.swift` 和 `TerminalViewContainer.swift` 的 `TerminalCompositionInputDelegate` 读 UIKit marked text，`TerminalShortcutBarComposition.swift` 呈现组合串；Composer 自身也保留 UIKit marked text。候选若不公开 `UITextInput`/preedit，可自动化范围需按实际能力缩小并把中文/日文/韩文组合与提交列为真机验收，不能声称已覆盖。
- **选择/剪贴板/滚动：** SwiftTerm selection 由 `TerminalViewDelegate.clipboardCopy` 写 UIPasteboard。`TerminalRemoteScrollback.swift` 区分 Herdr host scrollback 与 Mosh remote mouse-wheel；这是不同于 engine local scrollback 的协议功能。ghostty local scrollback/selection API 不能替代 Herdr scroll frames 或 Mosh wheel path。
- **主题/字体：** `TerminalAppearancePhase8Contracts.swift`、`TerminalViewContainer.swift` 当前安装 ANSI16/256 palette、truecolor、selection/cursor colors；`TerminalFont.swift` 使用系统/导入字体与 Nerd Font cascade。Ghostty config/theme/font 映射不能顺手改用户保存的 theme、palette 或字体偏好。
- **键盘/后台/多 Host：** `TerminalViewContainer.start/stop`、`RootTransparentReconnect.swift` 的透明重连、`RootView.swift` 的 active session 替换负责不丢 screen、不重复连接和 focus restoration。Ghostty `TerminalViewState`/Termini controller 的生命周期必须先通过 adapter tests 与人工检查，再讨论运行时切换。
- **Phase16 合流面：** 本工作树没有主 checkout 未提交的 Agent Actions Phase16 改动；后续合流需复查 Terminal toolbar/快捷动作接口和 plan 顺序。未验收/未实施 Phase16。

## 许可、分发、ABI 与维护风险

- Ghostty 官方 LICENSE 与被调查 wrappers 公开的 LICENSE 都为 MIT，但 MIT wrapper 不自动覆盖静态 XCFramework 内全部 bundled/transitive components。Lakr README 明确说历史 1.4.0–1.5.0 releases 因 GPLv3 shell-integration 误打包而撤回；当前 source 有 license scanner 和重写脚本，但上线前仍需对**精确 binary checksum**复查 SBOM/NOTICE/许可证。
- Termini 的 `THIRD_PARTY_NOTICES.md` 列 Ghostty；选择 `TerminiSSH` 还需检查 SwiftNIO/NIOSSH 等依赖 notices。下游 Ghostty patches、静态 Zig/C++ runtime、资源文件均需随 Mudi 合规审查。
- 官方 C API 未承诺稳定 ABI；libghostty-vt README 也说 API signatures still in flux。必须锁 package commit + binary checksum + Ghostty source ref/patch set，并在升级时重跑 compile/integration tests。当前 Mudi 的 `Package.resolved` 计划并未锁任何 Ghostty candidate。
- 完整 Ghostty 包体较大：本次 Lakr XCFramework zip 77.4 MB、Termini zip 137.6 MB；包体、下载供应链、静态符号/依赖许可证和更新频率都是发布评估项。
- 真实 Metal 绘制帧率、内存、热量、动态字号/resize、iPhone 输入和 App Store archive/signing 尚未测。arm64 iOS SDK compile 不是设备验证。

## 推荐测试合同（尚待用户确认）

A/B 候选为固定 `Lakr233/libghostty-spm@d403978c66870baa422709d1dde385730a4bdaef`（Ghostty `1e9e14af5df14211892f5fc15fd21a49c7d94868`, build variant 2）；SwiftTerm 继续默认。若用户不接受下游 full-engine patches/许可证审查，则改为官方 `libghostty-vt` engine + Mudi-owned renderer，重新确认更大的范围，不能把它当 full renderer。

下一轮确认后才先写 Mudi 自动化 tests 并观察红，再实现最小 settings opt-in A/B；本轮没有改 App、默认 renderer、网络或传输。
