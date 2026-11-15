#!/system/bin/sh
# Manual snapshot only. Write new files in /tmp; never change hardware or properties.
PATH=/system/bin:/vendor/bin:/sbin:$PATH
export PATH
umask 077

[ "$(id -u)" = 0 ] || { printf '%s\n' 'Run this collector as root in recovery.' >&2; exit 1; }
[ "$#" -le 1 ] || { printf '%s\n' 'Usage: sh collect_audio_crash_debug.sh [/tmp/aera-audio-crash-NAME]' >&2; exit 1; }
out=${1:-/tmp/aera-audio-crash-$(date -u +%Y%m%dT%H%M%SZ)-$$}
case "$out" in
    /tmp/aera-audio-crash-*) ;;
    *) printf '%s\n' 'Output must be a new /tmp/aera-audio-crash-NAME directory.' >&2; exit 1 ;;
esac
case "${out#/tmp/}" in
    */*) printf '%s\n' 'Output must be directly under /tmp.' >&2; exit 1 ;;
esac
mkdir -m 0700 "$out" || exit 1
printf '%s\n' 'Manual recovery snapshot; inspect each capture exit status.' > "$out/capture_status.txt"

capture() {
    name=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 1 8 "$@" > "$out/$name" 2>&1
        status=$?
    elif [ -x /system/bin/busybox ]; then
        /system/bin/busybox timeout -k 1 8 "$@" > "$out/$name" 2>&1
        status=$?
    else
        printf '%s\n' 'No timeout utility; skipped this capture to avoid an unbounded wait.' > "$out/$name"
        status=127
    fi
    printf '%s exit=%s\n' "$name" "$status" >> "$out/capture_status.txt"
}

capture pstore_directory.txt ls -l /sys/fs/pstore
mkdir "$out/pstore" || exit 1
pstore_count=0
for record in /sys/fs/pstore/*; do
    [ -f "$record" ] || continue
    capture "pstore/${record##*/}" cat "$record"
    pstore_count=$((pstore_count + 1))
done
printf 'pstore files attempted=%s; absence does not rule out a crash\n' "$pstore_count" >> "$out/capture_status.txt"

capture utc_time.txt date -u
capture uptime.txt cat /proc/uptime
capture kernel.txt uname -a
capture cmdline.txt cat /proc/cmdline
capture bootconfig.txt cat /proc/bootconfig
capture properties.txt getprop
capture dmesg.log dmesg
capture logcat_all.txt logcat -b all -d -v threadtime
capture recovery.log cat /tmp/recovery.log
capture processes.txt ps -A
capture modules.txt cat /proc/modules
capture mounts.txt cat /proc/mounts
capture asound_cards.txt cat /proc/asound/cards
capture sound_nodes.txt ls -l /dev/snd
capture devices_deferred.txt cat /sys/kernel/debug/devices_deferred
capture asoc_components.txt cat /sys/kernel/debug/asoc/components
capture asoc_dais.txt cat /sys/kernel/debug/asoc/dais
capture asoc_codecs.txt cat /sys/kernel/debug/asoc/codecs
capture clocks.txt cat /sys/kernel/debug/clk/clk_summary
capture regulators.txt cat /sys/kernel/debug/regulator/regulator_summary

sound=/sys/bus/platform/devices/soc:spf_core_platform:sound
driver=/sys/bus/platform/drivers/pineapple-asoc-snd
capture sound_device.txt ls -l "$sound"
capture sound_driver.txt readlink -f "$sound/driver"
capture sound_of_node.txt readlink -f "$sound/of_node"
capture sound_uevent.txt cat "$sound/uevent"
capture sound_modalias.txt cat "$sound/modalias"
capture probe_attributes.txt ls -l "$driver/bind" "$driver/unbind" /sys/bus/platform/drivers_probe
for property in compatible qcom,model qcom,sku-model nvmem-cell-names asoc-codec-names asoc-codec-dai-names asoc-cpu-names asoc-platform-names; do
    capture "dt-$property.txt" sh -c 'tr "\000" "\n" < "$1"' sh "$sound/of_node/$property"
done
capture live.dtb cat /sys/firmware/fdt
capture machine_staged_sha256.txt sha256sum /tmp/post_decrypt_modules/machine_dlkm.ko
capture machine_loaded_build_id.txt od -An -tx1 /sys/module/machine_dlkm/notes/.note.gnu.build-id
capture machine_refcnt.txt cat /sys/module/machine_dlkm/refcnt
capture machine_holders.txt ls -l /sys/module/machine_dlkm/holders
capture active_modules_dep.txt cat /vendor_dlkm/lib/modules/modules.dep

for node in /sys/class/remoteproc/remoteproc*; do
    [ -d "$node" ] || continue
    capture "${node##*/}_name.txt" cat "$node/name"
    capture "${node##*/}_state.txt" cat "$node/state"
done
seen_pids=' '
for process in recovery vold qseecomd keystore2 \
    android.hardware.security.keymint-service-qti android.hardware.security.keymint-service.strongbox-nxp \
    android.hardware.weaver-service.nxp-qti android.hardware.gatekeeper-service-qti \
    aera-houji-pd-mapper aera-dspservice aera-audioadsprpcd dspservice audioadsprpcd \
    android.hardware.audio.service android.hardware.audio.service_64 aera-audio-primary-opener aera-audio-bridge; do
    capture "pidof-$process.txt" pidof "$process"
    lookup_status=$status
    pids=
    [ "$lookup_status" != 0 ] || pids=$(cat "$out/pidof-$process.txt")
    printf 'pidof %s exit=%s pids=%s\n' "$process" "$lookup_status" "${pids:-unavailable}" >> "$out/capture_status.txt"
    for pid in $pids; do
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        case "$seen_pids" in *" $pid "*) continue ;; esac
        seen_pids="$seen_pids$pid "
        capture "proc-$pid-status.txt" cat "/proc/$pid/status"
        capture "proc-$pid-wchan.txt" cat "/proc/$pid/wchan"
        capture "proc-$pid-stack.txt" cat "/proc/$pid/stack"
    done
done

capture log_hashes.txt sha256sum "$out/dmesg.log" "$out/logcat_all.txt" "$out/recovery.log" "$out/live.dtb"
printf 'Snapshot: %s\nCheck capture_status.txt for unavailable or timed-out evidence.\n' "$out"
