#!/system/bin/sh
. /system/bin/aera-houji-common.sh
umask 022

MAPPER=/system/bin/aera-houji-pd-mapper
LIBDIR=/system/lib64/aera-pdmapper
READY_PROP=vendor.aera.pdmapper.ready
HAVE_LOCK=0
STARTED_MAPPER=0
ADSP_REQUESTED=0

cleanup() {
    [ "$HAVE_LOCK" = 0 ] || setprop "$READY_PROP" 0
    # Only undo a daemon started by this worker before an ADSP request.
    if [ "$STARTED_MAPPER" = 1 ] && [ "$ADSP_REQUESTED" = 0 ]; then
        setprop ctl.stop aera-houji-pd-mapper
    fi
    [ "$HAVE_LOCK" = 0 ] || rmdir "$STOCK_ROOT/.audio-lock"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$(getprop twrp.modules.loaded)" = true ] || fail 'Core module staging is incomplete.'
case "$(getprop ro.aera.fastbootd):$(getprop sys.usb.config.aera_fastbootd)" in
    1:*|true:*|*:1) exit 0 ;;
esac
# DFE may already publish post.decrypt.modules; ADSP still needs this worker.
SLOT=$(getprop ro.boot.slot_suffix)
case "$SLOT" in _a|_b) ;; *) fail "Invalid active slot: $SLOT" ;; esac

mkdir -p "$STOCK_ROOT" || fail 'Cannot create audio runtime directory.'
for attempt in $(seq 1 300); do
    mkdir "$STOCK_ROOT/.audio-lock" 2>/dev/null && break
    [ "$attempt" != 300 ] || fail 'Audio initialization is still busy.'
    sleep 0.1
done
HAVE_LOCK=1
setprop "$READY_PROP" 0 || fail 'Cannot reset mapper handoff.'

# Let the core's temporary ROM mounts finish before adding ramdisk aliases.
check_recovery_view() {
    ! awk '$2 == "/vendor" || $2 == "/odm" || $2 == "/system" {found=1}
           END {exit !found}' /proc/mounts
}
for attempt in $(seq 1 100); do
    check_recovery_view && break
    [ "$attempt" != 100 ] || fail 'Temporary ROM mounts still cover the audio runtime.'
    sleep 0.1
done
[ -x "$MAPPER" ] || fail 'Recovery PD mapper is unavailable.'
for library in libc++.so libjson.so libbase.so libcutils.so libutils.so \
               libqmi_cci.so libqmi_common_so.so libqmi_csi.so libqmi_encdec.so; do
    [ -r "$LIBDIR/$library" ] || fail "Missing private mapper library: $library"
done
[ -w /sys/kernel/boot_adsp/boot ] || fail 'ADSP boot node is unavailable.'
mount_ro "/dev/block/bootdevice/by-name/modem$SLOT" /firmware vfat
locators=0
for locator in /firmware/image/*.jsn; do
    [ -f "$locator" ] || continue
    bind_ro "$locator" "/vendor/firmware_mnt/image/${locator##*/}"
    locators=$((locators + 1))
done
[ "$locators" -gt 0 ] || fail 'Active-slot firmware has no PD service locators.'

adsp=
for node in /sys/class/remoteproc/remoteproc*; do
    [ -r "$node/name" ] || continue
    case "$(cat "$node/name")" in
        *remoteproc-adsp|adsp)
            [ -z "$adsp" ] || fail 'More than one ADSP remote processor.'
            adsp=$node
            ;;
    esac
done
[ -n "$adsp" ] || fail 'No ADSP remote processor.'
# A running ADSP may already depend on this mapper even if later checks fail.
[ "$(cat "$adsp/state")" != running ] || ADSP_REQUESTED=1
[ "$(getprop init.svc.aera-houji-pd-mapper)" = running ] || STARTED_MAPPER=1
start_service aera-houji-pd-mapper

mapper_pid() {
    local value
    value=$(getprop init.svc_debug_pid.aera-houji-pd-mapper)
    case "$value" in ''|*[!0-9]*) value=$(pidof aera-houji-pd-mapper) ;; esac
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$value"
}
PID=$(mapper_pid) || fail 'Cannot identify one mapper process.'
sleep 0.5
[ "$(getprop init.svc.aera-houji-pd-mapper)" = running ] &&
    [ "$(mapper_pid)" = "$PID" ] || fail 'Mapper changed during startup.'
[ "$(readlink /proc/$PID/exe)" = "$MAPPER" ] || fail 'Unexpected mapper executable.'
awk -v dir="$LIBDIR" -v root="/system" '
BEGIN {
    n=split("libc++.so libjson.so libbase.so libcutils.so libutils.so libqmi_cci.so libqmi_common_so.so libqmi_csi.so libqmi_encdec.so", libs, " ")
    for (i=1; i<=n; i++) wanted[dir "/" libs[i]]=1
}
$6 ~ /^\// && index($6, "/dev/") != 1 {
    if (index($6, root "/") != 1 || $4 !~ /^0+:/ || $7 == "(deleted)") bad=1
    if ($6 in wanted) seen[$6]=1
}
END {
    for (p in wanted) if (!(p in seen)) bad=1
    exit bad
}' /proc/$PID/maps || fail 'Mapper runtime is not wholly recovery-backed.'
log "Recovery-backed PD mapper verified; pid=$PID"
check_recovery_view || fail 'A temporary ROM mount appeared during mapper preparation.'
[ "$(getprop init.svc.aera-houji-pd-mapper)" = running ] &&
    [ "$(mapper_pid)" = "$PID" ] || fail 'Mapper changed during preparation.'
case "$(cat "$adsp/state")" in
    offline)
        # Keep the mapper if init may have received the boot request.
        ADSP_REQUESTED=1
        log 'Mapper checks passed; handing ADSP boot to init.'
        setprop "$READY_PROP" 1 || fail 'Cannot publish mapper handoff.'
        ;;
    running)
        ADSP_REQUESTED=1
        log 'ADSP is already running; keeping its current session.'
        ;;
    *) fail 'ADSP is neither offline nor running.' ;;
esac
for attempt in $(seq 1 150); do
    [ "$(cat "$adsp/state")" = running ] && [ -e /sys/class/power_supply/battery ] && break
    [ "$attempt" != 150 ] || fail 'ADSP or battery did not become ready.'
    sleep 0.1
done
[ "$(getprop init.svc.aera-houji-pd-mapper)" = running ] || fail 'PD mapper stopped during ADSP boot.'
[ "$(mapper_pid)" = "$PID" ] || fail 'PD mapper restarted during ADSP boot.'
setprop vendor.houji.adsp.ready 1 || fail 'Cannot publish ADSP readiness.'
log 'ADSP and battery are ready with the PD mapper running.'
