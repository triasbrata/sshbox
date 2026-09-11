# sshbox

A mobile-first SSH client built with Flutter, targeting Android and iOS.

The name is a placeholder — rename freely, it appears in `pubspec.yaml`,
`android/app/src/main/AndroidManifest.xml` and `lib/src/app.dart`.

## Why this stack

| Layer | Choice | Reason |
| --- | --- | --- |
| Terminal emulator | [`xterm2`](https://pub.dev/packages/xterm2) 5.2.0 | Maintained fork of `xterm.dart`; the original has gone quiet |
| SSH | [`dartssh2`](https://pub.dev/packages/dartssh2) 4.1.0 | Pure Dart, so Android and iOS run identical code with no JNI or cinterop |
| Secrets | `flutter_secure_storage` 11 | Android Keystore and iOS Keychain |
| Host list | `shared_preferences` | Non-secret metadata only |

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
    files/
      file_browser.dart             protocol-agnostic filesystem interface
      sftp_file_browser.dart        the SFTP implementation of it
    ui/
      tabs_shell.dart               pinned host list + a tab per session/file
      hosts_page.dart               host list
      host_edit_page.dart           add / edit a host
      terminal_page.dart            TerminalView wired to a session
      key_bar.dart                  the accessory keyboard row
      ctrl_click.dart               the URLs and paths a Ctrl+tap opens
      file_browser_page.dart        a VS Code-style file tree, as a drawer
      file_editor_page.dart         read and edit one remote file, in a tab
      file_search_page.dart         find text under a directory
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
still holding, drag to widen it word by word. Once you lift, a drag moves
whichever end of the selection is nearer, instead of scrolling, and a small bar
over it offers Copy and ✕. Copy, ✕, a tap on the terminal or any key sent to
the shell ends it. A mouse selects with a drag as before.

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

### Ctrl+tap

VS Code's Ctrl+click, for a touch screen. With CTRL armed on the bar — or Ctrl
held on a hardware keyboard, which covers a mouse click with Ctrl — every URL
and path on screen gets a thin underline, and a tap on one opens it instead of
raising the keyboard: a URL in the browser, a folder as the root of the files
drawer, a file in a tab of its own, the way one picked in the drawer opens. The
tap types nothing, a program reading the mouse does not see it, and it uses
CTRL up whether it hit anything or not. A path that is not there says
**Not found:** and the path.

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
home, and the snack bar says so when that misses. Inside tmux or screen, what
it finds is the multiplexer's client rather than the pane.

## Running it

```sh
flutter pub get
flutter run
```

Tests:

```sh
flutter test
```

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
link out of that text and the terminal shows it with a button; finishing in the
browser is what releases the session, so there is nothing to submit in the app.
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
on `localhost:3000`, and a moment later the app says **Port 3000 is on
`<host>.<tailnet>.ts.net:3001`**, with a button that opens it. The server
stopping, or the tab closing, takes it off again.

```
vite ── localhost:3000 ◀── tailscale serve --tcp 3001 ◀── <host>.ts.net:3001
                           (run on the host, over the session's SSH)
```

A phone cannot make a port appear under the server's MagicDNS name, so the
work happens on the host, over the connection the shell already holds:

- **Watching.** A loop on its own exec channel reads `/proc/net/tcp` every two
  seconds and sends back only the listening sockets. A port counts when it is
  the user's own, on loopback or every address, below the ephemeral range
  (32768), and was not already listening when the session connected — a
  session forwards what it started, not everything the box runs.
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

**What the host needs:** Linux, Tailscale, and permission to change the serve
config without root — `sudo tailscale set --operator=$USER`, once. Without it
the forward is refused and the app shows tailscale's own error. A refused
forward is not retried until its server restarts. Each forward holds a
channel, and OpenSSH allows ten per connection by default (`MaxSessions`), so
about seven fit beside the shell, the watch and the file browser.

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
which means typed commands going to the wrong host.

**Files get tabs too.** The folder button opens the files drawer over the
shell; tapping a file there gives it a tab of its own, named
`<host> · <file>` — the host as the host list names it, so
`WSL via tailnet · main.dart` — next to the session it was read over. Picking
the same file again returns to its tab rather than opening a second one, and
closing a session takes its file tabs with it — they are read over that
session and cannot outlive it.

**A tab whose shell has ended** — closed by the host, dropped, or never
reached — trades its close button for a reconnect one, a cable. The terminal
page has no header left to hold it. Closing such a tab instead is **Close
session** in the host's menu on the host list. A tab that has not been asked
to connect yet, for the one frame before its page does, keeps its close button
rather than flashing the other.

**Long-press a shell's tab** for **Duplicate session**: another shell on the
same host, opened the way a tap in the host list opens one — at the end of the
strip, and shown. It starts where any new shell on the host starts, not in
the folder the first one had reached. A file tab has no menu.

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

**One window, not two.** Dragging out a second sshbox window gives it a second
Flutter engine, and therefore its own `SessionManager` — the two windows would
not share sessions. Sharing them means moving sessions out of the isolate, so
sshbox is meant to be one window beside another app, not beside itself.

## Notifications

A notification carries a `sshbox://host/<hostId>` payload, so tapping one goes
through the same router as a deep link — there is no second code path to keep
in sync.

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

Get the device's registration token from the key icon in the host list, or
from logcat at startup.

**Testing without a server:** `sshbox://notify/<hostId>` posts a notification
locally, so the whole notify → tap → resume path can be exercised with adb:

```sh
adb shell "am start -a android.intent.action.VIEW \
  -d 'sshbox://notify/<hostId>?title=Build%20done&body=Tap%20to%20return'"
```

Firebase config lives in `android/app/google-services.json` and the
`applicationId` must match the `package_name` inside it.

### Sending one from a server

`tools/sshbox-notify` is a Go binary to drop on any server you SSH into:

```sh
cd tools/sshbox-notify && go build -o sshbox-notify .
scp sshbox-notify server:/usr/local/bin/

# then, at the end of something slow:
sshbox-notify "build selesai"
sshbox-notify -title Deploy -host <hostId> "selesai dalam 4m"
```

It is a compiled binary rather than a curl one-liner because FCM HTTP v1
requires OAuth2 with a service account, and signing an RS256 JWT in shell is
not worth the evening. Static, no runtime dependencies, and it cross-compiles
for linux/amd64, linux/arm64 and darwin/arm64.

Config lives at `~/.config/sshbox-notify/config.json`:

```json
{
  "service_account": "/etc/sshbox/service-account.json",
  "tokens": ["<FCM token from the key icon in sshbox>"],
  "host_id": "<the sshbox host entry for this server>"
}
```

The service account comes from the Firebase console under
**Project Settings → Service Accounts → Generate new private key**. It is a
credential that can send messages to every device in the project — keep it
readable only by the user running the command, and do not commit it.

Running with no config prints the exact commands to create one.

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

Any app's share sheet lists sshbox. The file lands in `/tmp` on the session you
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
which is the way back out. Back undoes the last re-rooting. The root and the
open folders survive the drawer closing, so picking a file and coming back
does not fold everything shut.

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
open it or to shut it, and every new root. Never twice in a row to the same
folder, so opening and shutting one types a single `cd`; tapping a file only
opens it, and opening the drawer or refreshing moves nothing. Off by default,
because it types into a live shell and a shell is not always at a prompt: with
an editor or a build running, a `cd` lands as input to that instead.

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

## Not done yet

- **APNs / iOS push.** Only FCM on Android is wired.
- **A relay**, so servers hold a token rather than a service-account JSON.
- **mosh.** The seam is in place, the transport is not. No mature mosh
  implementation exists in Dart, so this is real work, not a wiring job.
- **Downloading a file to the phone.** The browser reads and writes text in
  place; pulling a binary down to local storage is not wired.
- **A daemon on the host**, to replace SFTP where it is slow. `FileBrowser` is
  the seam; nothing has been written against it yet.
- **Biometric unlock**, key generation and import from file, and a
  landscape-aware font size control.
