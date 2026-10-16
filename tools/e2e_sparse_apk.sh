#!/usr/bin/env bash
# JEANSH-8's device-split APKs, the way Play serves them, with the base's
# drawable type written sparse.
#
# A single monolithic APK cannot carry this bug: the type chunk
# LoadedPackage::FindEntryByName reads past its end is sparse only when its
# entry ids have gaps, and `aapt2 optimize` strips configs, never whole
# entries, so it makes none. The gaps are bundletool's: splitting the bundle
# by density leaves the density-dependent drawables (ic_stat_jeansh among them)
# out of the base, so their id slots there are empty -- a sparse type once
# encoded. So this builds the per-device split set from the AAB, then forces
# the base's table sparse with `aapt2 optimize --force-sparse-encoding`, which
# is SparseEntriesMode::Forced: it skips the minSdk>=S_V2 gate (the app's
# minSdk is 24) but still needs those gaps, which the split has made.
#
# Usage: tools/e2e_sparse_apk.sh <app.aab> <out-dir>
# Leaves <out-dir>/splits/*.apk, all signed with one throwaway key, ready for
# `adb install-multiple`.
set -euo pipefail

aab=$1
out=$2
sdk=${ANDROID_HOME:?ANDROID_HOME is not set}
cache=${HOME}/.e2e-jeansh8
mkdir -p "$out/splits" "$cache"

BUNDLETOOL_VERSION=1.17.2
bundletool=$cache/bundletool-$BUNDLETOOL_VERSION.jar
if [ ! -f "$bundletool" ]; then
  curl -Ls -o "$bundletool" \
    "https://github.com/google/bundletool/releases/download/$BUNDLETOOL_VERSION/bundletool-all-$BUNDLETOOL_VERSION.jar"
fi
echo "bundletool: $(java -jar "$bundletool" version 2>&1 | head -1)"

# One throwaway key for the whole split set: install-multiple refuses splits
# that are not all signed alike.
ks=$cache/e2e.jks
if [ ! -f "$ks" ]; then
  keytool -genkeypair -keystore "$ks" -storepass android -keypass android \
    -alias e2e -keyalg RSA -keysize 2048 -validity 1 -dname CN=e2e >/dev/null 2>&1
fi

# The device the robot ran on: Android 11, xxhdpi, x86_64, English.
spec=$out/device-spec.json
cat >"$spec" <<'JSON'
{
  "supportedAbis": ["x86_64"],
  "supportedLocales": ["en"],
  "screenDensity": 480,
  "sdkVersion": 30
}
JSON

# The split set, signed, then just this device's splits pulled out of it.
java -jar "$bundletool" build-apks --bundle="$aab" --output="$out/app.apks" \
  --ks="$ks" --ks-pass=pass:android --ks-key-alias=e2e --key-pass=pass:android \
  --overwrite
rm -f "$out"/splits/*.apk
java -jar "$bundletool" extract-apks --apks="$out/app.apks" \
  --output-dir="$out/splits" --device-spec="$spec"
echo "splits for the device:"
ls -1 "$out/splits" | sed 's/^/    /'

base=$(ls "$out"/splits/*base-master*.apk 2>/dev/null | head -1)
[ -n "$base" ] || base=$(ls "$out"/splits/base-master.apk "$out"/splits/*base*.apk 2>/dev/null | head -1)
[ -n "$base" ] || { echo "::error::no base split among the extracted APKs"; exit 1; }
echo "base split: $(basename "$base")"

# The newest build-tools whose aapt2 takes --force-sparse-encoding, found by
# running it rather than reading its help, since the switch is not listed
# there. On a clean run (exit 0) that also changed the table, it is the one.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
before=$(unzip -p "$base" resources.arsc 2>/dev/null | sha256sum | cut -c1-16)
aapt2=
for d in $(ls -d "$sdk"/build-tools/*/ 2>/dev/null | sort -rV); do
  if "$d/aapt2" optimize --force-sparse-encoding -o "$work/try.apk" "$base" >"$work/err" 2>&1; then
    after=$(unzip -p "$work/try.apk" resources.arsc 2>/dev/null | sha256sum | cut -c1-16)
    if [ "$before" != "$after" ]; then
      aapt2=$d/aapt2
      echo "aapt2: build-tools $(basename "$d") forces sparse, arsc $before -> $after"
      break
    fi
    echo "build-tools $(basename "$d"): --force-sparse-encoding left the table as it was"
  else
    echo "build-tools $(basename "$d"): aapt2 rejected --force-sparse-encoding ($(tail -1 "$work/err"))"
  fi
done
[ -n "$aapt2" ] || {
  echo "::error::no installed aapt2 both accepts --force-sparse-encoding and changes the table"
  echo "::error::(the flag is SparseEntriesMode::Forced, recent in frameworks/base; the runner's build-tools may predate it)"
  exit 1
}

"$aapt2" optimize --force-sparse-encoding -o "$work/base-sparse.apk" "$base"

# A look at whether a sparse type landed, for the log. Not a gate: the marker
# string aapt2 prints is version-specific, and the device run below is the real
# proof -- a false "still dense" here would hide a true repro on every branch.
# The table did change (checked above), which forcing only does by sparse-
# encoding something.
sparse=$("$aapt2" dump resources "$work/base-sparse.apk" 2>/dev/null | grep -ciE "sparse" || true)
echo "lines mentioning sparse in dump resources: $sparse"
"$aapt2" dump chunks "$work/base-sparse.apk" 2>/dev/null | grep -iE "sparse|flags.*0x0*1" | head -5 || true
[ "$sparse" -gt 0 ] || echo "::warning::no sparse marker in dump resources; relying on the device run to show the crash"

# zipalign (API 11 refuses a misaligned resources.arsc) and re-sign, keeping
# the base's split name.
tools=$(dirname "$aapt2")
"$tools/zipalign" -p -f 4 "$work/base-sparse.apk" "$work/base-aligned.apk"
"$tools/apksigner" sign --ks "$ks" --ks-pass pass:android --ks-key-alias e2e \
  --out "$base" "$work/base-aligned.apk"
"$tools/apksigner" verify "$base"
echo "base split re-written sparse and re-signed: $(basename "$base")"
