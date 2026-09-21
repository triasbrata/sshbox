#!/usr/bin/env bash
# Builds Jeansh for macOS and iOS on a Mac and packages each build under
# dist/<version>/. Run tools/build_apple.sh --help for the options.
#
# Written for the bash 3.2 that ships with macOS: no associative arrays, and
# arrays that may be empty expand as ${a[@]+"${a[@]}"} because set -u would
# otherwise call them unbound.
set -euo pipefail

APP_NAME=Jeansh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: tools/build_apple.sh [options] [target...]

Targets (default: macos ios-sim ios):
  macos      Jeansh.app for this Mac's architecture and Intel, as a .zip and a .dmg
  ios-sim    debug Runner.app for the iOS simulator, as a .zip
             (install with: xcrun simctl install booted Runner.app)
  ios        device build: a signed .ipa with --team, else an unsigned .ipa
             to sign later

Options:
  --release | --profile | --debug   build mode for macos and ios (default: release);
                                    ios-sim is always debug, Flutter has no
                                    release build for the simulator
  --team ID             Apple team ID; signs the ios build with automatic signing
                        and exports a .ipa (env DEVELOPMENT_TEAM also works)
  --export-method M     for a signed .ipa: debugging (default), release-testing,
                        app-store-connect, enterprise
  --build-name X.Y.Z    version shown to users (default: pubspec.yaml)
  --build-number N      build number (default: pubspec.yaml)
  --skip-checks         skip flutter analyze and flutter test
  --clean               flutter clean first
  --out DIR             where packages go (default: dist)
  -h, --help            this text

Flutter SDK: $FLUTTER if set, else the version .fvmrc pins through fvm
(installed if missing), else flutter on PATH.

Signing without Xcode logged in to an Apple account: set ASC_KEY_PATH,
ASC_KEY_ID and ASC_ISSUER_ID to an App Store Connect API key and
xcodebuild uses it to fetch provisioning profiles.
EOF
}

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

mode=release
team="${DEVELOPMENT_TEAM:-}"
export_method=debugging
build_name=""
build_number=""
skip_checks=0
clean=0
out_root="$ROOT/dist"
targets=""

while [ $# -gt 0 ]; do
  case "$1" in
    --release | --profile | --debug) mode="${1#--}" ;;
    --team) team="${2:?--team needs a team ID}"; shift ;;
    --export-method) export_method="${2:?--export-method needs a method}"; shift ;;
    --build-name) build_name="${2:?--build-name needs a value}"; shift ;;
    --build-number) build_number="${2:?--build-number needs a value}"; shift ;;
    --skip-checks) skip_checks=1 ;;
    --clean) clean=1 ;;
    --out) out_root="${2:?--out needs a directory}"; shift ;;
    -h | --help) usage; exit 0 ;;
    macos | ios-sim | ios) targets="$targets $1" ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done
targets="${targets:- macos ios-sim ios}"

# Xcode 15.3 renamed the export methods; take the old names too.
case "$export_method" in
  development) export_method=debugging ;;
  ad-hoc) export_method=release-testing ;;
  app-store) export_method=app-store-connect ;;
  debugging | release-testing | app-store-connect | enterprise) ;;
  *) die "unknown export method: $export_method" ;;
esac

# Release, Profile or Debug: the Xcode configuration for a Flutter mode.
config="$(printf '%s' "${mode:0:1}" | tr '[:lower:]' '[:upper:]')${mode:1}"

# ---------------------------------------------------------------- preflight

[ "$(uname -s)" = Darwin ] || die "macOS and iOS builds need a Mac"
xcodebuild -version >/dev/null 2>&1 ||
  die "xcodebuild not usable; install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"

if [ -z "${FLUTTER:-}" ]; then
  pinned="$(sed -n 's/.*"flutter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .fvmrc 2>/dev/null || true)"
  if [ -n "$pinned" ] && command -v fvm >/dev/null; then
    FLUTTER="${FVM_CACHE_PATH:-$HOME/fvm}/versions/$pinned/bin/flutter"
    if [ ! -x "$FLUTTER" ]; then
      step "Installing Flutter $pinned with fvm"
      fvm install "$pinned"
    fi
  elif command -v flutter >/dev/null; then
    FLUTTER="$(command -v flutter)"
    [ -z "$pinned" ] || warn "fvm not found, using $FLUTTER; .fvmrc pins Flutter $pinned"
  else
    die "no Flutter SDK: brew install fvm (it installs the version .fvmrc pins), or set FLUTTER"
  fi
fi
[ -x "$FLUTTER" ] || die "not executable: $FLUTTER"
flutter() { "$FLUTTER" "$@"; }

pub_version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml)"
build_name="${build_name:-${pub_version%%+*}}"
case "$pub_version" in
  *+*) build_number="${build_number:-${pub_version#*+}}" ;;
  *) build_number="${build_number:-1}" ;;
esac
version_args=(--build-name "$build_name" --build-number "$build_number")
label="$build_name+$build_number"

# Baked into the build for the updater (lib/src/update/updater.dart): the
# version it compares against the release feed, and the host the feed's paths
# hang off. No JEANSH_UPDATE_HOST in the environment leaves the updater off,
# and Settings says so. iOS takes them too and ignores them: it updates
# through the App Store.
version_args+=(--dart-define "JEANSH_VERSION=$label")
[ -z "${JEANSH_UPDATE_HOST:-}" ] ||
  version_args+=(--dart-define "JEANSH_UPDATE_HOST=$JEANSH_UPDATE_HOST")

# Baked in for crash reporting (lib/src/telemetry/crash_reporting.dart). No
# JEANSH_SENTRY_DSN in the environment leaves crash reporting off, and
# Settings says so. The DSN is not a secret — every web app that uses Sentry
# has one in its JavaScript — but it stays out of this public repository so
# nobody fills the quota with junk.
[ -z "${JEANSH_SENTRY_DSN:-}" ] ||
  version_args+=(--dart-define "JEANSH_SENTRY_DSN=$JEANSH_SENTRY_DSN")

out="$out_root/$label"
mkdir -p "$out"

# Scratch space for archives and staging, gone when the script exits.
work="$(mktemp -d "${TMPDIR:-/tmp}/jeansh-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT

auth_args=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  : "${ASC_KEY_ID:?ASC_KEY_PATH needs ASC_KEY_ID}" "${ASC_ISSUER_ID:?ASC_KEY_PATH needs ASC_ISSUER_ID}"
  auth_args=(-authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

step "Jeansh $label ($mode):$targets"
printf 'Flutter: %s\n' "$(flutter --version 2>/dev/null | head -1)"
printf 'Xcode:   %s\n' "$(xcodebuild -version | head -1)"
printf 'Output:  %s\n' "$out"

# ---------------------------------------------------------------- stages

# The one .app a build left in $1, failing loudly if there is none.
find_app() {
  local app
  app="$(find "$1" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)"
  [ -n "$app" ] || die "no .app in $1"
  printf '%s\n' "$app"
}

build_macos() {
  step "macOS: flutter build macos --$mode"
  flutter build macos --"$mode" "${version_args[@]}"
  local app
  app="$(find_app "build/macos/Build/Products/$config")"

  ditto -c -k --keepParent "$app" "$out/$APP_NAME-$label-macos.zip"

  # A disk image with the app beside an Applications link, to drag it across.
  local stage="$work/dmg"
  rm -rf "$stage" && mkdir -p "$stage"
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO \
    "$out/$APP_NAME-$label-macos.dmg"

  codesign -dv "$app" 2>&1 | grep -E '^(Authority|Signature)=' | head -1 || true
}

build_ios_sim() {
  step "iOS simulator: flutter build ios --simulator --debug"
  flutter build ios --simulator --debug "${version_args[@]}"
  local app
  app="$(find_app build/ios/iphonesimulator)"
  ditto -c -k --keepParent "$app" "$out/$APP_NAME-$label-ios-simulator.zip"
}

build_ios_unsigned() {
  [ "$mode" != debug ] ||
    warn "an iOS debug build only starts under a debugger; use --release to sideload"
  step "iOS device, unsigned: flutter build ios --$mode --no-codesign"
  flutter build ios --"$mode" --no-codesign "${version_args[@]}"
  local app
  app="$(find_app build/ios/iphoneos)"

  # An .ipa is a zip with the app under Payload/.
  local stage="$work/ipa"
  rm -rf "$stage" && mkdir -p "$stage/Payload"
  cp -R "$app" "$stage/Payload/"
  (cd "$stage" && zip -qry "$out/$APP_NAME-$label-ios-unsigned.ipa" Payload)
}

build_ios_signed() {
  step "iOS device, signed by team $team: archive and export ($export_method)"
  # Writes Generated.xcconfig and installs pods, so xcodebuild sees the same
  # build settings flutter build would give it.
  flutter build ios --"$mode" --config-only "${version_args[@]}"

  local archive="$work/Runner.xcarchive"
  xcodebuild -quiet \
    -workspace ios/Runner.xcworkspace -scheme Runner -configuration "$config" \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -allowProvisioningUpdates ${auth_args[@]+"${auth_args[@]}"} \
    DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
    archive

  local options="$work/ExportOptions.plist"
  cat >"$options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$export_method</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
  xcodebuild -quiet -exportArchive \
    -archivePath "$archive" -exportPath "$work/export" -exportOptionsPlist "$options" \
    -allowProvisioningUpdates ${auth_args[@]+"${auth_args[@]}"}

  local ipa
  ipa="$(find "$work/export" -maxdepth 1 -name '*.ipa' -print -quit)"
  [ -n "$ipa" ] || die "xcodebuild exported no .ipa"
  mv "$ipa" "$out/$APP_NAME-$label-ios.ipa"
  # dSYMs, for symbolicating crashes from this exact build.
  ditto -c -k --keepParent "$archive/dSYMs" "$out/$APP_NAME-$label-ios-dSYMs.zip"
}

# ---------------------------------------------------------------- pipeline

if [ "$clean" = 1 ]; then
  step "flutter clean"
  flutter clean
fi

step "flutter pub get"
flutter pub get

if [ "$skip_checks" = 0 ]; then
  step "flutter analyze"
  flutter analyze
  step "flutter test"
  flutter test
fi

for target in $targets; do
  case "$target" in
    macos) build_macos ;;
    ios-sim) build_ios_sim ;;
    ios) if [ -n "$team" ]; then build_ios_signed; else build_ios_unsigned; fi ;;
  esac
done

(cd "$out" && rm -f SHA256SUMS && shasum -a 256 -- * >SHA256SUMS)

step "Done: $out"
ls -lh "$out"
