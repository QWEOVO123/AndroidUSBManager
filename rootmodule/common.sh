#!/system/bin/sh

MODDIR=${MODDIR:-${0%/*}}
DATA=/data/adb/usbmanager
RUN=$DATA/run
LOG_DIR=$DATA/logs
LOG=$LOG_DIR/service.log
SETTINGS=$DATA/settings.conf
APP_PACKAGE=com.tiger.usbmanager
APP_COMPONENT=$APP_PACKAGE/.ui.UsbChooserActivity
APK=$MODDIR/usbmanager.apk
AUTH_SCRIPT=$MODDIR/usb_auth_root.sh

mkdir -p "$RUN" "$LOG_DIR"
chmod 0700 "$DATA" "$RUN" "$LOG_DIR" 2>/dev/null || true

log_msg() {
    if [ "${USBMANAGER_DEBUG:-0}" != 1 ]; then
        case "$*" in
            'apply retry '*|'charging fallback begin '*|'rebind after charging requested '*|'confirmed close received;'*|'uninstall cleared '*|'host edit applying '*|'authentication capability detection started'|'chooser deferred '*) return 0 ;;
        esac
    fi
    if [ -f "$LOG" ]; then
        size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
        [ "${size:-0}" -lt 1048576 ] || mv -f "$LOG" "$LOG.1"
    fi
    echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
    log -t USBManagerRoot "$*" 2>/dev/null || true
}

now_ms() {
    seconds=$(date +%s)
    echo $((seconds * 1000))
}

current_user() {
    value=$(am get-current-user 2>/dev/null | tr -cd '0-9')
    echo "${value:-0}"
}

refresh_bridge_dir() {
    CURRENT_USER=$(current_user)
    APP_DE_DIR=/data/user_de/$CURRENT_USER/$APP_PACKAGE
    BRIDGE_DIR=$APP_DE_DIR/files/root_bridge
    BRIDGE_UID=
    if [ -d "$APP_DE_DIR" ]; then
        BRIDGE_UID=$(stat -c %u "$APP_DE_DIR" 2>/dev/null || true)
        mkdir -p "$BRIDGE_DIR"
        case "$BRIDGE_UID" in
            ''|*[!0-9]*) ;;
            *)
                chown "$BRIDGE_UID:$BRIDGE_UID" "$APP_DE_DIR/files" "$BRIDGE_DIR" 2>/dev/null || true
                chmod 0700 "$BRIDGE_DIR" 2>/dev/null || true
                restorecon -RF "$APP_DE_DIR/files" >/dev/null 2>&1 || true
                ;;
        esac
    fi
}

capture_diagnostics() {
    [ "${USBMANAGER_DEBUG:-0}" = 1 ] || return 0
    [ -f "$MODDIR/diagnose.sh" ] || return 0
    sh "$MODDIR/diagnose.sh" >/dev/null 2>&1 &
}

load_settings() {
    DEFAULT_MODE=none
    DEFAULT_ADB=0
    AUTO_OFF_ADB=1
    CHOOSER_LOCKED=0
    AUTH_ENABLED=0
    AUTH_BACKEND=none
    [ -f "$SETTINGS" ] || return 0
    while IFS='=' read -r key value; do
        case "$key" in
            default_mode) case "$value" in none|mtp|ptp|rndis|midi) DEFAULT_MODE=$value ;; esac ;;
            default_adb) [ "$value" = 1 ] && DEFAULT_ADB=1 || DEFAULT_ADB=0 ;;
            auto_off_adb) [ "$value" = 0 ] && AUTO_OFF_ADB=0 || AUTO_OFF_ADB=1 ;;
            chooser_locked) [ "$value" = 1 ] && CHOOSER_LOCKED=1 || CHOOSER_LOCKED=0 ;;
            auth_enabled) [ "$value" = 1 ] && AUTH_ENABLED=1 || AUTH_ENABLED=0 ;;
            auth_backend) case "$value" in generic_configfs|nothing_qxr) AUTH_BACKEND=$value ;; *) AUTH_BACKEND=none ;; esac ;;
        esac
    done < "$SETTINGS"
}

save_settings() {
    temp=$SETTINGS.$$
    {
        echo "default_mode=$DEFAULT_MODE"
        echo "default_adb=$DEFAULT_ADB"
        echo "auto_off_adb=$AUTO_OFF_ADB"
        echo "chooser_locked=$CHOOSER_LOCKED"
        echo "auth_enabled=$AUTH_ENABLED"
        echo "auth_backend=$AUTH_BACKEND"
    } > "$temp"
    chmod 0600 "$temp"
    mv -f "$temp" "$SETTINGS"
}

native_library() {
    abi=$(getprop ro.product.cpu.abi)
    case "$abi" in
        arm64-v8a) echo "$MODDIR/lib/arm64-v8a/libusbmanager_auth.so" ;;
        x86_64) echo "$MODDIR/lib/x86_64/libusbmanager_auth.so" ;;
        *) echo "$MODDIR/lib/$abi/libusbmanager_auth.so" ;;
    esac
}

physical_usb_online() {
    found=0
    for supply in /sys/class/power_supply/*; do
        [ -d "$supply" ] || continue
        supply_type=
        [ -r "$supply/type" ] && IFS= read -r supply_type < "$supply/type"
        case "$supply_type:${supply##*/}" in
            USB*:*|*:usb|*:USB|*:pc_port) ;;
            *) continue ;;
        esac
        path=$supply/online
        [ -r "$path" ] || continue
        found=1
        value=
        IFS= read -r value < "$path"
        [ "$value" = 1 ] && return 0
    done
    # Type-C partner and extcon survive gadget-function changes, unlike UDC.
    for partner in /sys/class/typec/port*-partner /sys/class/typec/port*/partner; do
        [ -e "$partner" ] && return 0
    done
    for state in /sys/class/extcon/*/state; do
        [ -r "$state" ] || continue
        grep -q -E '(^|[[:space:]])(USB|USB-SDP|USB-CDP)=1($|[[:space:]])' "$state" 2>/dev/null && return 0
    done
    # Last-resort fallback for older devices without power/typec/extcon nodes.
    [ "$found" = 0 ] && gadget_attached && return 0
    return 1
}

physical_power_node_available() {
    for supply in /sys/class/power_supply/*; do
        [ -d "$supply" ] || continue
        supply_type=
        [ -r "$supply/type" ] && IFS= read -r supply_type < "$supply/type"
        case "$supply_type:${supply##*/}" in
            USB*:*|*:usb|*:USB|*:pc_port) [ -r "$supply/online" ] && return 0 ;;
        esac
    done
    return 1
}

usb_role() {
    for path in /sys/class/usb_role/*/role /sys/class/typec/port*/data_role; do
        [ -r "$path" ] || continue
        value=
        IFS= read -r value < "$path"
        [ -n "$value" ] && { echo "$value"; return 0; }
    done
    echo unknown
}

usb_type() {
    for supply in /sys/class/power_supply/*; do
        [ -d "$supply" ] || continue
        supply_type=
        [ -r "$supply/type" ] && IFS= read -r supply_type < "$supply/type"
        case "$supply_type:${supply##*/}" in USB*:*|*:usb|*:USB|*:pc_port) ;; *) continue ;; esac
        for leaf in usb_type real_type type; do
            path=$supply/$leaf
            [ -r "$path" ] || continue
            value=
            IFS= read -r value < "$path"
            if [ -n "$value" ]; then
                # power_supply class attributes often print all supported values
                # and wrap only the currently selected one in square brackets.
                selected=$(echo "$value" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
                echo "${selected:-$value}"
                return 0
            fi
        done
    done
    echo unknown
}

gadget_attached() {
    for path in /sys/class/android_usb/android0/state /sys/class/udc/*/state; do
        [ -r "$path" ] || continue
        value=
        IFS= read -r value < "$path"
        case "$value" in CONNECTED|CONFIGURED|connected|configured|powered|addressed|suspended) return 0 ;; esac
    done
    return 1
}

is_data_peer() {
    role=$(usb_role)
    case "$role" in host|source|*\[host\]*|*\[source\]*) return 1 ;; esac
    case "$role" in device|peripheral|*\[device\]*|*\[peripheral\]*) return 0 ;; esac
    type=$(usb_type)
    case "$type" in
        *DCP*|*HVDCP*|*APPLE_BRICK_ID*|*Wireless*) return 1 ;;
        USB|*SDP*|*CDP*) return 0 ;;
    esac
    gadget_attached
}

is_device_locked() {
    power=$(dumpsys power 2>/dev/null)
    echo "$power" | grep -q -E 'mWakefulness=(Asleep|Dozing)|mInteractive=false' && return 0
    policy=$(dumpsys window policy 2>/dev/null)
    echo "$policy" | grep -q -E 'isStatusBarKeyguard=true|mShowingLockscreen=true|mKeyguardShowing=true|keyguardShowing=true|showingLockscreen=true' && return 0
    return 1
}

apply_usb_config() {
    mode=$1
    adb=$2
    case "$mode" in none|mtp|ptp|rndis|midi) ;; *) mode=none ;; esac
    [ "$adb" = 1 ] || adb=0

    # Keep the framework setting, persistent property and init service in sync.
    # ZUI's Qualcomm HAL can otherwise replay persist.sys.usb.config and undo a
    # successful-looking svc call a moment later.
    if [ "$adb" = 1 ]; then
        settings put global adb_enabled 1 2>/dev/null || true
        setprop persist.sys.usb.config adb
        setprop ctl.start adbd
    else
        settings put global adb_enabled 0 2>/dev/null || true
        setprop persist.sys.usb.config none
        setprop ctl.stop adbd
    fi

    APPLY_ATTEMPT=1
    APPLY_OK=0
    APPLY_OUTPUT=
    while [ "$APPLY_ATTEMPT" -le 2 ]; do
        if [ "$mode" = none ]; then
            APPLY_OUTPUT=$(/system/bin/svc usb setFunctions 2>&1)
            APPLY_CODE=$?
            if [ "$APPLY_CODE" != 0 ]; then
                APPLY_OUTPUT="$APPLY_OUTPUT; fallback=$(/system/bin/svc usb setFunctions none 2>&1)"
                APPLY_CODE=$?
            fi
        else
            APPLY_OUTPUT=$(/system/bin/svc usb setFunctions "$mode" 2>&1)
            APPLY_CODE=$?
        fi
        for APPLY_POLL in $(seq 1 50); do
            if [ -f "$RUN/charging.udc" ] && { [ "$mode" != none ] || [ "$adb" = 1 ]; } &&
                [ -z "$(cat /config/usb_gadget/g1/UDC 2>/dev/null)" ] && usb_config_applied "$mode" "$adb" links_only; then
                CHARGING_UDC=$(cat "$RUN/charging.udc")
                case "$CHARGING_UDC" in ''|*/*|dummy*) ;; *)
                    if [ -d "/sys/class/udc/$CHARGING_UDC" ]; then
                        echo "$CHARGING_UDC" > /config/usb_gadget/g1/UDC 2>/dev/null || true
                        log_msg "rebind after charging requested controller=$CHARGING_UDC mode=$mode"
                    fi
                    ;;
                esac
            fi
            if usb_config_applied "$mode" "$adb"; then
                APPLY_OK=1
                break
            fi
            sleep 0.1
        done
        [ "$APPLY_OK" = 0 ] || break
        log_msg "apply retry attempt=$APPLY_ATTEMPT mode=$mode adb=$adb svc_code=$APPLY_CODE links=$(usb_config_links) output=$(echo "$APPLY_OUTPUT" | tr '\n' ';' | cut -c1-300)"
        # Reassert the exact sequence used by the previously working backend.
        settings put global adb_enabled "$adb" 2>/dev/null || true
        if [ "$adb" = 1 ]; then
            setprop persist.sys.usb.config adb
        else
            setprop persist.sys.usb.config none
        fi
        APPLY_ATTEMPT=$((APPLY_ATTEMPT + 1))
    done
    if [ "$APPLY_OK" = 0 ] && [ "$mode" = none ] && [ "$adb" = 0 ]; then
        # Charging-only fallback: disconnect the actual gadget, not just the
        # framework property. Keep HAL running so future data modes can recover.
        log_msg "charging fallback begin udc=$(cat /config/usb_gadget/g1/UDC 2>/dev/null)"
        if [ -w /config/usb_gadget/g1/UDC ]; then
            CHARGING_UDC=$(cat /config/usb_gadget/g1/UDC 2>/dev/null)
            [ -z "$CHARGING_UDC" ] || printf '%s\n' "$CHARGING_UDC" > "$RUN/charging.udc"
            if [ -z "$(cat /config/usb_gadget/g1/UDC 2>/dev/null)" ] || echo '' > /config/usb_gadget/g1/UDC; then
                sleep 0.3
                if [ -z "$(cat /config/usb_gadget/g1/UDC 2>/dev/null)" ]; then
                    APPLY_OK=1
                    log_msg "charging fallback verified physical gadget unbound"
                fi
            fi
        fi
    fi
    if [ "$APPLY_OK" = 1 ]; then
        DETAIL=
        log_msg "apply success mode=$mode adb=$adb"
        return 0
    fi
    DETAIL="USB mode apply failed: $mode"
    log_msg "apply failed mode=$mode adb=$adb svc_code=$APPLY_CODE links=$(usb_config_links) sys.usb.state=$(getprop sys.usb.state) persist=$(getprop persist.sys.usb.config) adbd=$(getprop init.svc.adbd) output=$(echo "$APPLY_OUTPUT" | tr '\n' ';' | cut -c1-300)"
    capture_diagnostics
    return 1
}

usb_config_links() {
    ls -l /config/usb_gadget/g1/configs/* 2>/dev/null \
        | awk '/ -> / {print $9 "->" $11}' | tr '\n' ','
}

usb_config_applied() {
    expected_mode=$1
    expected_adb=$2
    if [ "${3:-}" != links_only ] && { [ "$expected_mode" != none ] || [ "$expected_adb" = 1 ]; }; then
        [ -n "$(cat /config/usb_gadget/g1/UDC 2>/dev/null)" ] || return 1
    fi
    links=$(ls -l /config/usb_gadget/g1/configs/* 2>/dev/null || true)
    case "$expected_mode" in
        mtp) echo "$links" | grep -q 'ffs\.mtp' || return 1 ;;
        ptp) echo "$links" | grep -q 'ffs\.ptp' || return 1 ;;
        rndis) echo "$links" | grep -q -E '(gsi|rndis)\.rndis' || return 1 ;;
        midi) echo "$links" | grep -q 'midi\.' || return 1 ;;
        none)
            echo "$links" | grep -q -E 'ffs\.(mtp|ptp)|((gsi|rndis)\.rndis)|midi\.' && return 1
            ;;
    esac
    if [ "$expected_adb" = 1 ]; then
        echo "$links" | grep -q 'ffs\.adb' || return 1
    else
        echo "$links" | grep -q 'ffs\.adb' && return 1
    fi
    return 0
}

random_session() {
    value=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -n "$value" ] || value=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-')
    echo "$value"
}

launch_chooser() {
    SESSION_ID=$(random_session)
    echo "$SESSION_ID" > "$RUN/session"
    chmod 0600 "$RUN/session"
    adb_value=false; [ "$DEFAULT_ADB" = 1 ] && adb_value=true
    output=$(am start --user "$CURRENT_USER" --activity-clear-top -n "$APP_COMPONENT" \
        --es session_id "$SESSION_ID" --es usb_mode "$DEFAULT_MODE" --ez adb_enabled "$adb_value" \
        2>&1)
    result=$?
    if [ "$result" = 0 ]; then
        log_msg "chooser launched user=$CURRENT_USER"
        return 0
    fi
    DETAIL="chooser launch failed ($result)"
    log_msg "chooser launch failed user=$CURRENT_USER code=$result result=$output package=$(pm path "$APP_PACKAGE" 2>&1)"
    capture_diagnostics
    return 1
}

dismiss_chooser() {
    [ -f "$RUN/session" ] || return 0
    session=
    IFS= read -r session < "$RUN/session"
    am broadcast --user "$CURRENT_USER" -p "$APP_PACKAGE" -a "$APP_PACKAGE.action.DISMISS_CHOOSER" \
        --es session_id "$session" >/dev/null 2>&1 || true
    rm -f "$RUN/session"
}

write_status() {
    [ -d "$BRIDGE_DIR" ] || return 0
    temp=$BRIDGE_DIR/backend.status.tmp
    {
        echo running=1
        echo "state=$STATE"
        echo "auth_backend=$AUTH_BACKEND"
        echo "timestamp=$(now_ms)"
        echo "detail=$DETAIL"
    } > "$temp"
    chmod 0600 "$temp" 2>/dev/null || true
    [ -z "$BRIDGE_UID" ] || chown "$BRIDGE_UID:$BRIDGE_UID" "$temp" 2>/dev/null || true
    restorecon "$temp" >/dev/null 2>&1 || true
    mv -f "$temp" "$BRIDGE_DIR/backend.status"
}

write_response() {
    request=$1
    shift
    case "${1:-}" in ERROR\|*) log_msg "command failed request=$request response=$1" ;; esac
    [ -d "$BRIDGE_DIR" ] || return 1
    temp=$BRIDGE_DIR/response.$request.tmp
    target=$BRIDGE_DIR/response.$request
    printf '%s\n' "$@" > "$temp"
    chmod 0600 "$temp" 2>/dev/null || true
    [ -z "$BRIDGE_UID" ] || chown "$BRIDGE_UID:$BRIDGE_UID" "$temp" 2>/dev/null || true
    restorecon "$temp" >/dev/null 2>&1 || true
    mv -f "$temp" "$target"
}
