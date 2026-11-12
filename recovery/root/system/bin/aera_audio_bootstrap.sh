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

backend_view_readonly() {
    local target
    target=$(readlink -f "$1") || return 1
    # Follow the existing directory alias and inspect the covering mount,
    # not the flags of /odm's parent.
    awk -v t="$target" '
        $5 == "/" || $5 == t || index(t, $5 "/") == 1 {
            if (length($5) > depth) {
                depth=length($5); flags=$6; count=1
            } else if (length($5) == depth) count++
        }
        END {exit !(count == 1 && flags ~ /(^|,)ro(,|$)/)}
    ' /proc/self/mountinfo
}

verify_backend_config() {
    local target staged staged_id
    staged=/mnt/aera-backend/backend_conf.xml
    backend_config_valid "$staged" || fail 'Invalid staged backend XML.'
    backend_view_readonly "$staged" || fail 'Backend staging is not read-only.'
    staged_id=$(stat -c '%d:%i' "$staged") || fail 'Cannot identify staged backend XML.'
    for target in /vendor/etc/backend_conf.xml /odm/etc/backend_conf.xml; do
        [ ! -L "$target" ] || fail "Backend XML consumer is a symlink: $target"
        backend_config_valid "$target" || fail "Invalid backend XML consumer: $target"
        [ "$(stat -c '%d:%i' "$target")" = "$staged_id" ] ||
            fail "Backend XML consumer is not bound to the staged file: $target"
        backend_view_readonly "$target" || fail "Backend XML consumer is not read-only: $target"
    done
    log 'Both Houji backend XML consumers verified read-only.'
}

prepare_backend_config() {
    local source target runtime record contents
    source=$STOCK_ROOT/odm/etc/backend_conf.xml
    if ! backend_config_valid "$source"; then
        # Keep this ramdisk source outside both public bind targets.
        source=/vendor/etc/aera/backend_conf.xml
        backend_config_valid "$source" ||
            fail 'No validated Houji backend_conf.xml in active ODM or the recovery bundle.'
    fi
    log "Using validated Houji backend configuration: $source"

    # Both public targets are packaged regular XML files. Only the private
    # staging file is created at runtime, on its own recovery tmpfs so sealing
    # it cannot make /mnt or rootfs read-only.
    runtime=/mnt/aera-backend
    [ ! -L "$runtime" ] || fail 'Backend staging directory is an unexpected symlink.'
    mkdir -p "$runtime" || fail 'Cannot create backend staging directory.'
    [ "$(readlink -f "$runtime")" = "$runtime" ] || fail 'Unexpected backend staging path.'
    record=$(awk -v t="$runtime" '$2 == t {print $1, $3}' /proc/mounts)
    if [ -n "$record" ]; then
        [ "$record" = 'aera-houji-backend tmpfs' ] || fail 'An unrelated mount covers backend staging.'
    else
        contents=$(ls -A "$runtime") || fail 'Cannot inspect backend staging directory.'
        [ -z "$contents" ] || fail 'Backend staging directory contains unrelated files.'
        mount -t tmpfs -o rw,nosuid,nodev,noexec,mode=0755,size=64k aera-houji-backend "$runtime" ||
            fail 'Cannot mount private backend tmpfs.'
    fi
    if awk -v t="$runtime/" 'index($2, t) == 1 {found=1} END {exit !found}' /proc/mounts; then
        fail 'An unrelated mount covers staged backend XML.'
    fi
    [ ! -L "$runtime/backend_conf.xml" ] || fail 'Staged backend XML is an unexpected symlink.'
    if [ ! -e "$runtime/backend_conf.xml" ]; then
        cp "$source" "$runtime/backend_conf.xml" || fail 'Cannot stage validated backend XML.'
        chmod 0444 "$runtime/backend_conf.xml" || fail 'Cannot protect staged backend XML.'
    fi
    backend_config_valid "$runtime/backend_conf.xml" || fail 'Invalid staged backend XML.'
    mount -o remount,ro "$runtime" || fail 'Cannot seal backend tmpfs read-only.'
    backend_view_readonly "$runtime/backend_conf.xml" || fail 'Backend tmpfs is not read-only.'

    for target in /vendor/etc/backend_conf.xml /vendor/odm/etc/backend_conf.xml; do
        [ -f "$target" ] && [ ! -L "$target" ] ||
            fail "Backend XML bind target is not a regular ramdisk file: $target"
        bind_ro "$runtime/backend_conf.xml" "$target"
    done
    verify_backend_config
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
   [ "$(getprop init.svc.aera-stock-audio-hal)" = running ] &&
   [ "$(getprop init.svc.aera-audio-primary-opener)" = running ]; then
    verify_backend_config
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
for daemon in dspservice audioadsprpcd; do
    [ -x "$STOCK_ROOT/vendor/bin/$daemon" ] || fail "Missing active-ROM audio daemon: $daemon"
done
bind_ro "$STOCK_ROOT/vendor/bin/dspservice" /vendor/bin/aera-dspservice
bind_ro "$STOCK_ROOT/vendor/bin/audioadsprpcd" /vendor/bin/aera-audioadsprpcd
start_service aera-dspservice
start_service aera-audioadsprpcd
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

verify_backend_config
# Keep Peridot's direct init service path while supporting Houji's _64 HAL.
if [ -x "$STOCK_ROOT/vendor/bin/hw/android.hardware.audio.service" ]; then
    hal=$STOCK_ROOT/vendor/bin/hw/android.hardware.audio.service
elif [ -x "$STOCK_ROOT/vendor/bin/hw/android.hardware.audio.service_64" ]; then
    hal=$STOCK_ROOT/vendor/bin/hw/android.hardware.audio.service_64
else
    fail 'No supported active-ROM Qualcomm audio HAL executable.'
fi
bind_ro "$hal" /vendor/bin/hw/android.hardware.audio.service
if [ "$(getprop init.svc.aera-stock-audio-hal)" != running ]; then
    setprop ctl.stop aera-audio-primary-opener
    rm -f /tmp/aera-audio-primary-opened
fi
start_service aera-stock-audio-hal
start_service aera-audio-primary-opener
for attempt in $(seq 1 100); do
    [ -f /tmp/aera-audio-primary-opened ] && break
    [ "$(getprop init.svc.aera-audio-primary-opener)" = running ] || fail 'Primary audio opener exited.'
    sleep 0.1
done
[ -f /tmp/aera-audio-primary-opened ] || fail 'Primary audio HAL did not open.'
log 'Houji primary audio HAL opened; PCM bridge available.'
