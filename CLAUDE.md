# sshbox — how Claude sessions work here

Several Claude sessions work this repo at the same time. These rules keep them
from colliding on the user's tablet, and make sure nothing counts as done until
the user has tried it.

## Who runs the app

- One **coordinator** session holds the only `flutter run` / `flutter attach` on
  the user's tablet: a Xiaomi Pad 8 on wireless adb over the tailnet,
  `100.101.228.69:<port>`. The port changes whenever wireless debugging restarts.
  The coordinator is currently **sshbox development center**.
- Every other session and sub-agent is a worker. Workers never run `flutter run`,
  `flutter install` or `adb install`, and never launch or drive the app on any
  device or emulator. `flutter analyze` and `flutter test` are fine.
- The coordinator hands feature work to sub-agents, each in its own worktree. It
  answers the user itself, merges, reloads the tablet and keeps the UAT table
  below.

## Finishing a change

1. Work on a branch in a worktree. Merge `main` into it, and get
   `flutter analyze` and `flutter test` clean.
2. Fast-forward `main` to the branch and push. The coordinator does this step for
   sub-agents, because git against the main checkout is blocked from their
   worktrees. If `main` moved in the meantime, merge it into the branch again and
   re-verify. `main` must always build.
3. Tell the coordinator the commit, what to test on the tablet, and what the
   change needs:
   - a hot reload, for most changes;
   - a hot restart, for new fields, `initState` or globals;
   - a full rebuild, for new plugins or native code.
4. The coordinator reloads the tablet (`kill -USR1 <pid>` for a hot reload,
   `kill -USR2 <pid>` for a hot restart) and asks the user to test. It then
   updates the table below.

## User acceptance test (UAT)

A feature is **not done when it is merged**. It is done when the user has tried
it on the tablet and said it is OK.

- **New feature:** as soon as work starts, add a row to the table below naming
  the responsible session.
- **Status:** update the row as the feature moves along:
  `in development` → `on tablet, UAT pending` → `UAT passed` or
  `UAT failed: <what the user saw>`.
- **Follow-up:** after every reload, the coordinator tells the user what to test.
  At the end of each report it lists every feature that is still
  `UAT pending` or `UAT failed`, and follows up with the user that its UAT has
  not passed yet ("UAT belum pass").
- **Failed UAT:** the feature goes back to its responsible session, or to a new
  sub-agent, with the user's exact words. The row stays open until the user
  confirms the fix.
- **Passing:** only the user's OK moves a row to `UAT passed`. Merged, tests
  green, or "should work" don't count.

## Features

Newest first. "Coordinator" means **sshbox development center**, working
through its sub-agents.

| Feature | Responsible session | Commits | UAT |
|---|---|---|---|
| Hidden tabs cannot take keyboard focus; switching tabs focuses the page shown (keys typed after a file tab opens no longer reach the hidden shell) | Coordinator | — | in development |
| Toasts in the toastification style at the top, auto-closing (1s by default); the port-forward notice becomes a 5s toast with Open | Coordinator | — | in development |
| Code editor: find and replace, go to line, and a search result opens at its line | text editor enhancement | bf404f2 | UAT passed |
| Code editor key bar: arrows and a cursor pad, Tab, undo/redo, symbols (the user found no way to move the cursor in a file) | text editor enhancement | 13c7831, 47d9013 | UAT passed (after a first failed try: physical-keyboard arrows did not move the editor cursor) |
| Holding a selection handle at the top or bottom edge keeps the terminal scrolling | Coordinator | 40bcdd9 | UAT failed: it scrolls only one line, then the selection disappears (fix in development) |
| Links open as a web tab beside their shell (WebView); the Tailscale sign-in stays on a Custom Tab | Coordinator | de465b5, f54e12f, 0168e48 | UAT passed (after a first failed try where the Custom Tab opened a separate screen) |
| Native tmux split panes ("Use tmux" per host) | Coordinator | 89845de, eea0e47, f2c3d92 | UAT passed |
| Terminal selection with the platform's start/end handles and toolbar | Coordinator | dbd8375 | UAT passed |
| Follow's busy-check messages as a toast | Coordinator | b984c8e | UAT passed |
| Files drawer reopens at its last scroll position | Coordinator | 039ca21, 5dc262e | UAT passed |
| Long press on text selects it; on blank space it arms the arrows | Coordinator | ce6223c, dbd8375 | UAT passed (after a first failed try with no start/end handles) |
| Ctrl+tap a path or link to open it | Coordinator | dd981a7 | UAT passed |
| Follow in terminal: every folder tapped in the tree, and never while a program runs | Coordinator | 47c3301, 3403407 | UAT passed |
| Code editor: line numbers, syntax colour, whole-file saves, drafts, sudo open/save | text editor enhancement | e20b9fe, 6bd0c2a, b418d69 | UAT passed |
| Long-press a shell tab → Duplicate session | Coordinator | 24c826a | UAT passed |
| File tab reads `<hostname> · file` | Coordinator | e2b66eb, a168f3a | UAT passed (after a first failed try that showed the profile label) |
| Magic key: two concentric rings, and it fades to 60% while idle | Coordinator | e3e7387, 30a4171, 29259ab | UAT passed |
| Magic key: throw it at a side to tuck it away | Coordinator | 7156040 | UAT passed |
| Terminal arrows only after a long press; a plain drag scrolls | Coordinator | 50e2107 | UAT passed |
| Shift+Enter on a hardware keyboard starts a new line | Coordinator | 02ef3c2 | UAT passed |
| Terminal page without its header: files and upload in the key bar, reconnect on the tab | Coordinator | 853997f | UAT passed |
| Forward servers started in a session to the tailnet | tailscale magic dns integration | 43e234d, fa53e25 | UAT passed |
| Files drawer is a VS Code-style tree, with a root saved in the host config | file tree redesign ssh root | 640461b, 8fe5a96 | UAT passed |
| Several sessions per host; the host list counts the active ones | config multi-session display | 7c84d2b | UAT passed |
| "Open in terminal" from the files drawer | file drawer open directory button | 30fda9b | UAT passed |
