# Jeansh: Play Store listing (en-US)

This claims only what has passed the user's test on the tablet ("UAT passed"
in CLAUDE.md, Features). Server notifications, sharing into a session and
custom keys come in once theirs pass.

## App name (max 30 characters)

Jeansh: SSH Terminal

## Short description (max 80 characters)

Terminal buddy in your pocket: SSH tabs, tmux, a file tree and a code editor.

## Full description (max 4000 characters)

Jeansh is an SSH terminal for Android phones and tablets. It's built for touch and works just as well with a hardware keyboard. Connect to your servers, keep several sessions open in tabs, browse and edit their files and forward ports, all from one app.

Terminal
• Tabs for every session, several per host; long-press a tab to duplicate a session
• Native tmux split panes, switched on per host
• A key bar with Ctrl, Alt, Esc, Tab and the arrows, which you can reorder and trim in Settings
• The magic key: a floating Enter key that opens two rings of keys under your thumb (arrows, Esc, Tab, Ctrl+C and more), and tucks into the edge of the screen when you throw it there
• Long-press blank space and drag for arrow keys; a plain drag scrolls
• Select text with the system's handles and toolbar
• Ctrl+tap a path to open it, or a link to open it in a web tab beside the shell
• Shift+Enter starts a new line from a hardware keyboard
• Light, dark or system mode, with Dracula, Nord, Gruvbox, Solarized, Catppuccin, Tokyo Night and One Dark themes for the app and the terminal
• Terminal fonts: Cascadia Mono, Cascadia Code, CaskaydiaCove Nerd Font, JetBrains Mono and Fira Code, at the size you like

Files
• A VS Code-style file tree for each server, starting from a folder you choose
• Open a folder in the terminal, or have the terminal follow the folders you tap
• A code editor with line numbers, syntax colours, find and replace, go to line, drafts that survive a restart, and sudo open and save
• Markdown files open rendered, with a switch to the source
• Upload files from your phone into any folder on the server, and download files to your phone

Connections
• Sign in with a password or a private key (OpenSSH or PEM, read from a file), with a passphrase
• Jump hosts, like ssh -J
• Port forwarding on its own screen: tablet to server (ssh -L) or server to tablet (ssh -R), with ready-made ports for PostgreSQL, MySQL, Redis and more
• Servers you start in a session can go on your tailnet through tailscale serve
• Tailscale SSH: its sign-in page opens beside your session
• Each host shows its operating system with its logo, and Logs keeps a history of your sessions

Security
• A new host key is trusted only after you've seen its fingerprint, and a changed one is shown old beside new
• Known hosts lists every fingerprint you trust, and can forget any of them
• Passwords, private keys and passphrases are encrypted with the Android Keystore, and none of the app's data goes into Google backups or device transfers
• No account, no ads, no analytics

Jeansh is a client: bring your own servers.
