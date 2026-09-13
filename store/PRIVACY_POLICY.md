# Privacy Policy for Jeansh

**Effective date:** September 14, 2026

**Last updated:** September 14, 2026

## Summary

Jeansh is an SSH client. It connects from your device straight to the servers
you add. Nothing you type, read, upload or edit in a session passes through a
server of ours.

Only one thing reaches us: your device's push-notification token. The app
trades it with our notification relay for a key that your servers use to
notify you. There are no accounts, ads, analytics or crash reports.

## What stays on your device

Jeansh keeps the following in its private app storage on your device:

- **Hosts:** for each saved host, its name, address, port, user name, sign-in
  method, jump host, file-tree folder, tmux and tailnet-forwarding switches,
  and the operating system the server reported at the last connection.
- **Secrets:** passwords, private keys and passphrases, encrypted with a key
  held in the Android Keystore. On iOS they're kept in the Keychain, on this
  device only.
- **Known hosts:** the fingerprints of the host keys you have trusted.
- **Logs:** a history of your sessions, with the host and when each session
  started and ended.
- **Port forwards:** the ports you set up on the Port forwarding screen.
- **Drafts:** unsaved edits to a server's files in the code editor, up to
  256 KB a file, kept until you save or discard them.
- **Settings:** theme, fonts, key bar, the magic key's position and the
  editor's look.
- **Notification key:** the relay key described below, with the token it was
  issued for, encrypted like the secrets above.
- **Web tabs:** pages you open in a web tab, such as a Tailscale sign-in,
  keep their cookies and cache in the app's web view storage.

The app turns off Google's cloud backup and device-to-device transfer, so
none of this leaves your device that way. Clearing the app's storage, or
uninstalling it, deletes all of it.

## What goes to your servers

Everything you do in a session goes to the server you're connected to, over
SSH, and is encrypted between your device and that server. That includes:

- what you type, and what the server prints;
- files you upload or open;
- commands the app runs for you there: reading the server's operating system,
  watching for servers you start when tailnet forwarding is on, and tmux.

Each shell also gets four environment variables:

- `LC_SSHBOX_TOKEN`: your notification key;
- `LC_SSHBOX_HOST_ID`: the id of the saved host;
- `LC_SSHBOX_NOTIFY_URL` and `LC_SSHBOX_NOTIFY_SECRET`: for notifications
  straight down that connection.

Those servers are yours, or ones you choose. We never receive what goes to
them.

## Notifications

A server you use can send a notification to your phone in two ways.

**Straight down the connection.** While a session is open, a server can
notify you through the SSH connection itself. The notification passes through
neither Google nor any server of ours.

**Through our relay**, which also works when no session is open:

- At launch, the app registers with **Firebase Cloud Messaging** (FCM),
  Google's push service, which gives the device a registration token. Google
  processes it under the [Google Privacy Policy](https://policies.google.com/privacy)
  and [Firebase's privacy terms](https://firebase.google.com/support/privacy).
- The app sends that token to **jeansh-notify**, our relay at
  `jeansh-notify.brata.cloud` (a Cloudflare Worker), and gets back a random
  notification key. It does this again only when FCM replaces the token.
- The relay stores one entry per key, in Cloudflare Workers KV: a SHA-256 hash
  of the key, pointing to the FCM token and the time it was created. It stores
  no key itself, and never logs keys, tokens or messages.
- When a server sends a notification with the key, the relay passes its title,
  text and host id to FCM, which delivers it to your device. The relay keeps
  nothing of the message.
- The relay counts registrations by IP address to limit abuse, and doesn't
  store the address. Cloudflare, which runs the relay, processes request data
  such as IP addresses under the
  [Cloudflare Privacy Policy](https://www.cloudflare.com/privacypolicy/).

**Deleting the relay's entry.** You have three routes:

- **Settings → Notifications → Reset notification key** deletes the relay's
  entry for your key and issues a new one.
- When FCM reports that a token is no longer valid, for example after you
  uninstall the app, the relay deletes its entry the next time a server tries
  to use it.
- To have your entry deleted without getting a new one, email us the key from
  **Settings → Notifications → Copy notification key**.

## What we don't collect

We don't collect:

- your name, email address or any account;
- your location or contacts;
- an advertising ID;
- analytics or crash reports.

The app includes neither Firebase Analytics nor Crashlytics. Apart from SSH to
your servers, FCM and the relay, the app connects only to web pages you open
in a web tab.

## Sharing

We don't sell or share your data. Google (for FCM) and Cloudflare (which hosts
the relay) process it only to deliver notifications.

## Android permissions

- **Internet** and **network state:** SSH connections, notifications and web
  tabs.
- **Notifications:** notifications from your servers, and the ongoing
  notification while a session is open.
- **Foreground service (data sync)** and **wake lock:** keep your open
  sessions and port forwards connected while the app is in the background.
- **Receive push messages** (`com.google.android.c2dm.permission.RECEIVE`):
  FCM delivery.
- **Run at startup** (`RECEIVE_BOOT_COMPLETED`): declared by the
  foreground-service library for a restart-at-boot option that Jeansh leaves
  off. Nothing starts when the phone boots.
- **Vibration:** declared by the notification library, for notifications.

## Children

Jeansh is a tool for people who look after servers. It isn't directed at
children.

## Security

SSH encrypts every session. The app asks before it trusts a new host key and
warns when a known one changes. Secrets are encrypted with the Android
Keystore. The relay holds only a hash of each key.

## Your rights and choices

- **On your device:** revoke the notification permission in Android's
  settings at any time. Clear the app's storage, or uninstall it, to remove
  everything the app keeps.
- **On the relay:** the relay entry is the only data of yours we hold. To get
  a copy or have it erased, including under the GDPR or the CCPA, email us
  with the key from **Settings → Notifications → Copy notification key**.

## Changes to this policy

When this policy changes, the "Last updated" date above changes with it.

## Contact

Email: triasbrata@gmail.com
