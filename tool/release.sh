#!/bin/sh
# Builds the bundle to upload to Google Play, signed with the upload key, and
# with --publish releases it on a testing track:
#   tool/release.sh [--name X.Y] [--publish [--track alpha] [--dry-run] [--draft]]
# --name first sets X.Y of pubspec.yaml's version, X.Y.N+N, keeping the build
# number N; commit that after. N is whatever the pre-commit hook last made it,
# and Play takes each one only once.
# Without --publish nothing is uploaded: publishing is always something asked
# for, never a side effect of a build. tool/play_publish.py does that half, and
# --dry-run there does everything except the commit that reaches testers.
set -eu
cd "$(dirname "$0")/.."

die() { echo "release: $*" >&2; exit 1; }
usage() { die "usage: tool/release.sh [--name X.Y] [--publish [--track alpha] [--dry-run] [--draft]]"; }

name= publish= track= dry= draft=
while [ $# -gt 0 ]; do
  case $1 in
    --name) [ $# -ge 2 ] || usage
            name=$2; shift 2
            printf '%s\n' "$name" | grep -qxE '[0-9]+\.[0-9]+' || usage ;;
    --publish) publish=1; shift ;;
    --track) [ $# -ge 2 ] || usage; track=$2; shift 2 ;;
    --dry-run) dry=--dry-run; shift ;;
    --draft) draft=--draft; shift ;;
    *) usage ;;
  esac
done
[ -n "$publish" ] || [ -z "$track$dry$draft" ] ||
  die "--track, --dry-run and --draft only mean something with --publish"

# Without key.properties Gradle signs with the debug key, and Play refuses that.
props=android/key.properties
[ -f "$props" ] || die "no $props, so the bundle would be debug-signed: see README.md, Releasing"
store=$(sed -n 's/^[[:space:]]*storeFile[[:space:]]*[=:][[:space:]]*//p' "$props" | tr -d '\r' | head -n 1)
case $store in /*) ;; *) store=android/app/$store ;; esac # Gradle reads it from android/app
[ -f "$store" ] || die "the keystore $props names is not there: $store"

[ -z "$(git status --porcelain --untracked-files=no)" ] &&
  [ -z "$(git ls-files --others --exclude-standard -- lib android ios assets)" ] ||
  die "the working tree has changes: commit or stash them, so the bundle matches a commit"

if [ -n "$name" ]; then
  sed "s/^\(version:[^0-9]*\)[^+]*+\([0-9][0-9]*\)/\1$name.\2+\2/" pubspec.yaml > pubspec.yaml.tmp
  mv pubspec.yaml.tmp pubspec.yaml
fi

# The track and the service account key are checked here rather than after the
# build, for the same reason keytool is: a setup mistake should cost a second.
play_publish() { python3 tool/play_publish.py ${track:+--track} ${track:+"$track"} "$@"; }
if [ -n "$publish" ]; then
  command -v python3 >/dev/null || die "no python3, which tool/play_publish.py needs"
  play_publish --preflight
fi

# keytool checks the signer below. Gradle finds Java by itself, so keytool is
# often not on PATH: look where Flutter's Java is before a long build, not after.
keytool=$(command -v keytool || true)
if [ -z "$keytool" ] && [ -x "${JAVA_HOME:-}/bin/keytool" ]; then keytool=$JAVA_HOME/bin/keytool; fi
if [ -z "$keytool" ]; then
  keytool=$(flutter doctor -v 2>/dev/null | sed -n 's/.*Java binary at: \(.*\)\/java$/\1\/keytool/p' | head -n 1)
fi
[ -x "${keytool:-}" ] || die "no keytool: put the JDK's bin on PATH or set JAVA_HOME"

flutter build appbundle --release
aab=build/app/outputs/bundle/release/app-release.aab

# Also catches a key.properties that Gradle reads as empty, which falls back
# to the debug key just the same.
signer=$("$keytool" -printcert -jarfile "$aab" | sed -n 's/^Owner: //p' | head -n 1)
case $signer in '' | *'Android Debug'*) die "$aab is not signed with the upload key (signer: ${signer:-none})" ;; esac

local_prop() { sed -n "s/^flutter\.$1=//p" android/local.properties; }
echo
echo "AAB          $aab"
echo "versionName  $(local_prop versionName)"
echo "versionCode  $(local_prop versionCode)"
echo "signed by    $signer"
[ -z "$name" ] || echo "pubspec.yaml now says $(local_prop versionName): commit it, git commit -m 'Version $name' pubspec.yaml"
echo

[ -z "$publish" ] || play_publish $dry $draft "$aab"
