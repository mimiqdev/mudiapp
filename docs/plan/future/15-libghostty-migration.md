# 15. libghostty 渲染引擎迁移（调研优先）

**出口：** Mudi 的 terminal 渲染/VT 解析基于 libghostty，SwiftTerm 完全移除或仅作回退；渲染质量与性能经真机验收确认不低于现状。

**优先级**：v1 发布后即启动调研，不是低优先级长期项。

- 生态已核实：Echo（iOS SSH+Mosh 客户端）、Geistty（iOS SSH + Metal 渲染）、Termini（SwiftUI + libghostty + iOS/macOS）均已验证可行；SwiftPM 接入路径现成（GhosttyKit、libghostty-spm）
- 调研试点：Settings 加实验性"Ghostty 渲染"开关做 A/B 并存，验证满意后切默认
- 迁移面清单（大头）：
  - shortcut bar / D-pad / Ctrl latch 的 input 路径接 C ABI
  - IME 组合显示、scrollback 手势、选择/复制
  - 阶段 8 主题体系（installColors/Ansi256PaletteStrategy 为 SwiftTerm API，需对等映射）
  - 键盘连续性、透明重连期间的 view 挂载语义
- 渲染收益：第一梯队 VT 兼容性（Kitty keyboard protocol、真彩、Nerd 字体）、Metal 渲染性能、活跃维护
- 与 future/14 图片粘贴协同：libghostty 的图片协议支持（kitty graphics 等）可作为该阶段的技术底座之一
