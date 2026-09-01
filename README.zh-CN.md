# Agent Island v2.1.2 —— Windows/WPF Fork

本仓库是 Agent Island v2.1.2 的非官方 Windows/WPF 开发 fork，当前在 `windows` 分支维护。

## Fork 信息

- **上游 Agent Island 仓库：** [tristan666666/agent-island](https://github.com/tristan666666/agent-island)
- **上游历史原文档：** [Agent Island README](https://github.com/tristan666666/agent-island/blob/main/README.md)
- **原始基础项目：** [ericjypark/codex-island](https://github.com/ericjypark/codex-island)
- **官方站点：** [agent-island.dev](https://agent-island.dev/)
- **v2.1.2 使用的源码归档：** [Fossies Agent Island v2.1.2](https://fossies.org/windows/misc/agent-island-2.1.2.zip)

上游仓库及其历史文档链接目前可能无法访问。本仓库保留上游版权声明和 MIT 许可证。

## 分支说明

- **默认分支：** `windows`
- **用途：** 基于 v2.1.2 源码快照进行 Windows/WPF 开发和维护。

## 本 fork 的 Windows/WPF 修改

`windows/` 是本 fork 当前维护的 Windows/WPF 实现，现有修改包括：

- **五个 Agent 选择：** 支持 Claude、Codex、Antigravity（`agy`）、Grok 和
  Cursor。在设置中最多启用两个，列表顺序决定岛上的左、右位置，服务行支持
  上下拖拽排序。
- **额度接入：** 从本机 `agy` / Antigravity language server 会话读取
  Antigravity 额度，并处理 CSRF/session。Claude 和 Codex 保持各自独立的额度
  窗口，包含 Codex 的 5 小时和周额度窗口。
- **额度展示：** Bar、Stepped、Numeric 三种样式支持双额度窗口，并显示绿色
  的重置剩余时间进度；进度随正常额度轮询刷新。
- **Windows 交互：** 悬浮模式仍支持拖拽并记忆位置。WPF 窗口现在按真实圆角岛体
  计算命中区域，不再用透明画布拦截鼠标；光晕和其他透明边缘会把鼠标事件穿透
  到后方应用，包括其他进程中的应用。
- **持久化与验证：** Provider 的选择和排序采用原子偏好保存，Windows 测试运行器
  覆盖 Provider 选择、额度解析、布局和额度缓存策略。

## 相关文档

- [Windows 构建说明](windows/README.md)
- [Windows 功能对齐说明](docs/WINDOWS_PARITY.md)
- [贡献指南](CONTRIBUTING.md)
- [MIT 许可证](LICENSE)
