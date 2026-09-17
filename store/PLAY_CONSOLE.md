# Play Console checklist for Jeansh

The package is `cloud.brata.terminal`. It can't change after the first upload.

## 1. Create the app

- **Play Console → Create app:**
  - name: Jeansh;
  - default language: English (United States);
  - type: App;
  - price: Free.
- **Store settings:**
  - category: Tools;
  - a contact email.

## 2. The first upload, by hand

Play's API can't upload to an app that has never had a bundle, and so neither
can `tool/release.sh --publish`. The first bundle goes through the Console:

1. Make the upload keystore and `android/key.properties`, as described in
   README.md, Releasing.
2. Run `tool/release.sh`. It writes
   `build/app/outputs/bundle/release/app-release.aab`.
3. Go to **Test and release → Testing → Internal testing → Create new
   release**. Accept **Play App Signing**: Google keeps the key that signs
   the app, and yours becomes the upload key.
4. Upload the AAB and paste "What's new" from `RELEASE_NOTES.md` (and
   `RELEASE_NOTES.id.md` for id-ID).
5. Save, review, and roll out to internal testing.
6. Under **Testers**, add an email list and copy the opt-in link. Testers
   install from Play through it.

**Warning, the tablet:** Play's copy is signed with Google's key. Android
won't install it over the debug build on the tablet, which has the same
package. Uninstalling that build wipes its hosts, keys and settings. Move them
off the tablet first, or test the Play build on another device.

## 3. `tool/release.sh --publish` takes over after that

Releases go out from your own machine, not from CI.

1. **In Google Cloud:**
   - enable the **Google Play Android Developer API**;
   - create a service account;
   - create a JSON key for it, and save it as
     `~/keys/jeansh-play-service-account.json` (`chmod 600`), or anywhere
     `$PLAY_SERVICE_ACCOUNT_JSON` names.
2. **In the Play Console → Users and permissions:** invite the service
   account's email, and give it, for Jeansh, **Release apps to testing
   tracks**. It takes a few minutes before the API agrees.
3. **Closed testing:** under **Test and release → Testing → Closed testing**,
   the track Play makes for you has the id `alpha`; a track you add yourself
   has its own id, the last part of its address. Add a tester list to it, and
   copy the opt-in link.
4. Run `tool/release.sh --publish --dry-run` first: it does everything but the
   commit. Then `tool/release.sh --publish`, which releases on `alpha`, or
   `--track <id>` for a track of your own.
5. Every upload needs a build number Play hasn't seen. The pre-commit hook
   raises it with each app commit, and the publisher refuses a number Play
   already has before it uploads anything.

## 4. Policy → App content

### Privacy policy

A public URL is required. Nothing hosts `PRIVACY_POLICY.md` yet. For example,
add `/privacy` to jeansh-web (https://jeansh.brata.cloud), or link the file in
a public repo.

### Ads

No.

### App access

Choose **All or some functionality is restricted**. Jeansh shows nothing past
the host list without an SSH server, so a reviewer who can't connect may
reject it as broken.

Give reviewers:
- a disposable demo account on a sandboxed host, with no sudo and no data of
  yours;
- its address, port, user name and password;
- one line saying what to try.

### Content rating (IARC)

- **Category:** Utility, Productivity, Communication or Other.
- Violence, sexual content, language, controlled substances, gambling:
  **No**.
- Users interact or exchange content with each other: **No**.
- Shares the user's location: **No**.
- Digital purchases: **No**.
- Web access: the web tabs open any page the user follows from the terminal.
  Answer that honestly. Some regions add an "unrestricted internet" notice.

### Target audience

**18 and over.** It's a tool for managing servers. Answer **No** to "appeals
to children", which keeps the app out of the Families policy.

### Other declarations

- **News app:** No.
- **Government app:** No.
- **Financial features:** none.
- **Health:** No.
- **Advertising ID:** No. The merged manifest has no `AD_ID` permission, and
  no analytics SDK is included.

### Data safety

**General questions:**

| Question | Answer |
|---|---|
| Collects or shares required user data types? | Yes |
| All collected data encrypted in transit? | Yes (HTTPS to the relay, TLS to FCM) |
| Account creation | The app doesn't let users create an account |
| Users can request that their data is deleted? | Yes: deleting a host, Settings → Notifications → Reset notification keys, or email (see the privacy policy) |

**Data types:**

| Data type | Collected | Shared | Ephemeral | Required | Purpose |
|---|---|---|---|---|---|
| Device or other IDs (the FCM registration token, stored on the jeansh-notify relay with the public half of each host's key, and the Firebase installation ID used by FCM) | Yes | No (Google and Cloudflare are service providers) | No | Yes (registered at launch, no switch) | App functionality |

**Not declared, and why:**

- **SSH credentials, host names, terminal content and files:** they go from
  the device straight to servers the user chooses, encrypted end to end by
  SSH. They never reach the developer or a service the developer runs.
- **Notification text:** it comes from the user's own servers, through the
  relay, to the device. The app doesn't send it off the device, and the relay
  keeps none of it. For the most conservative answer, declare "Messages → Other
  in-app messages", processed ephemerally, for app functionality.
- **Web tab pages:** these are sites the user opens, as in a browser.

### Foreground service permissions

**Type:** Data sync (`FOREGROUND_SERVICE_DATA_SYNC`, `foregroundServiceType="dataSync"`).

**What to write:**

> Jeansh is an SSH client. While at least one SSH session or port forward is
> open, it runs a foreground service with an ongoing "Active sessions"
> notification. Without it, Android freezes the process in the background
> and the user's open SSH connections drop, even while the user only picks a
> file to upload. Data flows continuously between the device and the user's
> server over the network. The service starts only when a session connects or
> the user switches a port forward on, and stops when the last one closes. If
> it is stopped, the SSH connection drops, programs lose their terminal and
> the user has to reconnect.

**Video:** an unlisted screen recording showing:
1. the user connects;
2. the notification appears;
3. the user switches to another app;
4. the user comes back to the still-live session;
5. the user closes it, and the notification goes away.

**Android 15+ limit:** with targetSdk 35 or higher, a `dataSync` service may
run 6 hours in any 24 in the background. The count resets when the user opens
the app. At the limit, Android calls `Service.onTimeout`, and
flutter_foreground_task 11.0.3 stops the service there without crashing. A
session left in the background after that can freeze and drop.

**Review risk:** Play may judge `dataSync` a poor fit for a long-lived
interactive connection. The fallback is `specialUse`, with a
`PROPERTY_SPECIAL_USE_FGS_SUBTYPE` that explains SSH sessions. That's a code
change: the manifest's service type, the permission, and
`ForegroundServiceTypes` in `session_keepalive.dart`.

## 5. Store listing

**Text:** from `STORE_LISTING.md` (en-US) and `STORE_LISTING.id.md` (id-ID).

**Graphics**, in `store/graphics/`. Each is drawn on a canvas in `src/` and
captured by `generate.ts` in headless Chromium, which also checks its size,
dimensions and alpha. To redraw them, run `bun install && bun run generate`
there.

- **App icon, 512 × 512 PNG:** `icon-512.png`, 32-bit. Play applies its own
  mask, so it's a full-bleed square: `assets/branding/app_icon.png` cut the
  way `app_icon_ios.png` is, 40 px in from each side.
- **Feature graphic, 1024 × 500:** `feature-graphic-1024x500.png`, 24-bit
  with no alpha. It has the icon, the name, the tagline and a terminal in Tokyo
  Night colours, on the promo site's indigo and amber.
- **Screenshots:**
  - phone: 2 to 8;
  - 7-inch and 10-inch tablet: worth it for a tablet-first app.

## 6. Before production

- A personal developer account created after November 2023 must first run a
  **closed test** with at least 12 testers opted in for 14 days in a row.
  Internal testing doesn't count toward it.
- Read the **pre-launch report** of the first closed-testing build.
- targetSdk 37 meets Play's minimum.
