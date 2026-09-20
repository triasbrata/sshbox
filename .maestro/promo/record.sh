#!/bin/sh
# Records one promo shot: screenrecord runs around a Maestro flow, at the same
# quality as the other promo clips (2560x1600, 16 Mbps, touches shown).
#
#   sh .maestro/promo/record.sh <shot> [out-dir]     e.g. record.sh db-edit
#
# Only ever the emulator: these flows change demo data and app tabs.
set -e
shot=$1
out=${2:-$HOME/jeansh-promo/footage/raw}
dev=emulator-5554
dir=$(dirname "$0")
adb -s $dev shell settings put system show_touches 1
adb -s $dev shell screenrecord --bit-rate 16000000 --time-limit 60 /sdcard/$shot.mp4 &
rec=$!
sleep 1
status=0
~/.maestro/bin/maestro --device $dev test "$dir/$shot.yaml" || status=$?
sleep 1
adb -s $dev shell pkill -INT screenrecord || true
wait $rec || true
adb -s $dev pull /sdcard/$shot.mp4 "$out/$shot.mp4"
adb -s $dev shell rm /sdcard/$shot.mp4
adb -s $dev shell settings delete system show_touches
exit $status
