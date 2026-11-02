#!/system/bin/sh
. /system/bin/aera-houji-common.sh

[ "$(getprop twrp.modules.loaded)" = true ] || fail 'Core module staging is incomplete.'
[ "$(getprop sys.usb.config.aera_fastbootd)" != 1 ] || exit 0
SLOT=$(getprop ro.boot.slot_suffix)
case "$SLOT" in _a|_b) ;; *) fail "Invalid active slot: $SLOT" ;; esac

mkdir -p "$STOCK_ROOT" || fail 'Cannot create audio runtime directory.'
for attempt in $(seq 1 300); do
    mkdir "$STOCK_ROOT/.audio-lock" 2>/dev/null && break
    [ "$attempt" != 300 ] || fail 'Audio initialization is still busy.'
    sleep 0.1
done
trap 'rmdir "$STOCK_ROOT/.audio-lock"' EXIT
trap 'exit 1' HUP INT TERM

# Let the core's temporary ROM mounts finish before adding ramdisk aliases.
for attempt in $(seq 1 100); do
    if ! awk '$2 == "/vendor" || $2 == "/odm" || $2 == "/system" {found=1}
             END {exit !found}' /proc/mounts; then
        break
    fi
    [ "$attempt" != 100 ] || fail 'Temporary ROM mounts still cover the audio runtime.'
    sleep 0.1
done
mount_ro "/dev/block/bootdevice/by-name/modem$SLOT" /firmware vfat
locators=0
for locator in /firmware/image/*.jsn; do
    [ -f "$locator" ] || continue
    bind_ro "$locator" "/vendor/firmware_mnt/image/${locator##*/}"
    locators=$((locators + 1))
done
[ "$locators" -gt 0 ] || fail 'Active-slot firmware has no PD service locators.'
start_service aera-houji-pd-mapper

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
case "$(cat "$adsp/state")" in
    offline)
        log 'PD mapper is running; requesting ADSP boot.'
        printf '1\n' > /sys/kernel/boot_adsp/boot || fail 'ADSP boot request failed.'
        # Preserve the device's existing USB/ADSP SSR configuration.
        if [ -e /sys/kernel/boot_adsp/ssr ]; then
            printf '1\n' > /sys/kernel/boot_adsp/ssr || fail 'Cannot configure ADSP SSR.'
        fi
        ;;
    running) log 'ADSP is already running; keeping its current session.' ;;
    *) fail 'ADSP is neither offline nor running.' ;;
esac
for attempt in $(seq 1 150); do
    [ "$(cat "$adsp/state")" = running ] && [ -e /sys/class/power_supply/battery ] && break
    [ "$attempt" != 150 ] || fail 'ADSP or battery did not become ready.'
    sleep 0.1
done
[ "$(getprop init.svc.aera-houji-pd-mapper)" = running ] || fail 'PD mapper stopped during ADSP boot.'
setprop vendor.houji.adsp.ready 1 || fail 'Cannot publish ADSP readiness.'
log 'ADSP and battery are ready with the PD mapper running.'
