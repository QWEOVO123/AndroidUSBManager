#!/system/bin/sh
# Root-only USB Authenticate backend. Invoked only after explicit detection/enable.
set -eu
umask 077
ACTION=${1:-}
APK=${2:-}
LIB=${3:-}
MODE=${4:-closed}
BACKEND=${5:-none}
PROFILE=${6:-none}
ROOT=/data/adb/usbmanager-auth
HOSTS=$ROOT/hosts
RUN=$ROOT/session
SERVICE_LOG_DIR=/data/adb/usbmanager/logs
TRACE_LOG=$SERVICE_LOG_DIR/auth-gadget.log
SESSION_TRACE=$ROOT/last-session.log
MOUNT_STAGE=/data/local/tmp/usbmanager-auth-mount
CONF=/vendor/etc/usb_compositions.conf
for CANDIDATE in /odm/etc/usb_compositions.conf /product/etc/usb_compositions.conf /vendor/etc/usb_compositions.conf; do
    [ -r "$CANDIDATE" ] && grep -q '^qxr,adb[[:space:]]' "$CANDIDATE" 2>/dev/null || continue
    CONF=$CANDIDATE
    break
done
QXR=/dev/usb-ffs/qxr
DAEMON_CLASS=com.tiger.usbmanager.auth.UsbAuthDaemon

# ReSukiSU can grant UID 0 while leaving the caller in the app mount namespace.
# Being able to list /data/adb does not prove that a bind mount will be visible
# to an init-managed HAL. Always re-enter its global mount namespace once when
# ksud is present; Magisk and ordinary KernelSU continue directly.
if [ "${USBMANAGER_GLOBAL:-0}" != 1 ] && [ -x /data/adb/ksud ] && [ "$ACTION" != list ] && [ "$ACTION" != delete ] && [ "$ACTION" != edit ]; then
    OUTER_ADB=$(settings get global adb_enabled 2>/dev/null || echo 0)
    OUTER_FUNCTIONS=$(/system/bin/svc usb getFunctions 2>/dev/null || echo none)
    if [ "$ACTION" = start ] && [ "$BACKEND" = nothing_qxr ]; then
        settings put global adb_enabled 1
        # Do not ask UsbDeviceManager to reconfigure an already working MTP
        # composition. Its delayed HAL request can otherwise overwrite D003.
        case ",$OUTER_FUNCTIONS," in
          *,mtp,*) ;;
          *) /system/bin/svc usb setFunctions mtp; sleep 1 ;;
        esac
    fi
    STATUS=0
    OUTPUT=$(printf 'USBMANAGER_GLOBAL=1 USBMANAGER_PARENT_ADB=%s sh %s %s %s %s %s %s %s\nexit\n' \
        "$OUTER_ADB" "$0" "$ACTION" "$APK" "$LIB" "$MODE" "$BACKEND" "$PROFILE" | /data/adb/ksud debug su -g) || STATUS=$?
    printf '%s\n' "$OUTPUT"
    RESTORE_LINE=$(printf '%s\n' "$OUTPUT" | grep '^FRAMEWORK_RESTORE ' | tail -n 1 || true)
    if [ -n "$RESTORE_LINE" ]; then
        : # The global root session has already restored the framework and gadget.
    elif [ "$ACTION" = start ] && ! printf '%s\n' "$OUTPUT" | grep -q '^STARTED$'; then
        settings put global adb_enabled 0 2>/dev/null || true
        /system/bin/svc usb setFunctions "$OUTER_FUNCTIONS" 2>/dev/null || true
        settings put global adb_enabled "$OUTER_ADB" 2>/dev/null || true
        [ "$OUTER_ADB" != 1 ] || setprop ctl.start adbd
    fi
    case "$ACTION" in
      detect) printf '%s\n' "$OUTPUT" | grep -q '^BACKEND=' && exit 0 ;;
      start) printf '%s\n' "$OUTPUT" | grep -q '^STARTED$' && exit 0 ;;
      restore) printf '%s\n' "$OUTPUT" | grep -q '^FRAMEWORK_RESTORE ' && exit 0 ;;
      list) exit 0 ;;
      delete) printf '%s\n' "$OUTPUT" | grep -q '^DELETED$' && exit 0 ;;
    esac
    exit "$STATUS"
fi

mkdir -p "$ROOT" "$HOSTS" "$SERVICE_LOG_DIR"
chmod 700 "$ROOT" "$HOSTS" "$SERVICE_LOG_DIR"

trace() {
    if [ "${USBMANAGER_DEBUG:-0}" != 1 ]; then
        case "$*" in
            BEGIN*|END*|*FAIL*|*WARN*|*TIMEOUT*|DAEMON_EXITED*|DETECT_RESULT*) ;;
            *) return 0 ;;
        esac
    fi
    LINE="$(date '+%m-%d %H:%M:%S.%3N') pid=$$ action=$ACTION $*"
    echo "$LINE" >> "$SESSION_TRACE"
    echo "$LINE" >> "$TRACE_LOG"
    log -t USBManagerAuth "$*" 2>/dev/null || true
}

begin_trace() {
    if [ -f "$TRACE_LOG" ]; then
        SIZE=$(wc -c < "$TRACE_LOG" 2>/dev/null || echo 0)
        [ "${SIZE:-0}" -lt 2097152 ] || mv -f "$TRACE_LOG" "$TRACE_LOG.1"
    fi
    : > "$SESSION_TRACE"
    trace "BEGIN uid=$(id -u) backend=$BACKEND mode=$MODE profile_present=$([ "$PROFILE" = none ] && echo 0 || echo 1)"
    trace_snapshot initial
}

trace_snapshot() {
    [ "${USBMANAGER_DEBUG:-0}" = 1 ] || return 0
    LABEL=$1
    G=/config/usb_gadget/g1
    SNAP_UDC=$(cat "$G/UDC" 2>/dev/null || echo missing)
    SNAP_VID=$(cat "$G/idVendor" 2>/dev/null || echo missing)
    SNAP_PID=$(cat "$G/idProduct" 2>/dev/null || echo missing)
    SNAP_LINKS=$(ls -l "$G/configs/b.1" 2>/dev/null | awk '{print $9 "->" $11}' | tr '\n' ',' || true)
    SNAP_QXR=$(for E in ep0 ep1 ep2; do [ -e "$QXR/$E" ] && printf '%s=1,' "$E" || printf '%s=0,' "$E"; done)
    trace "SNAPSHOT label=$LABEL hal=$(getprop init.svc.vendor.usbgadget-hal-1-2) udc=$SNAP_UDC vid=$SNAP_VID pid=$SNAP_PID qxr=$SNAP_QXR links=$SNAP_LINKS"
}

daemon_start() {
    DAEMON_MOUNT=$1
    DAEMON_PAIR_MODE=$2
    DAEMON_LOG_FILE=$3
    DAEMON_RESULT_FILE=$4
    trace "DAEMON_START mount=$DAEMON_MOUNT pair=$DAEMON_PAIR_MODE log=$DAEMON_LOG_FILE"
    rm -f "$DAEMON_RESULT_FILE" "$DAEMON_RESULT_FILE.tmp"
    CLASSPATH="$APK" app_process /system/bin "$DAEMON_CLASS" "$LIB" "$DAEMON_MOUNT" "$HOSTS" "$DAEMON_PAIR_MODE" "$DAEMON_RESULT_FILE" "$PROFILE" > "$DAEMON_LOG_FILE" 2>&1 &
    DAEMON=$!
    # app_process normally becomes ready in well under a second. Polling once per
    # second added a full second to every cable insertion on the common path.
    for i in $(seq 1 30); do
        if [ -f "$DAEMON_LOG_FILE" ] && grep -q '^READY ' "$DAEMON_LOG_FILE"; then
            trace "DAEMON_READY pid=$DAEMON after=${i}00ms"
            return 0
        fi
        kill -0 "$DAEMON" 2>/dev/null || {
            trace "DAEMON_EXITED pid=$DAEMON log=$(tail -n 5 "$DAEMON_LOG_FILE" 2>/dev/null | tr '\n' ';' | cut -c1-600)"
            return 1
        }
        sleep 0.1
    done
    trace "DAEMON_READY_TIMEOUT pid=$DAEMON log=$(tail -n 5 "$DAEMON_LOG_FILE" 2>/dev/null | tr '\n' ';' | cut -c1-600)"
    return 1
}

standard_composition_ready() {
    EXPECTED_DATA=$1
    EXPECTED_ADB=$2
    CURRENT_LINKS=$(ls -l /config/usb_gadget/g1/configs/b.1 2>/dev/null || true)
    echo "$CURRENT_LINKS" | grep -q ffs.qxr && return 1
    for FUNCTION in mtp ptp rndis midi accessory audio_source ncm; do
        case ",$EXPECTED_DATA," in
          *,$FUNCTION,*) echo "$CURRENT_LINKS" | grep -q "\.$FUNCTION" || return 1 ;;
          *) echo "$CURRENT_LINKS" | grep -q "\.$FUNCTION" && return 1 ;;
        esac
    done
    if [ "$EXPECTED_ADB" = 1 ]; then
        echo "$CURRENT_LINKS" | grep -q ffs.adb || return 1
    else
        echo "$CURRENT_LINKS" | grep -q ffs.adb && return 1
    fi
    return 0
}

wait_standard_composition() {
    EXPECTED_DATA=$1
    EXPECTED_ADB=$2
    LIMIT=$3
    REQUIRED_STABLE=${4:-3}
    STABLE=0
    for i in $(seq 1 "$LIMIT"); do
        if standard_composition_ready "$EXPECTED_DATA" "$EXPECTED_ADB"; then
            STABLE=$((STABLE + 1))
            [ "$STABLE" -lt "$REQUIRED_STABLE" ] || return 0
        else
            STABLE=0
        fi
        sleep 0.1
    done
    return 1
}

common_capability() {
    trace "CAPABILITY_CHECK begin"
    [ "$(id -u)" = 0 ] || { trace "CAPABILITY_FAIL reason=not_root"; return 1; }
    [ -r "$APK" ] || { trace "CAPABILITY_FAIL reason=apk_unreadable path=$APK"; return 1; }
    [ -r "$LIB" ] || { trace "CAPABILITY_FAIL reason=lib_unreadable path=$LIB"; return 1; }
    [ -d /config/usb_gadget ] || { trace "CAPABILITY_FAIL reason=configfs_missing"; return 1; }
    grep -qw functionfs /proc/filesystems || { trace "CAPABILITY_FAIL reason=functionfs_unsupported"; return 1; }
    UDCS=$(ls /sys/class/udc 2>/dev/null | tr '\n' ',' || true)
    [ -n "$UDCS" ] || { trace "CAPABILITY_FAIL reason=no_udc"; return 1; }
    trace "CAPABILITY_PASS udcs=$UDCS conf=$CONF"
}

find_gadget_hal_service() {
    for SERVICE in vendor.usbgadget-hal-1-2 vendor.usbgadget-hal-1-1 \
        vendor.usbgadget-hal-1-0 vendor.usb-gadget-hal; do
        [ "$(getprop "init.svc.$SERVICE")" = running ] || continue
        echo "$SERVICE"
        return 0
    done
    return 1
}

save_forced_gadget_state() {
    FORCE_G=$1
    FORCE_C=$2
    echo "$FORCE_C" > "$RUN/generic.config"
    : > "$RUN/generic.links"
    for EXISTING in "$FORCE_C"/*; do
        [ -L "$EXISTING" ] || continue
        printf '%s|%s\n' "${EXISTING##*/}" "$(readlink "$EXISTING")" >> "$RUN/generic.links"
    done
    for ATTRIBUTE in idVendor idProduct bcdDevice bDeviceClass bDeviceSubClass bDeviceProtocol; do
        [ -r "$FORCE_G/$ATTRIBUTE" ] || continue
        cat "$FORCE_G/$ATTRIBUTE" > "$RUN/generic.$ATTRIBUTE"
    done
    FORCE_HAL=$(find_gadget_hal_service 2>/dev/null || true)
    echo "$FORCE_HAL" > "$RUN/generic.hal_service"
    trace "FORCE_SAVE config=$FORCE_C hal=${FORCE_HAL:-none} links=$(tr '\n' ',' < "$RUN/generic.links") vid=$(cat "$RUN/generic.idVendor" 2>/dev/null || echo unknown) pid=$(cat "$RUN/generic.idProduct" 2>/dev/null || echo unknown)"
}

stop_gadget_hal() {
    FORCE_HAL=$1
    [ -n "$FORCE_HAL" ] || { trace "FORCE_HAL no_service_found"; return 0; }
    trace "FORCE_HAL stopping service=$FORCE_HAL"
    setprop ctl.stop "$FORCE_HAL" 2>/dev/null || true
    for i in $(seq 1 30); do
        [ "$(getprop "init.svc.$FORCE_HAL")" = stopped ] && {
            touch "$RUN/generic.hal_stopped"
            trace "FORCE_HAL stopped service=$FORCE_HAL after=${i}00ms"
            return 0
        }
        sleep 0.1
    done
    FORCE_HAL_PID=$(getprop "init.svc_debug_pid.$FORCE_HAL")
    case "$FORCE_HAL_PID" in ''|*[!0-9]*) trace "FORCE_FAIL reason=hal_stop_timeout service=$FORCE_HAL"; return 1 ;; esac
    kill -STOP "$FORCE_HAL_PID" || { trace "FORCE_FAIL reason=hal_freeze pid=$FORCE_HAL_PID"; return 1; }
    echo "$FORCE_HAL_PID" > "$RUN/generic.hal_frozen"
    trace "FORCE_HAL frozen service=$FORCE_HAL pid=$FORCE_HAL_PID"
}

force_auth_only_gadget() {
    FORCE_G=$1
    FORCE_C=$2
    FORCE_FN=$3
    FORCE_LINK=$4
    FORCE_UDC=$5
    save_forced_gadget_state "$FORCE_G" "$FORCE_C"
    touch "$RUN/generic.force"
    FORCE_HAL=$(cat "$RUN/generic.hal_service")
    stop_gadget_hal "$FORCE_HAL" || return 1
    # HAL shutdown may already have unbound the controller. A second unbind
    # can return ENODEV on this kernel; it is not a gadget capability failure.
    if [ -n "$(cat "$FORCE_G/UDC" 2>/dev/null || true)" ]; then
        echo '' > "$FORCE_G/UDC" || { trace "FORCE_FAIL reason=unbind_udc"; return 1; }
    else
        trace "FORCE_UNBIND skipped=already_unbound"
    fi
    for EXISTING in "$FORCE_C"/*; do
        [ -L "$EXISTING" ] || continue
        rm -f "$EXISTING" || { trace "FORCE_FAIL reason=remove_link path=$EXISTING"; return 1; }
    done
    # A distinct temporary PID prevents Windows from reusing the cached MTP-only
    # device node. The vendor ID and serial remain those of the physical device.
    # New development PID bypasses Windows' cached malformed OS properties.
    echo 0x7e5b > "$FORCE_G/idProduct" || { trace "FORCE_FAIL reason=set_pid"; return 1; }
    echo 0 > "$FORCE_G/bDeviceClass" 2>/dev/null || true
    echo 0 > "$FORCE_G/bDeviceSubClass" 2>/dev/null || true
    echo 0 > "$FORCE_G/bDeviceProtocol" 2>/dev/null || true
    ln -s "$FORCE_FN" "$FORCE_LINK" || { trace "FORCE_FAIL reason=link_auth"; return 1; }
    trace "FORCE_AUTH_ONLY prepared pid=$(cat "$FORCE_G/idProduct") link=$FORCE_LINK"
    echo "$FORCE_UDC" > "$FORCE_G/UDC" || { trace "FORCE_FAIL reason=bind_udc"; return 1; }
    for i in $(seq 1 50); do
        FORCE_STATE=$(cat "/sys/class/udc/$FORCE_UDC/state" 2>/dev/null || echo unknown)
        case "$FORCE_STATE" in configured|addressed|powered|default)
            trace "FORCE_AUTH_ONLY bound udc=$FORCE_UDC state=$FORCE_STATE after=${i}00ms"
            trace_snapshot force_auth_only
            return 0
            ;;
        esac
        sleep 0.1
    done
    trace "FORCE_FAIL reason=udc_state_timeout state=${FORCE_STATE:-unknown}"
    trace_snapshot force_timeout
    return 1
}

generic_prepare() {
    trace "GENERIC_PREPARE begin conf=$CONF"
    # Vendor-managed Qualcomm gadgets are deliberately excluded: a virtual-only
    # ConfigFS pass would over-report support on devices whose physical UDC rejects
    # direct gadget takeover (as observed on Nothing A065).
    if [ -e "$CONF" ] && grep -q '^qxr,adb[[:space:]]' "$CONF" 2>/dev/null; then
        trace "GENERIC_SKIP reason=qxr_vendor_composition"
        return 1
    fi
    G=/config/usb_gadget/g1
    [ -d "$G/functions" ] && [ -d "$G/configs" ] || { trace "GENERIC_FAIL reason=gadget_layout"; return 1; }
    C=$(find "$G/configs" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    [ -n "$C" ] || { trace "GENERIC_FAIL reason=no_configuration"; return 1; }
    ORIGINAL_UDC=$(cat "$G/UDC" 2>/dev/null || true)
    UDC=$ORIGINAL_UDC
    if [ -z "$UDC" ]; then
        UDC=$(getprop vendor.usb.controller)
        if [ -z "$UDC" ] || [ ! -d "/sys/class/udc/$UDC" ]; then
            UDC=$(ls /sys/class/udc 2>/dev/null | grep -v '^dummy_udc' || true)
            [ "$(printf '%s\n' "$UDC" | wc -l)" = 1 ] || { trace "GENERIC_FAIL reason=ambiguous_udc"; return 1; }
        fi
    fi
    [ -n "$UDC" ] || { trace "GENERIC_FAIL reason=no_physical_udc"; return 1; }
    [ -d "/sys/class/udc/$UDC" ] || { trace "GENERIC_FAIL reason=udc_not_found value=$UDC"; return 1; }
    F=/dev/usb-ffs/usb_auth
    FN=$G/functions/ffs.usb_auth
    LINK=$C/usbmanager_auth
    [ ! -e "$FN" ] && [ ! -L "$LINK" ] || { trace "GENERIC_FAIL reason=stale_function"; return 1; }
    # Creating the ConfigFS ffs.<instance> directory registers the FunctionFS
    # device name in the kernel. It must happen before mounting that same name;
    # otherwise several Android kernels return ENOENT from mount(2).
    echo "$ORIGINAL_UDC" > "$RUN/generic.udc"
    echo "$LINK" > "$RUN/generic.link"
    touch "$RUN/generic"
    mkdir "$FN" || { trace "GENERIC_FAIL reason=create_function_instance"; return 1; }
    trace "GENERIC_FUNCTION_INSTANCE created path=$FN"
    mkdir -p "$F" || { trace "GENERIC_FAIL reason=mount_dir"; return 1; }
    mountpoint -q "$F" || mount -t functionfs usb_auth "$F" || {
        trace "GENERIC_FAIL reason=functionfs_mount filesystems=$(grep functionfs /proc/filesystems 2>/dev/null | tr '\n' ',' || true) fn_exists=$([ -d "$FN" ] && echo 1 || echo 0) mount_dir=$([ -d "$F" ] && echo 1 || echo 0)"
        return 1
    }
    trace "GENERIC_FUNCTIONFS mounted path=$F"
    daemon_start "$F" "$MODE" "$RUN/daemon.log" "$RUN/auth-result" || { trace "GENERIC_FAIL reason=daemon_start"; return 1; }
    echo "$DAEMON" > "$RUN/daemon.pid"
    if [ "$ACTION" = start ]; then
        force_auth_only_gadget "$G" "$C" "$FN" "$LINK" "$UDC" || return 1
        return 0
    fi
    echo '' > "$G/UDC" || { trace "GENERIC_FAIL reason=unbind_udc"; return 1; }
    ln -s "$FN" "$LINK" || { trace "GENERIC_FAIL reason=link_function"; return 1; }
    echo "$UDC" > "$G/UDC" || { trace "GENERIC_FAIL reason=rebind_udc"; return 1; }
    for i in $(seq 1 30); do
        if [ "$(cat "$G/UDC" 2>/dev/null || true)" = "$UDC" ]; then
            trace "GENERIC_READY udc=$UDC after=${i}00ms"
            trace_snapshot generic_ready
            return 0
        fi
        sleep 0.1
    done
    trace "GENERIC_FAIL reason=rebind_timeout"
    trace_snapshot generic_timeout
    return 1
}

generic_probe() {
    trace "GENERIC_PROBE begin"
    # Classify Qualcomm/QXR gadgets before creating state or touching the active
    # USB configuration. Their supported path is the read-only Nothing probe.
    if [ -e "$CONF" ] && grep -q '^qxr,adb[[:space:]]' "$CONF" 2>/dev/null; then
        trace "GENERIC_PROBE skipped=qxr_vendor_composition"
        return 1
    fi
    # Prerequisite detection is read-only. Never overwrite a recovery session,
    # unbind the live gadget, or treat an already-empty UDC as incompatibility.
    [ -d /config/usb_gadget/g1/functions ] && [ -d /config/usb_gadget/g1/configs ] || {
        trace "GENERIC_PROBE_FAIL reason=gadget_layout"; return 1;
    }
    PROBE_UDCS=$(ls /sys/class/udc 2>/dev/null | grep -v '^dummy_udc' || true)
    [ -n "$PROBE_UDCS" ] || { trace "GENERIC_PROBE_FAIL reason=no_physical_udc"; return 1; }
    trace "GENERIC_PROBE_PASS prerequisites_only=1 live_usb_untouched=1"
    return 0
}

nothing_probe() {
    trace "NOTHING_PROBE begin conf=$CONF"
    HAL_STATE=$(getprop init.svc.vendor.usbgadget-hal-1-2)
    [ "$HAL_STATE" = running ] || { trace "NOTHING_PROBE_FAIL reason=hal_not_running state=${HAL_STATE:-empty}"; return 1; }
    grep -q '^qxr,adb[[:space:]]' "$CONF" || { trace "NOTHING_PROBE_FAIL reason=qxr_row_missing conf=$CONF"; return 1; }
    [ -d /config/usb_gadget/g1 ] || { trace "NOTHING_PROBE_FAIL reason=gadget_missing"; return 1; }
    REAL_UDCS=$(ls /sys/class/udc 2>/dev/null | grep -v '^dummy_udc' | tr '\n' ',' || true)
    [ -n "$REAL_UDCS" ] || { trace "NOTHING_PROBE_FAIL reason=no_physical_udc"; return 1; }
    [ -e "$QXR/ep0" ] || { trace "NOTHING_PROBE_FAIL reason=qxr_ep0_missing"; return 1; }
    trace "NOTHING_PROBE_PASS prerequisites_only=1 live_usb_untouched=1"
    return 0
}

save_state() {
    trace "SAVE_STATE begin run=$RUN"
    mkdir "$RUN" || { trace "SAVE_STATE_FAIL reason=mkdir"; return 1; }
    echo "$BACKEND" > "$RUN/backend"
    getprop vendor.usb.config > "$RUN/vendor-config"
    getprop persist.vendor.usb.config.extra > "$RUN/extra"
    LINKS=$(ls -l /config/usb_gadget/g1/configs/b.1 2>/dev/null || true)
    if [ -n "${USBMANAGER_PARENT_ADB:-}" ]; then
        echo "$USBMANAGER_PARENT_ADB" > "$RUN/adb"
    elif echo "$LINKS" | grep -q ffs.adb; then echo 1 > "$RUN/adb"; else echo 0 > "$RUN/adb"; fi
    COMPOSITION=''
    for NAME in mtp ptp rndis midi accessory audio_source ncm qxr adb; do
        echo "$LINKS" | grep -q "\.$NAME" || continue
        if [ -n "$COMPOSITION" ]; then COMPOSITION="$COMPOSITION,$NAME"; else COMPOSITION=$NAME; fi
    done
    [ -n "$COMPOSITION" ] || COMPOSITION=none
    echo "$COMPOSITION" > "$RUN/functions"
    trace "SAVE_STATE done vendor_config=$(cat "$RUN/vendor-config") extra=$(cat "$RUN/extra") adb=$(cat "$RUN/adb") functions=$COMPOSITION"
}

nothing_prepare() {
    trace "NOTHING_PREPARE begin mode=$MODE conf=$CONF shell_mnt=$(readlink /proc/self/ns/mnt 2>/dev/null || echo unknown) init_mnt=$(readlink /proc/1/ns/mnt 2>/dev/null || echo unknown)"
    trace_snapshot nothing_begin
    grep -q '^qxr,adb[[:space:]]' "$CONF" || { trace "NOTHING_FAIL reason=qxr_row_missing"; return 1; }
    [ -e "$QXR/ep0" ] || { trace "NOTHING_FAIL reason=qxr_ep0_missing"; return 1; }
    [ ! -e "$QXR/ep1" ] || { trace "NOTHING_FAIL reason=qxr_busy"; return 1; }
    rm -rf "$MOUNT_STAGE"
    mkdir "$MOUNT_STAGE" || { trace "NOTHING_FAIL reason=mount_stage_mkdir"; return 1; }
    chmod 700 "$MOUNT_STAGE"
    cp "$CONF" "$MOUNT_STAGE/patched.conf" || { trace "NOTHING_FAIL reason=copy_composition"; return 1; }
    echo 'mtp,qxr,adb  0x05C6  0xD003' >> "$MOUNT_STAGE/patched.conf"
    chmod 600 "$MOUNT_STAGE/patched.conf"
    chcon u:object_r:vendor_configs_file:s0 "$MOUNT_STAGE/patched.conf" 2>/dev/null || true
    trace "NOTHING_PATCH_CREATED path=$MOUNT_STAGE/patched.conf context=$(ls -Z "$MOUNT_STAGE/patched.conf" 2>/dev/null | awk '{print $1}' || echo unknown)"
    mount --bind "$MOUNT_STAGE/patched.conf" "$CONF" || { trace "NOTHING_FAIL reason=bind_mount errno=$?"; return 1; }
    trace "NOTHING_BIND_MOUNT mounted source=$MOUNT_STAGE/patched.conf target=$CONF rows=$(grep -c '^mtp,qxr,adb[[:space:]]' "$CONF" 2>/dev/null || echo 0)"
    for i in $(seq 1 80); do [ -e /dev/usb-ffs/mtp/ep1 ] && break; sleep 0.1; done
    [ -e /dev/usb-ffs/mtp/ep1 ] || { trace "NOTHING_FAIL reason=mtp_endpoint_timeout"; return 1; }
    trace "NOTHING_MTP_ENDPOINT ready"
    daemon_start "$QXR" "$MODE" "$RUN/daemon.log" "$RUN/auth-result" || { trace "NOTHING_FAIL reason=auth_daemon_start"; return 1; }
    trace "NOTHING_AUTH_DAEMON ready pid=$DAEMON"
    echo "$DAEMON" > "$RUN/daemon.pid"
    OLD_HAL_PID=$(pidof android.hardware.usb.gadget@1.2-service-qti 2>/dev/null || true)
    trace "NOTHING_HAL_RESTART request old_pid=${OLD_HAL_PID:-missing} state=$(getprop init.svc.vendor.usbgadget-hal-1-2)"
    setprop ctl.restart vendor.usbgadget-hal-1-2
    HAL_PID=''
    for i in $(seq 1 100); do
        HAL_PID=$(pidof android.hardware.usb.gadget@1.2-service-qti 2>/dev/null || true)
        [ "$(getprop init.svc.vendor.usbgadget-hal-1-2)" = running ] && [ -n "$HAL_PID" ] && [ "$HAL_PID" != "$OLD_HAL_PID" ] && break
        sleep 0.1
    done
    [ -n "$HAL_PID" ] && [ "$HAL_PID" != "$OLD_HAL_PID" ] || {
        trace "NOTHING_FAIL reason=hal_restart_timeout old_pid=${OLD_HAL_PID:-missing} new_pid=${HAL_PID:-missing} state=$(getprop init.svc.vendor.usbgadget-hal-1-2)"
        return 1
    }
    trace "NOTHING_HAL_RESTARTED old_pid=${OLD_HAL_PID:-missing} new_pid=$HAL_PID state=$(getprop init.svc.vendor.usbgadget-hal-1-2)"
    # UsbDeviceManager reapplies MTP+ADB after the restarted HAL reconnects. Wait
    # for the actual ConfigFS links to settle instead of sleeping six seconds.
    wait_standard_composition mtp 1 50 10 || {
        trace "NOTHING_FAIL reason=standard_composition_unstable"
        trace_snapshot standard_composition_timeout
        return 1
    }
    trace "NOTHING_STANDARD_COMPOSITION stable=1"
    HAL_ROWS=0
    [ -z "$HAL_PID" ] || HAL_ROWS=$(grep -c '^mtp,qxr,adb[[:space:]]' "/proc/$HAL_PID/root$CONF" 2>/dev/null || echo 0)
    HAL_MNT=unknown
    [ -z "$HAL_PID" ] || HAL_MNT=$(readlink "/proc/$HAL_PID/ns/mnt" 2>/dev/null || echo unknown)
    trace "NOTHING_HAL_VIEW pid=$HAL_PID patched_rows=$HAL_ROWS hal_mnt=$HAL_MNT shell_mnt=$(readlink /proc/self/ns/mnt 2>/dev/null || echo unknown)"
    [ "$HAL_ROWS" -gt 0 ] || { trace "NOTHING_FAIL reason=bind_mount_not_visible_to_hal"; return 1; }

    # QTI consults vendor.usb.config only for its ADB-only HIDL branch. A blank
    # data-function request with ADB enabled selects that branch; asking for MTP
    # directly would ignore the vendor composition and silently drop QXR.
    settings put global adb_enabled 1 || { trace "NOTHING_FAIL reason=enable_adb_setting"; return 1; }
    setprop vendor.usb.config mtp,qxr,adb || { trace "NOTHING_FAIL reason=set_vendor_usb_config"; return 1; }
    REQUEST_OUTPUT=$(/system/bin/svc usb setFunctions 2>&1) || {
        trace "NOTHING_FAIL reason=svc_request output=$(echo "$REQUEST_OUTPUT" | tr '\n' ';' | cut -c1-400)"
        return 1
    }
    trace "NOTHING_COMPOSITION_REQUESTED vendor_config=$(getprop vendor.usb.config) output=$(echo "$REQUEST_OUTPUT" | tr '\n' ';' | cut -c1-400)"
    READY=0
    for i in $(seq 1 100); do
        PID=$(cat /config/usb_gadget/g1/idProduct 2>/dev/null || true)
        LINKS=$(ls -l /config/usb_gadget/g1/configs/b.1 2>/dev/null || true)
        if [ "$PID" = 0xd003 ] && echo "$LINKS" | grep -q ffs.mtp && echo "$LINKS" | grep -q ffs.qxr && echo "$LINKS" | grep -q ffs.adb; then READY=1; break; fi
        sleep 0.1
    done
    trace "NOTHING_COMPOSITION_RESULT ready=$READY pid=$PID links=$(echo "$LINKS" | awk '{print $9 "->" $11}' | tr '\n' ',')"
    trace_snapshot nothing_result
    [ "$READY" = 1 ]
}

restore() {
    [ -d "$RUN" ] || { trace "RESTORE skipped=no_session"; return 0; }
    # A caller can be killed while restoring because the USB bus disappears.
    # A stale marker must never make all later recovery attempts no-ops.
    mkdir "$RUN/restoring" 2>/dev/null || true
    rm -f "$RUN/watchdog.armed"
    trace "RESTORE begin"
    trace_snapshot restore_begin
    if [ -f "$RUN/daemon.log" ]; then
        # Diagnostic preservation must never abort gadget recovery. A previous
        # interrupted restore can leave a bad destination inode or mount behind.
        cp -f "$RUN/daemon.log" "$ROOT/last-daemon.log" 2>/dev/null || trace "RESTORE_WARN step=copy_last_daemon"
        cp -f "$RUN/daemon.log" "$SERVICE_LOG_DIR/auth-daemon.log" 2>/dev/null || trace "RESTORE_WARN step=copy_service_daemon"
        DAEMON_LINES=$(wc -l < "$RUN/daemon.log" 2>/dev/null || echo unknown)
        trace "RESTORE daemon_log_saved lines=$DAEMON_LINES"
    fi
    [ ! -f "$RUN/watchdog.log" ] || cp -f "$RUN/watchdog.log" "$ROOT/last-watchdog.log" 2>/dev/null || trace "RESTORE_WARN step=copy_watchdog"
    if [ -f "$RUN/daemon.pid" ]; then
        SAVED_DAEMON_PID=$(cat "$RUN/daemon.pid" 2>/dev/null || true)
        case "$SAVED_DAEMON_PID" in
          ''|*[!0-9]*) trace "RESTORE_WARN step=daemon_pid value=invalid" ;;
          *)
            SAVED_DAEMON_CMD=$(tr '\000' ' ' < "/proc/$SAVED_DAEMON_PID/cmdline" 2>/dev/null || true)
            case "$SAVED_DAEMON_CMD" in
              *com.tiger.usbmanager.auth.UsbAuthDaemon*)
                kill "$SAVED_DAEMON_PID" 2>/dev/null || true
                trace "RESTORE daemon_stop pid=$SAVED_DAEMON_PID"
                ;;
              '') trace "RESTORE daemon_already_gone pid=$SAVED_DAEMON_PID" ;;
              *) trace "RESTORE_WARN step=daemon_pid_reused pid=$SAVED_DAEMON_PID" ;;
            esac
            ;;
        esac
    fi
    sleep 0.3
    # A generic preparation can fail before the first ConfigFS mutation.
    if [ ! -f "$RUN/generic" ] && [ "$(cat "$RUN/backend" 2>/dev/null || true)" = generic_configfs ]; then
        rm -rf "$RUN"
        trace "RESTORE generic_no_mutation"
        return 0
    fi
    if [ -f "$RUN/generic" ]; then
        G=/config/usb_gadget/g1
        UDC=$(cat "$RUN/generic.udc")
        LINK=$(cat "$RUN/generic.link")
        trace "RESTORE generic_unbind begin"
        echo '' > "$G/UDC" 2>/dev/null || true
        trace "RESTORE generic_unbind done udc=$(cat "$G/UDC" 2>/dev/null || echo missing)"
        if [ -f "$RUN/generic.force" ]; then
            C=$(cat "$RUN/generic.config")
            for EXISTING in "$C"/*; do [ ! -L "$EXISTING" ] || rm -f "$EXISTING"; done
        else
            rm -f "$LINK"
        fi
        umount /dev/usb-ffs/usb_auth 2>/dev/null || true
        rmdir "$G/functions/ffs.usb_auth" 2>/dev/null || true
        if [ -f "$RUN/generic.force" ]; then
            for ATTRIBUTE in idVendor idProduct bcdDevice bDeviceClass bDeviceSubClass bDeviceProtocol; do
                [ -f "$RUN/generic.$ATTRIBUTE" ] || continue
                cat "$RUN/generic.$ATTRIBUTE" > "$G/$ATTRIBUTE" 2>/dev/null || true
            done
            while IFS='|' read -r NAME TARGET; do
                [ -n "$NAME" ] && [ -n "$TARGET" ] || continue
                ln -s "$TARGET" "$C/$NAME" 2>/dev/null || true
            done < "$RUN/generic.links"
            trace "FORCE_RESTORE configfs_restored links=$(tr '\n' ',' < "$RUN/generic.links") pid=$(cat "$G/idProduct" 2>/dev/null || echo unknown)"
        fi
        echo "$UDC" > "$G/UDC" 2>/dev/null || true
        rmdir /dev/usb-ffs/usb_auth 2>/dev/null || true
        if [ -f "$RUN/generic.hal_frozen" ]; then
            kill -CONT "$(cat "$RUN/generic.hal_frozen")" 2>/dev/null || true
            trace "FORCE_HAL resumed pid=$(cat "$RUN/generic.hal_frozen")"
        elif [ -f "$RUN/generic.hal_stopped" ]; then
            FORCE_HAL=$(cat "$RUN/generic.hal_service")
            [ -z "$FORCE_HAL" ] || setprop ctl.start "$FORCE_HAL" 2>/dev/null || true
            trace "FORCE_HAL start_requested service=${FORCE_HAL:-none}"
            if [ -n "$FORCE_HAL" ]; then
                for i in $(seq 1 50); do
                    [ "$(getprop "init.svc.$FORCE_HAL")" = running ] && break
                    sleep 0.1
                done
                trace "FORCE_HAL restore_state service=$FORCE_HAL state=$(getprop "init.svc.$FORCE_HAL")"
            fi
        fi
        SAVED_ADB=$(cat "$RUN/adb" 2>/dev/null || echo 0)
        SAVED_FUNCTIONS=$(cat "$RUN/functions" 2>/dev/null || echo none)
        DATA_FUNCTIONS=$(echo "$SAVED_FUNCTIONS" | sed 's/,adb//;s/adb,//;s/^adb$//;s/^none$//')
        settings put global adb_enabled "$SAVED_ADB" 2>/dev/null || true
        if [ -n "$DATA_FUNCTIONS" ]; then
            /system/bin/svc usb setFunctions "$DATA_FUNCTIONS" >/dev/null 2>&1 || true
        else
            /system/bin/svc usb setFunctions >/dev/null 2>&1 || true
        fi
        if [ "$SAVED_ADB" = 1 ]; then setprop ctl.start adbd; else setprop ctl.stop adbd; fi
        if ! wait_standard_composition "$DATA_FUNCTIONS" "$SAVED_ADB" 50; then
            trace "RESTORE_FAIL reason=standard_composition_timeout state_preserved=1"
            return 1
        fi
        if [ -f "$RUN/generic.hal_service" ]; then
            RESTORED_HAL=$(cat "$RUN/generic.hal_service")
            if [ -n "$RESTORED_HAL" ] && [ "$(getprop "init.svc.$RESTORED_HAL")" != running ]; then
                trace "RESTORE_FAIL reason=hal_not_running state_preserved=1"
                return 1
            fi
        fi
        echo "FRAMEWORK_RESTORE $SAVED_ADB $SAVED_FUNCTIONS"
        rm -rf "$RUN"
        trace "RESTORE generic_done udc=$UDC"
        trace_snapshot restore_generic_done
        return 0
    fi
    SAVED_ADB=$(cat "$RUN/adb" 2>/dev/null || echo 0)
    SAVED_FUNCTIONS=$(cat "$RUN/functions" 2>/dev/null || echo none)
    setprop persist.vendor.usb.config.extra "$(cat "$RUN/extra" 2>/dev/null || echo none)" 2>/dev/null || true
    setprop vendor.usb.config none 2>/dev/null || true
    /system/bin/svc usb setFunctions >/dev/null 2>&1 || true
    # Wait until the temporary QXR link is actually gone before removing the
    # patched composition table. This is normally faster than the old fixed 1 s.
    for i in $(seq 1 30); do
        LINKS=$(ls -l /config/usb_gadget/g1/configs/b.1 2>/dev/null || true)
        echo "$LINKS" | grep -q ffs.qxr || break
        sleep 0.1
    done
    umount "$CONF" 2>/dev/null || true
    rm -rf "$MOUNT_STAGE"
    setprop vendor.usb.config "$(cat "$RUN/vendor-config" 2>/dev/null || true)" 2>/dev/null || true
    DATA_FUNCTIONS=$(echo "$SAVED_FUNCTIONS" | sed 's/,adb//;s/adb,//;s/^adb$//;s/^none$//')
    settings put global adb_enabled "$SAVED_ADB" 2>/dev/null || trace "RESTORE_WARN step=settings_adb value=$SAVED_ADB"
    /system/bin/svc usb setFunctions "$DATA_FUNCTIONS" >/dev/null 2>&1 || true
    if [ "$SAVED_ADB" = 1 ]; then setprop ctl.start adbd; else setprop ctl.stop adbd; fi
    # Return as soon as the restored standard composition is stable. A fixed
    # four-second delay kept both unknown and known computers waiting after the
    # phone had already restored its USB functions.
    wait_standard_composition "$DATA_FUNCTIONS" "$SAVED_ADB" 50 || true
    echo "FRAMEWORK_RESTORE $SAVED_ADB $SAVED_FUNCTIONS"
    trace "RESTORE physical_done adb=$SAVED_ADB functions=$SAVED_FUNCTIONS"
    trace_snapshot restore_done
    rm -rf "$RUN"
}

discard_already_restored_session() {
    [ -d "$RUN" ] || return 1
    [ "$BACKEND" = generic_configfs ] || return 1
    G=/config/usb_gadget/g1
    C=$(cat "$RUN/generic.config" 2>/dev/null || echo "$G/configs/b.1")
    if [ -f "$RUN/generic.hal_service" ]; then
        STALE_HAL=$(cat "$RUN/generic.hal_service")
        [ -z "$STALE_HAL" ] || [ "$(getprop "init.svc.$STALE_HAL")" = running ] || return 1
    fi
    CURRENT_PID=$(cat "$G/idProduct" 2>/dev/null || true)
    SAVED_PID=$(cat "$RUN/generic.idProduct" 2>/dev/null || true)
    if [ -n "$SAVED_PID" ]; then
        [ "$CURRENT_PID" = "$SAVED_PID" ] || return 1
    else
        case "$CURRENT_PID" in 0x7e5a|0x7e5b) return 1 ;; esac
    fi
    for EXISTING in "$C"/*; do
        [ -L "$EXISTING" ] || continue
        [ "${EXISTING##*/}" != usbmanager_auth ] || return 1
        case "$(readlink "$EXISTING" 2>/dev/null || true)" in *ffs.qxr*) return 1 ;; esac
    done
    # The vendor HAL and its original PID/links are already back. Replaying an
    # old half-finished restore is unnecessary; recreate FunctionFS cleanly.
    trace "STALE_SESSION discarded reason=gadget_already_restored pid=$CURRENT_PID complete=$([ -f "$RUN/generic.force" ] && echo 1 || echo 0) hal=$(getprop init.svc.vendor.usbgadget-hal-1-1)"
    if [ -f "$RUN/daemon.pid" ]; then
        STALE_DAEMON_PID=$(cat "$RUN/daemon.pid" 2>/dev/null || true)
        case "$STALE_DAEMON_PID" in
          ''|*[!0-9]*) ;;
          *)
            STALE_DAEMON_CMD=$(tr '\000' ' ' < "/proc/$STALE_DAEMON_PID/cmdline" 2>/dev/null || true)
            case "$STALE_DAEMON_CMD" in
              *com.tiger.usbmanager.auth.UsbAuthDaemon*) kill "$STALE_DAEMON_PID" 2>/dev/null || true ;;
            esac
            ;;
        esac
    fi
    umount /dev/usb-ffs/usb_auth 2>/dev/null || umount -l /dev/usb-ffs/usb_auth 2>/dev/null || true
    rmdir /dev/usb-ffs/usb_auth 2>/dev/null || true
    rmdir "$G/functions/ffs.usb_auth" 2>/dev/null || true
    rm -rf "$RUN"
    return 0
}

release_operation() {
    rm -f "$ROOT/operation.lock/pid"
    rmdir "$ROOT/operation.lock" 2>/dev/null || true
}

case "$ACTION" in
  detect|start|restore|edit|delete)
    if ! mkdir "$ROOT/operation.lock" 2>/dev/null; then
        OWNER=$(cat "$ROOT/operation.lock/pid" 2>/dev/null || true)
        case "$OWNER" in
          ''|*[!0-9]*) echo BUSY; exit 4 ;;
        esac
        if kill -0 "$OWNER" 2>/dev/null; then echo BUSY; exit 4; fi
        rm -f "$ROOT/operation.lock/pid"
        rmdir "$ROOT/operation.lock" 2>/dev/null || true
        mkdir "$ROOT/operation.lock" 2>/dev/null || { echo BUSY; exit 4; }
    fi
    echo $$ > "$ROOT/operation.lock/pid"
    trap 'release_operation' EXIT
    ;;
esac

case "$ACTION" in
  detect|start|restore) begin_trace ;;
esac

case "$ACTION" in
  detect)
    set +e
    common_capability
    [ $? = 0 ] || { trace "DETECT_RESULT unsupported=common_capability"; echo UNSUPPORTED; exit 3; }
    generic_probe
    [ $? != 0 ] || { trace "DETECT_RESULT backend=generic_configfs"; echo BACKEND=generic_configfs; exit 0; }
    nothing_probe
    [ $? != 0 ] || { trace "DETECT_RESULT backend=nothing_qxr"; echo BACKEND=nothing_qxr; exit 0; }
    trace "DETECT_RESULT unsupported=no_backend"
    echo UNSUPPORTED; exit 3
    ;;
  start)
    [ "$MODE" = closed ] || [ "$MODE" = pair ]
    # A closed recognition session may already be active for this cable. Pairing
    # replaces it atomically by restoring the saved gadget state first.
    if [ -d "$RUN" ]; then
        if ! discard_already_restored_session; then
            restore || { trace "RESTORE_FAIL step=prestart_restore"; exit 3; }
        fi
    fi
    rm -rf "$RUN"
    save_state || { trace "START_FAIL reason=save_state"; rm -rf "$RUN"; exit 3; }
    trace "START requested mode=$MODE backend=$BACKEND saved_adb=$(cat "$RUN/adb") saved_functions=$(cat "$RUN/functions")"
    trap 'restore || true; release_operation' EXIT
    trap 'exit 143' TERM INT
    cp "$0" "$RUN/script"; echo "$APK" > "$RUN/apk"; echo "$LIB" > "$RUN/lib"
    WATCH_TOKEN=$(cat /proc/sys/kernel/random/uuid)
    echo "$WATCH_TOKEN" > "$RUN/watchdog.armed"
    # A watchdog belongs to exactly one session, never the next connection.
    # Signal the owner so its EXIT trap recovers while it still owns the lock.
    nohup sh -c '
        sleep 120
        R=/data/adb/usbmanager-auth/session
        [ "$(cat "$R/watchdog.armed" 2>/dev/null)" = "$1" ] || exit 0
        [ "$(cat /data/adb/usbmanager-auth/operation.lock/pid 2>/dev/null)" = "$2" ] || exit 0
        if kill -0 "$2" 2>/dev/null; then
            kill -TERM "$2"
        else
            sh "$R/script" restore "$(cat "$R/apk")" "$(cat "$R/lib")"
        fi
    ' watchdog "$WATCH_TOKEN" "$$" > "$RUN/watchdog.log" 2>&1 < /dev/null &
    if [ "$BACKEND" = generic_configfs ]; then
        generic_prepare || { trace "START_FAIL backend=generic_configfs"; exit 3; }
    elif [ "$BACKEND" = nothing_qxr ]; then
        nothing_prepare || { trace "START_FAIL backend=nothing_qxr"; exit 3; }
    else
        trace "START_FAIL reason=unsupported_saved_backend value=$BACKEND"
        echo 'unsupported saved backend' >&2
        exit 3
    fi
    echo STARTED
    trace "STARTED waiting_for_host mode=$MODE"
    AUTH_RESULT=TIMEOUT
    ATTEMPTS=20
    [ "$MODE" != pair ] || ATTEMPTS=120
    for i in $(seq 1 "$ATTEMPTS"); do
        if [ -s "$RUN/auth-result" ]; then
            AUTH_RESULT=$(cat "$RUN/auth-result")
            trace "AUTH_RESULT_RECEIVED status=$(printf '%s' "$AUTH_RESULT" | cut -d '|' -f 1) attempt=$i"
            if [ "$MODE" = pair ]; then
                case "$AUTH_RESULT" in
                  PAIRED\|*|KNOWN\|*) ;;
                  *) AUTH_RESULT=TIMEOUT; sleep 0.5; continue ;;
                esac
            fi
            # Give nativeSend time to deliver the encrypted response before teardown.
            sleep 0.5
            break
        fi
        sleep 0.5
    done
    [ "$AUTH_RESULT" != TIMEOUT ] || trace "AUTH_TIMEOUT attempts=$ATTEMPTS interval_ms=500"
    if ! restore; then
        trace "RESTORE_FAIL step=postauth_restore"
        case "$AUTH_RESULT" in
            PAIRED\|*|KNOWN\|*) AUTH_RESULT="$AUTH_RESULT|RESTORE_FAILED" ;;
            *) AUTH_RESULT=RESTORE_FAILED ;;
        esac
    fi
    trap 'release_operation' EXIT
    # The owning service applies and verifies profiles through one shared path.
    printf 'AUTH_RESULT %s\n' "$AUTH_RESULT"
    trace "END result=$(printf '%s' "$AUTH_RESULT" | cut -d '|' -f 1)"
    ;;
  restore)
    trace "RESTORE_REQUEST external=1"
    restore
    ;;
  list)
    CLASSPATH="$APK" app_process /system/bin "$DAEMON_CLASS" list "$HOSTS"
    ;;
  edit)
    CLASSPATH="$APK" app_process /system/bin "$DAEMON_CLASS" edit "$HOSTS" "$MODE" "$PROFILE"
    ;;
  delete)
    ID=$MODE
    echo "$ID" | grep -qE '^[0-9a-f]{64}$'
    rm -f "$HOSTS/$ID.properties" "$HOSTS/$ID.entry"
    echo DELETED
    ;;
  *)
    echo 'usage: usb_auth_root.sh detect|start|restore|list|edit|delete' >&2
    exit 2
    ;;
esac
