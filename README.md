# Jeansh

A mobile-first SSH client built with Flutter, targeting Android and iOS.

It was called sshbox; the Dart and Kotlin package names, the `sshbox://`
deep-link scheme and the repo keep that name.

## License

Source-available, not open source: see [LICENSE](LICENSE). The official
builds, on Google Play, are paid for. Build it yourself from this repository
and you may use your build for free, but you may not give it, or the source,
to anyone else. Pull requests are welcome from collaborators, and whatever is
contributed may ship in the paid builds.

## Why this stack

| Layer | Choice | Reason |
| --- | --- | --- |
| Terminal emulator | [`xterm2`](https://pub.dev/packages/xterm2) 5.2.0 | Maintained fork of `xterm.dart`; the original has gone quiet |
| SSH | [`dartssh2`](https://pub.dev/packages/dartssh2) 4.1.0 | Pure Dart, so Android and iOS run identical code with no JNI or cinterop |
| Secrets | `flutter_secure_storage` 11 | Android Keystore and iOS Keychain |
| Host list | `shared_preferences` | Non-secret metadata only |
| Web tabs | [`webview_flutter`](https://pub.dev/packages/webview_flutter) 4.14 | Android System WebView — Chrome's engine — inside a tab; a Custom Tab is an activity of its own and cannot be one |

A local shell was never on the table: iOS forbids `fork`/`exec` outright, and
on Android the W^X rules since API 29 stop an app executing binaries from its
own data directory — which is why Termux is pinned to `targetSdk 28` and left
Google Play. An SSH client sidesteps all of it.

## Architecture

```
lib/
  main.dart
  src/
    app.dart                        MaterialApp, dark-only theme
    models/host_profile.dart        a saved destination, holds no secrets
    data/
      host_repository.dart          host list in shared_preferences
      secret_store.dart             passwords and keys in the platform keystore
      known_host_store.dart         trust-on-first-use host key pinning
    session/
      terminal_session.dart         protocol-agnostic session interface
      dartssh2_transport.dart       the SSH implementation of it
      tailnet_forwarder.dart        servers started in a session, onto the tailnet
      tmux.dart                     tmux control mode: a tab's panes and layout
    files/
      file_browser.dart             protocol-agnostic filesystem interface
      sftp_file_browser.dart        the SFTP implementation of it
    ui/
      tabs_shell.dart               pinned host list + a tab per session/file
      hosts_page.dart               host list
      host_edit_page.dart           add / edit a host
      terminal_page.dart            TerminalView wired to a session
      tmux_panes.dart               tmux's panes laid out as tmux laid them out
      key_bar.dart                  the accessory keyboard row
      ctrl_click.dart               the URLs and paths a Ctrl+tap opens
      file_browser_page.dart        a VS Code-style file tree, as a drawer
      file_editor_page.dart         read and edit one remote file, in a tab
      web_page.dart                 a web page opened from a link, in a tab
      file_search_page.dart         find text under a directory
      settings_page.dart            Settings: the terminal's font and size
assets/
  fonts/<family>/                   the terminal's fonts, each with its license
```

`dartssh2` is imported in exactly two files, `dartssh2_transport.dart` and
`sftp_file_browser.dart`. Both are SSH implementations of an interface that
mentions no protocol; everything else is written against the interface.

### The one structural decision that matters

`dartssh2` is never wired directly into the terminal widget. Everything the UI
touches goes through `TerminalSession` / `SessionTransport` in
`session/terminal_session.dart`, which mention SSH nowhere.

That seam exists for mosh. On mobile the operating system suspends a
backgrounded app and its TCP connection dies — iOS gives roughly 30 seconds.
Mosh survives suspension and IP changes, and it is the single biggest reason
Termius and Blink feel better than a plain SSH client. Adding it here means
writing one more `SessionTransport` and changing the line that picks it; no
widget has to learn that anything changed.

`FileBrowser` in `files/file_browser.dart` is the same move made twice. Today
the only implementation is SFTP over the session already open. Later a daemon
on the host could replace it — HTTP for the CRUD, and a WebSocket only where streaming
actually pays: search results arriving as they are found, transfer progress,
file watching. None of that is decided yet, and the interface does not care
which arrives.

The interface is deliberately shaped by what the pages need rather than by
what SFTP offers. Modelling it on SFTP would force a daemon into a
round-trip-per-entry shape and throw away the one advantage it has.

### Security decisions already made

- **Host keys are pinned on first use** (`known_host_store.dart`). A changed
  key is refused rather than silently accepted, which is the difference
  between having and not having MITM protection. `KnownHostStore.forget()`
  is what a user needs after legitimately rebuilding a server.
- **Secrets never touch `shared_preferences`.** They only go to
  `SecretStore`, backed by the platform keystore. To gate reads behind a
  fingerprint, swap `AndroidOptions()` for `AndroidOptions.biometric()` in
  `secret_store.dart` — that is the entire change.
- **`INTERNET` is declared in the main manifest.** Flutter only puts it in the
  debug manifest, so a release build would otherwise ship unable to connect.
- **Cleartext HTTP is allowed** (`network_security_config.xml`), for the web
  tabs: a dev server on a host, or one forwarded to the tailnet, is plain
  `http`, which the WebView otherwise refuses outright. The only other HTTP
  in the app is HTTPS to the notification relay, and the direct
  notifications' tiny server, which answers inside SSH channels rather than
  on a socket — so it changes what a web tab may load and nothing more.
- **Editing a host leaves blank credential fields alone**, so changing a port
  cannot silently wipe a stored key.

### The key bar

`ui/key_bar.dart` is the piece that makes the app usable at all. A soft
keyboard has no Ctrl, Esc, Tab or arrows, which rules out vim, less, tmux and
job control. The bar arms a sticky Ctrl or Alt, and `applyModifiers` folds it
into the next character on its way out — tap `CTRL`, then `c`, and the remote
end receives a real `0x03`.

Cursor keys follow `terminal.cursorKeysMode`, emitting the SS3 form
(`ESC O A`) when an application requests DECCKM and CSI (`ESC [ A`) otherwise.
Sending the wrong one is why arrow keys produce garbage in vim in many
hand-rolled terminals.

The terminal page has no header: the tab strip already names the session. Its
two buttons open the bar instead, dressed as keys — the files drawer, then
upload, then `ESC` and the rest. Without a shell the keys go and those two
stay, greyed out, the way the header used to show them.

A hardware keyboard's Shift+Enter goes out as `ESC CR`, what Alt+Enter sends,
rather than the bare `CR` a terminal otherwise has for it — so Claude Code,
zsh and fish start a new line instead of submitting. It is decided once,
in the input handler of the session's `Terminal` (`session_manager.dart`); a
program that switches on the kitty keyboard protocol gets `CSI 13;2u` instead.
`test/hardware_keyboard_test.dart` holds it there.

The terminal itself doubles as an arrow pad (`SwipeKeyPad`). Long-press a
blank spot (a space, past the end of a line, the padding) until it buzzes,
then, still holding, drag towards the arrow you want; reach further and it
repeats faster. A plain drag scrolls the scrollback, and a double tap sends
Tab.

Long-press a character instead and it selects the word, with a lighter tick;
still holding, drag to widen it word by word. Once you lift, it looks and
works like selected text anywhere else on Android: Flutter's own handles at
each end, which you drag a cell at a time (they may cross), and the platform's
toolbar above it with Copy, Paste and Select all. The toolbar steps aside while
a handle is held. A drag anywhere else scrolls, and the handles and toolbar
follow the text as it scrolls or as output pushes it up. Copy (which says so),
Paste (xterm2's own, as Ctrl+V), a tap on the terminal or any key sent to the
shell ends it. A mouse selects with a drag as before.

### The magic key

`ui/magic_key.dart` floats a round Enter key over the terminal, for when the
keyboard is down. Tap it for Enter. Drag it to move it; throw it at a side and
it tucks in half off the screen. Left alone for a few seconds it fades to 60%
so the output under it shows through; a touch brings it straight back.

Hold it and two rings of keys open round it, each on its own band. The inner
ring has the arrows where they point, with ESC, TAB, `^C` and `^D` between.
The outer ring holds, behind each of those, one or two keys that go with it
(`magicSubKeys`): PgUp and Home behind ↑, PgDn and End behind ↓, Home or End
and a word jump behind ← and →, Shift+Tab behind TAB, a double ESC behind ESC,
`^Z` and `^\` behind `^C`, `^L` and `^R` behind `^D`. The first of each pair
sits right behind its key and the second one step clockwise. Slide toward a
key and lift to send it. How far you slide picks the ring: a little way up is
↑, straight on further is PgUp, and leaning clockwise out there is Home.
Lifting in the middle sends nothing. Near an edge both rings fan into the room
that is left, each outer key still behind its inner one.

Tucked into a side, that fan reaches halfway across the screen, so there the
outer ring is a short pull instead: slide toward a key until it lights up, go
on about 30 dp and the key behind it lights up, ease back and the inner key
has it again. The switch back sits a few dp inside the switch out, so a thumb
resting on the line does not flicker between the two. Out there it only ever
lights a key behind the one you pulled toward — straight on for the first,
a lean clockwise for the second — never one hanging off its neighbour, however
tightly a corner packs the fan.

### Ctrl+tap

VS Code's Ctrl+click, for a touch screen. With CTRL armed on the bar — or Ctrl
held on a hardware keyboard, which covers a mouse click with Ctrl — every URL
and path on screen gets a thin underline, and a tap on one opens it instead of
raising the keyboard: a URL in a web tab beside the shell, a folder as the
root of the files drawer, a file in a tab of its own, the way one picked in
the drawer opens. The tap types nothing, a program reading the mouse does not see it, and
it uses CTRL up whether it hit anything or not. A path that is not there says
**Not found:** and the path.

**Links open in a tab.** A Ctrl+tapped URL, a forwarded port's **Open** and a
Tailscale sign-in all go through `openUrl` in `ui/terminal_page.dart`, which
opens a web page in a tab of its own beside the shell it came from — see
[Tabs](#tabs). With no shell to put it beside — the web tab's own **Open in
browser**, or a port's toast still up after its tab closed — the page goes to
a Custom Tab instead: the phone's default browser — Chrome, Firefox, Edge —
draws it over the app with its own engine, cookies and sign-ins, and Back
comes back to the app. A browser that cannot do Custom Tabs gets the link as
an ordinary page; `mailto:` and the like go wherever Android sends them; and
when nothing takes it a red toast says **No app can open** and the link.
No `<queries>` is needed for this: url_launcher fires the Custom Tabs intent
without asking the package manager first, which is the only thing Android 11's
package visibility restricts.

The text is read back from the terminal's own buffer (`ui/ctrl_click.dart`),
rows the terminal wrapped joined up again, and quotes, brackets and the full
stop of a sentence taken off. A `:12` or `:12:3` after a path is read and
dropped — the editor cannot open at a line yet — and grep's `path:3:text`
works too. A bare `README.md` is tried when tapped but never underlined: it
could as easily be a word with a dot in it, and asking the host about every
one would be a round trip each.

**A relative path starts where the program that printed it is.** When Claude
Code prints `lib/src/ui/magic_key.dart`, that is relative to Claude Code's
project, not to wherever the shell was. `LiveSession.foreground()` asks the
host which process has the terminal and where it is, from `/proc`, on an exec
channel beside the shell:

- The shell is the oldest process with a terminal whose environment carries
  this connection's `SSH_CONNECTION` — the phone's address and port, which no
  two connections share — and whose parent's does not. sshd and tailscaled
  set it only in what they start, and everything else on the connection
  comes later. A marker variable sent with the shell would be simpler, but
  dartssh2 fails the shell when sshd refuses one, and Tailscale SSH drops them
  unless the tailnet policy lists them.
- Field 8 of `/proc/<shell>/stat` is the terminal's foreground process group,
  and its `cwd` is the answer. Its name, and whether it is the shell itself,
  come back with it.
- The shell's pid is kept until the connection goes.

On a host without `/proc` — anything but Linux — a relative path is taken from
home, and the snack bar says so when that misses. In a tab set to use tmux,
tmux answers instead, for the focused pane — see [tmux](#tmux). Inside a tmux
or screen started by hand, what it finds is the multiplexer's client rather
than the pane.

### Settings and fonts

The gear in the host list's bar opens Settings (`ui/settings_page.dart`). Its
one section so far is **Terminal**: a preview, the font size (9 to 24, 13 by
default) and the font, each font's row drawn in that font. The preview is
drawn by xterm2's own view, so its cells, colours and glyphs are what a shell
gets. A choice applies at once to every open terminal, tmux's panes included —
each is re-measured in the new cells and tmux is told how many fit now — and
is saved as `sshbox.terminal.fontFamily` and `sshbox.terminal.fontSize`.
`main` reads them before the first frame, so a shell never opens in one font
and resizes into the other a moment later.

The fonts ship in the APK, so they work offline:

| Font | From | Notes |
| --- | --- | --- |
| Cascadia Mono | [microsoft/cascadia-code](https://github.com/microsoft/cascadia-code) 2407.24 | PowerShell's and Windows Terminal's font |
| Cascadia Code | the same | Cascadia with ligatures; xterm2 draws a cell at a time, so none form in the terminal |
| CaskaydiaCove Nerd Font Mono | [ryanoasis/nerd-fonts](https://github.com/ryanoasis/nerd-fonts) 3.5.1 | Cascadia Code patched with prompt glyphs |
| JetBrains Mono | [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono) 2.304 | |
| Fira Code | [tonsky/FiraCode](https://github.com/tonsky/FiraCode) 6.2 | |
| System monospace | Android | the default, and what the terminal drew with before |

Each is the static Regular and Bold TTF from the official release, in
`assets/fonts/<family>/` beside its license, the SIL Open Font License 1.1.
Italic is left to Flutter's slant. Together they add about 5 MB to the APK,
3.5 MB of it the Nerd Font. Adding one means its files under `assets/fonts/`,
its family in `pubspec.yaml`, and a row in `terminalFonts`;
`test/settings_page_test.dart` fails if the two names differ, which would
otherwise draw in the system font without a word.

**Prompt glyphs never show as boxes.** spaceship and powerlevel10k draw
powerline arrows and a git branch from Unicode's Private Use Area, which no
ordinary font covers — Android's monospace included. Whatever font is picked,
those glyphs fall back to CaskaydiaCove Nerd Font Mono, whose Mono build draws
them a cell wide, and then to xterm2's own list, which ends at the system
monospace; emoji and CJK go where they always went.

## Running it

```sh
flutter pub get
flutter run
```

Tests:

```sh
flutter test
```

### Building for macOS and iOS

On a Mac with Xcode:

```sh
tools/build_apple.sh                  # macos, ios-sim and ios, release
tools/build_apple.sh macos            # just the Mac app
tools/build_apple.sh --team ABCDE12345 ios   # a signed .ipa
```

It runs `flutter pub get`, `flutter analyze` and `flutter test`
(`--skip-checks` drops the last two), then builds each target and leaves its
packages in `dist/<version>+<build>/` with a `SHA256SUMS`:

| Target | Package | Notes |
| --- | --- | --- |
| `macos` | `Jeansh-…-macos.zip`, `Jeansh-…-macos.dmg` | Signed ad hoc ("Sign to Run Locally"): it runs on the Mac that built it; another Mac's Gatekeeper refuses it until the quarantine flag is cleared (`xattr -dr com.apple.quarantine Jeansh.app`) |
| `ios-sim` | `Jeansh-…-ios-simulator.zip` | Always a debug build. `xcrun simctl install booted Runner.app` |
| `ios` | `Jeansh-…-ios-unsigned.ipa` | Without `--team`: unsigned, to sign later or sideload |
| `ios --team ID` | `Jeansh-…-ios.ipa`, `…-ios-dSYMs.zip` | Archived and exported with automatic signing; `--export-method` picks `debugging` (default), `release-testing`, `app-store-connect` or `enterprise` |

A signed build needs Xcode signed in to the team's Apple account (Xcode →
Settings → Accounts) so it can fetch a provisioning profile, or an App Store
Connect API key in `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID`. A device
only takes a `debugging` build once it is registered with the team.

The Flutter SDK comes from `$FLUTTER` if set, else the version `.fvmrc` pins,
through fvm (installed if missing), else `flutter` on `PATH`.

The macOS app keeps its secrets in the login keychain, not the data protection
keychain `flutter_secure_storage` uses by default, which only answers an app
signed with a provisioning profile (`lib/src/data/secret_store.dart`). Because
an ad hoc signature changes with every build, macOS asks for the keychain
password the first time a new build reads a saved secret. Its sandbox allows
outgoing connections (SSH, web tabs), listening sockets (`ssh -L` port
forwards) and reading a file the user picks (private keys, uploads).

### UI flows

`.maestro/` holds [Maestro](https://maestro.mobile.dev) flows:

```sh
maestro --device <serial> test .maestro/
```

| Flow | Covers | Needs |
| --- | --- | --- |
| `smoke` | app starts, host list renders | nothing |
| `deeplink_resume` | `sshbox://host/<id>` opens that host's terminal — the same payload a notification carries | nothing |
| `tabs` | opening a host adds a tab, switching away keeps the session, closing the tab ends it | a reachable host with a stored credential — a tab that cannot connect offers reconnect in place of its close button |
| `connect_and_keybar` | SSH connects and the accessory key bar renders | a reachable host with a stored credential |
| `file_browser` | the file tree opens and shows a listing rather than an error | a reachable host with a stored credential |

Two things worth knowing before editing these:

**Selectors need regex.** Flutter merges a `ListTile`'s title and subtitle into
a single accessibility node, so the host row reads as
`"WSL via tailnet\ntriasbrata@… · password"`. Maestro regex-matches the whole
string, so selectors use `"(?s)WSL via tailnet.*"` — plain text will not match.
This is correct screen-reader behaviour, so the selector adapts rather than the
app.

**Device choice matters.** Maestro installs a driver APK, and MIUI/HyperOS
refuses new-package installs over adb, so flows cannot run on a Xiaomi device
without lifting that restriction.

**Check the device's ABI before building for it.** The Galaxy A13 (SM-A135F)
here is `armeabi-v7a` only — arm64 hardware shipped with a 32-bit userspace.
An APK built `--target-platform android-arm64` installs onto it perfectly
happily and then dies at launch with `Could not find 'libflutter.so'`, which
reads like an app bug and is not one. `adb shell getprop ro.product.cpu.abilist`
settles it; a plain `flutter build apk --debug` covers every ABI and sidesteps
the question. `connect_and_keybar` additionally fails on
any device that cannot reach the host — that failure is the assertion doing
its job, since the keys only render on a live session.

`test/ssh_transport_live_test.dart` performs a real handshake against an sshd
on `127.0.0.1:22` using a deliberately wrong credential — reaching a clean
"authentication rejected" proves the socket, key exchange, host key pinning
and error mapping all work. It skips itself when nothing is listening on
port 22.

From an Android emulator the host machine is reachable at `10.0.2.2`, so a
local sshd is the easiest first target.

## Authentication

Three modes, chosen per host:

| Mode | What is stored | Notes |
| --- | --- | --- |
| Password | password, in the keystore | Fails fast if none is saved, rather than hanging on repeated prompts |
| Key | private key + passphrase, in the keystore | OpenSSH or PEM |
| Tailscale | **nothing** | tailscaled decides; the first connection may ask you to sign in through a link |

### Tailscale SSH

When a host uses Tailscale SSH, the app sends no credential at all. dartssh2
always appends `none` as the last authentication method to try, so configuring
no identity, no password callback and no keyboard-interactive handler leaves
`none` as the only one attempted — which is exactly what tailscaled expects.
Anything else would be offered first and rejected before it got there.

If the tailnet policy calls for a check, tailscaled sends the URL as an SSH
auth banner and holds the connection open. `session_manager.dart` pulls the
link out of that text and the terminal shows it with a button, which opens it
in a web tab beside the shell; finishing the sign-in is what releases the
session, so there is nothing to submit in the app, and the tab closes itself
once the session is through.
`authTimeout` is raised to five minutes for this mode, because a human is in
the loop.

Once the check passes, later sessions connect straight through until it
expires — which is why this mode ends up being the least friction of the three.

**Reachability, not preference, decides the address.** An emulator cannot see
the tailnet at all (its NAT does not route to the host's tailscale interface),
so it has to use `10.0.2.2` and the system sshd. Only real devices on the
tailnet can use Tailscale SSH.

### Forwarding ports to the tailnet

With **Forward ports to the tailnet** on in the host editor, a server started
in a session goes on the tailnet by itself. Run `vite` on the host, it listens
on `localhost:3000`, and a moment later a blue toast at the top says **Port
3000 is on `<host>.<tailnet>.ts.net:3001`**, with **Open**, for five seconds.
The server stopping takes it off again, and a toast says **Port 3000 closed**;
so does the tab closing.

```
vite ── localhost:3000 ◀── tailscale serve --tcp 3001 ◀── <host>.ts.net:3001
                           (run on the host, over the session's SSH)
```

A phone cannot make a port appear under the server's MagicDNS name, so the
work happens on the host, over the connection the shell already holds:

- **Watching.** A loop on its own exec channel reads `/proc/net/tcp` every two
  seconds and sends back only the listening sockets. A port counts when it is
  the user's own, on loopback or every address, below the ephemeral range
  (32768), not a debugger's, and was not already listening when the session
  connected — a session forwards what it started, not everything the box
  runs. A server listening on IPv4 and IPv6 both is one forward.
- **Debuggers never.** Some ports are not forwarded whoever opened them: V8's
  inspector on 9229, and 9230–9239 where more than one runs (node, deno, and
  workerd under miniflare, wrangler and vite's Cloudflare plugin); Chrome's
  DevTools on 9222; Bun's inspector on 6499; node's old `--debug` on 5858; and
  vite's old HMR port, 24678. They come up beside a dev server rather than
  being one — `vite dev` with Cloudflare's plugin opens workerd's inspector on
  9229 next to vite — and an inspector runs whatever code whoever connects
  sends it. On the tailnet it would be remote code execution on the host, for
  every device the tailnet lets in.
- **Forwarding.** One `tailscale serve --tcp <public> tcp://localhost:<port>`
  per server, in the foreground on a pty channel. Foreground rather than
  `--bg` because tailscaled drops a foreground config the moment its process
  goes, however it goes — `kill -9` included — so a phone that vanishes
  mid-session leaves nothing behind on the host.
- **The public port** is the first one above the server's that nothing on the
  host listens on, so 3000 goes to 3001. The tab remembers it: after a dropped
  connection the same server comes back at the same address.
- **Two tabs on one host** forward a server once. If the tab that forwarded it
  closes while the server keeps running, the other one takes it over.

The channels are closed with dartssh2's `destroy`, not `close`: `close` only
sends EOF and waits for the far end to finish, and neither the loop nor
`tailscale serve` reads stdin, so both would run on until the connection
dropped.

Closing the channel hangs up `tailscale serve` under OpenSSH, whose pty goes
with it. Tailscale SSH keeps the pty until the whole connection goes, and a
`serve` with nothing to write never notices: it kept serving and kept its
public port, so each restart of a server was forwarded one port further up —
3001, then 3002, 3003 — beside forwards that never went. So a forward that ends,
when its server stops, the tab closes or forwarding is switched off, is also
killed by its exact command line (`pkill -xf 'tailscale serve --tcp 3001
tcp://localhost:3000'`) on a channel of its own, and the server's next start
gets the same public port back. Without a connection there is nothing to send
that on, and no need: the host ends what the connection was running.

**What the host needs:** Linux, Tailscale, and permission to change the serve
config without root — `sudo tailscale set --operator=$USER`, once. Without it
the forward is refused, and a red toast in the blue one's place says **Port
3000 not forwarded** with tailscale's own words under it, for eight seconds.
A host that cannot forward at all (no tailscale, not Linux), or whose watch
fails, says **Not forwarding ports** and why, the same way. A refused forward
is not retried until its server restarts. Each forward holds a channel, and
OpenSSH allows ten per connection by default (`MaxSessions`), so about seven
fit beside the shell, the watch and the file browser.

**Recent Vite refuses hostnames it does not know.** Opened at `…ts.net:3001`
it answers "Blocked request. This host is not allowed"; add
`server: { allowedHosts: ['.ts.net'] }` to `vite.config.js`.

**It opens the port to the whole tailnet**, not only this phone — every device
the tailnet's ACLs let reach the host. That is why it is off by default, and
set per host.

## Sessions and resuming

`session/session_manager.dart` owns every open terminal, keyed by host id. The
`Terminal` object holds the scrollback, so it lives there rather than inside a
widget `State` — creating it in the page meant navigating back disposed it and
threw the session away.

`SessionManager.openOrCreate(host)` is the whole "take me back to my session,
or start a new one" rule, in one place. A tap in the host list and a tap on a
notification both route through `SshboxApp.openHost`, so they cannot drift
apart.

## Tabs

`ui/tabs_shell.dart` is the app's one screen: the host list pinned on the left,
then one tab per open session. Nothing is pushed on the navigator — the tab
strip is a *view* of `SessionManager`, so which tabs exist, in what order, and
which one is showing all come from the registry that already owned the
sessions. Opening a host selects its tab; closing a tab is the only thing that
ends a session.

The pages sit in an `IndexedStack`, so every terminal keeps its scrollback,
key bar and connection while another one is on screen. Only the visible page
may hold focus (`ExcludeFocus`), because hidden terminals still have focus
nodes — without it keystrokes land in whichever terminal grabbed focus last,
which means typed commands going to the wrong host. A tab shown again puts the
focus back on its terminal (the focused pane, with tmux), its file's text or
its web view, without raising the soft keyboard, so a hardware keyboard types
into what is on screen; only letters in a file wait for a tap into the text,
since re_editor takes them through the soft keyboard's connection.

**Files get tabs too.** The folder button opens the files drawer over the
shell; tapping a file there gives it a tab of its own, named
`<host> · <file>` — the host by its own name, the one its prompt shows, so
`DESKTOP-L2EPDPG · main.dart` rather than `WSL via tailnet · main.dart` — next
to the session it was read over. The session asks the host once per
connection, as it comes up (`uname -n`, cut at the first dot the way bash's
`\h` and zsh's `%m` cut it); until the answer arrives, or on a host that cannot
give one, the tab carries the host list's name instead. Picking
the same file again returns to its tab rather than opening a second one, and
closing a session takes its file tabs with it — they are read over that
session and cannot outlive it.

**So do links.** A web link from a session — Ctrl+tapped, a forwarded port's
**Open**, a sign-in check — gets a tab beside that session's shell, after its
files, under a globe. It is named by the page's own title once one has
loaded, and by the host until then: `box.ts.net` while
`http://box.ts.net:3001` loads. Android System WebView draws it, Chrome's
engine, through `webview_flutter`. A link already showing in one of the
session's tabs goes back to that tab. The tab closes with its ×, and with its
shell, whose link it was; but it needs nothing of the connection — the phone
fetches the page itself — so a shell reconnecting leaves it open. A sign-in
check's tab also closes itself once the session is through the check, and
whoever was still on it lands back in the shell. Some identity providers,
Google in particular, refuse to sign in inside an embedded web view; a check
that goes through one needs the bar's **Open in browser**, below. The app
does not pass the web view off as a browser to get past that: the providers'
policies forbid it.

A slim bar over the page (`ui/web_page.dart`) has back, forward, reload — stop
while a page loads, with a thin line under the bar for how far — the address,
and **Open in browser**, which hands the page to the phone's browser the way a
link with no shell opens. Tap the address to edit it and Go loads it; one
typed without a scheme gets `https://`. JavaScript is on, as in any browser,
and a popup opens in the same tab. What a page opens that is not for the web —
`mailto:`, `tel:`, `intent:` — goes to Android, as it would from a browser.

Keys typed in a web tab go to the page. The key bar and the magic key are the
shell page's, so a web tab shows neither, and the hidden terminal cannot take
focus back (`ExcludeFocus`, above). A hardware keyboard's Tab and arrows
would still be taken by Flutter to move its own focus — a web view has no key
handling of its own — so the page hands every key straight on to the view.

**A tab whose shell has ended** — closed by the host, dropped, or never
reached — trades its close button for a reconnect one, a cable. The terminal
page has no header left to hold it. Closing such a tab instead is **Close
session** in the host's menu on the host list. A tab that has not been asked
to connect yet, for the one frame before its page does, keeps its close button
rather than flashing the other.

**Long-press a shell's tab** for **Duplicate session**: another shell on the
same host, opened the way a tap in the host list opens one — at the end of the
strip, and shown. It starts where any new shell on the host starts, not in
the folder the first one had reached. A file or web tab has no menu. On a
host set to use tmux the menu also splits and closes panes — see
[tmux](#tmux).

**Room on the strip.** A phone fits about one and a half tabs, so the space
goes where it is read: the selected tab gets 180dp of name — enough for
`host · file.dart` — and the rest get 110dp and an ellipsis. A file tab too
narrow for its name cuts the host rather than the file, which is what tells two
files on one host apart. The pinned host list drops to its icon while you are
on a session, and selecting a tab scrolls it into view, so a notification tap
never lands on a tab that is off the right-hand edge.

**Deep link:** `sshbox://host/<hostId>` opens that host, resuming its terminal
if one is still open. Test it without any push infrastructure:

```sh
adb shell am start -a android.intent.action.VIEW -d "sshbox://host/<hostId>"
```

Both entry points are handled: `getInitialLink()` for a tap that cold-starts
the app, and `uriLinkStream` for one that arrives while it is already running.
Missing the first is the usual reason a notification only works when the app
was already open.

### Staying connected in the background

`session/session_keepalive.dart` runs an Android foreground service for as
long as any session is connected, and stops it when the last one closes. The
persistent notification it shows is a requirement of the platform, not
information the user needs — hence the low-importance channel.

This is not optional polish. Android freezes a backgrounded app and its TCP
connections die with it, and the bar for "backgrounded" is low: opening the
file picker to upload something was enough to drop a live shell before this
existed. Termux and Termius both run such a service for the same reason.

Android 14 wants the service type declared in two places that must agree —
`FOREGROUND_SERVICE_DATA_SYNC` in the manifest, and
`ForegroundServiceTypes.dataSync` when starting the service.

**What a session still does not survive:** the app process actually being
killed. Sessions live in memory, so if Android reclaims the app there is
nothing to return to and the next open is a fresh connection. iOS has no
equivalent to any of this — a suspended app there always reconnects, so the
keep-alive is a no-op off Android.

### Multi-window and floating windows

Split screen on a tablet and the OEM floating window (Samsung's pop-up view,
the Android desktop windowing shell) are one system feature, and the app only
has to declare it can be resized: `android:resizeableActivity` plus a
`<layout>` giving the window its minimum and default bounds. There is no
Flutter-side code for it.

Two things already in place are what make that declaration safe:

- `android:configChanges` lists `screenSize|smallestScreenSize|screenLayout|
  density`, so a resize reconfigures the activity instead of recreating it.
  Without that, dragging the split-screen divider would restart `MainActivity`
  and take every live shell with it.
- `TerminalView` reports its new size on every layout pass, which reaches
  `LiveSession.onResize` and then `shell.resizeTerminal` — so `vim` and `tmux`
  on the far end reflow to the new window instead of drawing to a size that no
  longer exists.

The declared minimum is 320x280dp: the tab strip (44dp) and key bar (48dp)
leave roughly eleven terminal rows between them.

**One window, not two.** Dragging out a second Jeansh window gives it a second
Flutter engine, and therefore its own `SessionManager` — the two windows would
not share sessions. Sharing them means moving sessions out of the isolate, so
Jeansh is meant to be one window beside another app, not beside itself.

## tmux

With **Use tmux** on in the host editor, a tab on that host is a tmux session,
and tmux's panes are the app's own terminals: laid out the way tmux split
them, with a thin line between, and no status bar, no borders drawn in text
and no Ctrl-b. Long-press the tab for **Split right**, **Split down** and
**Close pane**. They act on the focused pane, the one last touched, which is
outlined; the key bar, the magic key, the swipe pad and both keyboards type
into it. The tab's icon turns into a split pane to say which mode it is in.

```
tab ── SSH exec channel, no pty ── tmux -u -C new-session -A -s sshbox-<id>
         %output %1 <bytes>       ──▶ pane %1's Terminal
         send-keys -t %1 -H <hex> ◀── what is typed into it
```

This is tmux's control mode, the way iTerm2 uses it (`session/tmux.dart`).
The tab writes tmux commands and reads back replies and notifications; each
pane is an xterm2 `Terminal` fed from its own `%output`.

- **One tmux session per tab**, named `sshbox-<id>` with an id made when the
  tab opens. A dropped connection reattaches to it: the panes come back with
  their programs still running, each filled in from `capture-pane` along with
  its cursor and screen. Closing the tab kills it. The id is random rather
  than the tab's number, so a tab never lands in a session left behind by an
  earlier run of the app, or by another device.
- **tmux decides the sizes.** The tab tells tmux how many cells it has room
  for (`refresh-client -C WxH`), tmux answers with a layout, and each pane's
  view goes at exactly its cells, with the divider in the one cell tmux leaves
  between neighbours. `ui/tmux_panes.dart` measures a cell the way xterm2
  does.
- **Keys go as hex** (`send-keys -H`), so no byte is read as tmux syntax or
  looked up as a key binding: Ctrl-b is just Ctrl-b to the program.
- **Output is read as bytes.** tmux writes control bytes in `%output` as
  octal but UTF-8 as it is, so a character a pane wrote in two reads arrives
  split across two lines, and each pane decodes its own.
- **What a terminal says back on its own is dropped.** tmux is the programs'
  real terminal and has already answered "what are you" and "where is the
  cursor"; the pane's `Terminal` answering as well would type its answer
  into the program.
- **tmux knows where each pane is.** A split starts in the focused pane's
  folder, and `LiveSession.foreground()` asks tmux for the focused pane's
  program and folder rather than reading `/proc`, which would find tmux
  itself: a relative path Ctrl+tapped in a pane starts from that pane.
- **No tmux on the host** falls back to a plain shell, and says why.

It needs tmux on the host; it was built against 3.2a.
`test/tmux_live_test.dart` runs the real thing when tmux is installed where
the tests run — split, type, drop and reattach, kill — against a tmux server
of its own.

**Not yet:** tmux windows as tabs (a tab shows its session's current window),
dragging a divider to resize, copy mode, and zooming a pane. Nor does a tab
come back after Android kills the app: its session is left running on the
host, as is one closed while its connection was already down (`tmux ls`
lists them as `sshbox-…`).

## Notifications

A notification carries a `sshbox://host/<hostId>` payload, so tapping one goes
through the same router as a deep link — there is no second code path to keep
in sync.

The whole flow, as sequence diagrams: [docs/notification-architecture.md](docs/notification-architecture.md).

`notifications/notification_gateway.dart` displays them and handles taps,
including `getNotificationAppLaunchDetails()` for a tap that cold-starts the
app. `notifications/push_messaging.dart` is only the delivery half: FCM hands
over a message, the gateway does the rest.

**Message shape** — data-only, deliberately:

```json
{ "data": { "hostId": "1788717544349041", "title": "Build done", "body": "…" } }
```

A `notification` block would let Android post its own notification while the
app is backgrounded, and that one carries no payload to route with.

Every shell the app opens is told two ways to reach the phone: a port on the
host that comes straight down its own connection, and the host's own key for
the relay that sends the push. See [Sending one from a server](#sending-one-from-a-server).
**Copy notification key** on a host's edit page copies its relay key for a
server that won't take it.

**Testing without a server:** `sshbox://notify/<hostId>` posts a notification
locally, so the whole notify → tap → resume path can be exercised with adb:

```sh
adb shell "am start -a android.intent.action.VIEW \
  -d 'sshbox://notify/<hostId>?title=Build%20done&body=Tap%20to%20return'"
```

Firebase config lives in `android/app/google-services.json` and the
`applicationId` must match the `package_name` inside it.

### Sending one from a server

Two ways, and neither needs anything on the server but curl: straight down
the SSH connection while its session is open, and through the relay
otherwise.

**Straight down the connection.** Before a connection opens its shell, it
asks the host to listen on a port of the host's own loopback for us — `ssh
-R` on `127.0.0.1`, a port the host picks. What connects there comes down
that connection to the app, which answers it itself, as a tiny HTTP server
would, and shows it as a notification that opens the host when tapped. No
FCM, no relay, no internet: it works while the session is open, in the
background too. Nothing listens on the phone.

```sh
curl --connect-timeout 2 -m 5 "$LC_SSHBOX_NOTIFY_URL" \
  -H "Authorization: Bearer $LC_SSHBOX_NOTIFY_SECRET" \
  --data-urlencode "title=Build" \
  --data-urlencode "body=build done"
```

Only `POST /v1/send` is answered, with the connection's secret as its bearer
token. The body is a form, as there, or JSON: `body` is required and cut at
1000 characters, and `title` is "Jeansh" when left out, cut at 100. It
answers 200 `{"ok":true}`; 401 for a wrong secret; 400, 404, 405, or 413
past 16 KB otherwise; and hangs up on a request that has not arrived in five
seconds. A host that will not forward — `AllowTcpForwarding no`, say — still
connects, and its shells get neither variable.

**Through the relay.** [jeansh-notify](https://github.com/triasbrata/jeansh-notify),
a Cloudflare Worker at `https://jeansh-notify.brata.cloud`, holds the Firebase
credentials and sends a push, which reaches the phone with no session open.
Every request to it is signed, the way Indonesia's SNAP payment API signs
one, with a key only that host holds:

| Header | Holds |
| --- | --- |
| `X-PARTNER-ID` | the key id: `LC_SSHBOX_KEY` up to its colon |
| `X-TIMESTAMP` | the time, `yyyy-MM-ddTHH:mm:ssTZD`, as in `2026-09-14T08:15:30+07:00` |
| `X-EXTERNAL-ID` | 16 to 64 of `A-Z a-z 0-9 -`, new for each request |
| `X-SIGNATURE` | the ECDSA P-256 SHA-256 signature, DER, in standard base64 |

What is signed is
`<METHOD>:<PATH>:<lowercase hex SHA-256 of the body>:<X-TIMESTAMP>:<X-EXTERNAL-ID>`;
an empty body hashes the empty string. The relay checks the signature with
the key's public half and sends the push for the host the key belongs to.
With openssl and curl:

```sh
# A push through the relay, signed with this host's LC_SSHBOX_KEY. Title and
# body on one line each.
relay_notify() {
  esc() { printf %s "$1" | sed 's/[\\"]/\\&/g'; }
  body=$(printf '{"title":"%s","body":"%s"}' "$(esc "$1")" "$(esc "$2")")
  ts=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
  id=$(openssl rand -hex 16)
  hash=$(printf %s "$body" | openssl dgst -sha256 -r | cut -d' ' -f1)
  # The key reaches openssl on a file descriptor: never on disk or in ps.
  sig=$(printf 'POST:/v1/send:%s:%s:%s' "$hash" "$ts" "$id" |
    openssl dgst -sha256 -sign /dev/fd/3 3<<EOF | openssl base64 -A
-----BEGIN PRIVATE KEY-----
$(printf %s "${LC_SSHBOX_KEY#*:}" | fold -w 64)
-----END PRIVATE KEY-----
EOF
  )
  curl -fsS https://jeansh-notify.brata.cloud/v1/send \
    -H 'Content-Type: application/json' \
    -H "X-PARTNER-ID: ${LC_SSHBOX_KEY%%:*}" -H "X-TIMESTAMP: $ts" \
    -H "X-EXTERNAL-ID: $id" -H "X-SIGNATURE: $sig" \
    --data-binary "$body"
}
```

The relay repo's [notify.sh](https://github.com/triasbrata/jeansh-notify/blob/main/notify.sh)
does the same, after trying the direct way, and installs as `sshbox-notify`.

**One key per host.** `LC_SSHBOX_KEY` is `<key id>:<private key>`, the
private key PKCS#8 DER in standard base64. Each saved host has its own: a
P-256 key pair the app makes at the host's first connect and registers with
the relay (`POST /v1/register`, with the phone's FCM token, the public key's
SPKI DER in base64 and the host id). The key id is `jnk_` and the first 32
characters of the base64url SHA-256 of that SPKI, worked out on both sides.
The relay gets only the public half; the FCM token goes to no server. When
FCM replaces the token, every key is registered again for the new one and
keeps its id, so servers holding it carry on. With the relay out of reach, a
connect goes without `LC_SSHBOX_KEY` and the next one tries again. Deleting a
host revokes its key (`DELETE /v1/key`, signed with that key). **Settings →
Notifications → Reset notification keys** revokes every host's key, for when
one has got out: servers holding an old key stop notifying until their host
reconnects and gets a new one.

The two together, the direct way first:

```sh
notify() {
  curl -fsS --connect-timeout 2 -m 5 "$LC_SSHBOX_NOTIFY_URL" \
    -H "Authorization: Bearer $LC_SSHBOX_NOTIFY_SECRET" \
    --data-urlencode "title=$1" --data-urlencode "body=$2" >/dev/null ||
  relay_notify "$1" "$2" >/dev/null
}

# then, at the end of something slow:
make build; notify Build "build selesai"
```

Jeansh passes these with every shell it opens, plain or tmux:

| Variable | Holds |
| --- | --- |
| `LC_SSHBOX_NOTIFY_URL` | `http://127.0.0.1:<port>/v1/send`, the port the host listens on for this connection |
| `LC_SSHBOX_NOTIFY_SECRET` | this connection's own secret, 32 random bytes in base64url |
| `LC_SSHBOX_KEY` | this host's relay key: its id, a colon, and its private key |
| `LC_SSHBOX_HOST_ID` | the id of the saved host; the relay needs only the key, which names its host |

The first two only when the host listens for us, the last two only once the
host has a relay key.

**The server has to accept them.** OpenSSH takes only the variables its
`AcceptEnv` lists. Debian, Ubuntu and macOS ship `AcceptEnv LANG LC_*`, which
is why every name starts with `LC_`, the trick iTerm2's `LC_TERMINAL` uses.
Elsewhere, add `AcceptEnv LC_SSHBOX_*` (or `LC_*`) to `sshd_config` and reload
sshd. Tailscale SSH passes them only when the tailnet policy's SSH rule lists
them in `acceptEnv`, as in `"acceptEnv": ["LC_SSHBOX_*"]`, on Tailscale 1.76
or later. A server that refuses them still connects, and
`echo $LC_SSHBOX_KEY` prints nothing there; export `LC_SSHBOX_KEY` in its
shell's profile instead, from **Copy notification key** on the host's edit
page. The direct way
cannot be set by hand: its port and secret are new with each connection.

In tmux mode a tab adds the four names to tmux's `update-environment`, once
per tmux server, so tmux copies them into the tab's session when it makes it
and at every reattach. A new pane gets this connection's values even when the
tmux server was started by something else; a pane already running keeps the
ones it started with, whose direct URL went with the connection that gave it
— which is what the relay in `notify` above is for.

**A host's key goes to that host only.** It signs notifications to this
phone and does nothing else, and the relay sends them as that host's, so a
key that gets out of one host cannot speak for another. Deleting the host
revokes it; if one gets out, reset them.

**The direct way's ceiling.** The port is on the host's loopback, so on a
server others log in to, once the connection has ended another local user can
listen on that port and read what a shell left over from the connection sends
to it. They get the text of that one message and nothing more: the secret
stops them sending anything to the phone. It is also why `LC_SSHBOX_KEY`
never goes to the direct URL — whoever held the port would hold the key.

## Uploading files

The paperclip at the front of the key bar picks a local file, sends it to `/tmp`
on the host over SFTP, and types the resulting remote path at the prompt — so
the next thing you write is a command that uses it.

File transfer is an optional capability (`FileUploadCapable`), probed for
rather than assumed, because not every transport can do it — mosh cannot. The
upload is chunked against the file offset rather than read whole: dartssh2
offers no streaming write, and loading a video into memory is not something a
phone forgives. Filenames are scrubbed to `[A-Za-z0-9._-]`, since they arrive
from Android's picker and end up on a command line.

### Sharing into a session

Any app's share sheet lists Jeansh. The file lands in `/tmp` on the session you
were last in, and its path is typed at the prompt — the same path the paperclip
takes, so there is one upload routine and not two.

A share usually starts the app from dead, which means there is nothing to
upload to yet: the file waits until a host is opened, then goes. Android hands
over a `content://` URI owned by the sending app, which SFTP cannot read, so
`MainActivity` copies it into our cache first and passes only the path across
the method channel.

Android only. iOS needs a separate Share Extension target to appear in its
share sheet.

## Browsing files

The folder button that opens the key bar slides the remote filesystem in as a
drawer from the right. A drawer rather than a screen
because tapping outside it returns you to the terminal in one gesture, from
however deep in the tree you had wandered.

**It is laid out like VS Code's Explorer.** Dense one-line rows, a chevron on
each folder, a file-type icon on each file in the colours VS Code's default
theme uses, and a guide line down every open folder. Tap a folder to open it
in place, tap a file to open it as a tab. The root's header carries VS Code's
four actions — new file, new folder, refresh, collapse all. Everything else
is a context menu: long-press a row, or
right-click it with a mouse, for new file or folder inside it, set as root,
open in terminal, type path in terminal (shell-quoted, so the next thing you
write is a command that uses it), copy path, rename and delete. Rows are 32dp
rather than VS Code's 22px, which a finger cannot hit reliably.

**The tree hangs from one root.** **Set as root** re-hangs the tree from a
folder; the root's name on its header opens a menu of the folders above it,
which is the way back out. Back undoes the last re-rooting. The root, the
open folders and the scroll position survive the drawer closing, so picking a
file and coming back does not fold everything shut or jump back to the top;
a new root starts at its top.

**Where the tree starts is part of the host's config.** The host editor has a
**File tree root** field — blank is the login home, and `~/…` or a bare
relative path is taken from home, because SFTP expands neither itself. Each
new connection opens the tree there. **Save root to host config** in the
drawer's overflow menu writes the current root into that field, after a
dialog confirming it: unlike everything else in the drawer it outlives the
session. The saved profile is re-read before writing, so saving a root never
reverts an edit made to the host since the session opened.

The row menu also sends the shell to a folder with `cd`. **Follow in terminal**
in the overflow menu does that without being asked: every folder tapped, to
open it or to shut it, and every new root. Tapping a file only opens it, and
opening the drawer or refreshing moves nothing. Off by default, because it
types into a live shell on every tap.

Every `cd`, asked for or followed, first asks the host what the terminal is
running, through the `LiveSession.foreground()` a Ctrl+tap uses. Only a shell
sitting at its prompt gets the `cd` — and not even then when it is already in
that folder, so opening and shutting one types a single `cd`. With a program
in the foreground, where a `cd` would land as input to it, nothing is typed
and an amber toast names it: `claude is running — not moving the shell`. A
host that cannot say (not Linux, the probe failed) or does not answer within
1.5s gets nothing typed either, and the toast says which. In a tab set to use
tmux, tmux answers for the focused pane and the `cd` goes to it; inside a tmux
started by hand the probe sees tmux rather than the pane's shell, so every
`cd` is refused there.

**Toasts** (`ui/toast.dart`, on the `toastification` package) are cards in
their kind's colour — blue info, green success, amber warning, red error —
that slide in at the top, under the status bar. Each goes by itself after a
second, counting down along its bottom edge; a touch holds it, a swipe or its
× sends it off sooner. They stack rather than queue, three at most, so a
refusal for every folder tapped is on screen at once instead of each waiting
its turn, and words already showing are not said twice. A message's first
line is its title and any more go under it, since the title stops at two.

**A picked file opens as a tab**, named `<host> · <file>`, beside the session
it was read over:

```
files drawer ──tap──▶ tab `<host> · <file>`
   └── SFTP, over the session already open
```

One answer on every screen size, rather than a pane on a tablet and a pushed
screen on a phone — the tab strip is already the app's way of holding more
than one thing at once, and a file is one more thing. Picking a file that is
already open returns to its tab rather than stacking a second copy, and
closing a session takes its file tabs with it: they are read over that
session's own browser, which cannot outlive it. Every file tab on a session
shares that one browser, because a browser per tab is a channel per tab
sitting idle on the server.

Everything the pages touch goes through `FileBrowser`. They import no SSH, no
SFTP and no HTTP, which is what makes the transport swappable later.

**Errors are normalised in the adapter, not the pages.** SFTP status codes and
a daemon's HTTP responses look nothing alike, and letting either leak would
make the UI fluent in two error languages. `FileBrowserException` carries one
readable line plus a `fault` for the handful of cases a user can act on
differently — too large, not text, permission denied, gone.

**Refusing beats guessing.** A file over 1 MiB is not truncated into the
editor, it is refused with its size; a file with a NUL byte in it is refused as
binary; a file that is not valid UTF-8 is refused rather than decoded loosely,
because showing mojibake means saving mojibake back over the original.

### Search

Search is an optional capability (`FileSearchCapable`), probed for the same way
file upload is. Over SFTP it shells out to `grep -rnIF` on the session's own
connection — literal string, binaries skipped, capped at 500 hits — and runs on
submit rather than per keystroke, because each run is a process walking a tree
on the far end.

That is honestly the weaker half of the promise: a daemon could stream ranked
hits as it finds them. Having two implementations of unequal quality is exactly
why search is stated as a separate capability rather than folded into
`FileBrowser`.

## Releasing

### Build numbers

`pubspec.yaml`'s `version: X.Y.Z+N` holds the version name, X.Y.Z, which
users see, and the build number, N, which is Android's `versionCode` and
iOS's `CFBundleVersion`.

Every commit that changes the app raises N by one, through
`.githooks/pre-commit`. These count as changes to the app:
- anything in `lib/`, `android/`, `ios/`, `macos/`, `linux/`, `windows/`,
  `assets/` or `third_party/`;
- `pubspec.lock`;
- a `pubspec.yaml` change beyond its version line.

Docs, tests and `tool/` don't. A commit that changes the version line gets
`[build vN]` in its message, placed above any trailers.

The name is semver. The patch, Z, is X.Y's newest tag's, and goes up by
itself on the tenth build past the one that tag was made at, so 1.0.6 tagged
at build 65 becomes 1.0.7 at build 75. The major and minor are changed by
hand, with the patch back to 0, in the version line or with
`tool/release.sh --name X.Y`; an X.Y nobody has tagged yet is kept as
written. `.githooks/post-commit` tags the first commit
to carry each name, `vX.Y.Z`, annotated with its build number, so a new
major or minor and every patch get a tag. The tags stay on this machine:
pushing one releases that build on Play's closed testing (see From CI
below), so a tag goes up only when a release is meant, never with a push
of `main`. Leave `push.followTags` off.

The hooks stay off until a clone turns them on, once. Worktrees share the
setting, and a relative path makes each run the hooks its own branch holds:

```sh
git config core.hooksPath .githooks
```

`tool/test_hooks.sh` runs the hooks against a throwaway repo. Parallel
branches collide on the version line, X.Y.Z+N on both sides: keep the line
with the higher N, with `main`'s X.Y if the two differ, and the hook raises
it again on the merge commit and names its patch from the tags.

### A release from this machine

Without `android/key.properties`, a release build falls back to the debug key,
and Play refuses a bundle signed with it. So make an upload key once. Keep it
outside the repo, and back it up: if it's lost, only Play support can reset
it.

```sh
keytool -genkeypair -v -keystore ~/keys/jeansh-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Then write `android/key.properties`, which git ignores. It's a Java
properties file, so double any backslash in a password.

```properties
storeFile=/home/you/keys/jeansh-upload.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

Then, from a clean tree:

```sh
tool/release.sh                # or: tool/release.sh --name 1.1
```

The script:
1. refuses to run without the key, or with uncommitted changes;
2. builds `build/app/outputs/bundle/release/app-release.aab`;
3. checks that the bundle isn't debug-signed;
4. prints the bundle's versionName and versionCode.

`--name` first sets X.Y in `pubspec.yaml` and keeps N: `--name 1.1` turns
1.0.13+13 into 1.1.13+13. Commit that change afterwards.

### Publishing to Play, from the same machine

The release goes to Play from here, with `--publish`, or from CI below.

```sh
tool/release.sh --publish --dry-run   # everything but the commit
tool/release.sh --publish             # the real one
```

`--publish` builds as above and then hands the bundle to
`tool/play_publish.py`, which speaks the Play Developer API v3 with a service
account: it opens an edit, refuses a build number Play already has, uploads
the bundle, puts it on a track and commits. It needs `python3` and `openssl`:
between them they read the key, sign the sign-in token and speak the API,
without a single pip package. Nothing it prints is a secret, so its output is
safe to paste anywhere.

| Flag | Means |
| --- | --- |
| `--publish` | upload and release. Without it nothing is ever uploaded, and no plain `flutter build` can publish by accident |
| `--dry-run` | open the edit, upload the bundle, set the track — then drop the edit instead of committing, so no tester sees anything |
| `--track <id>` | the track to release on. The default, `alpha`, is what Play calls Closed testing. A custom closed track's id is the last part of its address in the Play Console; `production` is refused, and rolls out from the Console by hand |
| `--draft` | leave the release a draft rather than rolling it out. Play takes nothing else until the app has been published once |

The service account's JSON key is read from `$PLAY_SERVICE_ACCOUNT_JSON`, or
from `~/keys/jeansh-play-service-account.json` beside the upload keystore.
Keep it outside the repo — git ignores `*service-account*.json` in case one
lands there anyway. To make one:

1. **Google Cloud**, in the project the Play account is linked to: enable the
   **Google Play Android Developer API**, create a service account, and create
   a **JSON key** for it.
2. **Play Console → Users and permissions:** invite the service account's
   email address, and give it, for Jeansh, **Release apps to testing tracks**.
   Permissions take a few minutes to reach the API.
3. Save the JSON at the path above, `chmod 600` it.

`tool/release.sh --publish` checks the key and the track before the build, not
after it. Any failure before the commit drops the Play edit again, so a run
that dies half way leaves nothing behind and can just be run again.

Release notes are not sent. `store/RELEASE_NOTES.md` and
`store/RELEASE_NOTES.id.md` still describe 1.0 as the first release, and notes
that stale are worse for a real tester than none at all: paste them into the
Play Console instead, where they can be read before they go out.

`tool/test_play_publish.sh` checks what the publisher refuses — a missing or
malformed key, a bad track, `production`, a missing bundle — and that no
output holds the key. It needs no credentials and reaches no network. The
happy path can only be checked against Play itself.

If Play answers the commit with "Changes cannot be sent for review
automatically", the app has a change waiting that only the Console can send:
finish that release there once, then `--publish` again.

### From CI

The repository is public, so GitHub Actions costs nothing.

- `.github/workflows/ci.yml` runs `flutter analyze` and `flutter test` on
  every pull request and every push to `main`, as the job `check`.
- `.github/workflows/tag.yml` makes the tags on GitHub, so every new version
  name releases by itself. Once a push to `main` brings a name with no tag
  there, it tags `vX.Y.Z` the way the post-commit hook does on this machine:
  annotated `Jeansh X.Y.Z, build N`, on the first commit since the last
  tag to carry the name. "Since the last tag" matters: the old `1.0.N+N`
  names, 1.0.13 to 1.0.65, all came before `v1.0.6`.
  It uses `CLAUDE_GITHUB_TOKEN`, because a tag made with `GITHUB_TOKEN`
  starts no workflow and only an admin may make a `v*` tag.
- `.github/workflows/release.yml` runs on a `v*` tag.
  - `android` runs `tool/release.sh --publish`, which releases on Closed
    testing. Mobile goes straight to its store, and nowhere else. Run by
    hand from the Actions tab it is a `--dry-run` unless its box is
    unticked.
  - `desktop` builds Linux (`tools/build_desktop.sh`), Windows (the same
    zip, built on Windows itself) and macOS (`tools/build_apple.sh`, signed
    ad-hoc), and keeps each in the private R2 bucket `jeansh-builds`, under
    `desktop/<X.Y.Z+N>/<linux|windows|macos>/` with its `SHA256SUMS`. Nothing
    else keeps a build: no Actions artifact, no GitHub release, the bucket
    has no public URL or domain, and the public run log names neither the
    bucket nor an object.

The release reads these secrets from the `release` environment, which only
`v*` tags and `main` can deploy to, so a workflow on any other branch never
sees them:

| Secret | Holds |
| --- | --- |
| `ANDROID_UPLOAD_KEYSTORE_BASE64` | the upload keystore, from `base64 -w0 jeansh-upload.jks` |
| `ANDROID_UPLOAD_STORE_PASSWORD` | the keystore's password |
| `ANDROID_UPLOAD_KEY_ALIAS` | `upload` |
| `ANDROID_UPLOAD_KEY_PASSWORD` | the key's password |
| `PLAY_SERVICE_ACCOUNT_JSON` | the service account's JSON key, its contents rather than a path |
| `R2_ACCESS_KEY_ID` | an R2 API token's Access Key ID, **Object Read & Write** on `jeansh-builds` only |
| `R2_SECRET_ACCESS_KEY` | that token's Secret Access Key |
| `R2_ENDPOINT` | `https://<account id>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | `jeansh-builds` |
| `CLAUDE_GITHUB_TOKEN` | the owner's fine-grained token for this repository alone, **Contents: Read and write**, for `tag.yml` |

Only collaborators can contribute. Pull requests and issues can only be
opened by collaborators. On `main`, a ruleset refuses deletion and force
pushes and asks anyone but an admin for a pull request with one approval and
a green `check`. Another ruleset lets only an admin create, move or delete a
`v*` tag. A workflow from a fork waits for approval, `GITHUB_TOKEN` is read-only
by default, and secret scanning with push protection, Dependabot alerts and
private vulnerability reporting are on.

### The first upload, by hand

Play's API can't upload to an app that has never had a bundle, so the first
one goes through the Play Console:
1. create the app;
2. upload the bundle from `tool/release.sh` to Internal testing;
3. accept Play App Signing.

After that, `tool/release.sh --publish` does it.

`store/` holds the listing, the privacy policy and the release notes, in
English and Indonesian. `store/PLAY_CONSOLE.md` walks through the rest of the
Console: Data safety, the foreground service declaration, content rating and
testing.

## Not done yet

- **APNs / iOS push.** Only FCM on Android is wired.
- **Your own relay.** Its address is one constant, `notifyRelay` in
  `notifications/notify_key.dart`; a self-hosted
  [jeansh-notify](https://github.com/triasbrata/jeansh-notify) means changing
  it and building.
- **mosh.** The seam is in place, the transport is not. No mature mosh
  implementation exists in Dart, so this is real work, not a wiring job.
- **Downloading a file to the phone.** The browser reads and writes text in
  place; pulling a binary down to local storage is not wired.
- **A daemon on the host**, to replace SFTP where it is slow. `FileBrowser` is
  the seam; nothing has been written against it yet.
- **Biometric unlock**, key generation and import from file, and a font
  size per orientation (Settings has one for both).
- **More of a browser in a web tab:** downloads (handed to the phone's browser
  for now), `<input type=file>`, popups as tabs of their own, Back stepping
  back through a page's history, and HTTP auth prompts. Google refuses to sign
  in inside any embedded web view, so a Google login in a web tab — a
  Tailscale check that goes through Google included — needs **Open in
  browser**.
