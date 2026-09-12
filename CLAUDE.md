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
5. A full rebuild never goes through `flutter run`'s own install. When that
   install fails, flutter uninstalls the app and installs again, and the
   uninstall wipes the app's data on the tablet (hosts, keys, settings). This
   happened once, when HyperOS rejected an install with
   `INSTALL_FAILED_USER_RESTRICTED`. Instead:
   - build with `flutter build apk --debug`;
   - install with `adb install -r -t <apk>`, which fails without uninstalling;
   - launch the app and `flutter attach`.
   If HyperOS blocks the install, ask the user to tap Install on the tablet.

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
| Theme contrast: stronger colours for every named theme (terminal text 7:1, ANSI colours 4.5:1, dim grey 3:1; app colours more contrasty and truer to each theme's accent) | Coordinator | 53c761e | UAT passed |
| Logs: a history of past sessions (date, start–end, host with its distro icon, Saved bookmark), opened from the host list, like Termius | Coordinator | 6ce6441 | UAT passed |
| Server OS info: read on every connect (os-release, uname, macOS, Windows) and saved on the host; the host list shows it with a distro/OS icon | Coordinator | db1c6b0, ba6d9c2, d80018f, 7260967, b74a50f | UAT passed (after three failed tries: "yang server info ini ngebuat card sizenya tidak konsisten", uneven cards; "mending tulisan Ubuntu 22.04.5 LTS dipindah di bawah logonya saja … arch version di takeout saja"; "tulisan ubuntunya di remove aja kan udah ada iconnya itu sudah cukup sih" and "terus tulisan versionnya di kecilkan lagi", so now only the version, in smaller text, under the logo) |
| Host list as cards: a grid, 1 column on a phone and 3 on a tablet, not full width | Coordinator | 4bf1e4a | UAT passed |
| The host-list tab chip reads "Home" with a home icon | Coordinator | e93419e | UAT passed |
| Port forwarding on its own screen from Home: a setting picks a saved or new host and runs a headless SSH connection; each port is Tablet → Remote (`ssh -L`, 127.0.0.1 on the tablet) or Remote → Tablet (`ssh -R`), with one port field, common-port snippets (PostgreSQL, MySQL, Redis…), a live sentence and Advanced host/port | Coordinator | d8b0fe1, 9d719a0, 158e1f8, 17c5a90, 42ad695 | UAT passed (after three failed tries: "untuk portforward ini buatnya headless session, jadi perlu ada screen tersendiri …"; then "ini aku nga ngerti cara pakainya, ux nya mending di buat pilih arah port forward apakah dari tablet ke remote, atau remote ke table, lalu port yang mau di forward  dan ada pilihan advance untuk mengisi mengcustom port atau hostnya" and "user juga di kasikan port snippet, misalkan dia mau connect untuk postgrest"; then "harusnya untuk bagian advance ketika user sudah pilih snippet di bagian advance juga langsung terpilih", so a snippet now fills Advanced with real values) |
| Theme in Settings: light/dark/system mode and named colour themes (Clode, Dracula, Nord, Gruvbox, Solarized, Catppuccin, Tokyo Night, One Dark) for the app and the terminal | Coordinator | f3ad854, 73026d6, 627d7a1 | UAT passed ("theme, sudah pass tapi color palettenya kurang kontras"; the contrast follow-up is its own row at the top; after two failed tries: "theme and collor pallet yang aku maksud bukan cuma applikasi tapi di color schema terminalnya juga harusnya berubah juga", then "untuk theme ini kayanya sama aja", where switching palettes changed only a faint terminal tint and the cursor) |
| Long-press a tab that failed to connect → Close tab (its ✕ is Reconnect then, so it could not be closed) | Coordinator | 6c77828 | UAT passed |
| Security hardening: a new host key asks before it is trusted (fingerprint shown), a changed one shows old and new and can be replaced; no Google backup or device transfer of app data; `/tmp` uploads and editor saves never follow a planted link, and uploads are `0600`; release builds sign with `android/key.properties`; the private-key field stays out of keyboard learning | security audit codebase | 00f3aaa | UAT passed (backup off, checked over adb; new-host-key prompt, private-key field, editor save and http links passed by the user; uploads land as `-rw-------`, checked on DESKTOP-L2EPDPG; the planted-link trap was never set up, because the coordinator's setup was blocked for deleting the uploaded copy, and the user accepted that part; release signing can't be checked on a debug build) |
| Proxy jump: a host can connect through another saved host ("Jump host" in its edit page, like `ssh -J`; a jump host may have its own) | proxy jump settings | b8484f5 | UAT passed |
| Tailnet forwarding: never forward debugger ports (9229 etc.), stop a forward as soon as its server stops, reuse the same tailnet port when it comes back (restarting `bun dev` stacked 3002–3005 and exposed the inspector) | Coordinator | 5ed4f74 | UAT passed |
| Settings page (⚙ on the host list) with a terminal font picker (Cascadia Mono, Cascadia Code, CaskaydiaCove Nerd Font, JetBrains Mono, Fira Code) and font size, live everywhere | Coordinator | 09ced89 | UAT passed |
| App renamed to Clode (visible name only; package id, settings keys, tmux names and the sshbox:// scheme keep "sshbox") | Coordinator | 66d22e3 | UAT passed |
| The Tailscale sign-in link opens in a web tab too (Google may refuse embedded sign-in; Open in browser is the fallback) | Coordinator | bf149c7 | UAT passed |
| Tucked magic key: a short pull (~32 dp past the dead zone) switches the aim to ring 2, sliding back returns to ring 1 | Coordinator | b5d129c, 1da91aa | UAT passed |
| Hidden tabs cannot take keyboard focus; switching tabs focuses the page shown (keys typed after a file tab opens no longer reach the hidden shell) | Coordinator | b34a998, 6e112ce | UAT passed |
| Toasts in the toastification style at the top, auto-closing (1s by default); the port-forward notice becomes a 5s toast with Open | Coordinator | 6764896, 89f37e0 | UAT passed (after a retest: the first port-forward test ran a server started before the session connected) |
| Code editor: find and replace, go to line, and a search result opens at its line | text editor enhancement | bf404f2 | UAT passed |
| Code editor key bar: arrows and a cursor pad, Tab, undo/redo, symbols (the user found no way to move the cursor in a file) | text editor enhancement | 13c7831, 47d9013 | UAT passed (after a first failed try: physical-keyboard arrows did not move the editor cursor) |
| Holding a selection handle at the top or bottom edge keeps the terminal scrolling | Coordinator | 40bcdd9, 7df6997, 479c2a5, 46e9fcd | Dropped by the user after three failed UATs; removed in 46e9fcd |
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
