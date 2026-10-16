#!/usr/bin/env bash
# JEANSH-8 on Android 11: install the device-split set tools/e2e_sparse_apk.sh
# made (its base written sparse), cold-launch past the first-run slides, and
# see whether starting the local notifications kills the app.
#
# Every verdict prints ✅ or ❌, and any ❌ fails the step:
#   - the app is alive 10 s after notifications started (pidof);
#   - no SIGSEGV is in the log, and nothing names FindEntryByName;
#   - flutter_local_notifications finished its initialize: it writes the icon
#     it was given to notification_plugin_cache.xml right after its
#     getIdentifier check, so that file is there only if the lookup returned,
#     and on the fix the icon is a number.
# A failure that is JEANSH-8 itself also prints `repro:`, so a red run on an
# unfixed build can be told from a red run for any other reason.
#
# Usage: tools/e2e_api30.sh <splits-dir>
set -uo pipefail

PKG=cloud.brata.terminal
splits=${1:-build/e2e-api30/splits}
fail=0
ok() { echo "✅ $*"; }
bad() { echo "❌ $*"; fail=1; }

adb wait-for-device
echo "device: Android $(adb shell getprop ro.build.version.release | tr -d '\r'), API $(adb shell getprop ro.build.version.sdk | tr -d '\r'), $(adb shell getprop ro.product.cpu.abi | tr -d '\r')"

apks=("$splits"/*.apk)
[ -e "${apks[0]}" ] || { echo "❌ no split APKs in $splits"; exit 1; }
echo "installing ${#apks[@]} splits: $(basename -a "${apks[@]}" | tr '\n' ' ')"
adb install-multiple -r -t "${apks[@]}" || { echo "❌ install-multiple failed"; exit 1; }

# Past the first-run slides, which hold the notifications back until they are
# done (app.dart's _startNotifications): the flag OnboardingDone reads.
printf '%s\n' \
  "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>" \
  '<map><boolean name="flutter.sshbox.onboarding.done" value="true" /></map>' |
  adb shell 'cat > /data/local/tmp/e2e-api30-prefs.xml'
adb shell "run-as $PKG sh -c 'mkdir -p shared_prefs && cp /data/local/tmp/e2e-api30-prefs.xml shared_prefs/FlutterSharedPreferences.xml'"
adb shell rm -f /data/local/tmp/e2e-api30-prefs.xml

adb logcat -b all -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

# Until the plugin's initialize has written its cache, or the process is gone
# (a debug build's first start is slow, so up to 60 s), then 10 s more.
cache=
for _ in $(seq 1 60); do
  cache=$(adb shell "run-as $PKG cat shared_prefs/notification_plugin_cache.xml" 2>/dev/null | tr -d '\r')
  case $cache in *defaultIcon*) break ;; esac
  cache=
  sleep 1
  if [ -z "$(adb shell pidof "$PKG" | tr -d '\r')" ] &&
    adb logcat -d -b all | grep -q "Process $PKG (pid"; then
    break
  fi
done
sleep 10

pid=$(adb shell pidof "$PKG" | tr -d '\r')
log=$(adb logcat -d -b all)

if [ -n "$pid" ]; then ok "app alive 10 s after notifications started (pid $pid)"; else bad "app not running 10 s after launch"; fi

crash=$(printf '%s\n' "$log" | grep -E "Fatal signal 11|SIGSEGV" | head -5)
frame=$(printf '%s\n' "$log" | grep -E "FindEntryByName" | head -5)
if [ -z "$crash" ] && [ -z "$frame" ]; then
  ok "no SIGSEGV and no FindEntryByName in logcat"
else
  bad "native crash in logcat:"
  printf '%s\n' "$crash" "$frame" | sed '/^$/d; s/^/    /'
  if [ -n "$crash" ] && [ -n "$frame" ]; then
    echo "repro: SIGSEGV in LoadedPackage::FindEntryByName reproduced (JEANSH-8)"
    printf '%s\n' "$log" | grep -E "F DEBUG|#[0-9]{2} pc" | head -25 | sed 's/^/    /'
  fi
fi

icon=$(printf '%s\n' "$cache" | sed -n 's/.*name="defaultIcon">\([^<]*\)<.*/\1/p')
if [ -z "$cache" ]; then
  bad "flutter_local_notifications never finished initialize (no notification_plugin_cache.xml)"
elif [[ $icon =~ ^[0-9]+$ ]]; then
  ok "notifications initialised with the icon by id: defaultIcon=$icon"
else
  bad "notifications initialised with the icon by name: defaultIcon=$icon"
fi

sessions=$(adb shell dumpsys notification | tr -d '\r' | grep -c "mName=Sessions")
echo "info: Sessions channels in dumpsys notification: $sessions (made only when the app first posts)"

adb shell am force-stop "$PKG"
exit $fail
