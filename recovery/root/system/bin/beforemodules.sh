#!/system/bin/sh
# AERA's existing synchronous pre-module hook. Repair only a temporary copy of
# the installed metadata, then bind it over the read-only source before parsing.
fail() {
    printf 'E:houji-beforemodules::%s\n' "$*" >> /tmp/recovery.log
    exit 1
}

slot=$(getprop ro.boot.slot_suffix)
case "$slot" in _a|_b) ;; *) fail 'Missing active slot.' ;; esac
block=/dev/block/mapper/vendor_dlkm$slot
[ -b "$block" ] || block=/dev/block/mapper/vendor_dlkm
[ -b "$block" ] || fail 'The active vendor_dlkm mapping is unavailable.'
block=$(readlink -f "$block") || fail 'Cannot resolve vendor_dlkm.'

if ! awk '$2 == "/vendor_dlkm" {found=1} END {exit !found}' /proc/mounts; then
    mkdir -p /vendor_dlkm || fail 'Cannot create the vendor_dlkm mount point.'
    mount -t erofs -o ro "$block" /vendor_dlkm 2>/dev/null ||
        mount -t ext4 -o ro,noload "$block" /vendor_dlkm || fail 'Cannot mount vendor_dlkm read-only.'
fi
record=$(awk '$2 == "/vendor_dlkm" {print $1, $3, $4}' /proc/mounts)
set -- $record
[ "$#" -eq 3 ] && [ "$(readlink -f "$1")" = "$block" ] || fail 'vendor_dlkm mount does not match the active mapping.'
case "$2" in erofs|ext4) ;; *) fail 'Unexpected vendor_dlkm filesystem.' ;; esac
case ",$3," in *,ro,*) ;; *) fail 'vendor_dlkm is not mounted read-only.' ;; esac

source=/vendor_dlkm/lib/modules/modules.softdep
[ -f "$source" ] || exit 0
grep -qx 'softdep mpam_policy mpam_policy pre: mpam_arch' "$source" || exit 0
fixed=/tmp/aera-vendor-dlkm.softdep
sed 's/^softdep mpam_policy mpam_policy pre: mpam_arch$/softdep mpam_policy pre: mpam_arch/' \
    "$source" > "$fixed" || fail 'Cannot prepare corrected module metadata.'
chmod 0400 "$fixed" || fail 'Cannot protect corrected module metadata.'
mount -o bind "$fixed" "$source" || fail 'Cannot bind corrected module metadata.'
mount -o remount,bind,ro "$source" || fail 'Cannot make the metadata bind read-only.'
printf 'I:houji-beforemodules::Corrected the mpam_policy softdep token in a temporary read-only bind.\n' >> /tmp/recovery.log
# Leave this mount for the native loader, which detaches vendor_dlkm afterwards.
