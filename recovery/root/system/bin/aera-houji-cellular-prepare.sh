#!/system/bin/sh
. /system/bin/aera-houji-common.sh

# QWES reads factory PFM licenses here. The early /tmp/persist bind can still
# refer to the empty ramdisk directory when the real persist mount arrives.
# Reuse the dedicated read-only factory mount; never create or alter licenses.
mount_ro /dev/block/bootdevice/by-name/persist /mnt/aera-wlan-persist ext4
[ -d /mnt/aera-wlan-persist/data/pfm/licenses ] || fail 'Factory modem license directory is unavailable.'
bind_ro /mnt/aera-wlan-persist/data/pfm/licenses /mnt/vendor/persist/data/pfm/licenses
log 'Factory PFM licenses exposed read-only for the modem.'
