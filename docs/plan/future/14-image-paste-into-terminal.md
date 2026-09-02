# 12. 向终端粘贴图片/文件

**出口：** 在支持的终端与程序下，手机/iPad 可向远端 terminal 粘贴图片（及文件），行为与桌面端粘贴一致。

- 前提约束：只有 terminal 与运行的程序支持图片输入时才生效；先调研远端能力探测方式：
  - Kitty graphics protocol / iTerm2 inline images (OSC 1337) / Sixel 的支持矩阵与探测序列
  - Herdr 控制通道（terminal.input 字节流）传图片字节的可行性与大小限制
  - pi / Claude Code / Codex 等 agent 程序在终端里接收图片的实际路径（部分支持剪贴板图片 via OSC 52 或自定义序列）
- 交互：从相册/相机/文件选择，粘贴进当前 pane；粘贴前预览与确认
- 不支持时优雅降级：明确提示当前终端/程序不支持，而不是静默丢弃
- 参考 Moshi 的 Image and file paste 文档（/docs/image-paste）作为对标
- 明确非 V1；与阶段 8（终端外观/字体）无耦合，可独立排期
