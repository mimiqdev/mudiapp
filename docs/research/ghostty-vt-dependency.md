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
- view 不拨号、不持有网络 transport。初始化/resize/update 使用真实 throwing API；feed 返回 `drainEvents`，由后续 adapter 处理 PTY replies/bell/title。
- 本切片尚未由 `TerminalScreen` 挂载；App 仍只用旧 SwiftTerm。软键盘/IME、中立快捷栏/Composer/ThumbArc、设置 opt-in、同 session 回退、主题完整映射、selection/clipboard/scroll gestures 与焦点/session 替换待后续切片。cursor/text blink、复杂文字装饰与 ligatures/batching 尚未实现。不能报全量迁移。

## 首次红 → 绿（2026-10-13）

1. 计划先提交 `c8c704a`。
2. 测试/依赖先提交 `280ecaf`。真实依赖已解析/编译；`xcodebuild test -only-testing:MudiTests/GhosttyVTRendererTests` exit 65，原因是产品 `GhosttyVTView` 尚不存在（编译期红，不是已运行的 assertion 失败）。该精确 HEAD 的 `qing verify --check renderer-red` 记录为 failed。
3. 实现后同一窄 suite 在 iPhone 18 Pro / iOS 27 模拟器上 **7 tests, 0 failures**，exit 0。包含逐字节 UTF-8/CSI feed，真实 full/partial/clean、resize/mode 保留，实际 UIView.layer/CoreText 像素、ANSI16/256/RGB 背景、组合字符/中文宽字/Nerd glyph（非 .notdef）与 cursor hide/move。XCTest 保存 `GhosttyVT-CoreText-wide-combining-Nerd` 图像 attachment。

复现（串行，复用唯一 DerivedData；其他 booted arm64 simulator 可替换 destination）：

```sh
scripts/generate-xcodeproj.sh
xcodebuild test -project Mudi.xcodeproj -scheme Mudi \
  -destination 'platform=iOS Simulator,id=92F2836A-68F8-49E0-9E90-6A89B2792F3E' \
  -derivedDataPath /tmp/mudi-build -parallel-testing-enabled NO \
  -only-testing:MudiTests/GhosttyVTRendererTests CODE_SIGNING_ALLOWED=NO
```

此证据不是 iOS 17 运行、物理设备/IME、GPU/性能或发布签名验收。最终 handoff 以精确 clean HEAD 的 verify 与实际全套结果为准。
