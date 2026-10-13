# Mudi Ghostty VT dependency / first correctness slice

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
- 本切片尚未由 `TerminalScreen` 挂载；App 仍只用旧 SwiftTerm。adapter 的 committed-text API **不是** UIKit IME 验收。软键盘/IME、中立快捷栏/Composer/ThumbArc、设置 opt-in、同 session 回退、主题完整映射、selection/clipboard/scroll gestures 与焦点/session 替换待后续切片。cursor/text blink、复杂文字装饰与 ligatures/batching 尚未实现。不能报全量迁移。

## 首次红 → 绿（2026-10-13）

1. 计划先提交 `c8c704a`。
2. 测试/依赖先提交 `280ecaf`。真实依赖已解析/编译；`xcodebuild test -only-testing:MudiTests/GhosttyVTRendererTests` exit 65，原因是产品 `GhosttyVTView` 尚不存在（编译期红，不是已运行的 assertion 失败）。该精确 HEAD 的 `qing verify --check renderer-red` 记录为 failed。
3. 实现后同一窄 suite 在 iPhone 18 Pro / iOS 27 模拟器上 **7 tests, 0 failures**，exit 0。包含逐字节 UTF-8/CSI feed，真实 full/partial/clean、resize/mode 保留，实际 UIView.layer/CoreText 像素、ANSI16/256/RGB 背景、组合字符/中文宽字/Nerd glyph（非 .notdef）与 cursor hide/move。XCTest 保存 `GhosttyVT-CoreText-wide-combining-Nerd` 图像 attachment。

4. session/effects 窄测试先提交 `7437db5`；精确 HEAD `vt-session-red` exit 65（缺少 `GhosttyVTSessionAdapter`）。实现后两组共 **13 tests, 0 failures**：真实 VT 的 DSR/status 回复、bell/title/PWD、Ctrl-C/Shift-Tab/DEC application cursor/Enter/bracketed paste，原 PTY 单消费者、初次可见 resize/后续 chrome resize、detached 超 1 MiB 输出末尾中文/组合字符与回复、实际 send failure/EOF、stop 不关闭原 session。transport 被记录；VT/frame/view/replies 没有 mock。

5. 错误传播补充测试 `d651ee5` 得到**运行期红**：未 start 抛 CancellationError、输入 caller 得到 opaque error wrapper，两条 assertion 实际失败；精确 HEAD `vt-errors-red` exit 65。首次包含这两条的 suite 已跑完 8 tests / 2 failures，但 coverage 结果收尾超过 240 秒，未报命令成功；限定两条、关闭 coverage 的 verify 正常记录失败。修正后两组共 **15 tests, 0 failures**，包含暂停第一次 PTY send 后并发发送的顺序验证，exit 0。

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

此证据不是 iOS 17 运行、物理设备/IME、GPU/性能或发布签名验收。下个实现入口是 active plan 切片 2 的 UIKit 输入/主题与 lifecycle，再接切片 3 的受控 opt-in；不能用本阶段报告代替尚未完成的 A/B/高级交互验收。
