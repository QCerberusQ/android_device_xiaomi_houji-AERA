#!/system/bin/sh
. /system/bin/aera-houji-common.sh

# QWES reads factory PFM licenses here. The early /tmp/persist bind can still
# refer to the empty ramdisk directory when the real persist mount arrives.
# Reuse the dedicated read-only factory mount; never create or alter licenses.
mount_ro /dev/block/bootdevice/by-name/persist /mnt/aera-wlan-persist ext4
[ -d /mnt/aera-wlan-persist/data/pfm/licenses ] || fail 'Factory modem license directory is unavailable.'
bind_ro /mnt/aera-wlan-persist/data/pfm/licenses /mnt/vendor/persist/data/pfm/licenses
# Check the listener's view as well as the preparation process's mount.
if [ "${1:-}" != --before-qseecomd ]; then
    qsee_pid=$(getprop init.svc_debug_pid.vendor.qseecomd)
    case "$qsee_pid" in
        ''|0|*[!0-9]*) fail 'QSEE listener PID is unavailable; skipping modem startup.' ;;
    esac
    licenses=/proc/$qsee_pid/root/mnt/vendor/persist/data/pfm/licenses
    [ -d "$licenses" ] || fail 'QSEE listener cannot see factory PFM licenses; skipping modem startup.'
    [ "$(stat -c '%d:%i' /mnt/aera-wlan-persist/data/pfm/licenses)" = "$(stat -c '%d:%i' "$licenses")" ] ||
        fail 'QSEE listener sees a different PFM directory; skipping modem startup.'
fi
log 'Factory PFM licenses exposed read-only for the modem.'
