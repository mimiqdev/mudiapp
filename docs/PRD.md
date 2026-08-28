# Herdr Mobile Client — V1 PRD

## 1. 产品概述

Herdr Mobile Client 是一款面向 iPhone 和 iPad 的远程开发终端客户端。

客户端围绕远端 Herdr 中的 workspace、tab、pane 和 agent 状态组织导航。用户可以查看各个 agent 的状态，包括工作中、等待输入和已结束，并直接进入对应的 terminal 继续交互。

主要使用场景是：用户在外出时通过 iPhone 或 iPad 连接自己的开发主机，在不复制本地开发环境的前提下，继续使用远端已有的 Herdr 和 coding agent workflow。

App 必须在纯触屏环境下完整可用；外接键盘用于提升操作效率。

---

## 2. 背景与问题

现有 iOS / iPadOS 远程终端产品通常围绕以下模型设计：

```text
Host
  → SSH / Mosh connection
    → terminal session
```

这种模型适合普通远程 shell，却很难满足 coding agent 长时间运行、随时等待用户介入的工作方式。

实际使用时，用户更关心的是：

- 哪些 Herdr workspace 目前还存在；
- 哪些 pane 中正在运行 agent；
- 哪个 agent 正在工作；
- 哪个 agent 正在等待用户输入；
- 哪个任务已经结束；
- 如何直接回到对应的 agent terminal。

理想情况下，用户无需先连接 host、进入 shell、手动操作 Herdr，再逐级查找 pane。客户端应直接呈现 Herdr runtime 中已有的信息，并保留真实 terminal 作为最终交互界面。

---

## 3. 产品目标

V1 聚焦于建立一套稳定、低摩擦的 Herdr 远程工作流。

用户应该可以完成以下流程：

```text
打开 App
  ↓
连接已有 Host
  ↓
查看 Herdr workspaces 和 agent 状态
  ↓
选择一个目标
  ↓
进入真实 terminal
  ↓
通过触屏或外接键盘与 agent 继续交互
```

网络条件发生变化时，例如从 Wi-Fi 切换到蜂窝网络，App 应保留完整的工作上下文。

如果远端支持 Mosh，应优先使用 Mosh；如果远端没有安装 `mosh-server` 或 Mosh 建连失败，应自动回退到 SSH。

---

## 4. V1 核心使用场景

### 4.1 打开 App 后继续已有工作

用户打开 App。

App 自动或手动连接已保存的 Host。

连接完成后，App 展示 Herdr 中当前存在的 workspace、tab、pane，以及可获得的 agent 状态。

用户选择正在运行或等待输入的 agent，直接进入对应 terminal。

原有 agent 和开发环境保持不变，可以继续使用。

---

### 4.2 在纯触屏环境下回复 agent

用户没有连接任何外接键盘。

进入 terminal 后，点击输入区域唤起系统软件键盘。

用户可以：

- 输入普通文本；
- 输入 shell command；
- 回复 agent；
- 使用 `Esc`；
- 使用 `Tab`；
- 使用方向键；
- 使用 `Ctrl-C`、`Ctrl-D`、`Ctrl-Z` 等 terminal 常用组合；
- 使用 `Alt/Meta`；
- 滚动 terminal；
- 选择文本；
- copy / paste。

纯触屏模式必须支持完整的工作流程，包括查看和操作。

---

### 4.3 使用外接键盘

用户连接 Bluetooth 键盘后即可直接使用。

普通字符输入和 terminal modifier 应正常工作。

常见的 terminal shortcuts 应优先传递给 terminal。

外接键盘用于提升输入效率，所有核心操作仍需支持纯触屏完成。

---

### 4.4 移动网络切换

用户当前通过 Mosh 使用一个 Herdr pane。

设备从 Wi-Fi 切换到 cellular，或者短暂失去网络。

App 显示 reconnecting 状态，但不立即销毁当前 session。

网络恢复后继续当前 terminal。

如果当前 Host 无法使用 Mosh，则通过 SSH 使用同样的产品流程，但不承诺 SSH 能提供相同程度的 roaming 能力。

---

### 4.5 App 离开前台后恢复

用户短暂切到其他 App、锁屏或让 App 进入后台。

重新返回时，App 应尽量：

1. 恢复 Host connection；
2. 找回上次 Herdr target；
3. 回到对应 terminal。

如果该 target 已经不存在，则回到 Herdr browser，并明确表示原目标已经结束或消失。

---

## 5. 产品对象

客户端应尽可能直接映射 Herdr 自身已有的数据模型，不额外创造独立的 agent session system。

主要对象包括：

- Host
- Herdr server/session
- Workspace
- Tab
- Pane
- Agent state

Pane 对应真实 terminal。

如果一个 pane 中存在 Herdr 已识别的 agent，客户端显示相应 agent 信息与状态。

客户端不通过 terminal 文本猜测 agent 生命周期。

Herdr 是 agent runtime 状态的 source of truth。

---

## 6. V1 功能范围

### P0 — V1 必须具备

#### Host Connection

用户可以保存 Host 配置，至少包括：

- display name
- hostname / IP
- SSH port
- username
- authentication information
- preferred connection mode

Connection mode 支持：

- Auto
- Mosh
- SSH

默认使用 Auto。

Auto 模式：

```text
SSH bootstrap
  ↓
尝试启动 / 连接 Mosh
  ├─ 成功：使用 Mosh
  └─ 失败：继续使用 SSH
```

发生 fallback 时，App 继续建立连接，并显示当前实际使用的 transport。

---

#### Herdr Discovery

连接 Host 后，App 自动识别 Herdr 是否可用，并以只读方式查询当前 session。用户无需手动进入 shell 执行 discovery 命令。

Herdr 的 default session 和 named session 分别对应独立的 background server namespace。App 将它们统一显示为 Herdr sessions。

如果可用，应展示至少：

- session
- workspace
- tab
- pane
- agent presence
- agent state

如果 Herdr 不可用，普通 terminal 连接仍然可以使用。

Herdr discovery 本身不依赖 agent hook。Herdr integrations 可以提高 agent state 和原生 session identity 的准确度，属于可选的 server 端增强。

---

#### Herdr Navigation

用户可以直接从 App 中选择 Herdr target。

整个过程可以在 App 导航界面中完成，无需先进入 shell 手动操作 Herdr。

Discovery 完成后的导航规则：

1. 没有活动 session：显示未发现活动 Herdr session，并提供普通 terminal 入口；
2. 只有一个活动 session：跳过 session 选择，直接列出其中的 workspace、tab、pane 和 agent；
3. 存在多个活动 session：先展示 session 列表，用户选择后再展示对应的 workspace、tab、pane 和 agent。

导航界面应突出：

- 当前正在工作的 agent；
- 等待用户输入的 agent；
- 已结束或 idle 的 agent。

---

#### Direct Terminal Attach

选择 Herdr pane 后，进入该 pane 对应的真实 terminal。

Terminal 是主要交互界面，并保留原始的终端体验，不转换成 Chat UI。

App 仅在用户选择 pane，或明确触发“恢复上次 pane”时建立 terminal attach。单个 Herdr session 只会跳过 session 选择，不会自动选择或 attach 其中的 pane。

恢复上次 pane 时不抢占已有的 writable controller。目标当前被其他客户端控制时，App 先进入 observe 状态，再由用户确认是否 takeover。

---

#### Terminal Rendering

V1 使用成熟 terminal emulator library。

至少需要：

- ANSI / xterm 常用行为；
- colors；
- alternate screen；
- Unicode；
- wide characters；
- scrollback；
- resize；
- cursor；
- text selection；
- copy / paste。

---

#### 触屏输入

触屏输入属于 V1 核心功能。

普通文字输入使用 iOS / iPadOS system keyboard。

同时提供 terminal-specific input bar。

第一版至少需要：

```text
Esc
Ctrl
Alt
Tab
←
↓
↑
→
```

`Ctrl` 和 `Alt` 应作为 modifier 使用，能够与其他按键组成组合键。

至少应能方便完成：

```text
Ctrl-C
Ctrl-D
Ctrl-Z
Ctrl-L
Ctrl-[
```

软件键盘弹出后：

- terminal viewport 应正确缩小；
- 当前输入行应尽量保持可见；
- terminal size 应同步更新。

---

#### Touch Interaction

Terminal 中至少支持：

- tap focus
- vertical scroll
- text selection
- copy
- paste

标准 Bluetooth mouse / trackpad 如果通过系统 pointer API 暴露，应能够完成基本 click 和 scroll。

---

#### Session Restoration

App 应保存上一次使用的：

- Host
- Herdr target

重新进入 App 后，应尝试恢复工作位置。

如果原 Herdr target 已不存在，App 应返回 Herdr browser，并提示目标已失效。

---

#### Appearance

支持：

- System
- Light
- Dark

默认跟随系统。

---

#### Font

Terminal 字体属于基础可用性需求。

V1 至少支持：

- monospace font
- font size adjustment
- Nerd Font glyph 正常显示

App 应提供至少一个适合 terminal 使用并允许随 App 分发的 Nerd Font-compatible font。

---

### P1 — V1 后续增强

以下功能可以较早加入，但不阻塞 V1：

- 外接键盘专属 App shortcuts；
- 自定义 terminal shortcut bar；
- 用户导入 `.ttf` / `.otf`；
- 更多 terminal palettes；
- 更丰富的触控 gesture；
- iPad multi-window；
- Herdr target 快速切换快捷键；
- recent sessions；
- more detailed connection diagnostics。

---

## 7. 外接键盘支持

V1 的完整流程必须支持纯触屏操作，同时保证外接键盘的基础兼容性。

至少应正常处理：

- character input
- Shift
- Ctrl
- Option / Alt
- Tab
- Shift-Tab
- Esc
- arrow keys
- Home / End
- Page Up / Page Down
- Function keys，在系统允许范围内

App-level shortcut 应尽量少。

原则：

> terminal input 优先于 App navigation shortcut。

V1 不依赖针对 programmable keyboard、ZMK 或特定硬件的专项优化。

---

## 8. UX 原则

### 以 Herdr workload 为导航核心

用户进入 Host 后，首先看到当前的 Herdr workload。界面应直接呈现 workspace、任务和 agent 状态，避免将它们简化成一组缺少上下文的 terminal tabs。

例如更接近：

```text
desktop

qing
  coding
    Pi          working
    reviewer    blocked

mmq_vibe
  main
    Pi          done
```

以下形式无法提供足够的任务上下文：

```text
Terminal 1
Terminal 2
Terminal 3
```

---

### Agent attention 应快速可见

如果 Herdr 已经能够提供 agent state，UI 应让用户不进入 terminal 就能快速判断：

- 哪里正在工作；
- 哪里需要输入；
- 哪里已经结束。

V1 不要求实现 Inbox 或 push notification，但状态必须在 Herdr browser 中直接可见。

---

### 保留原生 Terminal 体验

Herdr 提供的上下文用于帮助用户找到目标 terminal。进入工作状态后，用户直接使用真实 terminal，agent 原有的对话和 TUI 保持不变。

---

### 触屏支持完整交互

移动端用户必须能够只拿设备完成一次完整 agent interaction。

以下行为均需支持纯触屏完成：

- 找到 agent；
- 打开 terminal；
- 输入 prompt；
- interrupt；
- copy / paste；
- 切换 Herdr target。

---

## 9. V1 明确不做

V1 不包含：

- native agent Chat View
- transcript parsing
- Diff Viewer
- push notifications
- Live Activity
- Browser Preview
- image / file upload
- SFTP browser
- Git UI
- port forwarding management UI
- embedded Tailscale
- account system
- cloud sync
- credential sync
- team collaboration
- MCP client
- voice input / dictation
- server monitoring dashboard

这些功能可以在后续版本中单独评估，V1 不为其预留额外范围。

---

## 10. 成功标准

V1 达到可用状态时，应满足以下四个结果。

### 1. 纯触屏可完成完整流程

用户不连接任何外设，可以：

```text
连接 Host
→ 找到 Herdr agent
→ 进入 terminal
→ 输入回复
→ 发送 Ctrl-C 等控制操作
→ 返回并切换其他 agent
```

---

### 2. Herdr 是一级产品对象

App 直接展示 Herdr workspace、pane 和 agent state，用户可以快速找到正在运行的 Herdr session 并进入对应 terminal。

---

### 3. 移动连接具有合理韧性

远端支持 Mosh 时，Wi-Fi / cellular 切换和短暂断网不会导致用户重新寻找 Herdr 工作上下文。

远端不支持 Mosh 时，App 自动通过 SSH 保持基本可用。

---

### 4. 可以作为日常 terminal 使用

Terminal 的以下基础能力均达到日常可用水平：

- 字体；
- Nerd Font；
- Unicode；
- colors；
- touch scroll；
- copy / paste；
- software keyboard；
- external keyboard basic compatibility；
- light / dark。

---

## 11. V1 产品边界

V1 的核心验收问题是：

> 用户能否拿起 iPhone 或 iPad，在几秒内找到远端 Herdr 中需要自己关注的 agent，并可靠地继续操作？

围绕通用 SSH client 的功能完整度不作为 V1 的衡量标准。上述工作流达到稳定、自然、可日常使用的程度，即视为 V1 达成产品目标。
