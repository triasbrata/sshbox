# Developer ID signing for macOS

The macOS build is signed ad hoc by default. That has two costs. First, the
keychain's "Always Allow" does not survive an update, so each update asks
again for every saved password and key. Second, the app cannot use the data
protection keychain. A build signed with a Developer ID fixes both. It is
notarized too, so Gatekeeper opens it without a warning.

All of this sits behind one switch, and the switch is **off** by default.
Until it is on, every build is the ad-hoc build, step for step.

## What you need first

- A paid Apple Developer Program membership.
- Your team ID: ten letters and digits. It is under Membership details at
  developer.apple.com/account.

## The seven secrets

Add each of these to the repository's `release` environment (Settings →
Environments → release → Environment secrets).

| Secret | What it holds |
|---|---|
| `MACOS_CERT_P12_BASE64` | The Developer ID Application certificate with its private key, as a `.p12`, base64-encoded |
| `MACOS_CERT_PASSWORD` | The password you gave the `.p12` when you exported it |
| `MACOS_TEAM_ID` | Your ten-character team ID |
| `MACOS_PROVISIONING_PROFILE_BASE64` | A Developer ID provisioning profile for the app, base64-encoded |
| `MACOS_NOTARY_KEY_P8_BASE64` | An App Store Connect API key (`AuthKey_XXXXXXXXXX.p8`), base64-encoded |
| `MACOS_NOTARY_KEY_ID` | That key's ID |
| `MACOS_NOTARY_ISSUER_ID` | The issuer ID shown above the list of keys |

To base64-encode a file on a Mac: `base64 -i FILE | pbcopy`. Then paste the
result as the secret's value.

### The certificate (`.p12`)

1. In Certificates, Identifiers & Profiles → Certificates, choose **+** and
   then **Developer ID Application**. Upload a certificate signing request
   made in Keychain Access (Certificate Assistant → Request a Certificate
   From a Certificate Authority, saved to disk).
2. Download the certificate and open it, so it lands in your login keychain
   beside its private key.
3. In Keychain Access → My Certificates, select "Developer ID Application:
   *your name* (*TEAMID*)". Then choose File → Export Items… → Personal
   Information Exchange (.p12), and set a password.

An Apple Development or Apple Distribution certificate will not do. The build
checks for this and says so.

### The provisioning profile

The data protection keychain needs the app's identifier entitlement. macOS
only lets an app keep that entitlement when a provisioning profile allows it.
A Developer ID app with the entitlement and no profile is killed at launch.
This is why the profile is required.

1. In Identifiers, register an App ID with the bundle ID in
   `macos/Runner/Configs/AppInfo.xcconfig` (`PRODUCT_BUNDLE_IDENTIFIER`).
2. In Profiles, choose **+** and then **Developer ID** (under Distribution).
   Pick that App ID and the Developer ID Application certificate above.
3. Download the `.provisionprofile`.

The build checks that the profile is for your team and for this app.

### The notary key

In App Store Connect → Users and Access → Integrations → App Store Connect
API → Team Keys, generate a key with the **Developer** role. Download the
`.p8`: Apple offers it only once. Note its Key ID and the Issuer ID.

## The switch

Settings → Secrets and variables → Actions → Variables. Add a repository
variable **`MACOS_DEVELOPER_ID`** with the value **`true`**.

- Only the exact value `true` turns it on. Any other value, or no variable,
  keeps the ad-hoc build.
- When it is on, every secret above must be set. A missing or wrong one fails
  the macOS build before it starts, and the error names it. **It never falls
  back to an ad-hoc build.**
- `tag.yml` needs nothing: it calls `release.yml`, which reads the variable.

To build signed on your own Mac, export the same names and run
`MACOS_DEVELOPER_ID=true tools/build_apple.sh macos`.

## What changes for the user

The first signed release moves each saved secret out of the login keychain
and into the data protection keychain. It does this the first time the app
reads the secret.

- The old item is deleted only after the new copy reads back the same.
- If anything fails, the old item is kept and used, and the app says so once.
  It tries again on the next run.
- macOS asks once for each old item as it moves. The old items were tied to
  the ad-hoc signature, so this cannot be avoided. After that, nothing asks.

## Turning it off again

An ad-hoc build cannot read the data protection keychain. So if the switch is
turned off after a signed release, **every secret that moved has to be
entered again**, or the signed build installed again.

The app remembers which secrets moved. It never stores a value, only the
name. An ad-hoc build that finds one of those secrets missing says: "This
secret was moved to the signed build's keychain; enter it again, or install
the signed build". It never just shows an empty field.

## Not proven until the first signed release

CI has no certificate, so `tool/test_apple_signing.sh` runs the build against
stand-ins for Apple's tools. It proves the commands, the order and the
failures, not Apple's answers. These are proven only by the first signed
release:

- the real `codesign`, notarization and stapling of the app and the disk
  image;
- the app launching with its profile and entitlements;
- the data protection keychain reading and writing, and the move with its
  one-time prompts;
- Gatekeeper opening the downloaded build without a warning.
