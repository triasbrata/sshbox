# Notification architecture

How a server puts a notification on the tablet. There are two ways, and
`sshbox-notify` tries them in this order:

1. **Direct**: an HTTP request to a port on the server's loopback, which comes
   straight down the open SSH connection to the app. No FCM, no relay.
2. **Relay**: a request signed SNAP-style with the host's own key, sent to the
   jeansh-notify Cloudflare Worker, which pushes it through FCM. It works with
   no session open.

The diagrams follow the code at app commit `493ba25` and jeansh-notify
`a493c69`. Paths that start with `relay:` are in
[jeansh-notify](https://github.com/triasbrata/jeansh-notify); the rest are in
this repo.

## Components

```mermaid
flowchart LR
  subgraph Tablet
    App["Jeansh app"]
    Store[("Secret store<br/>sshbox.notify.keys")]
  end
  subgraph Server["SSH server"]
    SSHD["sshd or Tailscale SSH"]
    Shell["shell or tmux"]
    Notify["sshbox-notify<br/>(notify.sh)"]
  end
  subgraph Cloudflare
    Relay["jeansh-notify Worker<br/>jeansh-notify.brata.cloud"]
    KV[("Workers KV<br/>KEYS")]
  end
  subgraph Google
    OAuth["OAuth token endpoint"]
    FCM["FCM HTTP v1"]
  end

  App --- Store
  App <-->|"SSH connection: shell, LC_SSHBOX_* variables,<br/>remote forward on 127.0.0.1:0"| SSHD
  SSHD --> Shell --> Notify
  Notify -->|"1 direct: HTTP to 127.0.0.1:port,<br/>down the SSH connection"| SSHD
  Notify -->|"2 fallback: signed POST /v1/send"| Relay
  App -->|"POST /v1/register,<br/>signed DELETE /v1/key"| Relay
  Relay --- KV
  Relay -->|"service-account JWT"| OAuth
  Relay -->|"messages:send"| FCM
  FCM -->|"push"| App
```

| Where | Holds | Code |
|---|---|---|
| App, secret store `sshbox.notify.keys` | for each host id: the key id, the P-256 private key (PKCS#8 DER, base64) and the FCM token it is registered for | `NotifyKeys._save`, `lib/src/notifications/notify_key.dart` |
| App, memory only | FCM's current token; each connection's direct secret | `NotifyKeys._fcmToken`; `DirectNotify.secret`, `lib/src/notifications/direct_notify.dart` |
| Server, the shell's environment | `LC_SSHBOX_KEY` = `<keyId>:<base64 PKCS#8>`, `LC_SSHBOX_HOST_ID`, `LC_SSHBOX_NOTIFY_URL`, `LC_SSHBOX_NOTIFY_SECRET` | `LiveSession.connect`, `lib/src/session/session_manager.dart` |
| Server, during one relay send | the key as a PEM file, created under `umask 077` and deleted on exit | `relay: notify.sh` |
| Relay, Worker secret `FCM_SERVICE_ACCOUNT` | the Firebase service account JSON with its RSA key; the access token it buys, cached until 5 minutes before it expires | `accessToken`, `relay: src/index.ts` |
| Relay, Workers KV `KEYS` | `k:<keyId>` → `{publicKey, token, host, created}`; `n:<keyId>:<X-EXTERNAL-ID>` → `"1"` for 600 s | `register`, `verified`, `relay: src/index.ts` |
| Google | the device's FCM registration behind the token | — |

## 1. Per-host key registration

A host gets its key pair at its first connect once FCM has given the app a
token. Only the public half leaves the phone.

```mermaid
sequenceDiagram
  autonumber
  participant App as Jeansh app
  participant Store as Secret store
  participant Relay as jeansh-notify relay
  participant KV as Workers KV
  participant FCM as Google OAuth and FCM

  App->>Store: once per launch (_load): read sshbox.notify.keys,<br/>delete the old bearer key sshbox.notify.key
  Note over App: NotifyKeys.forConnect(hostId) at a connect,<br/>or useFcmToken for the hosts that have a key (diagram 7)
  App->>App: _sync(hostId): one registration per host at a time
  alt no FCM token yet, or the key is registered for this token
    App->>App: nothing to register
  else a key to register
    App->>App: the host's key, or RelayKey.generate(): a P-256 scalar from Random.secure()
    App->>App: keyId = jnk_ + first 32 chars of base64url SHA-256(SPKI DER)
    App->>Relay: POST /v1/register {token: FCM token, publicKey: base64 SPKI DER, host: hostId}
    Relay->>Relay: REGISTER_LIMIT, by cf-connecting-ip, 10 per 60 s
    break over the limit
      Relay-->>App: 429 too many requests
    end
    break token not 1 to 4096 chars, host not 1 to 100, or publicKey not SPKI P-256
      Relay-->>App: 400
    end
    Relay->>FCM: messages:send {validate_only: true, message: {token}}<br/>(access token as in diagram 4)
    break 404, INVALID_ARGUMENT, UNREGISTERED or SENDER_ID_MISMATCH
      Relay-->>App: 400 FCM does not accept this token
    end
    break any other failure
      Relay-->>App: 502 FCM returned HTTP status and code
    end
    Relay->>Relay: keyId = jnk_ + base64url SHA-256(SPKI DER), first 32
    Relay->>KV: put k:keyId = {publicKey, token, host, created}, no expiry
    Relay-->>App: 200 {keyId}
    App->>App: keyId must equal the app's own, else HttpException
    App->>Store: hostId → {keyId, privateKey: base64 PKCS8 DER, fcmToken}
  end
  Note over App: A failure is logged by its kind only and tried again at the<br/>next connect, token or launch, never in a loop of its own.
```

Code: `lib/src/notifications/notify_key.dart` (`NotifyKeys.forConnect`,
`_sync`, `_register`, `_save`, `_load`; `RelayKey.generate`, `spki`, `id`;
`RelayClient.register`), `relay: src/index.ts` (`register`, `fcm`),
`relay: wrangler.jsonc` (`REGISTER_LIMIT`).

## 2. Connect

Registration runs alongside SSH sign-in. The shell waits for it 3 s at most.
The direct port is asked for on every connection, before any shell or tmux.

```mermaid
sequenceDiagram
  autonumber
  participant App as Jeansh app
  participant Relay as jeansh-notify relay
  participant SSHD as sshd or Tailscale SSH
  participant Shell as shell or tmux

  Note over App: LiveSession.connect
  par registration, started first and not awaited yet
    App->>Relay: NotifyKeys.forConnect(host.id): diagram 1, if the host has no key<br/>or FCM has replaced the token
  and SSH sign-in (Dartssh2Transport.connect)
    App->>SSHD: TCP, through jump hosts if any, host key check, then auth:<br/>key, password, or none for Tailscale SSH
    SSHD-->>App: authenticated
  end
  Note over App: beforeShell(this): after auth, before any channel
  App->>App: wait for the key 3 s more at most. On timeout this connect goes<br/>without it, and registration carries on for the next one
  App->>SSHD: tcpip-forward 127.0.0.1 port 0 (listen, dartssh2 forwardRemote), 10 s timeout
  alt the host listens
    SSHD-->>App: the port P it picked
    App->>App: a new DirectNotify for this connection:<br/>secret = 32 random bytes, base64url
  else refused (AllowTcpForwarding no) or no answer in 10 s
    SSHD-->>App: failure
    App->>App: no direct variables, and nothing is said
  end
  Note over App: The variables: LC_SSHBOX_KEY = keyId:base64 PKCS8 DER and<br/>LC_SSHBOX_HOST_ID = host.id when there is a key,<br/>LC_SSHBOX_NOTIFY_URL = http://127.0.0.1:P/v1/send and<br/>LC_SSHBOX_NOTIFY_SECRET when there is a port
  alt plain shell
    App->>SSHD: session channel: env requests, pty-req, shell
  else tmux (LiveSession._attachTmux, Dartssh2Transport.open)
    App->>SSHD: session channel: env requests, exec TmuxSession.command
  end
  opt the host refuses a variable (sshd AcceptEnv, Tailscale SSH acceptEnv)
    SSHD-->>App: the channel request fails (SSHChannelRequestError)
    App->>SSHD: _withEnvironment: the same channel again with no variables at all,<br/>and no later channel on this connection sends them
  end
  SSHD->>Shell: start it, with the variables it accepted
  opt tmux
    Shell->>Shell: find tmux by full path. If update-environment lacks LC_SSHBOX_KEY:<br/>set -ga update-environment LC_SSHBOX_KEY LC_SSHBOX_HOST_ID<br/>LC_SSHBOX_NOTIFY_URL LC_SSHBOX_NOTIFY_SECRET
    Shell->>Shell: tmux -u -C new-session -A -s name. tmux copies the four into<br/>the session when it makes it and at every attach
  end
```

A refused variable drops all four, the direct pair too. Such a server can
still be given `LC_SSHBOX_KEY` by hand, from **Copy notification key** on the
host's edit page (`lib/src/ui/host_edit_page.dart`, `_copyNotifyKey`). When
tmux turns out to be missing, the connection is closed and a plain-shell
connect runs this diagram again.

Code: `lib/src/session/session_manager.dart` (`LiveSession.connect`,
`_openNotifyPort`, `_attachTmux`), `lib/src/session/dartssh2_transport.dart`
(`connect`, `listen`, `open`, `_withEnvironment`), `lib/src/session/tmux.dart`
(`TmuxSession.command`).

## 3. Sending the direct way

```mermaid
sequenceDiagram
  autonumber
  participant N as sshbox-notify (notify.sh)
  participant SSHD as sshd or Tailscale SSH
  participant App as Jeansh app
  participant OS as Android

  Note over N: only when LC_SSHBOX_NOTIFY_URL and LC_SSHBOX_NOTIFY_SECRET are both set
  N->>SSHD: curl -fsS POST http://127.0.0.1:P/v1/send, connect 2 s, total 5 s<br/>Authorization: Bearer secret, read from stdin (-H @-), never in ps<br/>form: body=message, title=title
  SSHD->>App: forwarded-tcpip channel on the same SSH connection
  App->>App: DirectNotify.serve(tunnel): the whole request within 5 s, 16 KB at most
  Note over App: DirectNotify._evaluate, in this order:<br/>16 KB and no end of headers: 413. Bad request line: 400.<br/>Path not /v1/send: 404. Not POST: 405.<br/>Bearer not this connection's secret, compared in constant time: 401.<br/>No Content-Length: 400. Over 16 KB: 413.<br/>Neither a form nor JSON: 400. Empty body: 400.<br/>Body cut to 1000 chars, title to 100, title Jeansh when empty.
  alt accepted
    App-->>N: HTTP/1.1 200 {ok: true}, Connection: close
    App->>OS: NotificationGateway.showForHost(host.id, title, body),<br/>payload sshbox://host/hostId, one notification id per host
    N->>N: sent directly to Jeansh, exit 0
  else refused, or no whole request within 5 s
    App-->>N: 4xx {ok: false, error}, or a hang-up with no answer
    N->>N: curl fails, so try the relay (diagram 4)
  end
```

Code: `relay: notify.sh`, `lib/src/notifications/direct_notify.dart`
(`serve`, `_evaluate`), `lib/src/session/session_manager.dart`
(`_openNotifyPort`), `lib/src/notifications/notification_gateway.dart`
(`showForHost`).

## 4. Sending through the relay

The fallback. The request is signed the way Indonesia's SNAP payment API signs
one, and the relay checks it in exactly this order.

```mermaid
sequenceDiagram
  autonumber
  participant N as sshbox-notify (notify.sh)
  participant Relay as jeansh-notify relay
  participant KV as Workers KV
  participant OAuth as Google OAuth
  participant FCM as FCM HTTP v1
  participant App as Jeansh app

  Note over N: No direct variables, or the direct way failed.<br/>No LC_SSHBOX_KEY or no openssl: exit 1 with a hint.
  N->>N: data = JSON {body, title}, escaped with awk, title only when given
  N->>N: umask 077, mktemp: PEM of LC_SSHBOX_KEY after the colon,<br/>folded at 64, removed on exit by a trap
  N->>N: stamp = date -u +%Y-%m-%dT%H:%M:%S+00:00<br/>id = openssl rand -hex 16<br/>hash = hex SHA-256 of data
  N->>N: sig = base64 of openssl dgst -sha256 -sign PEM<br/>over POST:/v1/send:hash:stamp:id
  N->>Relay: POST /v1/send, body data, headers read from stdin:<br/>X-PARTNER-ID = LC_SSHBOX_KEY before the colon, X-TIMESTAMP = stamp,<br/>X-EXTERNAL-ID = id, X-SIGNATURE = sig, Content-Type: application/json
  Note over Relay: verified()
  Relay->>KV: get k:keyId, only if X-PARTNER-ID is jnk_ and 32 base64url chars
  break no such key
    Relay-->>N: 401 unknown key
  end
  break X-TIMESTAMP not yyyy-MM-ddTHH:mm:ss and a zone, or more than 300 s from now
    Relay-->>N: 401 stale or bad timestamp
  end
  break X-EXTERNAL-ID not 16 to 64 of A-Z a-z 0-9 and -
    Relay-->>N: 400
  end
  Relay->>Relay: verify X-SIGNATURE (DER turned into r and s) with the stored<br/>SPKI key, over METHOD:PATH:hex SHA-256 of body:X-TIMESTAMP:X-EXTERNAL-ID
  break signature does not verify
    Relay-->>N: 401 bad signature
  end
  Relay->>KV: get n:keyId:externalId
  break seen within the last 600 s
    Relay-->>N: 409 duplicate X-EXTERNAL-ID
  end
  Relay->>Relay: SEND_LIMIT, by key id, 30 per 60 s
  break over the limit
    Relay-->>N: 429 too many requests
  end
  Relay->>KV: put n:keyId:externalId = 1, expirationTtl 600
  Note over Relay: send()
  break readMessage: not a JSON object, not strings, empty body,<br/>body over 1000 or title over 100 chars
    Relay-->>N: 400
  end
  opt no cached access token, or it expires within 5 minutes
    Relay->>OAuth: POST oauth2.googleapis.com/token, grant type jwt-bearer,<br/>an RS256 JWT signed with the FCM_SERVICE_ACCOUNT key<br/>(iss client_email, scope firebase.messaging, aud, iat, exp 1 h)
    OAuth-->>Relay: access_token, expires_in
  end
  Relay->>FCM: POST /v1/projects/project_id/messages:send, Bearer access token<br/>{token, data: {hostId: the key's host, title, body},<br/>notification: {title, body}, android: {priority: high}}
  alt 200
    FCM-->>Relay: 200
    Relay-->>N: 200 {ok: true}
    N->>N: sent through the relay, exit 0
    FCM-)App: the push
    alt app in the foreground
      App->>App: onMessage, _showFrom: showForHost(data.hostId, data.title, data.body)
    else app in the background or not running
      App->>App: the FCM SDK shows the notification block itself,<br/>with default_notification_icon from the manifest
    end
  else 404 or UNREGISTERED: the phone's token is dead
    FCM-->>Relay: 404 or UNREGISTERED
    Relay->>KV: delete k:keyId
    Relay-->>N: 410 the phone is no longer registered, this key is deleted
  else any other error (a 401 also drops the cached access token)
    FCM-->>Relay: error
    Relay-->>N: 502 FCM returned HTTP status and code, or FCM is unavailable
  end
  Note over N: Anything but 200: print the relay's answer, exit 1
```

Code: `relay: notify.sh`, `relay: src/index.ts` (`send`, `verified`,
`verify`, `derToRaw`, `readMessage`, `fcm`, `accessToken`, `signJwt`),
`relay: wrangler.jsonc` (`SEND_LIMIT`), `lib/src/notifications/push_messaging.dart`
(`_showFrom`).

## 5. Tap to open

The host a tap opens is fixed before any message exists. A send's body gives
only a title and a body.

```mermaid
sequenceDiagram
  autonumber
  actor User
  participant OS as Android
  participant App as Jeansh app
  participant Sessions as SessionManager

  Note over OS,App: Direct: host.id of the connection the port belongs to (_openNotifyPort).<br/>Relay: the host stored with the key at registration (entry.host).
  User->>OS: tap the notification
  alt one the app posted (direct, or FCM in the foreground)
    OS->>App: payload sshbox://host/hostId: onDidReceiveNotificationResponse,<br/>or getNotificationAppLaunchDetails on a cold start (NotificationGateway)
  else Android's own, from the FCM notification block
    OS->>App: RemoteMessage with data.hostId: onMessageOpenedApp,<br/>or getInitialMessage on a cold start (PushMessaging._routeFrom)
    App->>App: sshbox://host/hostId
  end
  App->>App: _handleLink, then openHost(hostId)
  App->>App: HostRepository.load(). No such host, a deleted one say: stop
  App->>Sessions: resume(hostId)
  alt a tab on this host is open
    Sessions-->>App: that session, now the tab shown
  else none
    App->>App: openInSheet: the connect sheet, and a new session (diagram 2)
  end
```

Code: `lib/src/notifications/notification_gateway.dart`,
`lib/src/notifications/push_messaging.dart` (`_routeFrom`), `lib/src/app.dart`
(`_handleLink`, `openHost`), `lib/src/session/session_manager.dart`
(`SessionManager.resume`), `relay: src/index.ts` (`send` takes `host` from the
key's entry).

## 6. Revoke

```mermaid
sequenceDiagram
  autonumber
  actor User
  participant App as Jeansh app
  participant Store as Secret store
  participant Relay as jeansh-notify relay
  participant KV as Workers KV

  alt delete a host (HostsPage._confirmDelete)
    User->>App: Delete, confirmed
    App->>App: closeHost(hostId), then NotifyKeys.revoke(hostId), not awaited
    App->>App: wait for any registration under way for this host
    App->>Store: drop the key and save, before the relay is asked
    App->>Relay: signed DELETE /v1/key, best effort, errors ignored
  else Settings, Reset notification keys (_NotificationsSection._reset)
    User->>App: Reset, confirmed
    App->>App: NotifyKeys.reset(): wait for every registration under way
    loop each key, one at a time
      App->>Relay: signed DELETE /v1/key
      App->>App: drop the key once revoked
    end
    App->>Store: save what is left, after a failure too
    Note over App: A failure stops the loop, and a toast says some old keys still work
  end
  Note over App,Relay: RelayClient.revoke: no body, the four headers from _signed,<br/>over DELETE:/v1/key:hex SHA-256 of nothing:X-TIMESTAMP:X-EXTERNAL-ID
  Relay->>KV: verified(): the checks of a send, in the same order (diagram 4),<br/>so it also writes n:keyId:externalId and counts against SEND_LIMIT
  alt every check passes
    Relay->>KV: delete k:keyId
    Relay-->>App: 204
  else the key is already gone
    Relay-->>App: 401 unknown key. RelayClient.revoke counts 401 and 404 as done
  else anything else from 300 up
    Relay-->>App: HttpException: ignored after a delete, thrown by reset
  end
  Note over Relay: A server still holding the old LC_SSHBOX_KEY now gets 401 unknown key
```

After a reset each host gets a new key pair at its next connect (diagram 1).

Code: `lib/src/ui/hosts_page.dart` (`_confirmDelete`),
`lib/src/ui/settings_page.dart` (`_NotificationsSection._reset`),
`lib/src/notifications/notify_key.dart` (`NotifyKeys.revoke`, `reset`;
`RelayClient.revoke`, `_signed`), `relay: src/index.ts` (`revoke`,
`verified`).

## 7. FCM token refresh

```mermaid
sequenceDiagram
  autonumber
  participant FCM as FCM SDK on the tablet
  participant App as Jeansh app
  participant Store as Secret store
  participant Relay as jeansh-notify relay
  participant KV as Workers KV

  Note over FCM,App: PushMessaging.initialize: getToken() at launch, then every onTokenRefresh
  FCM->>App: token T2, replacing T1
  App->>App: NotifyKeys.useFcmToken(T2): _fcmToken = T2
  loop every host with a key, all at once (Future.wait)
    App->>App: _sync(hostId): registered for T1, not T2
    App->>Relay: POST /v1/register {token: T2, publicKey: the same SPKI, host: hostId}
    Relay->>KV: put k:keyId, the same keyId, now with token T2
    Relay-->>App: 200 {keyId}, the same id
    App->>Store: save the key with fcmToken T2
  end
  Note over App,Relay: _register goes round again if the token changed meanwhile.<br/>Servers keep their LC_SSHBOX_KEY and carry on, with no reconnect.<br/>A failure keeps the T1 registration, tried again at the next connect, token or launch.
```

Code: `lib/src/notifications/push_messaging.dart` (`initialize`),
`lib/src/notifications/notify_key.dart` (`NotifyKeys.useFcmToken`, `_register`).

## Security properties

- **A leaked relay KV** gives public keys, FCM tokens, host ids and recent
  external ids. It holds no private key and no Firebase credential (that is a
  Worker secret), so nothing in it can sign a send or push to a phone.
- **A compromised server** holds its own host's private key, and the direct
  secret of each of its connections while that connection lasts. It can
  notify this phone as its own host and no other: the relay takes the host
  from the key, and the direct handler from the connection. Through the relay
  it can send at most 30 a minute. It never sees the phone's FCM token, and
  nothing listens on the phone.
- **Replay protection** covers a signed request sent again. Within the 300 s
  window the `n:` record, kept for 600 s, answers 409; after the window the
  timestamp answers 401. The signature binds method, path, body hash, time
  and external id, so a captured send can't come back as a `DELETE` or with
  another body. `POST /v1/register` is not signed. The direct way has no
  replay check: its secret stays on one server, for one connection.
- **Known limits**, from the relay's `ponytail:` notes:
  - KV is eventually consistent, so a replay that lands on another Cloudflare
    location within about a minute may pass. A Durable Object would make the
    check strict.
  - Whoever holds a public key can register it again with another FCM token
    from the same Firebase project (any install of Jeansh has one), and with
    another host id, which sends that key's pushes to them. The relay counts
    on the public key never leaving the phone and the relay. A leaked KV
    breaks that, and so does a server, which can work out the public key from
    its private one, though a server can redirect only its own host's pushes.
    The phone registers again only when its FCM token changes, or after a
    reset.
- **Also in the code:**
  - Deleting a host drops its key before revoking it. With the relay out of
    reach, the key stays live and the phone has nothing left to revoke it
    with; it goes when FCM rejects the token (410).
  - `RelayClient.revoke` counts every 401 as done, including "stale or bad
    timestamp" from a phone clock more than 5 minutes off.
- **The KV write quota:** Cloudflare's free plan allows 1,000 KV writes a day,
  and 1,000 deletes. Each accepted send or revoke writes an `n:` record, and
  each registration a `k:` record, so the relay handles about 1,000 of those a
  day for all users together. Past that, `put` throws and the request fails.
  One key sending at its 30-a-minute limit uses up the day in about half an
  hour.

## Where each piece lives

- `lib/src/notifications/notify_key.dart`: the relay address; `RelayKey` (the
  P-256 pair, SPKI and PKCS#8, key id, signing); `_signed` (the SNAP headers);
  `RelayClient` (register, revoke); `NotifyKeys` (keys per host, stored,
  registered, revoked, reset).
- `lib/src/notifications/direct_notify.dart`: `DirectNotify`, the HTTP handler
  and secret for one connection.
- `lib/src/notifications/push_messaging.dart`: FCM tokens to `NotifyKeys`, a
  push shown in the foreground, a tap routed.
- `lib/src/notifications/notification_gateway.dart`: local notifications with
  the `sshbox://host/<hostId>` payload, and their taps.
- `lib/src/session/session_manager.dart`: `LiveSession.connect` builds the
  variables and `_openNotifyPort` asks for the port; `SessionManager.resume`.
- `lib/src/session/dartssh2_transport.dart`: `beforeShell` after auth, `listen`
  (the remote forward), `_withEnvironment` (the retry without variables).
- `lib/src/session/tmux.dart`: `TmuxSession.command` and `update-environment`.
- `lib/src/ui/hosts_page.dart`: deleting a host revokes its key.
- `lib/src/ui/host_edit_page.dart`: Copy notification key.
- `lib/src/ui/settings_page.dart`: Reset notification keys.
- `lib/src/app.dart`: the wiring, `_handleLink` and `openHost`.
- `relay: src/index.ts`: the Worker: `register`, `send`, `revoke`, `verified`,
  `fcm`, `accessToken`, `signJwt`.
- `relay: wrangler.jsonc`: the route, the KV binding and both rate limits.
- `relay: notify.sh`: `sshbox-notify`, direct first, then the relay.
