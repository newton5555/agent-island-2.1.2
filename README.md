# Agent Island v2.1.2 — Windows/WPF Fork

This repository is an unofficial development fork for the Windows/WPF code of Agent Island v2.1.2. It is maintained on the `windows` branch.

## Fork information

- **Upstream Agent Island repository:** [tristan666666/agent-island](https://github.com/tristan666666/agent-island)
- **Historical upstream documentation:** [Agent Island README](https://github.com/tristan666666/agent-island/blob/main/README.md)
- **Original base project:** [ericjypark/codex-island](https://github.com/ericjypark/codex-island)
- **Official website:** [agent-island.dev](https://agent-island.dev/)
- **Source archive used for v2.1.2:** [Fossies Agent Island v2.1.2](https://fossies.org/windows/misc/agent-island-2.1.2.zip)

The upstream repository and its historical documentation links may currently be unavailable. This repository keeps the upstream copyright notice and MIT license.

## Branch

- **Default branch:** `windows`
- **Purpose:** Windows/WPF development and maintenance based on the v2.1.2 source snapshot.

## Windows/WPF changes in this fork

The `windows/` project is the active Windows/WPF implementation maintained in
this fork. The current branch includes the following Windows-side changes:

- **Five-provider selection:** Claude, Codex, Antigravity (`agy`), Grok, and
  Cursor can be enabled in Settings. At most two providers are shown on the
  island; their order determines the left and right slots, and provider rows
  can be reordered by dragging.
- **Usage integration:** Antigravity usage is read from the local `agy` /
  Antigravity language-server session, including CSRF/session handling. Claude
  and Codex usage keep their separate quota windows, including the Codex 5-hour
  and weekly windows.
- **Quota presentation:** Bar, stepped, and numeric styles support dual quota
  windows and a green reset-time progress indicator. Progress is refreshed with
  the normal usage polling cycle.
- **Windows interaction:** Floating mode remains draggable and remembers its
  position. The WPF window now tests the actual rounded silhouette instead of
  the transparent canvas; the halo and other transparent margins pass mouse
  input through to the application underneath, including applications from
  another process.
- **Persistence and verification:** Provider ordering/selection is saved as an
  atomic preference update, and the Windows test runner covers provider
  selection, quota parsing, layout, and usage-cache behavior.

## Related documentation

- [Windows build notes](windows/README.md)
- [Windows parity notes](docs/WINDOWS_PARITY.md)
- [Contribution guidelines](CONTRIBUTING.md)
- [MIT license](LICENSE)
