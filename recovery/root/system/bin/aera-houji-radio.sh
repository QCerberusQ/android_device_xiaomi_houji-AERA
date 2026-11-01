#!/system/bin/sh
# Native modem/HAL bring-up only. This is not an aera-cellular-provider:
# it does not unlock a SIM, choose an APN, establish a data call or install routes.
# Init's radio manager starts this supervisor automatically and requests shutdown
# through /tmp/aera-houji-radio-stop before AERA changes backing partitions.
. /system/bin/aera-houji-common.sh

require_data
[ "$(getprop post.decrypt.modules)" = true ] || fail 'Wait for the existing deferred WLAN/IPA loader.'

# AERA StorageLease takes this lock exclusively before flash/restore/wipe.
# Keep a shared lease for the entire native modem session, including shutdown.
exec 9> /tmp/aera-cellular-operation.lock
flock -s -n 9 || fail 'A storage operation is active.'
# Native daemons take read-only shared leases after init drops their uid.
chmod 0644 /tmp/aera-cellular-operation.lock || fail 'Cannot expose the shared radio lease.'
services='vendor.qcrild2 vendor.qcrild vendor.ipacm vendor.per_proxy vendor.per_mgr vendor.rmt_storage'
started_services=
modem=
owned_modem=false
owned_mcfg=false

cleanup() {
    local service busy
    trap '' HUP INT TERM
    for service in $started_services; do setprop ctl.stop "$service"; done
    # Never release the storage lease while a native daemon can access the modem.
    while :; do
        busy=false
        for service in $started_services; do
            case "$(getprop "init.svc.$service")" in ''|stopped) ;; *) busy=true ;; esac
        done
        [ "$busy" = false ] && break
        sleep 0.2
    done
    if [ "$owned_modem" = true ] && [ "$(cat "$modem/state")" = running ]; then
        printf 'stop\n' > "$modem/state"
    fi
    if [ "$owned_modem" = true ]; then
        while [ "$(cat "$modem/state")" != offline ]; do
            log 'Waiting for modem shutdown; storage lease remains held. Reboot if this does not finish.'
            sleep 5
        done
    fi
    if [ "$owned_mcfg" = true ]; then
        umount /data/vendor/modem_config || log 'Modem configuration mount remains busy.'
    fi
    [ "$owned_modem" != true ] || setprop vendor.houji.radio.owned 0
    log 'Native radio stopped; releasing its storage lease.'
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

check_cancel() {
    [ ! -e /tmp/aera-houji-radio-stop ] || exit 0
}
check_cancel

for service in $services; do
    case "$(getprop "init.svc.$service")" in
        ''|stopped) ;;
        *) fail "Another native service is already active: $service" ;;
    esac
done

start_radio_service() {
    check_cancel
    started_services="$1 $started_services"
    start_service "$1"
    check_cancel
}

prepare_stock
check_cancel
mount_ro "/dev/block/bootdevice/by-name/modemfirmware$SLOT" /vendor/modem_firmware vfat
bind_list /vendor/etc/aera/houji-radio.binds
load_modules /vendor/etc/aera/houji-radio.modules
check_cancel

# Identify MPSS from its name/device-tree compatible, never from a remoteproc index.
for node in /sys/class/remoteproc/remoteproc*; do
    [ -r "$node/name" ] || continue
    identity=$(cat "$node/name"; tr '\000' '\n' < "$node/device/of_node/compatible" 2>/dev/null)
    if printf '%s\n' "$identity" | grep -Eiq 'modem|mpss'; then
        [ -z "$modem" ] || fail 'More than one MPSS remoteproc; refusing an ambiguous modem.'
        modem=$node
    fi
done
[ -n "$modem" ] && [ -w "$modem/state" ] || fail 'No controllable MPSS remoteproc; modem shutdown cannot be guaranteed.'
[ "$(cat "$modem/state")" = offline ] || fail 'MPSS was already active; refusing to take over another modem session.'
owned_modem=true

# Stock Houji uses a separate modemfirmware slot, unlike its Wi-Fi/ADSP modem
# image. Keep provisioned userdata MBNs; use a temporary read-only view only if
# Android has not populated the modem_config directory yet.
if [ ! -d /data/vendor/modem_config/mcfg_sw ] || [ ! -d /data/vendor/modem_config/mcfg_hw ]; then
    mcfg=/vendor/modem_firmware/image/modem_pr/mcfg/configs
    if [ -f /data/vendor/mbnconfig/image/modem_pr/mcfg/configs/mbn_build_utc.txt ]; then
        mcfg=/data/vendor/mbnconfig/image/modem_pr/mcfg/configs
    fi
    [ -d "$mcfg/mcfg_sw" ] && [ -d "$mcfg/mcfg_hw" ] || fail 'Stock modem MBN configuration is unavailable.'
    bind_ro "$mcfg" /data/vendor/modem_config
    owned_mcfg=true
fi
resetprop -n ro.vendor.ril.mbn_copy_completed 1 || fail 'Cannot publish verified MBN availability.'

mkdir -p /dev/socket/qcrild /data/vendor/radio /data/vendor/ipa || fail 'Cannot create radio runtime directories.'
chown radio:radio /dev/socket/qcrild /data/vendor/ipa
chmod 0750 /dev/socket/qcrild
chown system:radio /data/vendor/radio
chmod 0770 /data/vendor/radio /data/vendor/ipa
# Follow stock QCRIL prebuilt DB initialization; preserve the live qcrilNr.db.
cp "$STOCK_ROOT/vendor/etc/qcril_database/qcrilNr.db" /data/vendor/radio/qcrilNr_prebuilt.db || fail 'Cannot seed QCRIL prebuilt database.'
printf '1\n' > /data/vendor/radio/prebuilt_db_support
printf '0\n' > /data/vendor/radio/db_check_done
printf '1\n' > /data/vendor/radio/copy_complete
chown radio:radio /data/vendor/radio/qcrilNr_prebuilt.db /data/vendor/radio/prebuilt_db_support /data/vendor/radio/db_check_done /data/vendor/radio/copy_complete
chmod 0660 /data/vendor/radio/qcrilNr_prebuilt.db /data/vendor/radio/db_check_done /data/vendor/radio/copy_complete
chmod 0400 /data/vendor/radio/prebuilt_db_support
cp /vendor/etc/IPACM_Filter_cfg.xml /data/vendor/ipa/IPACM_Filter_cfg.xml || fail 'Cannot prepare IPA filters.'
chown radio:radio /data/vendor/ipa/IPACM_Filter_cfg.xml

# Houji's stock build.prop declares dsds. Set it in this recovery property area;
# resetprop -n bypasses persistent-property writes and init restart triggers.
grep -qx 'persist.radio.multisim.config=dsds' "$STOCK_ROOT/vendor/build.prop" || fail 'The active ROM is not the expected Houji DSDS configuration.'
resetprop -n persist.radio.multisim.config dsds || fail 'Cannot select stock DSDS mode.'
setprop vendor.houji.radio.owned 1 || fail 'Cannot record native radio session ownership.'
check_cancel
start_service aera-houji-pd-mapper
start_radio_service vendor.rmt_storage
start_radio_service vendor.per_mgr
start_radio_service vendor.per_proxy
start_radio_service vendor.ipacm
start_radio_service vendor.qcrild
start_radio_service vendor.qcrild2
log 'Native QCRIL daemons started; no packet-data call has been requested.'

while :; do
    check_cancel
    for service in $services; do
        [ "$(getprop "init.svc.$service")" = running ] || fail "Native service exited: $service"
    done
    sleep 1
done
