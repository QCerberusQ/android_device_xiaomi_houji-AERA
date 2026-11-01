#!/system/bin/sh
. /system/bin/aera-houji-common.sh

require_data
mkdir -p /mnt/aera-stock || fail 'Cannot create stock runtime directory.'
for attempt in $(seq 1 300); do
    mkdir /mnt/aera-stock/.audio-lock 2>/dev/null && break
    [ "$attempt" != 300 ] || fail 'Another audio bootstrap did not finish.'
    sleep 0.1
done
trap 'rmdir /mnt/aera-stock/.audio-lock' EXIT
trap 'exit 1' HUP INT TERM

prepare_stock
bind_list /vendor/etc/aera/houji-audio.binds
load_modules /vendor/etc/aera/houji-audio.modules
mount_ro "/dev/block/bootdevice/by-name/dsp$SLOT" /vendor/dsp ext4
bind_ro /vendor/dsp /dsp
bind_ro "$STOCK_ROOT/vendor/lib/rfsa/adsp" /vendor/lib/rfsa/adsp

# PAL reads factory speaker calibration here. Expose only the audio directory
# from the existing read-only persist mount; never recalibrate factory storage.
mount_ro /dev/block/bootdevice/by-name/persist /mnt/aera-wlan-persist ext4
if [ -d /mnt/aera-wlan-persist/audio ]; then
    bind_ro /mnt/aera-wlan-persist/audio /mnt/vendor/persist/audio
fi

mkdir -p /data/vendor/audio/acdbdata/delta /data/vendor/audio_dsp || fail 'Cannot create audio state directories.'
chmod 0770 /data/vendor/audio /data/vendor/audio/acdbdata /data/vendor/audio/acdbdata/delta /data/vendor/audio_dsp
chown audio:audio /data/vendor/audio
chown media:audio /data/vendor/audio/acdbdata /data/vendor/audio/acdbdata/delta
chown media:media /data/vendor/audio_dsp

start_service aera-houji-pd-mapper
start_service aera-houji-dspservice
start_service aera-houji-audiopd
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
