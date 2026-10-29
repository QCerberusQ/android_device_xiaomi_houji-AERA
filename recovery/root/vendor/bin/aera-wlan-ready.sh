#!/system/bin/sh

log() {
    printf 'I:aera-wlan-ready::%s\n' "$*" >>/tmp/recovery.log
}

fail() {
    setprop wifi.driver.ready false
    printf 'E:aera-wlan-ready::%s\n' "$*" >>/tmp/recovery.log
    exit 2
}

# Require an unambiguous mount, its bind root, filesystem, read-only flag and device.
# /proc/mounts alone cannot distinguish a Kiwi bind from a whole-modem mount.
readonly_mount() {
    mount_root=$2
    mount_type=$3
    mount_device=$4
    mount_record=$(awk -v target="$1" '
        $5 == target { record = $0; matches++ }
        END {
            if (matches != 1) exit 1
            n = split(record, field, " ")
            if (index("," field[6] ",", ",ro,") == 0) exit 1
            for (i = 7; i <= n; i++)
                if (field[i] == "-") {
                    print field[4], field[i + 1], field[i + 2]
                    exit 0
                }
            exit 1
        }' /proc/self/mountinfo) || return 1
    set -- $mount_record
    [ "$#" -eq 3 ] && [ "$1" = "$mount_root" ] && [ "$2" = "$mount_type" ] &&
        [ "$(readlink -f "$3")" = "$mount_device" ]
}

setprop wifi.driver.ready false || fail "Cannot clear driver readiness."
[ "$(getprop wifi.driver.ready)" = false ] || fail "Driver readiness clear did not persist."
[ "$(getprop post.decrypt.modules)" = true ] || fail "Primary userdata stage is incomplete."

slot=$(getprop ro.boot.slot_suffix)
case "$slot" in
    _a|_b) ;;
    *) fail "Missing or invalid Houji modem slot: $slot." ;;
esac
firmware=/vendor/firmware_mnt/image/kiwi
persist=/mnt/aera-wlan-persist
cnss_ready=false
attempts=0
reason="Firmware and calibration have not been verified."

while [ "$attempts" -lt 30 ]; do
    [ "$(getprop post.decrypt.modules)" = true ] || fail "Primary userdata stage was reset."
    modem_device=$(readlink -f "/dev/block/bootdevice/by-name/modem$slot")
    persist_device=$(readlink -f /dev/block/bootdevice/by-name/persist)
    firmware_ready=false
    if [ -b "$modem_device" ] &&
        readonly_mount "$firmware" /image/kiwi vfat "$modem_device"; then
        for amss in "$firmware/amss.bin" "$firmware/amss20.bin"; do
            [ -f "$amss" ] && [ -r "$amss" ] && [ -s "$amss" ] || continue
            [ -f "$firmware/m3.bin" ] && [ -r "$firmware/m3.bin" ] &&
                [ -s "$firmware/m3.bin" ] && firmware_ready=true
        done
    fi

    if [ "$firmware_ready" != true ]; then
        reason="No slot-matched read-only Kiwi bind with readable amss/m3 firmware."
    elif ! [ -b "$persist_device" ] ||
        ! readonly_mount "$persist" / ext4 "$persist_device" ||
        ! [ -r "$persist/wlan/wlan_mac.bin" ] || ! [ -s "$persist/wlan/wlan_mac.bin" ]; then
        reason="Live persist WLAN calibration is unavailable or its mount is unverified."
    elif ! [ -r /vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini ] ||
        ! [ -s /vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini ]; then
        reason="The Houji Kiwi INI is unavailable."
    else
        # A UI retry may find an already initialized interface; do not signal it twice.
        if [ -d /sys/class/net/wlan0 ]; then
            [ "$(getprop post.decrypt.modules)" = true ] || fail "Primary userdata stage was reset."
            setprop wifi.driver.ready true || fail "Cannot publish driver readiness."
            [ "$(getprop wifi.driver.ready)" = true ] || fail "Driver readiness readback failed."
            log "Verified Kiwi firmware, live calibration and wlan0."
            exit 0
        fi
        if [ "$cnss_ready" = false ]; then
            for ready in /sys/bus/platform/drivers/cnss2/*/fs_ready; do
                [ -w "$ready" ] || continue
                printf '1\n' >"$ready" || fail "Cannot signal CNSS2 at $ready."
                cnss_ready=true
            done
        fi
        reason="Waiting for a writable bound CNSS2 fs_ready endpoint and wlan0 (cnss=$cnss_ready)."
    fi
    attempts=$((attempts + 1))
    sleep 1 || fail "Readiness wait failed."
done

fail "Timed out after 30s: $reason Check dmesg and the module/kernel ABI."
