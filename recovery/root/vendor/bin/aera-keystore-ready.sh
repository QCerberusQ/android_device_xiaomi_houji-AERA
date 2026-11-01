#!/system/bin/sh

# Both KeyMint processes also host their SharedSecret instances. Wait for
# registration, since init.svc=running only confirms that the process started.
attempt=0
waiting_for=crypto.ready=1
while [ "$attempt" -lt 30 ]; do
    if [ "$(getprop crypto.ready)" != 1 ]; then
        waiting_for=crypto.ready=1
        attempt=$((attempt + 1))
        sleep 1
        continue
    fi
    registered=true
    for instance in \
        android.hardware.security.keymint.IKeyMintDevice/default \
        android.hardware.security.keymint.IKeyMintDevice/strongbox \
        android.hardware.security.sharedsecret.ISharedSecret/default \
        android.hardware.security.sharedsecret.ISharedSecret/strongbox \
        android.hardware.security.secureclock.ISecureClock/default; do
        if ! /system/bin/service check "$instance" 2>/dev/null | grep -q ': found$'; then
            registered=false
            waiting_for=$instance
            break
        fi
    done
    if [ "$registered" = true ]; then
        [ "$(getprop crypto.ready)" = 1 ] || exit 1
        echo 'I:aera-keystore-ready::KeyMint and SharedSecret registered; starting keystore2.' >> /tmp/recovery.log
        exec /system/bin/keystore2 "$@"
    fi
    attempt=$((attempt + 1))
    sleep 1
done

echo "E:aera-keystore-ready::Timed out waiting for $waiting_for; keystore2 remains stopped." >> /tmp/recovery.log
exit 1
