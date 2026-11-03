#!/system/bin/sh
# Secure apps can request factory licenses during listener initialization.
# Prepare the mount in this service before its first secure-world lookup.
/system/bin/sh /system/bin/aera-houji-cellular-prepare.sh --before-qseecomd ||
    printf 'E:aera-houji::PFM preparation failed before QSEE; continuing essential listeners.\n' >> /tmp/recovery.log
exec /vendor/bin/qseecomd "$@"
