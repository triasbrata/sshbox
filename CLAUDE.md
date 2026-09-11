# sshbox — how Claude sessions work here

Several Claude sessions work this repo at the same time. These rules keep them
from colliding on the user's tablet, and make sure nothing counts as done until
the user has tried it.

## Who runs the app

- One **coordinator** session holds the only `flutter run` / `flutter attach` on
  the user's tablet: a Xiaomi Pad 8 on wireless adb over the tailnet,
  `100.101.228.69:<port>`. The port changes whenever wireless debugging restarts.
  The coordinator is currently **fab enter magic key radial**.
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

Newest first. "Coordinator" means **fab enter magic key radial**, working
through its sub-agents.

| Feature | Responsible session | Commits | UAT |
|---|---|---|---|
| Links open in an in-app browser (Custom Tabs, the OS default browser's engine) | Coordinator | — | in development |
| Native tmux split panes ("Use tmux" per host) | Coordinator | 89845de, eea0e47, f2c3d92 | on tablet, UAT pending |
| Terminal selection with the platform's start/end handles and toolbar | Coordinator | — | in development |
| Follow's busy-check messages as a toast | Coordinator | — | in development |
| Files drawer reopens at its last scroll position | Coordinator | 039ca21, 5dc262e | on tablet, UAT pending (the first try ran on an older build) |
| Long press on text selects it; on blank space it arms the arrows | Coordinator | ce6223c | UAT failed: no start/end handles like built-in selection (fix in development above) |
| Ctrl+tap a path or link to open it | Coordinator | dd981a7 | UAT passed |
| Follow in terminal: every folder tapped in the tree, and never while a program runs | Coordinator | 47c3301, 3403407 | UAT passed |
| Code editor: line numbers, syntax colour, whole-file saves, drafts, sudo open/save | text editor enhancement | e20b9fe, 6bd0c2a, b418d69 | UAT passed |
| Long-press a shell tab → Duplicate session | Coordinator | 24c826a | on tablet, UAT pending |
| File tab reads `host · file` | Coordinator | e2b66eb | on tablet, UAT pending |
| Magic key: two concentric rings, and it fades to 60% while idle | Coordinator | e3e7387, 30a4171, 29259ab | on tablet, UAT pending |
| Magic key: throw it at a side to tuck it away | Coordinator | 7156040 | on tablet, UAT pending |
| Terminal arrows only after a long press; a plain drag scrolls | Coordinator | 50e2107 | on tablet, UAT pending |
| Shift+Enter on a hardware keyboard starts a new line | Coordinator | 02ef3c2 | on tablet, UAT pending |
| Terminal page without its header: files and upload in the key bar, reconnect on the tab | Coordinator | 853997f | on tablet, UAT pending |
| Forward servers started in a session to the tailnet | tailscale magic dns integration | 43e234d, fa53e25 | on tablet, UAT pending |
| Files drawer is a VS Code-style tree, with a root saved in the host config | file tree redesign ssh root | 640461b, 8fe5a96 | on tablet, UAT pending |
| Several sessions per host; the host list counts the active ones | config multi-session display | 7c84d2b | on tablet, UAT pending |
| "Open in terminal" from the files drawer | file drawer open directory button | 30fda9b | on tablet, UAT pending |
