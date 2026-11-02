#!/system/bin/sh
# Sourced by the Houji ADSP and audio bootstrap scripts.

PATH=/system/bin:/vendor/bin:/sbin
export PATH
STOCK_ROOT=/mnt/aera-stock

fail() {
    printf 'E:aera-houji::%s\n' "$*" >> /tmp/recovery.log
    exit 1
}

log() {
    printf 'I:aera-houji::%s\n' "$*" >> /tmp/recovery.log
}

require_data() {
    [ "$(getprop twrp.modules.loaded)" = true ] || fail 'Core module staging is incomplete.'
    [ "$(getprop sys.usb.config.aera_fastbootd)" != 1 ] || fail 'fastbootd is active.'
    awk '$2 == "/data" && ($3 == "f2fs" || $3 == "ext4") &&
         $4 ~ /(^|,)rw(,|$)/ {ok=1} END {exit !ok}' /proc/mounts ||
        fail 'Userdata is not mounted read-write.'
    if [ -e /data/unencrypted/key/version ]; then
        [ "$(getprop twrp.decrypt.done)" = true ] || fail 'Primary user is locked.'
    fi
    local probe
    probe=$(mktemp /data/media/0/.aera-hardware-check.XXXXXX) || fail 'Primary user data is inaccessible.'
    rm -f "$probe" || fail 'Cannot remove primary-user access probe.'
}

mount_ro() {
    local source target record actual flags
    source=$(readlink -f "$1")
    target=$2
    [ -b "$source" ] || fail "Missing active-slot partition: $1"
    mkdir -p "$target" || fail "Cannot create $target"
    target=$(readlink -f "$target")
    record=$(awk -v t="$target" '$2 == t {print $1, $4}' /proc/mounts)
    if [ -n "$record" ]; then
        set -- $record
        [ "$#" = 2 ] || fail "Ambiguous mount: $target"
        actual=$(readlink -f "$1")
        flags=$2
        [ "$actual" = "$source" ] || fail "Wrong partition mounted at $target"
        case ",$flags," in *,ro,*) return 0 ;; esac
        fail "Writable stock mount: $target"
    fi
    case "$3" in
        vfat) mount -t vfat -o ro,uid=0,gid=0,fmask=0133,dmask=0022 "$source" "$target" ;;
        *) mount -t erofs -o ro "$source" "$target" 2>/dev/null ||
           mount -t ext4 -o ro,noload "$source" "$target" ;;
    esac || fail "Cannot mount $source read-only"
}

bind_ro() {
    local source target
    source=$1
    target=$2
    [ -e "$source" ] || fail "Missing stock audio asset: $source"
    if [ -d "$source" ]; then
        mkdir -p "$target" || fail "Cannot create $target"
    else
        mkdir -p "${target%/*}" || fail "Cannot create ${target%/*}"
        [ -e "$target" ] || : > "$target" || fail "Cannot create $target"
    fi
    target=$(readlink -f "$target")
    if awk -v t="$target" '$2 == t {found=1} END {exit !found}' /proc/mounts; then
        [ "$(stat -c '%d:%i' "$source")" = "$(stat -c '%d:%i' "$target")" ] ||
            fail "An unrelated mount covers $target"
    else
        mount -o bind "$source" "$target" || fail "Cannot bind $target"
    fi
    mount -o remount,bind,ro "$target" || fail "Cannot protect $target read-only"
}

prepare_stock() {
    local part system_lib
    mkdir -p "$STOCK_ROOT" || fail 'Cannot create stock runtime directory.'
    # The caller holds .audio-lock through preparation and HAL startup.
    SLOT=$(getprop ro.boot.slot_suffix)
    case "$SLOT" in _a|_b) ;; *) fail "Invalid active slot: $SLOT" ;; esac
    for part in vendor system odm; do
        mount_ro "/dev/block/mapper/$part$SLOT" "$STOCK_ROOT/$part" erofs
    done
    system_lib=$STOCK_ROOT/system/system/lib64
    [ -d "$system_lib" ] || system_lib=$STOCK_ROOT/system/lib64
    bind_ro "$STOCK_ROOT/vendor/lib64" /vendor/aera-stock-lib64
    bind_ro "$STOCK_ROOT/odm/lib64" /vendor/aera-stock-odm-lib64
    bind_ro "$system_lib" /vendor/aera-stock-system-lib64
    mount_ro "/dev/block/bootdevice/by-name/modem$SLOT" /firmware vfat
    # pd-mapper reads these descriptors. Preserve the already working Kiwi bind.
    for part in /firmware/image/*.jsn; do
        [ -f "$part" ] || continue
        bind_ro "$part" "/vendor/firmware_mnt/image/${part##*/}"
    done
}

bind_list() {
    local part source target
    while read -r part source target; do
        case "$part" in ''|'#'*) continue ;; esac
        bind_ro "$STOCK_ROOT/$part/$source" "$target"
    done < "$1"
}

module_live() {
    local name
    name=$(printf '%s' "${1%.ko}" | tr '-' '_')
    if [ -e "/sys/module/$name/initstate" ]; then
        [ "$(cat "/sys/module/$name/initstate")" = live ]
    else
        # Built-in modules have no initstate file.
        [ -d "/sys/module/$name" ]
    fi
}

load_modules() {
    local module directory file
    while read -r module; do
        case "$module" in ''|'#'*) continue ;; esac
        module_live "$module" && continue
        file=
        # Core Copy_Modules_To_Tmpfs retains the active ROM modules here.
        for directory in /tmp/vendor_dlkm/lib/modules /tmp/vendor/lib/modules /tmp/system_dlkm/lib/modules /tmp/post_decrypt_modules; do
            if [ -f "$directory/$module" ]; then file=$directory/$module; break; fi
        done
        [ -n "$file" ] || fail "Missing staged native module: $module"
        insmod "$file" >> /tmp/recovery.log 2>&1
        module_live "$module" || fail "Native module failed: $module; inspect dmesg."
    done < "$1"
}

start_service() {
    local attempt
    [ "$(getprop "init.svc.$1")" = running ] || setprop ctl.start "$1" || fail "Cannot start $1"
    for attempt in $(seq 1 50); do
        [ "$(getprop "init.svc.$1")" = running ] && break
        sleep 0.1
    done
    sleep 0.5
    [ "$(getprop "init.svc.$1")" = running ] || fail "Service $1 exited; inspect logcat."
}
