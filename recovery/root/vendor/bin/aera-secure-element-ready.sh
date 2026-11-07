#!/system/bin/sh

# OMAPI can request eSE1 through init's AIDL interface before the QSEE-ready
# action runs. Enforce the same prerequisite for that lazy start path.
attempt=0
while [ "$(getprop vendor.sys.listeners.registered)" != true ]; do
    if [ "$attempt" -ge 30 ]; then
        echo 'E:aera-secure-element-ready::Timed out waiting for QSEE listeners; secure-element HAL not started.' >> /tmp/recovery.log
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1 || exit 1
done

echo 'I:aera-secure-element-ready::QSEE listeners registered; starting secure-element HAL.' >> /tmp/recovery.log
exec /vendor/bin/hw/android.hardware.secure_element-service.qti "$@"
