#!/bin/bash
# Runs tools/build_apple.sh's macOS build against stand-ins for Flutter and
# Apple's tools, in a throwaway copy of the repository, and checks:
#
#   - MACOS_DEVELOPER_ID off (unset, false, anything but "true"): the very
#     commands the ad-hoc build ran before Developer ID signing existed,
#     recorded below, and nothing of signing;
#   - on, with no secrets: the build fails before anything is built, naming
#     every missing secret;
#   - on, with a bad secret: the preflight's own errors, before the build;
#   - on, with every secret: the certificate in a keychain of the build's own,
#     the hardened runtime, the access group, notarization and stapling, and
#     the keychain deleted however the build ends.
#
# Nothing here signs anything: real signing needs the certificate, so what
# only a signed release proves is in docs/macos-developer-id.md.
#
#   tool/test_apple_signing.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
fail() {
  printf 'FAIL: %s\n' "$*"
  failures=$((failures + 1))
}
pass() { printf 'ok: %s\n' "$*"; }

# ------------------------------------------------------------- stand-ins

bin="$work/bin"
mkdir -p "$bin"

# Each stand-in records its argv, a line per call. FAKE_EXTRA_FOR=<name>
# makes that one record an argument it was never given, for the self-checks
# at the end.
stub() {
  cat >"$bin/$1" <<EOF
#!/bin/bash
extra=""
[ "\${FAKE_EXTRA_FOR:-}" != "$1" ] || extra=" --extra"
printf '%s\n' "$1 \$*\$extra" >>"\$LOG"
$2
EOF
  chmod +x "$bin/$1"
}

stub uname 'echo Darwin'
stub xcodebuild 'echo "Xcode 99.0"'
stub hdiutil ':'
stub ditto ':'
stub spctl ':'
stub plutil ':'
stub shasum ':'
stub openssl 'echo 0123456789abcdef'
stub flutter '
case "$*" in
  --version*) echo "Flutter 9.9.9" ;;
  "build macos"*)
    app=build/macos/Build/Products/Release/Jeansh.app/Contents
    mkdir -p "$app/MacOS" "$app/Frameworks/FlutterMacOS.framework" "$app/Frameworks/App.framework" ;;
esac'
stub codesign '[ "${1:-}" != -dv ] || echo "Signature=adhoc" >&2'
stub security '
case "$1" in
  list-keychains) [ "$*" != "list-keychains -d user" ] || echo "    \"/Users/someone/Library/Keychains/login.keychain-db\"" ;;
  cms) cat "$4" ;;
  import) [ -z "${FAKE_IMPORT_FAILS:-}" ] || exit 1 ;;
  find-identity)
    printf "  1) %s \"%s\"\n" 1111111111111111111111111111111111111111 "Apple Development: Someone (AAAAAAAAAA)"
    [ -z "${FAKE_IDENTITY:-}" ] ||
      printf "  2) %s \"%s\"\n" 2222222222222222222222222222222222222222 "$FAKE_IDENTITY"
    printf "     2 valid identities found\n" ;;
esac'
stub xcrun '
case "$1 $2" in
  "notarytool submit") printf "{\"id\":\"sub-1\",\"status\":\"%s\",\"message\":\"done\"}\n" "${FAKE_NOTARY:-Accepted}" ;;
  "notarytool log") echo "the notary log" ;;
esac'

# A throwaway repository holding only what the script reads.
repo() {
  local r="$work/repo"
  rm -rf "$r" "$work/tmp" && mkdir -p "$r/tools" "$r/macos/Runner/Configs" "$work/tmp"
  cp "$1" "$r/tools/build_apple.sh"
  cp "$root/macos/Runner/Release.entitlements" "$r/macos/Runner/"
  cp "$root/macos/Runner/Configs/AppInfo.xcconfig" "$r/macos/Runner/Configs/"
  printf 'name: sshbox\nversion: 1.2.3+45\n' >"$r/pubspec.yaml"
  printf '%s\n' "$r"
}

# Runs the script in a fresh repository with the environment given, leaving
# its output in $work/out, its calls in $work/log (temporary paths made
# stable), and its exit status in $status.
run() {
  local script="$1"
  shift
  local r
  r=$(repo "$script")
  : >"$work/log.raw"
  (cd "$r" && env -i PATH="$bin:/usr/bin:/bin" HOME="$work" TMPDIR="$work/tmp" \
    LOG="$work/log.raw" FLUTTER="$bin/flutter" "$@" \
    bash tools/build_apple.sh --skip-checks macos) >"$work/out" 2>&1
  status=$?
  sed -e "s#$work/tmp/jeansh-build\.[A-Za-z0-9]*#<work>#g" -e "s#$work#<t>#g" \
    "$work/log.raw" >"$work/log"
}

# ------------------------------------------------------------- off

# What the ad-hoc build ran before Developer ID signing existed, call for
# call: the script as it was, run here, gives exactly this.
expected_off() {
  cat <<'EOF'
uname -s
xcodebuild -version
flutter --version
xcodebuild -version
flutter pub get
flutter build macos --release --build-name 1.2.3 --build-number 45 --dart-define JEANSH_VERSION=1.2.3+45
ditto -c -k --keepParent build/macos/Build/Products/Release/Jeansh.app <t>/repo/dist/1.2.3+45/Jeansh-1.2.3+45-macos.zip
hdiutil create -quiet -volname Jeansh -srcfolder <work>/dmg -ov -format UDZO <t>/repo/dist/1.2.3+45/Jeansh-1.2.3+45-macos.dmg
codesign -dv build/macos/Build/Products/Release/Jeansh.app
shasum -a 256 -- *
EOF
}

# Whether the last run's calls are exactly expected_off's, the diff kept.
off_matches() { diff -u <(expected_off) "$work/log" >"$work/diff"; }

check_off() {
  local what="$1"
  [ "$status" = 0 ] || { fail "$what: exited $status"; cat "$work/out"; return; }
  if off_matches; then
    pass "$what: the same commands as the ad-hoc build"
  else
    fail "$what: the commands changed"
    cat "$work/diff"
  fi
  grep -Eq 'security|notarytool|stapler|--options runtime|MACOS_KEYCHAIN_GROUP' "$work/log" &&
    fail "$what: something of signing ran"
}

# The baseline itself, from the script as it was before Developer ID, when
# git has it (or BUILD_APPLE_BEFORE names a copy): so the list above is a
# record, not a guess.
if [ -n "${BUILD_APPLE_BEFORE:-}" ]; then
  cp "$BUILD_APPLE_BEFORE" "$work/old.sh"
else
  before=$(git -C "$root" log --format=%H -1 -S'developer_id_preflight' -- tools/build_apple.sh 2>/dev/null)
  [ -n "$before" ] && git -C "$root" show "$before~1:tools/build_apple.sh" >"$work/old.sh" 2>/dev/null
fi
if [ -s "$work/old.sh" ]; then
  run "$work/old.sh"
  check_off "the script before Developer ID"
else
  printf 'skip: the script before Developer ID is not in this checkout\n'
fi

script="$root/tools/build_apple.sh"
run "$script"
check_off "MACOS_DEVELOPER_ID unset"
run "$script" MACOS_DEVELOPER_ID=false
check_off "MACOS_DEVELOPER_ID=false"
run "$script" MACOS_DEVELOPER_ID=TRUE MACOS_TEAM_ID=ABCDE12345
check_off "MACOS_DEVELOPER_ID=TRUE, not exactly true"

# ------------------------------------------------------------- on, no secrets

run "$script" MACOS_DEVELOPER_ID=true
if [ "$status" = 0 ]; then
  fail "on with no secrets: the build succeeded"
else
  pass "on with no secrets: the build failed"
fi
for name in MACOS_CERT_P12_BASE64 MACOS_CERT_PASSWORD MACOS_TEAM_ID \
  MACOS_PROVISIONING_PROFILE_BASE64 MACOS_NOTARY_KEY_P8_BASE64 \
  MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER_ID; do
  grep -q "$name" "$work/out" || fail "on with no secrets: $name not named"
done
grep -q 'does not fall back to ad-hoc' "$work/out" ||
  fail "on with no secrets: no word that nothing falls back"
grep -q '^flutter' "$work/log" && fail "on with no secrets: flutter ran before the check"
grep -q 'codesign' "$work/log" && fail "on with no secrets: something was signed"

# ------------------------------------------------------------- on, secrets

team=ABCDE12345
group="$team.$(sed -n 's/^PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*//p' "$root/macos/Runner/Configs/AppInfo.xcconfig")"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
profile() {
  b64 "<plist><dict>
<key>Entitlements</key>
<dict>
<key>com.apple.application-identifier</key>
<string>$2</string>
</dict>
<key>TeamIdentifier</key>
<array>
<string>$1</string>
</array>
</dict></plist>"
}
secrets=(
  MACOS_CERT_P12_BASE64="$(b64 'not really a p12')"
  MACOS_CERT_PASSWORD=pw
  MACOS_TEAM_ID=$team
  MACOS_PROVISIONING_PROFILE_BASE64="$(profile "$team" "$group")"
  MACOS_NOTARY_KEY_P8_BASE64="$(b64 '-----BEGIN PRIVATE KEY-----
abc
-----END PRIVATE KEY-----')"
  MACOS_NOTARY_KEY_ID=KEY123
  MACOS_NOTARY_ISSUER_ID=issuer-1
  FAKE_IDENTITY="Developer ID Application: Someone ($team)"
)

# $1 what, $2 the message the build must stop with; the rest, settings over
# the good ones.
refused() {
  local what="$1" message="$2"
  shift 2
  run "$script" MACOS_DEVELOPER_ID=true "${secrets[@]}" "$@"
  if [ "$status" = 0 ]; then
    fail "$what: the build succeeded"
  elif ! grep -qF "$message" "$work/out"; then
    fail "$what: not said ($message)"
    cat "$work/out"
  elif grep -q '^flutter build' "$work/log"; then
    fail "$what: built before refusing"
  else
    pass "$what: refused before the build"
  fi
}

refused "a team ID that is no team ID" 'MACOS_TEAM_ID is not a 10-character' MACOS_TEAM_ID=nope
refused "a notary key that is not base64" 'MACOS_NOTARY_KEY_P8_BASE64 is not base64' 'MACOS_NOTARY_KEY_P8_BASE64=***'
refused "a notary key that is no key" 'is not an App Store Connect API key' MACOS_NOTARY_KEY_P8_BASE64="$(b64 hello)"
refused "a profile of another team" "the provisioning profile is team ZZZZZ99999's" \
  MACOS_PROVISIONING_PROFILE_BASE64="$(profile ZZZZZ99999 "$group")"
refused "a profile for another app" 'the provisioning profile is for ABCDE12345.other.app' \
  MACOS_PROVISIONING_PROFILE_BASE64="$(profile "$team" "$team.other.app")"
refused "a certificate that will not import" 'would not import with MACOS_CERT_PASSWORD' FAKE_IMPORT_FAILS=1
refused "an Apple Development certificate" 'holds no Developer ID Application identity' FAKE_IDENTITY=
refused "a Developer ID of another team" "is not team $team's" \
  FAKE_IDENTITY="Developer ID Application: Someone Else (ZZZZZ99999)"
grep -q "delete-keychain <t>/tmp/.*/signing/jeansh-signing.keychain-db\|delete-keychain <work>/signing/jeansh-signing.keychain-db" "$work/log" ||
  fail "a refused certificate left its keychain"

run "$script" MACOS_DEVELOPER_ID=true "${secrets[@]}"
if [ "$status" != 0 ]; then
  fail "on with every secret: exited $status"
  cat "$work/out"
else
  pass "on with every secret: built"
fi
kc='<work>/signing/jeansh-signing.keychain-db'
id=2222222222222222222222222222222222222222
app=build/macos/Build/Products/Release/Jeansh.app
dmg='<t>/repo/dist/1.2.3+45/Jeansh-1.2.3+45-macos.dmg'
# What the flag-on build must have run, each a whole line of the log, a tab,
# and what it is.
on_expected() {
  cat <<EOF
security create-keychain -p 0123456789abcdef $kc	a keychain of the build's own
security import <work>/signing/certificate.p12 -k $kc -P pw -f pkcs12 -T /usr/bin/codesign	the certificate into it
security list-keychains -d user -s $kc /Users/someone/Library/Keychains/login.keychain-db	searched beside the user's
flutter build macos --release --build-name 1.2.3 --build-number 45 --dart-define JEANSH_VERSION=1.2.3+45 --dart-define MACOS_KEYCHAIN_GROUP=$group	the access group into the app
codesign --force --options runtime --timestamp --sign $id --keychain $kc $app/Contents/Frameworks/App.framework	frameworks first
codesign --force --options runtime --timestamp --entitlements <work>/signing/Release.entitlements --sign $id --keychain $kc $app	then the app, with the hardened runtime
codesign --verify --deep --strict --verbose=2 $app	verified
xcrun notarytool submit <work>/signing/notarize.zip --key <work>/signing/AuthKey.p8 --key-id KEY123 --issuer issuer-1 --wait --timeout 30m --output-format json	the app notarized
xcrun stapler staple $app	the app stapled
spctl --assess --type execute --verbose=2 $app	Gatekeeper asked
codesign --force --timestamp --sign $id --keychain $kc $dmg	the disk image signed
xcrun stapler staple $dmg	the disk image stapled
security list-keychains -d user -s /Users/someone/Library/Keychains/login.keychain-db	the search list put back
security delete-keychain $kc	the keychain deleted
EOF
}
# How many of on_expected's calls the last run's log lacks.
on_misses() {
  local n=0 line what
  while IFS=$'\t' read -r line what; do
    grep -qxF -- "$line" "$work/log" || n=$((n + 1))
  done < <(on_expected)
  printf '%s\n' "$n"
}
while IFS=$'\t' read -r line what; do
  if grep -qxF -- "$line" "$work/log"; then
    pass "on: $what"
  else
    fail "on: $what ($line)"
  fi
done < <(on_expected)
[ "$(on_misses)" = 0 ] || cat "$work/log"
# Stapled before it is packaged: the zip and the disk image carry the ticket.
staple=$(grep -n 'stapler staple build/' "$work/log" | head -1 | cut -d: -f1)
zip=$(grep -n 'ditto -c -k --keepParent build/macos/Build/Products/Release/Jeansh.app <t>/repo/dist' "$work/log" | cut -d: -f1)
[ -n "$staple" ] && [ -n "$zip" ] && [ "$staple" -lt "$zip" ] &&
  pass "on: stapled before packaged" || fail "on: packaged before stapling"
[ -f "$work/repo/build/macos/Build/Products/Release/Jeansh.app/Contents/embedded.provisionprofile" ] &&
  pass "on: the profile embedded" || fail "on: no embedded profile"
# The entitlements the app was signed with: Release.entitlements and the group.
run_entitlements() {
  local r="$work/ent" e
  mkdir -p "$r/macos/Runner"
  cp "$root/macos/Runner/Release.entitlements" "$r/macos/Runner/"
  e=$(cd "$r" && PATH="$bin:$PATH" LOG=/dev/null MACOS_TEAM_ID=$team bash -c "
    keychain_group=$group
    $(sed -n '/^developer_id_entitlements() {$/,/^}$/p' "$script")
    developer_id_entitlements out.plist && cat out.plist")
  printf '%s\n' "$e"
}
ent=$(run_entitlements)
for want in "<string>$group</string>" '<key>keychain-access-groups</key>' \
  '<key>com.apple.application-identifier</key>' "<string>$team</string>" \
  '<key>com.apple.security.network.client</key>'; do
  printf '%s' "$ent" | grep -qF "$want" || fail "entitlements lack $want"
done
[ "$(printf '%s\n' "$ent" | tail -2 | head -1)" = '</dict>' ] || fail "entitlements end out of shape"

# A rejected notarization stops the build, with the notary's log, and still
# deletes the keychain.
run "$script" MACOS_DEVELOPER_ID=true "${secrets[@]}" FAKE_NOTARY=Invalid
if [ "$status" = 0 ]; then
  fail "a rejected notarization: the build succeeded"
elif ! grep -q 'notarization of Jeansh.app ended Invalid' "$work/out" || ! grep -q 'the notary log' "$work/out"; then
  fail "a rejected notarization: not said with its log"
  cat "$work/out"
elif grep -q 'ditto -c -k --keepParent build/macos/Build/Products/Release/Jeansh.app <t>/repo/dist' "$work/log"; then
  fail "a rejected notarization: packaged anyway"
elif ! grep -qF "security delete-keychain $kc" "$work/log"; then
  fail "a rejected notarization: the keychain left"
else
  pass "a rejected notarization stops the build and deletes the keychain"
fi

# The workflow: the flag reaches the build only as the variable, and the
# signing secrets reach the macOS build alone.
flow="$root/.github/workflows/release.yml"
grep -q 'MACOS_DEVELOPER_ID: ${{ vars.MACOS_DEVELOPER_ID }}' "$flow" ||
  fail "release.yml does not pass the MACOS_DEVELOPER_ID variable"
for name in MACOS_CERT_P12_BASE64 MACOS_CERT_PASSWORD MACOS_TEAM_ID \
  MACOS_PROVISIONING_PROFILE_BASE64 MACOS_NOTARY_KEY_P8_BASE64 \
  MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER_ID; do
  grep -qF "$name: \${{ matrix.target == 'macos' && secrets.$name || '' }}" "$flow" ||
    fail "release.yml does not hand $name to the macOS build alone"
done

# ------------------------------------------------------------- self-checks

# The checks above must bite. Each is shown failing on a change made here, in
# a scratch copy or a stand-in, never in the script any branch carries.

# Off: two independent lines of the script swapped, the toolchain's version
# lines, which nothing reads, and the baseline must see it.
swapped="$work/swapped.sh"
awk '/^printf .Flutter: / { held = $0; next }
  { print }
  /^printf .Xcode: / && held != "" { print held }' "$script" >"$swapped"
if cmp -s "$script" "$swapped"; then
  fail "self-check: the version lines to swap were not found"
else
  run "$swapped"
  if [ "$status" = 0 ] && ! off_matches; then
    pass "self-check: the off baseline sees two commands swapped"
  else
    fail "self-check: the off baseline missed two commands swapped"
  fi
fi

# On: codesign recording one argument more, and the sequence must miss it.
run "$script" MACOS_DEVELOPER_ID=true "${secrets[@]}" FAKE_EXTRA_FOR=codesign
misses=$(on_misses)
if [ "$status" = 0 ] && [ "$misses" -gt 0 ]; then
  pass "self-check: the on sequence sees codesign's extra argument ($misses calls)"
else
  fail "self-check: the on sequence missed codesign's extra argument"
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d failed\n' "$failures"
  exit 1
fi
printf '\nall passed\n'
