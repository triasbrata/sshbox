# jeansh-telemetry

The Cloudflare Worker behind two things in Jeansh: the daily count of installs,
and the bug reports somebody chose to send without their name on them.

Nobody has deployed it yet. Everything below is yours to run once.

## Why a Worker of its own, and not `jeansh-notify`

`jeansh-notify` holds the Firebase service account and checks a P-256
signature on every request. Putting a GitHub token beside it would mean one
Worker whose compromise hands over both the push channel and write access to
the issue tracker — and it would give a notification relay a second job with a
completely different threat model: notify is authenticated by a key the app
registered, and this is a public, unauthenticated write surface. They are
separate because they should fail separately.

The cost is one more thing to deploy, which is this page.

## Why D1 and not Analytics Engine

Analytics Engine is the cheaper answer at scale and is built for exactly this
shape of write. Two things made D1 the right one here:

- The anonymous bug relay needs a counter it can **read back** to rate limit.
  Analytics Engine is write-then-query-over-HTTP, sampled, and not something a
  request can consult. D1 gives the count and the quota in one place instead of
  two services.
- The counts wanted are exact and tiny: one row per install per day, which for
  an app with hundreds or thousands of users is far inside D1's free tier
  (100k writes a day; the app already asks only once a day, so writes ≈ daily
  actives). `SELECT count(*) FROM pings WHERE day = ?` is the whole of the
  analysis, with no sampling to reason about.

If Jeansh ever gets big enough that D1 writes cost money, moving `pings` to
Analytics Engine is a ten-line change and the quota table stays in D1.

## What you have to do, once

1. **Make the database and paste its id.**

   ```sh
   cd worker/jeansh-telemetry
   wrangler d1 create jeansh-telemetry     # prints a database_id
   ```

   Put that id in `wrangler.toml` where the placeholder is, then create the
   tables:

   ```sh
   wrangler d1 execute jeansh-telemetry --remote --file schema.sql
   ```

2. **Make a GitHub token for the bot and give it to the Worker.**

   A fine-grained personal access token, on `triasbrata/sshbox` alone, with
   **Issues: Read and write** and nothing else. Anonymous issues will be opened
   as whichever account makes the token, so a bot account is nicer than yours —
   but your own works.

   ```sh
   wrangler secret put GITHUB_TOKEN
   ```

   The token lives only here. It is never in the app, never in this
   repository, and never in a log: the app is source-available, so anything
   baked into it is readable with `strings`.

3. **Deploy, and point the app's hostname at it.**

   ```sh
   wrangler deploy
   ```

   The app calls `https://jeansh-telemetry.brata.cloud`
   (`telemetryHost` in `lib/src/telemetry/telemetry.dart`). Add that custom
   domain to this Worker in the Cloudflare dashboard, the way
   `jeansh-notify.brata.cloud` is set up. If you would rather use a different
   name, change `telemetryHost` and say so — it is a constant, not a secret.

4. **Make a Sentry project and bake its DSN into the builds.**

   Crash reporting is separate from this Worker. Jeansh reads its DSN from
   `--dart-define JEANSH_SENTRY_DSN`, and a build without one does not report
   and says so in Settings. `tools/build_desktop.sh`, `tools/build_apple.sh`
   and `tool/release.sh` all pass it on from the environment, so:

   ```sh
   export JEANSH_SENTRY_DSN='https://…@…ingest.sentry.io/…'
   ```

   For CI, the release workflow has to hand the same variable to
   `tool/release.sh` and to `tools/build_desktop.sh`. That is a change to
   `.github/workflows/release.yml`, which another session owns — it is not
   done here.

## What it does

`POST /ping`

```json
{ "install": "<uuid v4>", "version": "1.0.62", "build": "66",
  "platform": "android", "os": "6.6.0 #1 SMP" }
```

Answers 204. Anything else in the body is ignored rather than stored. One row
per install per day; a second ping the same day is an ignored write.

`POST /issue`

```json
{ "install": "<uuid v4>", "title": "…", "body": "…" }
```

Answers `{"url": "https://github.com/…/issues/N"}`, or 429 when the allowance
is spent, 403 when the relay is switched off, 400 for a body that is not the
above.

## Reading the counts

```sh
# People who ran Jeansh today, and yesterday
wrangler d1 execute jeansh-telemetry --remote \
  --command "SELECT day, count(*) AS installs FROM pings
             GROUP BY day ORDER BY day DESC LIMIT 14"

# By platform and version, this week
wrangler d1 execute jeansh-telemetry --remote \
  --command "SELECT platform, version, count(DISTINCT install) AS installs
             FROM pings WHERE day >= date('now', '-7 day')
             GROUP BY platform, version ORDER BY installs DESC"
```

Old rows are nobody's friend. Once a month, or whenever you think of it:

```sh
wrangler d1 execute jeansh-telemetry --remote \
  --command "DELETE FROM pings WHERE day < date('now', '-400 day');
             DELETE FROM quota WHERE day < date('now', '-7 day')"
```

## Turning the anonymous relay off

One command, no deploy, effective at the next request:

```sh
wrangler d1 execute jeansh-telemetry --remote \
  --command "INSERT INTO flags (name, on_) VALUES ('issues_off', 1)
             ON CONFLICT (name) DO UPDATE SET on_ = 1"
```

`on_ = 0` turns it back on. The app then says so and points at the named
route, which needs nothing of ours.

## What the anonymous route does not protect against

Say this plainly, because it is a public write surface onto a public issue
tracker:

- **Install ids are made by the client.** Anybody who reads the app's source —
  which is everybody, it is source-available — can send a fresh UUID with every
  request and the per-install limit is gone. The per-IP limit is the one that
  actually binds.
- **The per-IP limit is defeated by many IPs and over-applied to few.** A
  botnet, a VPN pool or Tor walks round it; a university, an office or a
  mobile carrier's NAT shares one address, so a handful of honest users behind
  one NAT can spend each other's allowance.
- **The quota is not transactional.** Two requests arriving together can both
  read the same count and both write, so a burst can land one or two past the
  limit. A Durable Object would make it exact.
- **The content is whatever the sender wrote.** It is scrubbed on the device,
  but a determined sender is not bound by that — they can send anything they
  like, and it lands in a public issue under a bot's name. Abuse, spam and
  libel all fit in the body. The `anonymous-report` label and the footer are so
  a maintainer knows to read it that way.
- **There is no proof a report came from Jeansh at all.** The endpoint takes an
  unsigned JSON body; anything with `curl` can use it. Signing a report with
  the install's own key, the way `jeansh-notify` signs a send, would fix that
  and is the obvious next piece if it is ever abused.
- **Cloudflare's own protections are not configured here.** A WAF rate-limiting
  rule or Turnstile in front of `/issue` would do more than this code can, and
  would be the first thing to reach for.

The switch above is the answer to all of it in the meantime: one command and
the relay is shut, with the named route — the user's own browser and their own
GitHub account — still working.
