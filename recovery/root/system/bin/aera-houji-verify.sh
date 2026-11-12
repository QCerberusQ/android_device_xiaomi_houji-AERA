#!/system/bin/sh
# Read-only snapshot after audio preparation and settled UI connect/disconnect.
PATH=/system/bin:/vendor/bin:/sbin
export PATH
result=0
bad() { printf 'FAIL: %s\n' "$*"; result=1; }

source=/mnt/aera-wlan-persist/data/pfm/licenses
target=/mnt/vendor/persist/data/pfm/licenses
qsee_pid=$(getprop init.svc_debug_pid.vendor.qseecomd)
case "$qsee_pid" in
    ''|0|*[!0-9]*) bad 'QSEE listener PID is unavailable.' ;;
    *)
        view=/proc/$qsee_pid/root$target
        source_id=$(stat -c '%d:%i' "$source" 2>/dev/null)
        view_id=$(stat -c '%d:%i' "$view" 2>/dev/null)
        if [ -d "$view" ] && [ -n "$source_id" ] && [ "$source_id" = "$view_id" ]; then
            printf 'PASS: QSEE PID %s sees factory PFM directory %s.\n' "$qsee_pid" "$view_id"
        else
            bad 'QSEE PFM view is missing or differs from factory persist.'
        fi
        awk -v t="$target" '$2 == t {print "QSEE PFM mount: " $1 " -> " $2 " (" $4 ")"}' /proc/$qsee_pid/mounts
        ;;
esac

source=/vendor/aera-audio-abi/libaudiofeaturestats.so
target=/vendor/lib64/libaudiofeaturestats.so
source_id=$(stat -c '%d:%i' "$source" 2>/dev/null)
target_id=$(stat -c '%d:%i' "$target" 2>/dev/null)
if [ -s "$source" ] && [ -n "$source_id" ] && [ "$source_id" = "$target_id" ]; then
    printf 'PASS: bundled audio statistics library is bound at %s.\n' "$target"
else
    bad 'Bundled audio statistics library is missing or not bound.'
fi
audio_pid=$(getprop init.svc_debug_pid.aera-stock-audio-hal)
case "$audio_pid" in
    ''|0|*[!0-9]*) bad 'Audio HAL PID is unavailable.' ;;
    *)
        if grep -F 'libaudiofeaturestats.so' /proc/$audio_pid/maps; then
            printf 'PASS: audio HAL PID %s currently maps the statistics library.\n' "$audio_pid"
        else
            bad 'Statistics library is not observed in audio HAL maps; play audio and rerun.'
        fi
        ;;
esac

found=0
mss_state=
for node in /sys/class/remoteproc/remoteproc*; do
    [ -r "$node/name" ] || continue
    case "$(cat "$node/name")" in
        *remoteproc-mss|mss)
            found=$((found + 1))
            mss_state=$(cat "$node/state")
            printf 'MSS: %s state=%s recovery=%s\n' "$node" "$mss_state" "$(cat "$node/recovery")"
            ;;
    esac
done
[ "$found" = 1 ] || bad 'Expected exactly one MSS remote processor.'
printf 'Provider service: %s\n' "$(getprop init.svc.aera-houji-cellular)"
if [ -r /tmp/aera-cellular/status.json ]; then
    snapshot=$(cat /tmp/aera-cellular/status.json)
    printf '%s\n' "$snapshot"
    if printf '%s\n' "$snapshot" | grep -Eq '"connected"[[:space:]]*:[[:space:]]*true'; then
        [ "$mss_state" = running ] || bad 'Provider reports connected while MSS is not running.'
    fi
    if printf '%s\n' "$snapshot" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"off"'; then
        [ "$mss_state" = offline ] || bad 'Provider reports off while MSS is not offline.'
    fi
else
    bad 'Cellular provider status is unavailable.'
fi

printf 'Relevant log history (may include earlier failures):\n'
logcat -b all -d 2>/dev/null | grep -E 'DrmLibFs.*pfm/licenses|Smart Transmit License Check Failure|aera-cellular.*(MSS|DMS)'
exit "$result"
