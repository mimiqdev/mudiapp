# 2. SSH Terminal Vertical Slice

**出口：** 用户可以保存一台 Host，并通过 SSH 完成日常 terminal 操作。

- 完成 Host 配置、凭据存储和 host key 验证
- 将 SSH session 接入选定的 terminal adapter
- 支持基本连接状态、错误处理和手动重连
- 建立连接层与 terminal UI 之间的稳定接口，为 Mosh 留出替换空间
