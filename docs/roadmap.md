# Agent Island Roadmap

Agent Island is focused on one job first: keep Claude Code and Codex status visible, then bring you back when a run needs input. Website: [agent-island.dev](https://agent-island.dev).

## Shipping now

- Native macOS top-bar companion for Claude Code, Claude Desktop, Codex CLI, and the Codex app.
- One app, native on both platforms: SwiftUI on macOS, WPF on Windows ([windows/](../windows/)), same detection engine.
- Turn alarms when a background run finishes and needs your reply.
- Live provider logo states: working, idle, your turn, and needs attention.
- Claude and Codex usage, reset windows, and cost pages — plus Codex reset-card tracking.
- Weekly & monthly report cards with island ranks: your tokens, API value, and model mix as a shareable image, rendered locally.
- Visual modes with glow color choices, plus a solo layout for single-subscription machines.
- English and Simplified Chinese.
- Notch-style and compact top-bar layouts, so both notched and non-notched Macs can use it.

## Near term

- Keep tightening the turn alarm and deep-link flow across Claude Desktop, Claude Code CLI, Codex CLI, and the Codex app.
- Improve onboarding for first-time users: permissions, login state, and "why am I seeing this state?" explanations.
- Add clearer public examples for non-notched Macs, external displays, iMac, Mac mini, and older MacBooks.
- Improve release notes, issue templates, and contributor docs so bugs are easier to reproduce.

## Planned later

- More agent/provider integrations only after Claude and Codex are reliable enough for daily use.
- More install paths if the project gets enough demand.

## Non-goals for now

- A large agent dashboard.
- iOS support.
- Cloud sync or telemetry.
- Running user code on a remote server.

Everything should stay local-first and understandable: Agent Island reads local session files, shows local state, and uses the credentials already on your machine.
