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
      dartssh2_transport.dart       the only file that imports dartssh2
    ui/
      hosts_page.dart               host list
      host_edit_page.dart           add / edit a host
      terminal_page.dart            TerminalView wired to a session
      key_bar.dart                  the accessory keyboard row
```

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

Two things worth knowing before editing these:

**Selectors need regex.** Flutter merges a `ListTile`'s title and subtitle into
a single accessibility node, so the host row reads as
`"WSL via tailnet\ntriasbrata@… · password"`. Maestro regex-matches the whole
string, so selectors use `"(?s)WSL via tailnet.*"` — plain text will not match.
This is correct screen-reader behaviour, so the selector adapts rather than the
app.

**Device choice matters.** Maestro installs a driver APK, and MIUI/HyperOS
refuses new-package installs over adb, so flows cannot run on a Xiaomi device
without lifting that restriction. `connect_and_keybar` additionally fails on
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

## Browsing files (code-server)

The folder button in a terminal opens
[code-server](https://github.com/coder/code-server) — VS Code running on the
host — giving a file tree, search and an editor without building any of it.

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

**On a phone** VS Code's web UI is cramped; on a tablet it is comfortable. A
native file browser over SFTP would suit small screens better, but it is a
different piece of work and not a "VS Code feel".

## Not done yet

- **APNs / iOS push.** Only FCM on Android is wired.
- **A relay**, so servers hold a token rather than a service-account JSON.
- **mosh.** The seam is in place, the transport is not. No mature mosh
  implementation exists in Dart, so this is real work, not a wiring job.
- **A tab switcher.** Several sessions can be open at once and the host list
  marks them, but there is no UI for moving between them directly.
- **SFTP.** `dartssh2` already implements SFTPv3; only UI is missing.
- **Biometric unlock**, port forwarding, key generation and import from file,
  and a landscape-aware font size control.
