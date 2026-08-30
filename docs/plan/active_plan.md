# 4. 移动端完整交互

**出口：** PRD 中的纯触屏主流程可以完整执行。

- 完善 terminal shortcut bar、modifier、选择、复制和粘贴
- 补齐外接键盘、鼠标和触控板的基础行为
- 实现 Host、Herdr target 和界面位置恢复
- 完成字体、主题、Dynamic Type 边界和基础无障碍检查
- 触屏能滑回 scrollback，看 agent 已经发出的内容（现在进 pane 后滚不回去）
- 进了 pane 之后，导航标题用 pane / agent 名，不要再用 Host IP
- 待定：terminal 里要不要有快捷切 pane 的入口，还是退回列表再选
- 进了 Host 的 Herdr 列表后要能回到 Host 列表（现在列表页没有返回，只能从 terminal 里 Disconnect）
