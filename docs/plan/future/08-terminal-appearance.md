# 8. Terminal 字体与配色

**出口：** 用户能选择适合 Light/Dark 的经典 terminal 配色和预装字体，也能导入自己的字体；ANSI 色彩与 Nerd Font 符号正确显示。

## 配色

- 内置 Mudi Default Light / Dark
- 内置 Solarized Light / Dark
- 内置 Catppuccin Latte / Mocha；评估是否同时提供 Frappé / Macchiato
- 内置经典 Monokai（Dark）；不虚构不存在的官方 Monokai Light
- 至少再提供一组许可清晰的经典 Light / Dark 方案，最终清单实现前确认
- 每套配色定义 ANSI 16 色锚点、默认前景/背景、粗体、cursor、selection，并明确 16–255 的扩展 palette 策略；不得把 terminal 实际显示限制为 16 色
- 完整支持 ANSI 256 色输入（`38;5` / `48;5`）和 24-bit True Color（`38;2` / `48;2`）；True Color 按程序指定 RGB 原样渲染
- SwiftTerm 当前以 16 色调用 `installColors`，再通过 `base16Lab` / xterm 策略生成扩展 palette；若内置主题需要官方 256 色表，再增加显式 256 palette 支持，不能静默降级
- 审核 SSH / Mosh 的 `TERM=xterm-256color` 与 `COLORTERM=truecolor` 能力声明，确保远端程序会正确选择 256 色或 True Color
- 支持 Automatic pair：跟随 App/System Light/Dark 自动选择成对主题
- 也允许固定选择一个 Light 或 Dark palette，并记住设置
- 设置页提供真实 terminal preview，不只显示色块
- 颜色值、名称与许可取自各主题官方仓库；禁止凭印象抄色值
- 真机预览和自动化色表覆盖 ANSI 0–15、16–255、前景/背景 indexed color 与 True Color，验证主题切换不会破坏程序指定 RGB

## 字体

- 预装若干可分发的免费等宽字体，并带 Nerd Font 符号
- 用户可导入 `.ttf` / `.otf`
- 可选字族、字号；SwiftTerm 必须真正用到所选字体（阶段 4 的 Symbols cascade 在真机上是方块，不能当做成了）
- 配色和字体设置彼此独立，但在同一 Terminal Appearance 设置区域预览

## 不在本步

- 付费字体商店
- 第一版不导入第三方 terminal theme 文件
- 不改变 App 的 System / Light / Dark 导航外观逻辑
