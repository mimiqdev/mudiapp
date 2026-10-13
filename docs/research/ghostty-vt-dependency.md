# Mudi Ghostty VT dependency / correctness slices and App A/B

## 固定来源

- `project.yml` 精确 pin Swift facade `https://github.com/caelyreth/libghostty-vt-spm.git` revision `1f5446ec78f38546f1aee8f73067b9a4f7703262`（0.2.1）。不是官方 SwiftPM 包，不是 Lakr/iOS full-engine fork。
- 发布包 `GhosttyVt.config` 记录官方 `ghostty-org/ghostty` revision `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`。
- Binary URL `https://github.com/caelyreth/libghostty-vt-spm/releases/download/0.2.1/GhosttyVtPrebuilt.xcframework.zip`。
- Manifest checksum `ea8f578e1f63e2a7b1cbc89eba71ad305affe2d41131cfc6132ed0a3f04129a2`，由 SwiftPM 在 fetch 时验证；不依赖 floating main/nightly。
- upstream MIT 与 wrapper MIT 完整 notices 随 App 保留于 `Mudi/Resources/GhosttyVT-NOTICE.txt`。upstream LICENSE 从该**精确 revision**读取，wrapper LICENSE 从锁定 checkout 读取。尚未做 binary SBOM/全部 transitive-license 审查，不能据此报发布合规已完成。
- 未安装 Zig、未重建官方源码；iOS slices 的编译证据见 `libghostty-ios.md`。本次不是完整 Ghostty renderer/Metal 接入。

## 设计边界

- `GhosttyVTScreen` 只保留 VT 提供的 Swift-owned frame rows/cursor/theme，不解析任何 ANSI。full/尺寸改变重建；partial 按 row.index 覆盖；clean 保留行。
- `GhosttyVTView` 拥有真实 `GhosttyVt.Terminal`，用 CoreText fallback/排版、CoreGraphics 两遍绘制（背景先于宽字符 glyph），按 column/width/spacer 放置。没有隐藏的 SwiftTerm。
- view 只接受已扣除 chrome 的可见 bounds；零/不可见尺寸不发 resize、不清 screen。CPU renderer 限制 512 columns × 256 rows，防止极端 geometry 溢出/无界工作；有效小 viewport 至少 1×1。字体有效范围为 `(0, 128]` pt；不改变用户持久化偏好。
- view 不拨号、不持有网络 transport。初始化/resize/update 使用真实 throwing API；feed 返回 `drainEvents`。`GhosttyVTSessionAdapter` 绑定已有 `SSHShellSession`：有序发送 VT PTY replies/输入/resize，交付 bell/title/PWD；重复 start 不重复读流；stop 只 detach、不关连接，EOF/error 与原 pump 一样明确断开/报告。adapter 不应在 view 隐藏时 stop，持续 feed 到 bounded VT scrollback，没有 1 MiB pre-attach raw-byte 队列。
- App 通过 Settings → Terminal → Renderer 受控选择；缺省/旧偏好是 SwiftTerm。`TerminalChromeView`/`TerminalHost` 固定一次 mount 的真实 renderer，偏好更新只显示“下次挂载生效”，不替换 VT/view/session。状态栏与常驻快捷栏/键盘预留在 surface bounds 外，首个 resize 就是可见网格。
- `GhosttyVTUIKitInput` 真正实现 `UITextInput`，preedit/UTF-16 positions 留在本地输入文档；只有 commit 发送一次，输入不借用隐藏 SwiftTerm。控键/UTF-8/Enter/bracketed paste 与 VT 回复由原 adapter 有序发送。Theme 与字体更新不重建 engine；xterm/explicit/LAB/harmonious palette 由自有数学生成，LAB 的 MIT 源归属另随 App 保留。
- `GhosttyVTViewport` 使用 VT row/column/width/spacer/soft-wrap 做 UIKit cell selection、edit menu/copy/paste 与逐行 pan。颜色更新保留选区，实际 cell 内容/reflow/viewport 改变则清除过期索引。普通 session 调用官方 VT viewport；Herdr 走原 `PTYScrollChannel`，Mosh wheel 仅在协商 channel 所有权且 VT mouse mode 开启时通过 VT encoder 发送。wheel owner 在 mode 关闭时不偷偷转成本地 scrollback。
- 仍不是全量迁移：真实系统 IME/复杂手势/前后台/远端手工出口未验收；selection handles、跨 viewport 拖选/autoscroll、惯性滚动与鼠标点击/拖曳未实现；cursor/text blink、复杂文字装饰、ligatures/batching 与性能测量未完成。

## 首次红 → 绿（2026-10-13）

1. 计划先提交 `c8c704a`。
2. 测试/依赖先提交 `280ecaf`。真实依赖已解析/编译；`xcodebuild test -only-testing:MudiTests/GhosttyVTRendererTests` exit 65，原因是产品 `GhosttyVTView` 尚不存在（编译期红，不是已运行的 assertion 失败）。该精确 HEAD 的 `qing verify --check renderer-red` 记录为 failed。
3. 实现后同一窄 suite 在 iPhone 18 Pro / iOS 27 模拟器上 **7 tests, 0 failures**，exit 0。包含逐字节 UTF-8/CSI feed，真实 full/partial/clean、resize/mode 保留，实际 UIView.layer/CoreText 像素、ANSI16/256/RGB 背景、组合字符/中文宽字/Nerd glyph（非 .notdef）与 cursor hide/move。XCTest 保存 `GhosttyVT-CoreText-wide-combining-Nerd` 图像 attachment。

4. session/effects 窄测试先提交 `7437db5`；精确 HEAD `vt-session-red` exit 65（缺少 `GhosttyVTSessionAdapter`）。实现后两组共 **13 tests, 0 failures**：真实 VT 的 DSR/status 回复、bell/title/PWD、Ctrl-C/Shift-Tab/DEC application cursor/Enter/bracketed paste，原 PTY 单消费者、初次可见 resize/后续 chrome resize、detached 超 1 MiB 输出末尾中文/组合字符与回复、实际 send failure/EOF、stop 不关闭原 session。transport 被记录；VT/frame/view/replies 没有 mock。

5. 错误传播补充测试 `d651ee5` 得到**运行期红**：未 start 抛 CancellationError、输入 caller 得到 opaque error wrapper，两条 assertion 实际失败；精确 HEAD `vt-errors-red` exit 65。首次包含这两条的 suite 已跑完 8 tests / 2 failures，但 coverage 结果收尾超过 240 秒，未报命令成功；限定两条、关闭 coverage 的 verify 正常记录失败。修正后两组共 **15 tests, 0 failures**，包含暂停第一次 PTY send 后并发发送的顺序验证，exit 0。

6. teardown 补充测试 `d376912`：若在飞行中的 PTY write 忽略取消，stop 后不应再派发同一帧剩余的旧 bell/title。先实际得到两条 runtime assertion 红（exit 65）；该 HEAD 的 `qing verify` 重跑 180 秒超时，query 未有 check，**没有**把那次当作已记录测试结果。添加每个 event 派发前的 generation/cancellation guard 后，两组共 **16 tests, 0 failures**，exit 0。

复现（串行，复用唯一 DerivedData；其他 booted arm64 simulator 可替换 destination）：

```sh
scripts/generate-xcodeproj.sh
xcodebuild test -project Mudi.xcodeproj -scheme Mudi \
  -destination 'platform=iOS Simulator,id=92F2836A-68F8-49E0-9E90-6A89B2792F3E' \
  -derivedDataPath /tmp/mudi-build -parallel-testing-enabled NO -enableCodeCoverage NO \
  -only-testing:MudiTests/GhosttyVTRendererTests \
  -only-testing:MudiTests/GhosttyVTSessionTests CODE_SIGNING_ALLOWED=NO
```

在 `f91fb7f` 已实际执行完整 `MudiTests` 模拟器回归：**388 tests, 0 failures**，exit 0（同一 destination/DerivedData，串行、coverage 关闭），包括原 Phase 4/7/8、Herdr/Mosh 回归。最终 handoff 再以最终 clean HEAD 的 `vt-correctness` / `simulator-regression` / 核心包检查记录为准。

首阶段性交接保留 `6e5024466a49745c035664a06748a95a5ffcbc1a`（16 项 VT、389 项完整模拟器回归、13 项核心包测试）。该阶段证据不是 iOS 17 runtime、物理设备/IME、GPU/性能或发布签名验收。

## 本轮续作：UIKit / App A/B / 基础 viewport（2026-10-13）

按同一已批准 active-plan 合同实施，没有切回 full-engine fork、修改 transport/wire 或推进 Phase 16：

| 先测试的 clean HEAD / 运行期红 | 实现后的 clean HEAD / 绿 |
| --- | --- |
| `7a7e8f4`，`ime-red`：4 项真实 UIKit 接口测试失败，原因是无 `UITextInput` conformance | `e1195ef`，`vt-ime`：4 项通过；marked 更新/取消零发送、insertText/unmarkText 各提交一次、组合字符删除、UTF-16 ranges/替换 |
| `9cfcb67`，`host-red`：5 host + 2 theme 测试失败，原因是两引擎无中立 host | `6c74722`，`vt-host`：11 项通过（含 IME）；同一 VT/theme/font、application cursor、bar/Composer、硬键命令/IME 不竞争、session 替换拒绝旧输入、离窗/隐藏持续读流/真实 scrollback/focus |
| `40761a5`，`mount-red`：5 项 / 7 条 assertion 失败，原因是偏好尚未持久化/路由，实验 view 未挂载、无明确回退状态 | `4338bb9`，`vt-mount`：5 项通过；App 实际实验 view、原偏好默认 SwiftTerm、Settings 偏好下次 mount、可见网格、原 session 回退 |
| `09a2676`，`viewport-red`：4 项失败，原因是无 viewport-interaction conformance；独立 LAB oracle 3 theme 测试通过 | `88f15b2`，`vt-viewport`：17 项通过（viewport/theme/session）；viewport 后续加强到 5 项，覆盖 soft/hard wrap、宽字选区像素与 clipboard、主题保留/输出清过期选区、remote ownership/SGR wheel/mode/边界/64-event 上限 |

- 首次 IME runtime-red 的收尾诊断超时，不报通过；从本机 `xcodebuild -help` 确认 `-collect-test-diagnostics never` 后正常记录失败。后续检查关闭 coverage、禁用失败诊断收集，但正常 xcresult/attachments 仍保留。
- host 隐藏测试曾先观察到 rows/history 数变化：窗口首次 layout 被推迟到重新挂回，合法 resize 将 history reflow 入可见区。修正测试 harness 为先建立同一 viewport 再隐藏，输出增加到 20 行并断言 history > 0；不是禁用 VT resize，也不是以清零状态通过。
- 回退测试传 `.init(columns: 0, rows: 24)` 给**同一生产真实 throwing VT initializer**，得到 `invalidSize`，不是 mock factory 人工 throw。失败发生于开始任一 output consumer 之前；UILabel 明示错误/“回退 SwiftTerm（原会话）”。预先排队的 backlog/DSR 回复保留，session reference 相同，reader=1、close=0；Esc 只发送一次，无第二连接。
- prefs `.terminalEngine` 缺省 `.swiftTerm`；当前 view/VT identity 不因设置更新而改变。`67f1ac8` 增强实际 model setter 持久化与 UIView screenshots：`GhosttyVT-App-native-opt-in`、`GhosttyVT-App-real-invalidSize-SwiftTerm-fallback`；`GhosttyVT-UIKit-cell-selection` 为真实 CoreGraphics 图像与选区 RGB 像素验证。原 `GhosttyVT-CoreText-wide-combining-Nerd` 仍保留。
- palette 数学来源为 SwiftTerm 1.15.0 revision `dd2fb8ac5b861e7bf617c872895e338f38165648` 的 `Colors.swift`；App 保留 `TerminalVTPalette-NOTICE.txt`。只有测试 oracle 另创建独立 SwiftTerm harness；实验产品代码没有创建/喂入它。LAB/harmonious 在深/浅 anchor 下与独立 OSC palette query 比较（8-bit 转换容差 1）；ANSI/explicit/真彩断言仍精确。
- scroll 所有权来自原 `SSHShellSession.scrollCapability()`，新 adapter 不解析/发明 Herdr JSON。已只读执行本机 `herdr 0.9.3` 的 `--help`、`api/pane --help`、`api snapshot`、`api schema --json`；实际 JSON 捕获在 `/tmp/mudi-build/ghostty-herdr-{snapshot,schema}.json`，两次 exit 0。snapshot 根字段为 `id/result`，schema 根字段为 `$schema/protocol/schema_version/schemas/title`。这些本机只读观测**不是**远端 scroll/wheel 手工验收，未控制其他 pane/session。
- `67f1ac87825d5b770cf426d816b7547ec30e28e4` 已以 `qing verify --check simulator-regression` 记录 **411 tests / 0 failures**，包括原 Phase 4/7/8、Herdr/Mosh 回归。xcresult：`/tmp/mudi-build/Logs/Test/Test-Mudi-2026.10.13_20-40-23-+0800.xcresult`。两个 App 图像已用本机 `xcresulttool export attachments` 导出并检查，内容/错误状态/常驻栏可见，不是黑图或假 renderer。

### 最终复现与证据边界

```sh
scripts/generate-xcodeproj.sh
xcodebuild test -project Mudi.xcodeproj -scheme Mudi \
  -destination 'platform=iOS Simulator,id=92F2836A-68F8-49E0-9E90-6A89B2792F3E' \
  -derivedDataPath /tmp/mudi-build -parallel-testing-enabled NO -enableCodeCoverage NO \
  -collect-test-diagnostics never \
  -only-testing:MudiTests/GhosttyVTRendererTests \
  -only-testing:MudiTests/GhosttyVTSessionTests \
  -only-testing:MudiTests/GhosttyVTUIKitInputTests \
  -only-testing:MudiTests/GhosttyVTHostTests \
  -only-testing:MudiTests/GhosttyVTThemeTests \
  -only-testing:MudiTests/GhosttyVTAppMountTests \
  -only-testing:MudiTests/GhosttyVTViewportTests CODE_SIGNING_ALLOWED=NO
# 去掉七个 -only-testing 参数跑完整模拟器回归。
make test-core
git diff --check 0e5250d37e21f2f7345940a52f4044ed789fc90d..HEAD
```

七组 VT suite 共 38 项。最终 handoff 必须再对**最终 clean HEAD**记录 `vt-correctness`、`simulator-regression`、`core-tests`、`diff-check`，历史 HEAD 的绿不代替本轮最终验证。

当前 runtime 仅 iPhone 18 Pro / iOS 27 模拟器、Xcode 27；UIKit protocol 调用、gesture 安装/selector、窗口移除与后台通知模拟是可重复自动化，不等于中文/日文/韩文系统键盘输入、实际 OS 后台、真实 Herdr/Mosh 或 iOS 17 真机验收。基础 edit menu/cell selection/pan 不是完整 SwiftTerm 交互同等性；无 selection handles/跨 viewport autoscroll/惯性/鼠标点击拖曳。没有 GPU/性能结果、设备安装、发布/法律合规审查或独立 Review。保留 active plan，不归档、不合流、不 push。
