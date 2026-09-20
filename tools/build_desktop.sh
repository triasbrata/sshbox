#!/usr/bin/env bash
# Builds Jeansh for Linux and Windows and packages each build under
# dist/<version>/, as tools/build_apple.sh does for macOS and iOS. Run
# tools/build_desktop.sh --help for the options.
#
# A script of its own rather than more of build_apple.sh: that one needs a Mac
# and Xcode, this one needs Linux — WSL for the Windows build, which has to
# run on Windows itself, since Flutter cannot cross-compile to it.
set -euo pipefail

APP_NAME=Jeansh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: tools/build_desktop.sh [options] [target...]

Targets (default: linux, and windows too under WSL):
  linux      the release bundle for this machine's architecture, as a .tar.gz
  windows    the release build, as a .zip; from WSL, built by the Windows
             side's own Flutter in a copy of the tree under
             %LOCALAPPDATA%\Jeansh\build, since Flutter and MSBuild cannot
             build from a \\wsl$ path

Options:
  --release | --profile | --debug   build mode (default: release)
  --build-name X.Y.Z    version shown to users (default: pubspec.yaml)
  --build-number N      build number (default: pubspec.yaml)
  --skip-checks         skip flutter analyze and flutter test
  --clean               flutter clean first
  --out DIR             where packages go (default: dist)
  -h, --help            this text

Flutter SDK: $FLUTTER if set, else the version .fvmrc pins through fvm,
else flutter on PATH. On the Windows side: $FLUTTER_WINDOWS if set (a
Windows path to flutter.bat), else flutter on the Windows PATH.

Linux needs, on Debian or Ubuntu:
  sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
    liblzma-dev libstdc++-12-dev libsecret-1-dev
Windows needs Flutter for Windows, and Visual Studio or its Build Tools with
the "Desktop development with C++" workload.
EOF
}

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

mode=release
build_name=""
build_number=""
skip_checks=0
clean=0
out_root="$ROOT/dist"
targets=""

while [ $# -gt 0 ]; do
  case "$1" in
    --release | --profile | --debug) mode="${1#--}" ;;
    --build-name) build_name="${2:?--build-name needs a value}"; shift ;;
    --build-number) build_number="${2:?--build-number needs a value}"; shift ;;
    --skip-checks) skip_checks=1 ;;
    --clean) clean=1 ;;
    --out) out_root="${2:?--out needs a directory}"; shift ;;
    -h | --help) usage; exit 0 ;;
    linux | windows) targets="$targets $1" ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

wsl=0
grep -qi microsoft /proc/version 2>/dev/null && wsl=1
if [ -z "$targets" ]; then
  targets=" linux"
  [ "$wsl" = 0 ] || targets="$targets windows"
fi

# Release, Profile or Debug: the folder Flutter's Windows build writes to.
config="${mode^}"

# ---------------------------------------------------------------- preflight

[ "$(uname -s)" = Linux ] || die "run this on Linux, or in WSL for the Windows build"

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
  else
    die "no Flutter SDK: install fvm (it installs the version .fvmrc pins), or set FLUTTER"
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
# and Settings says so.
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

# sentry_flutter builds sentry-native from source on Linux and Windows: its
# sentry-native/sentry-native.cmake clones the upstream repository while CMake
# configures, so a desktop build now wants a network. Its crash backend
# defaults to crashpad, a large C++ tree of its own that nobody here has ever
# put through MSVC — Firebase's prebuilt C++ SDK already cost this project its
# desktop Firebase over a toolchain that could not link it. "none" builds the
# transport and no crash handler, so a Dart error is still reported and a
# native desktop crash is not. Set SENTRY_NATIVE_BACKEND in the environment to
# try crashpad, and be ready for a long build.
export SENTRY_NATIVE_BACKEND="${SENTRY_NATIVE_BACKEND:-none}"

out="$out_root/$label"
mkdir -p "$out"

# Scratch space for staging, gone when the script exits.
work="$(mktemp -d "${TMPDIR:-/tmp}/jeansh-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT

step "Jeansh $label ($mode):$targets"
printf 'Flutter: %s\n' "$(flutter --version 2>/dev/null | head -1)"
printf 'Output:  %s\n' "$out"

# ---------------------------------------------------------------- linux

check_linux() {
  local missing=""
  local tool
  for tool in clang++ cmake ninja pkg-config; do
    command -v "$tool" >/dev/null || missing="$missing $tool"
  done
  local lib
  for lib in gtk+-3.0 libsecret-1; do
    pkg-config --exists "$lib" 2>/dev/null || missing="$missing $lib"
  done
  [ -z "$missing" ] || die "missing for the Linux build:$missing
  sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libsecret-1-dev"
}

build_linux() {
  check_linux
  local arch
  case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "no Flutter Linux build for $(uname -m)" ;;
  esac
  step "Linux: flutter build linux --$mode"
  flutter build linux --"$mode" "${version_args[@]}"

  # One folder to unpack, named for the build, holding the bundle as Flutter
  # laid it out: jeansh beside data/ and lib/, which it finds relative to
  # itself.
  local name="jeansh-$label"
  rm -rf "${work:?}/$name"
  cp -a "build/linux/$arch/$mode/bundle" "$work/$name"
  tar -C "$work" -czf "$out/$APP_NAME-$label-linux-$arch.tar.gz" "$name"
}

# ---------------------------------------------------------------- windows

# A command for PowerShell on the Windows side, passed encoded so no quote in
# it is read twice on the way through WSL. No progress records: written to a
# pipe, they come out as a screenful of XML.
powershell() {
  powershell.exe -NoProfile -NonInteractive -EncodedCommand \
    "$(printf '%s' "\$ProgressPreference = 'SilentlyContinue'
$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" | tr -d '\r'
}

# [1] as a PowerShell string literal: in single quotes, which take nothing but
# a doubled quote as special.
psq() { printf "'%s'" "${1//\'/\'\'}"; }

build_windows() {
  [ "$wsl" = 1 ] || die "the Windows build runs from WSL, on the Windows machine itself"
  command -v powershell.exe >/dev/null ||
    die "powershell.exe not found: WSL interop is off (see [interop] in /etc/wsl.conf)"

  local flutter_bat="${FLUTTER_WINDOWS:-}"
  if [ -z "$flutter_bat" ]; then
    flutter_bat="$(powershell '(Get-Command flutter.bat -ErrorAction SilentlyContinue).Source' | head -1)"
  fi
  [ -n "$flutter_bat" ] && [ -f "$(wslpath -u "$flutter_bat")" ] ||
    die "no Flutter on the Windows side${flutter_bat:+ at $flutter_bat}. Install Flutter for
  Windows (https://docs.flutter.dev/get-started/install/windows, the same
  version as here, $(flutter --version 2>/dev/null | head -1 | cut -d' ' -f2)) and put its bin folder on the Windows PATH,
  or set FLUTTER_WINDOWS to its flutter.bat"

  local vs
  vs="$(powershell '& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath' 2>/dev/null | head -1)"
  [ -n "$vs" ] || die "no Visual Studio with the C++ tools on the Windows side. Install Visual
  Studio 2022 or its Build Tools with the \"Desktop development with C++\" workload"

  local local_app_data
  local_app_data="$(powershell '$env:LOCALAPPDATA' | head -1)"
  local wsrc="$local_app_data\\Jeansh\\build\\src"
  local src
  src="$(wslpath -u "$wsrc")"
  step "Windows: copying the tree to $wsrc"
  mkdir -p "$src"
  rsync -a --delete \
    --exclude /.git/ --exclude /build/ --exclude /dist/ --exclude /.dart_tool/ \
    --exclude /.fvm/ --exclude /.idea/ --exclude /.flutter-plugins-dependencies \
    --exclude '/*/flutter/ephemeral/' --exclude /android/ --exclude /ios/ \
    --exclude /macos/ --exclude /linux/ \
    "$ROOT/" "$src/"

  # The same defines as the Linux build, written out here because this build
  # goes through PowerShell rather than through version_args.
  local defines
  defines="--dart-define $(psq "JEANSH_VERSION=$label")"
  [ -z "${JEANSH_UPDATE_HOST:-}" ] ||
    defines="$defines --dart-define $(psq "JEANSH_UPDATE_HOST=$JEANSH_UPDATE_HOST")"
  [ -z "${JEANSH_SENTRY_DSN:-}" ] ||
    defines="$defines --dart-define $(psq "JEANSH_SENTRY_DSN=$JEANSH_SENTRY_DSN")"

  step "Windows: flutter build windows --$mode (Flutter $flutter_bat, Visual Studio $vs)"
  # Each line Flutter writes to stderr turned back into plain text: redirected,
  # PowerShell would wrap them as errors.
  # SENTRY_NATIVE_BACKEND is read by CMake, and an exported variable in this
  # shell does not cross into PowerShell, so it is set there as well.
  powershell "Set-Location -LiteralPath $(psq "$wsrc")
\$env:SENTRY_NATIVE_BACKEND = $(psq "${SENTRY_NATIVE_BACKEND:-none}")
& $(psq "$flutter_bat") build windows --$mode --build-name $(psq "$build_name") --build-number $(psq "$build_number") $defines 2>&1 | ForEach-Object { \"\$_\" }
exit \$LASTEXITCODE"

  local built="$src/build/windows/x64/runner/$config"
  [ -f "$built/$APP_NAME.exe" ] || die "no $APP_NAME.exe in $built"
  local name="Jeansh-$label"
  rm -rf "${work:?}/$name"
  cp -a "$built" "$work/$name"
  (cd "$work" && zip -qr "$out/$APP_NAME-$label-windows-x64.zip" "$name")
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
    linux) build_linux ;;
    windows) build_windows ;;
  esac
done

(cd "$out" && rm -f SHA256SUMS && sha256sum -- * >SHA256SUMS)

step "Done: $out"
ls -lh "$out"
