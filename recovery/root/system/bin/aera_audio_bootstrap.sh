#!/system/bin/sh
. /system/bin/aera-houji-common.sh
# Public stock/RFSA parents must be searchable by system/media audio children.
umask 022

backend_config_valid() {
    local digest
    [ -f "$1" ] && [ -r "$1" ] || {
        log "Backend XML is not a readable regular file: $1"
        return 1
    }
    digest=$(sha256sum "$1" 2>> /tmp/recovery.log) || {
        log "Cannot compute SHA-256 for backend XML: $1"
        return 1
    }
    # Exact identity also validates the XML parsed from the authorized source.
    [ "${digest%% *}" = d44a02e78bc063af96d6f599bee244852b73bacad0732cec0e0814d599b8fedd ] || {
        log "Rejected backend XML with unexpected SHA-256: $1 (${digest%% *})"
        return 1
    }
}

prepare_backend_config() {
    local source target
    source=$STOCK_ROOT/odm/etc/backend_conf.xml
    if ! backend_config_valid "$source"; then
        # Keep this ramdisk source outside both public bind targets.
        source=/vendor/etc/aera/backend_conf.xml
        backend_config_valid "$source" ||
            fail 'No validated Houji backend_conf.xml in active ODM or the recovery bundle.'
    fi
    log "Using validated Houji backend configuration: $source"
    mkdir -p /vendor/etc /vendor/odm/etc || fail 'Cannot create backend XML destination directories.'
    for target in /vendor/etc/backend_conf.xml /odm/etc/backend_conf.xml; do
        if [ ! -e "$target" ]; then
            cp "$source" "$target" || fail "Cannot seed backend XML target: $target"
            chmod 0644 "$target" || fail "Cannot make backend XML target readable: $target"
        fi
        bind_ro "$source" "$target"
    done
}

# Give the UI handoff time to finish; only the optional init worker sleeps.
[ "${1:-}" != --late ] || sleep 3
require_data
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
# The essential init sequence already boots ADSP. Observe it; never restart it.
for attempt in $(seq 1 150); do
    [ "$(cat "$adsp/state")" = running ] && [ -e /sys/class/power_supply/battery ] && break
    [ "$attempt" != 150 ] || fail 'Essential ADSP or battery is not ready; skipping optional audio.'
    sleep 0.1
done
if [ -f /tmp/aera-audio-primary-opened ] &&
   [ "$(getprop init.svc.aera-houji-audio-hal)" = running ] &&
   [ "$(getprop init.svc.aera-audio-primary-opener)" = running ]; then
    exit 0
fi
mkdir -p /mnt/aera-stock || fail 'Cannot create stock runtime directory.'
for attempt in $(seq 1 300); do
    mkdir /mnt/aera-stock/.audio-lock 2>/dev/null && break
    [ "$attempt" != 300 ] || fail 'Another audio bootstrap did not finish.'
    sleep 0.1
done
trap 'rmdir /mnt/aera-stock/.audio-lock' EXIT
trap 'exit 1' HUP INT TERM

prepare_stock
# GPR uses AudioPD notifications; PAL XML must not gate its prerequisites.
start_service aera-houji-pd-mapper
mount_ro "/dev/block/bootdevice/by-name/dsp$SLOT" /vendor/dsp ext4
bind_ro /vendor/dsp /dsp
bind_ro "$STOCK_ROOT/vendor/lib/rfsa/adsp" /vendor/lib/rfsa/adsp
bind_ro "$STOCK_ROOT/vendor/etc/seccomp_policy/vendor.qti.hardware.dsp.policy" /vendor/etc/seccomp_policy/vendor.qti.hardware.dsp.policy

mkdir -p /data/vendor/audio/acdbdata/delta /data/vendor/audio_dsp || fail 'Cannot create audio state directories.'
chmod 0770 /data/vendor/audio /data/vendor/audio/acdbdata /data/vendor/audio/acdbdata/delta /data/vendor/audio_dsp
chown audio:audio /data/vendor/audio
chown media:audio /data/vendor/audio/acdbdata /data/vendor/audio/acdbdata/delta
chown media:media /data/vendor/audio_dsp

# AERA_LOAD_VENDOR_MODULES owns insertion; process startup checks real state.
require_modules frpc-adsprpc.ko
for attempt in $(seq 1 50); do
    [ -c /dev/adsprpc-smd ] && break
    sleep 0.1
done
[ -c /dev/adsprpc-smd ] || fail 'FastRPC /dev/adsprpc-smd is unavailable; cannot start AudioPD.'
start_service aera-houji-dspservice
start_service aera-houji-audiopd
log 'PD mapper, DSP service and AudioPD processes started.'

prepare_backend_config
bind_list /vendor/etc/aera/houji-audio.binds
# Bundle the matching Houji statistics extension and its vendor dependencies.
# Audio services already search this private directory before the active ROM.
for library in \
    libaudiofeaturestats.so \
    libprotobuf-cpp-lite-21.7.so \
    libprotobuf-cpp-full-21.7.so \
    libqcc_sdk.so \
    vendor.qti.hardware.qccsyshal@1.0.so \
    vendor.qti.hardware.qccsyshal@1.1.so \
    vendor.qti.hardware.qccsyshal@1.2.so; do
    [ -s "/vendor/aera-audio-abi/$library" ] || fail "Missing bundled Houji audio library: $library"
done
bind_ro /vendor/aera-audio-abi/libaudiofeaturestats.so /vendor/lib64/libaudiofeaturestats.so
log 'Bundled Houji audio statistics library exposed read-only.'
# AERA_POST_DECRYPT_MODULES owns the speaker dependency pass.
require_modules audio_pkt_dlkm.ko q6_dlkm.ko pinctrl_lpi_dlkm.ko stub_dlkm.ko machine_dlkm.ko cs35l41_dlkm.ko

# PAL reads factory speaker calibration here. Expose only the audio directory
# from the existing read-only persist mount; never recalibrate factory storage.
mount_ro /dev/block/bootdevice/by-name/persist /mnt/aera-wlan-persist ext4
if [ -d /mnt/aera-wlan-persist/audio ]; then
    bind_ro /mnt/aera-wlan-persist/audio /mnt/vendor/persist/audio
fi

# ADSP already provides charging/USB; do not reset or reboot it for audio.
for attempt in $(seq 1 150); do
    [ -e /dev/snd/controlC0 ] && break
    sleep 0.1
done
[ -e /dev/snd/controlC0 ] || fail 'No ALSA machine card after native audio module loading.'

if [ "$(getprop init.svc.aera-houji-audio-hal)" != running ]; then
    setprop ctl.stop aera-audio-primary-opener
    rm -f /tmp/aera-audio-primary-opened
fi
start_service aera-houji-audio-hal
start_service aera-audio-primary-opener
for attempt in $(seq 1 100); do
    [ -f /tmp/aera-audio-primary-opened ] && break
    [ "$(getprop init.svc.aera-audio-primary-opener)" = running ] || fail 'Primary audio opener exited.'
    sleep 0.1
done
[ -f /tmp/aera-audio-primary-opened ] || fail 'Primary audio HAL did not open.'
log 'Houji primary audio HAL opened; PCM bridge available.'
