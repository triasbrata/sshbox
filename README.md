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
    files/
      file_browser.dart             protocol-agnostic filesystem interface
      sftp_file_browser.dart        the SFTP implementation of it
    ui/
      hosts_page.dart               host list
      host_edit_page.dart           add / edit a host
      terminal_page.dart            TerminalView wired to a session
      key_bar.dart                  the accessory keyboard row
      workbench.dart                the tablet split and its draggable seam
      file_browser_page.dart        native directory listing
      file_editor_page.dart         read and edit one remote file
      file_search_page.dart         find text under a directory
      files_page.dart               code-server in a WebView
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
on the host, reached through the same kind of port forward code-server uses,
could replace it — HTTP for the CRUD, and a WebSocket only where streaming
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
| `connect_and_keybar` | SSH connects and the accessory key bar renders | a reachable host with a stored credential |
| `file_browser` | the native browser opens and shows a listing rather than an error | a reachable host with a stored credential |
| `tablet_files` | the listing opens as a drawer rather than a screen | the same, on a device at least 840dp wide |

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
its job, since the key bar only renders on a live session.

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

## Sessions and resuming

`session/session_manager.dart` owns every open terminal, keyed by host id. The
`Terminal` object holds the scrollback, so it lives there rather than inside a
widget `State` — creating it in the page meant navigating back disposed it and
threw the session away.

`SessionManager.openOrCreate(host)` is the whole "take me back to my session,
or start a new one" rule, in one place. A tap in the host list and a tap on a
notification both route through `SshboxApp.openHost`, so they cannot drift
apart.

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

The paperclip in the terminal's app bar picks a local file, sends it to `/tmp`
on the host over SFTP, and types the resulting remote path at the prompt — so
the next thing you write is a command that uses it.

File transfer is an optional capability (`FileUploadCapable`), probed for
rather than assumed, because not every transport can do it — mosh cannot. The
upload is chunked against the file offset rather than read whole: dartssh2
offers no streaming write, and loading a video into memory is not something a
phone forgives. Filenames are scrubbed to `[A-Za-z0-9._-]`, since they arrive
from Android's picker and end up on a command line.

## Browsing files

The folder button in a terminal opens the remote filesystem as a native
listing: tap a folder to descend, tap a file to read or edit it, and save back
to the host. Rename, delete, new file and new folder are on each row's menu,
and "type path in terminal" drops a path at the prompt, shell-quoted, so the
next thing you write is a command that uses it.

The row menu also types a path at the prompt, and sends the shell to a folder
with `cd`. **Follow in terminal** in the overflow menu does that on every
navigation instead of on request — off by default, because it types into a live
shell and a shell is not always at a prompt: with an editor or a build running,
a `cd` lands as input to that instead.

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

### On a tablet

Past 840dp the same two pages are arranged rather than stacked. The terminal
keeps the whole width until there is something to put beside it; "Browse files"
opens the listing as a **drawer** over it, and choosing a file closes the
drawer and splits the screen — terminal on the left, editor on the right, with
a seam you can drag between a quarter and three quarters.

That ordering is the point. A permanent side panel would cost the terminal half
its width for the whole session, when most of a session has no file open at
all. The split appears when it earns its place and folds away when the editor
is closed.

Nothing forks into a tablet copy of the UI. `FileBrowserPage` and
`FileEditorPage` are the same widgets a phone shows; each takes a callback that
says who owns what happens next — hand the tapped file over rather than push a
screen, close the pane rather than pop a route. `Workbench` holds the geometry
and knows about neither of them, which is what lets the split be tested without
an SSH session.

840dp is Material's "expanded" breakpoint and it is the right line here: a
phone in landscape is 800dp, and splitting that would leave two columns too
narrow to read.

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

## Editing files with code-server

The session menu opens [code-server](https://github.com/coder/code-server) —
VS Code running on the host. It stays alongside the native browser rather than
being replaced by it: this is a full editor with a language server behind it,
which is a different thing from reading a config file on a phone.

code-server is a web application rather than a file API, so the way to use it
is to display it. `ui/files_page.dart` is a WebView; everything interesting is
in how it is reached:

```
WebView → http://127.0.0.1:<device port>
            └── SSH local forward, over the session already open
                  └── host 127.0.0.1:8080 ← code-server
```

code-server stays bound to loopback **on the host**. It is never published to
the LAN or the tailnet, so there is no port for anyone to scan for, and the
only route in is a session that has already authenticated. No second
connection, no second credential for the network hop.

Port forwarding is an optional capability (`PortForwardCapable`) for the same
reason file upload is — a future mosh transport could not offer it.

### Running code-server on the host

```sh
curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=~/.local
code-server ~/dev
```

Its config lives at `~/.config/code-server/config.yaml`. Keep
`bind-addr: 127.0.0.1:8080`, and keep `auth: password` — loopback is still
reachable by every other process and user on that machine, so the password is
what stops them; the SSH tunnel only protects the network hop. You log in once
in the WebView and the cookie persists.

**Gotcha worth knowing:** started from a terminal inside VS Code, code-server
sees `VSCODE_IPC_HOOK_CLI`, decides it is a CLI talking to a running VS Code,
and exits 0 with no output and no server. Unset the `VSCODE_*` variables when
launching it:

```sh
env -u VSCODE_IPC_HOOK_CLI code-server ~/dev
```

**On a phone** VS Code's web UI is cramped; on a tablet it is comfortable.
That is what the native browser above is for — on a small screen it is the
better of the two, and it needs nothing installed on the host.

## Not done yet

- **APNs / iOS push.** Only FCM on Android is wired.
- **A relay**, so servers hold a token rather than a service-account JSON.
- **mosh.** The seam is in place, the transport is not. No mature mosh
  implementation exists in Dart, so this is real work, not a wiring job.
- **A tab switcher.** Several sessions can be open at once and the host list
  marks them, but there is no UI for moving between them directly.
- **Downloading a file to the phone.** The browser reads and writes text in
  place; pulling a binary down to local storage is not wired.
- **A daemon on the host** behind a port forward, to replace SFTP where it is
  slow. `FileBrowser` is the seam; nothing has been written against it yet.
- **Biometric unlock**, port forwarding, key generation and import from file,
  and a landscape-aware font size control.
