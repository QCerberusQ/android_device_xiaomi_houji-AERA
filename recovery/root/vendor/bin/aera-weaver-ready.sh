#!/system/bin/sh

# Enforce listener readiness for explicit and AIDL lazy starts alike.
attempt=0
while [ "$(getprop vendor.sys.listeners.registered)" != true ]; do
    if [ "$attempt" -ge 30 ]; then
        echo 'E:aera-weaver-ready::Timed out waiting for QSEE listeners; Weaver HAL not started.' >> /tmp/recovery.log
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1 || exit 1
done

echo 'I:aera-weaver-ready::QSEE listeners registered; starting Weaver HAL.' >> /tmp/recovery.log
exec /vendor/bin/hw/android.hardware.weaver-service.nxp-qti "$@"
