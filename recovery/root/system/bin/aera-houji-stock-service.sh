#!/system/bin/sh
# Init starts this wrapper after the active ROM has been prepared.
# Native radio children retain their own lease if the supervisor exits early.
case "$1" in
    rmt-storage|per-mgr|per-proxy|qcrild|qcrild2|ipacm)
        exec 9< /tmp/aera-cellular-operation.lock
        flock -s -n 9 || exit 75
        ;;
esac
export LD_LIBRARY_PATH=/vendor/aera-stock-lib64:/vendor/aera-stock-odm-lib64:/vendor/aera-stock-system-lib64:/vendor/lib64:/system/lib64
export ANDROID_ROOT=/system
export ANDROID_DATA=/data
base=/mnt/aera-stock/vendor/bin
case "$1" in
    pd-mapper) exec "$base/pd-mapper" ;;
    dspservice) exec "$base/dspservice" ;;
    audiopd) exec "$base/audioadsprpcd" audiopd ;;
    audio-hal) exec "$base/hw/android.hardware.audio.service_64" ;;
    rmt-storage) exec "$base/rmt_storage" ;;
    per-mgr) exec "$base/pm-service" ;;
    per-proxy) exec "$base/pm-proxy" ;;
    qcrild) exec "$base/hw/qcrilNrd" ;;
    qcrild2) exec "$base/hw/qcrilNrd" -c 2 ;;
    ipacm) exec "$base/ipacm" ;;
    *) exit 64 ;;
esac
