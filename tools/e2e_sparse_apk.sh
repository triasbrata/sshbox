#!/usr/bin/env bash
# JEANSH-8's APK: the debug build with every resource type table written
# sparse, as a Play-served APK can carry it, so that tools/e2e_api30.sh can
# cold-launch it on Android 11, where LoadedPackage::FindEntryByName reads a
# sparse type chunk past its end.
#
# `aapt2 optimize --enable-sparse-encoding` only touches configurations for
# API 26 and up while minSdk is below that, which leaves the default
# configuration dense; --force-sparse-encoding applies it whatever the minSdk.
# Not every build-tools' aapt2 has that switch, so the newest one installed
# that does is used, and build-tools 36.0.0 is installed if none does.
#
# Usage: tools/e2e_sparse_apk.sh <in.apk> <out.apk>
set -euo pipefail

in=$1
out=$2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sdk=${ANDROID_HOME:?ANDROID_HOME is not set}

# The newest build-tools whose aapt2 takes --force-sparse-encoding.
tools=
pick() {
  local d
  for d in $(ls -d "$sdk"/build-tools/*/ 2>/dev/null | sort -rV); do
    if "$d/aapt2" optimize -h 2>&1 | grep -q -- '--force-sparse-encoding'; then
      tools=${d%/}
      return 0
    fi
    echo "build-tools $(basename "$d"): aapt2 has no --force-sparse-encoding"
  done
  return 1
}
if ! pick; then
  echo "no installed aapt2 forces sparse encoding; installing build-tools 36.0.0"
  yes | "$sdk/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
  "$sdk/cmdline-tools/latest/bin/sdkmanager" --install "build-tools;36.0.0" >/dev/null
  pick || { echo "::error::build-tools 36.0.0's aapt2 has no --force-sparse-encoding either"; exit 1; }
fi
echo "aapt2: build-tools $(basename "$tools"), $("$tools/aapt2" version 2>&1 | head -1)"

"$tools/aapt2" optimize --force-sparse-encoding -o "$work/sparse.apk" "$in"

# The rewrite has to have changed the resource table, or the run below
# proves nothing about sparse tables.
before=$(unzip -p "$in" resources.arsc | sha256sum | cut -c1-16)
after=$(unzip -p "$work/sparse.apk" resources.arsc | sha256sum | cut -c1-16)
echo "resources.arsc: $before -> $after ($(unzip -p "$in" resources.arsc | wc -c) -> $(unzip -p "$work/sparse.apk" resources.arsc | wc -c) bytes)"
[ "$before" != "$after" ] || { echo "::error::aapt2 optimize left resources.arsc as it was"; exit 1; }
# What dump chunks says of sparse types, where this aapt2 can say it.
"$tools/aapt2" dump chunks "$work/sparse.apk" 2>/dev/null | grep -i -m5 sparse || true

# Android 11 refuses a resources.arsc that is compressed or not 4-aligned.
"$tools/zipalign" -p -f 4 "$work/sparse.apk" "$work/aligned.apk"
unzip -v "$work/aligned.apk" resources.arsc | grep -q ' Stored ' ||
  { echo "::error::resources.arsc is compressed"; exit 1; }

# A throwaway key: the APK is installed fresh and thrown away with the runner.
keytool -genkeypair -keystore "$work/k.jks" -storepass android -keypass android \
  -alias e2e -keyalg RSA -keysize 2048 -validity 1 -dname CN=e2e >/dev/null 2>&1
"$tools/apksigner" sign --ks "$work/k.jks" --ks-pass pass:android \
  --ks-key-alias e2e --out "$out" "$work/aligned.apk"
"$tools/apksigner" verify "$out"
echo "sparse APK ready: $(wc -c <"$out") bytes"
