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
# Validate access and the live modules even if the native loader published the
# property. This also makes UI retries use the same device-specific load path.
/system/bin/sh /vendor/bin/aera-post-decrypt-modules.sh || fail "Primary userdata or deferred modules are not ready."
[ "$(getprop post.decrypt.modules)" = true ] || fail "Primary userdata stage is incomplete."

slot=$(getprop ro.boot.slot_suffix)
case "$slot" in
    _a|_b) ;;
    *) fail "Missing or invalid Houji modem slot: $slot." ;;
esac

# Prepare the same recovery-only MAC as Wlan::Init before CNSS starts the chip.
# Shared module completion must not wait for the later core Wi-Fi restore path.
mac_identity=
if [ ! -d /sys/class/net/wlan0 ]; then
    umask 022
    ini=/vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini
    mac=/vendor/firmware/wlan/qca_cld/kiwi_v2/wlan_mac.bin
    [ ! -L "$mac" ] || fail "Kiwi MAC target is an unexpected symlink."
    ini_target=$(readlink -f "$ini") || fail "Cannot resolve the Kiwi INI."
    mac_parent=$(readlink -f "${mac%/*}") || fail "Cannot resolve the Kiwi MAC directory."
    [ -d "$mac_parent" ] || fail "The recovery Kiwi MAC directory is unavailable."
    # Reject covering ROM mounts, including descendants of /vendor. Never write
    # an installed partition or the separate read-only firmware/calibration view.
    for target in "$ini_target" "$mac_parent/${mac##*/}"; do
        awk -v t="$target" '
            $5 == "/" || $5 == t || index(t, $5 "/") == 1 {
                if (length($5) > depth) {
                    depth=length($5); count=1; flags=$6; device=$3; fs=""
                    for (i=7; i<=NF; i++) if ($i == "-") {fs=$(i+1); break}
                } else if (length($5) == depth) count++
            }
            END {exit !(count == 1 && device ~ /^0:/ && flags ~ /(^|,)rw(,|$)/ &&
                (fs == "rootfs" || fs == "tmpfs" || fs == "ramfs"))}
        ' /proc/self/mountinfo || fail "WLAN configuration is not in writable recovery RAM: $target."
    done
    # Pin the directory across public /vendor mount changes; verify the object
    # actually opened before any write, including a race at directory open.
    exec 9< "$mac_parent" || fail "Cannot pin the recovery Kiwi MAC directory."
    mac_dir=/proc/self/fd/9
    mac_fs=$(stat -f -c %t "$mac_dir") || fail "Cannot verify the pinned MAC filesystem."
    case "$mac_fs" in
        1021994|858458f6) ;; # TMPFS_MAGIC / RAMFS_MAGIC
        *) fail "The pinned Kiwi MAC directory is not recovery RAM." ;;
    esac
    mac_file=$mac_dir/${mac##*/}
    grep -qx 'read_mac_addr_from_mac_file=1' "$ini" || fail "Kiwi MAC-file configuration is unavailable."
    serial=$(getprop ro.serialno)
    [ -n "$serial" ] || serial=$(getprop ro.boot.serialno)
    [ -n "$serial" ] || fail "Device serial is unavailable for the recovery WLAN MAC."
    bytes=$(printf 'AERA-WLAN-v1:%s' "$serial" | busybox od -An -v -tu1) || fail "Cannot read WLAN MAC input bytes."
    # Exact FNV-1a using two 32-bit words; all awk intermediates fit in 53 bits.
    address=$(printf '%s\n' "$bytes" | awk '
        function xor_byte(value, byte, low, result, bit) {
            low=value%256; result=value-low
            for (bit=1; bit<256; bit*=2) {
                if (low%2 != byte%2) result+=bit
                low=int(low/2); byte=int(byte/2)
            }
            return result
        }
        BEGIN {hi=342167472; lo=1939669891; word=4294967296}
        {
            for (i=1; i<=NF; i++) {
                lo=xor_byte(lo, $i); product=lo*435
                hi=(hi*435 + lo*256 + int(product/word))%word
                lo=product%word
            }
        }
        END {
            if (NR == 0) exit 1
            printf "02%02X%02X%02X%02X%02X\n", lo%256, int(lo/256)%256,
                int(lo/65536)%256, int(lo/16777216)%256, hi%256
        }') || fail "Cannot derive the recovery WLAN MAC."
    printf '%s\n' "$address" | grep -Eq '^02[[:xdigit:]]{10}$' || fail "Invalid recovery WLAN MAC."
    mac_tmp=$(mktemp "$mac_file.XXXXXX") || fail "Cannot stage the recovery Kiwi MAC."
    trap 'rm -f "$mac_tmp"' EXIT
    trap 'exit 2' HUP INT TERM
    printf 'Intf0MacAddress=%s\nEND\n' "$address" > "$mac_tmp" &&
        chmod 0644 "$mac_tmp" && busybox mv -fT "$mac_tmp" "$mac_file" || fail "Cannot publish the recovery Kiwi MAC."
    [ -f "$mac_file" ] && [ ! -L "$mac_file" ] || fail "Prepared Kiwi MAC is not a regular file."
    mac_identity=$(stat -L -c '%d:%i' "$mac_file") || fail "Cannot identify the prepared Kiwi MAC."
    log "Prepared deterministic Kiwi MAC before CNSS2 fs_ready."
fi
firmware=/vendor/firmware_mnt/image/kiwi
cnss_ready=false
attempts=0
reason="Kiwi firmware has not been verified."

while [ "$attempts" -lt 30 ]; do
    [ "$(getprop post.decrypt.modules)" = true ] || fail "Primary userdata stage was reset."
    modem_device=$(readlink -f "/dev/block/bootdevice/by-name/modem$slot")
    firmware_ready=false
    # CNSS selects the firmware files for the detected chip after fs_ready.
    # A separate m3.bin is not a prerequisite for signaling that the filesystem
    # is ready. Firmware/calibration failures must still keep wifi.driver.ready
    # false until the driver creates wlan0.
    if [ -b "$modem_device" ] &&
        readonly_mount "$firmware" /image/kiwi vfat "$modem_device" &&
        [ -d "$firmware" ] && [ -r "$firmware" ] && [ -x "$firmware" ]; then
        firmware_ready=true
    fi

    if [ "$firmware_ready" != true ]; then
        reason="No accessible slot-matched read-only Kiwi firmware bind."
    elif ! [ -r /vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini ] ||
        ! [ -s /vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini ]; then
        reason="The Houji Kiwi INI is unavailable."
    else
        if [ -n "$mac_identity" ]; then
            current_mac=$(stat -L -c '%d:%i' "$mac" 2>/dev/null) || fail "The public Kiwi MAC is unavailable."
            [ "$current_mac" = "$mac_identity" ] || fail "The public Kiwi MAC view changed before CNSS readiness."
        fi
        # A UI retry may find an already initialized interface; do not signal it twice.
        if [ -d /sys/class/net/wlan0 ]; then
            [ "$(getprop post.decrypt.modules)" = true ] || fail "Primary userdata stage was reset."
            setprop wifi.driver.ready true || fail "Cannot publish driver readiness."
            [ "$(getprop wifi.driver.ready)" = true ] || fail "Driver readiness readback failed."
            log "Verified active-slot Kiwi mount, AERA WLAN configuration and wlan0."
            exit 0
        fi
        if [ "$cnss_ready" = false ]; then
            # Use Houji's stock endpoint first; retain the device-path fallback.
            for ready in /sys/kernel/cnss/fs_ready /sys/bus/platform/drivers/cnss2/*/fs_ready; do
                [ -w "$ready" ] || continue
                printf '1\n' >"$ready" || fail "Cannot signal CNSS2 at $ready."
                cnss_ready=true
                log "Signaled CNSS2 fs_ready at $ready; waiting for calibration and wlan0."
                break
            done
        fi
        reason="Waiting for a writable bound CNSS2 fs_ready endpoint and wlan0 (cnss=$cnss_ready)."
    fi
    attempts=$((attempts + 1))
    sleep 1 || fail "Readiness wait failed."
done

fail "Timed out after 30s: $reason Check dmesg for CNSS/firmware errors."
