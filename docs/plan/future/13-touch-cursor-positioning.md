# 11. 触屏光标定位（重做）

**出口：** 在 pi agent / vim / 普通 shell 三类场景真机验证：点击与拖动能可靠地把输入光标移动到预期位置。

- 第一版（阶段 7）在真机 pi pane 上完全不生效，已整体移除（SGR mouse 转发、grid-cursor 列差方向键、双指拖动全部撤掉）
- 重做前先在真机上做根因调研：
  - pi agent 输入行的渲染方式（是否 alternate screen、readline 行为、光标序列）
  - SwiftTerm grid cursor 在真实会话中的可靠性（echo、重绘、底部行）
  - mouse-reporting 探测的准确性与误判影响
- 基于调研结果设计手势与发送路径；先做最小可靠路径（如仅 mouse-reporting 场景），再评估普通 shell
- 验收以 pi agent 真机场景为准，不以上位机模拟
