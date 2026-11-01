#!/system/bin/sh

# Keep this list in sync with AERA_POST_DECRYPT_MODULES in BoardConfig.mk.
modules="rfkill.ko cfg80211.ko gsim.ko rmnet_mem.ko usb_f_gsi.ko ipam.ko cnss_nl.ko qrtr-mhi.ko qca_cld3_kiwi_v2.ko"
stage=/tmp/post_decrypt_modules

publish() {
    [ "$(getprop post.decrypt.modules)" = "$1" ] && return 0
    setprop post.decrypt.modules "$1" && [ "$(getprop post.decrypt.modules)" = "$1" ]
}

fail() {
    printf 'E:aera-post-decrypt-modules::%s\n' "$*" >> /tmp/recovery.log
    publish false
    exit 1
}

data_ready() {
    # A tmpfs /data or mounted DE storage alone is not primary-user access.
    awk '$2 == "/data" && ($3 == "f2fs" || $3 == "ext4") &&
         $4 ~ /(^|,)rw(,|$)/ {ready=1} END {exit !ready}' /proc/mounts || return 1
    [ -d /data/media/0 ] || return 1
    if [ -e /data/unencrypted/key/version ]; then
        [ "$(getprop twrp.decrypt.done)" = true ] || return 1
    fi
    # Creating a temporary file also fails with ENOKEY if CE is still locked.
    # Do not create the media directory or change its encryption policy.
    probe=$(mktemp /data/media/0/.aera-module-check.XXXXXX 2>/dev/null) || return 1
    rm -f "$probe" || return 1
}

module_live() {
    awk -v name="$1" '$1 == name && $5 == "Live" {live=1} END {exit !live}' /proc/modules
}

wlan_config_ready() {
    # Wlan::Init prepares this file; the driver reads its MAC during insertion.
    mac=/vendor/firmware/wlan/qca_cld/kiwi_v2/wlan_mac.bin
    [ -f "$mac" ] && [ ! -L "$mac" ] &&
        grep -Eq '^Intf0MacAddress=02[[:xdigit:]]{10}$' "$mac" &&
        grep -qx END "$mac" &&
        grep -qx 'read_mac_addr_from_mac_file=1' /vendor/etc/wifi/kiwi_v2/WCNSS_qcom_cfg.ini
}

if [ "$1" = --wait ]; then
    printf 'I:aera-post-decrypt-modules::Waiting for primary userdata and AERA WLAN configuration.\n' >> /tmp/recovery.log
    while ! wlan_config_ready || ! data_ready; do
        # Stop waiting during a transition to fastbootd; init restarts us on return.
        [ "$(getprop sys.usb.config.aera_fastbootd)" != 1 ] || exit 0
        sleep 1 || exit 1
    done
else
    data_ready || fail 'Primary userdata is not accessible.'
    wlan_config_ready || fail 'AERA WLAN MAC/INI preparation is incomplete.'
fi
[ "$(getprop twrp.modules.loaded)" = true ] || fail 'Module staging is incomplete.'

for module in $modules; do
    name=$(printf '%s' "${module%.ko}" | tr '-' '_')
    module_live "$name" && continue
    [ -r "$stage/$module" ] || fail "Missing staged module: $stage/$module"
    # A concurrent native loader can return EEXIST; the live kernel state is
    # authoritative. Never mark readiness merely because insmod was attempted.
    insmod "$stage/$module" >> /tmp/recovery.log 2>&1
    attempts=0
    while ! module_live "$name"; do
        [ "$attempts" -lt 5 ] || fail "Module did not become live: $module (see dmesg)."
        attempts=$((attempts + 1))
        sleep 1 || fail 'Module readiness wait failed.'
    done
done

data_ready || fail 'Primary userdata became unavailable during module loading.'
publish true || fail 'Unable to publish module readiness.'
printf 'I:aera-post-decrypt-modules::All requested modules are live and primary userdata is accessible.\n' >> /tmp/recovery.log
