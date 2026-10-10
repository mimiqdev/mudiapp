# 16. 快捷键扩展与 Agent 操作预设

**出口：** 手机端保留稳定的通用终端快捷栏，并能根据远端 Herdr 返回的当前 pane 的 agent 类型提供内置快捷操作；首批支持 Pi，无需额外安装 Mudi host hook。

- 通用快捷键扩展优先加入 Shift+Tab；保持现有 Esc、Tab、Ctrl、方向键、粘贴、Jump To 与键盘开关的位置和语义稳定，不把所有操作塞进底栏。
- 采用「通用快捷栏 + Agent Actions 弹出面板」。通用操作显示按键名称，agent 专属操作可显示语义名称及对应按键/命令。
- 手机通过现有 SSH discovery 消费 Herdr 的 pane/agent 信息，不在手机解析 terminal 画面猜 agent 类型；pane 切换与类型刷新后更新预设，避免沿用旧 pane 的类型。
- 识别到 Pi 时推荐 Pi 预设；类型缺失或不支持时回退通用操作。面板明确显示当前预设，允许手动选择内置预设；这不等于自定义快捷键。
- Pi 首批候选操作：模型选择（Ctrl+L，对应 /model）、循环 thinking level（Shift+Tab）、工具输出折叠（Ctrl+O）、thinking 内容折叠（Ctrl+T）、中止（Esc）、/reload、/compact、/resume、/tree。实施前按远端 Pi 版本确认行为与最终清单；其他 agent 预设另行确认，不在本步承诺全量支持。
- 区分发送按键与插入文本命令：slash command 默认不自动追加 Enter，不偷偷清空远端输入；agent 类型不代表当前一定处于空白编辑器。发送策略在提升为 active plan 时明确。
- 不新增 Herdr 协议或原生模型选择器，操作仍通过真实 terminal 输入链路完成。
- 自定义快捷键属于高级功能，暂不规划；本步不做自定义文本、键序列、宏、固定/排序配置或配置同步。
