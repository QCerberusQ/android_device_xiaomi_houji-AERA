#!/system/bin/sh
# Only these audio children use the active ROM's private library directories.
export LD_LIBRARY_PATH=/vendor/aera-audio-abi:/vendor/aera-stock-lib64:/vendor/aera-stock-odm-lib64:/vendor/aera-stock-system-lib64:/vendor/lib64:/system/lib64
export ANDROID_ROOT=/system
export ANDROID_DATA=/data
base=/mnt/aera-stock/vendor/bin
case "$1" in
    dspservice) exec "$base/dspservice" ;;
    audiopd) exec "$base/audioadsprpcd" audiopd ;;
    audio-hal)
        if [ -x "$base/hw/android.hardware.audio.service" ]; then
            exec "$base/hw/android.hardware.audio.service"
        fi
        exec "$base/hw/android.hardware.audio.service_64"
        ;;
    *) exit 64 ;;
esac
