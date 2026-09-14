#!/bin/sh
# Builds the bundle to upload to Google Play, signed with the upload key:
#   tool/release.sh [--name X.Y.Z]
# --name first sets the version name in pubspec.yaml, keeping the build
# number; commit that after. The build number is whatever the pre-commit hook
# last made it, and Play takes each one only once.
set -eu
cd "$(dirname "$0")/.."

die() { echo "release: $*" >&2; exit 1; }
usage() { die "usage: tool/release.sh [--name X.Y.Z]"; }

name=
case $# in
  0) ;;
  2) [ "$1" = --name ] || usage
     name=$2
     printf '%s\n' "$name" | grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' || usage ;;
  *) usage ;;
esac

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
  sed "s/^version:[^+]*+/version: $name+/" pubspec.yaml > pubspec.yaml.tmp
  mv pubspec.yaml.tmp pubspec.yaml
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
[ -z "$name" ] || echo "pubspec.yaml now says $name: commit it, git commit -m 'Version $name' pubspec.yaml"
