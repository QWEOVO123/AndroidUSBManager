#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/common.sh"

STATE=BOOTING
DETAIL=
ACTIVE=0
AUTH_PID=
AUTH_KIND=
AUTH_REQUEST=
AUTH_OUTPUT=$RUN/auth.output
SESSION_ID=
CURRENT_HOST_ID=

start_auth_worker() {
    kind=$1
    request=$2
    mode=$3
    adb=$4
    [ -z "$AUTH_PID" ] || return 1
    lib=$(native_library)
    if [ ! -f "$APK" ] || [ ! -f "$lib" ]; then
        [ "$kind" != pair ] || write_response "$request" "ERROR|BACKEND_FILES_MISSING"
        DETAIL="authentication files missing"
        capture_diagnostics
        return 1
    fi
    rm -f "$AUTH_OUTPUT"
    auth_mode=closed
    profile=none
    if [ "$kind" = pair ]; then
        auth_mode=pair
        adb_word=false; [ "$adb" = 1 ] && adb_word=true
        profile=,$mode,$adb_word
    fi
    sh "$AUTH_SCRIPT" start "$APK" "$lib" "$auth_mode" "$AUTH_BACKEND" "$profile" \
        > "$AUTH_OUTPUT" 2>&1 &
    AUTH_PID=$!
    AUTH_KIND=$kind
    AUTH_REQUEST=$request
    STATE=AUTHENTICATING
    log_msg "authentication started kind=$kind pid=$AUTH_PID backend=$AUTH_BACKEND"
    return 0
}

cancel_auth_worker() {
    [ -n "$AUTH_PID" ] || return 0
    kill "$AUTH_PID" 2>/dev/null || true
    wait "$AUTH_PID" 2>/dev/null || true
    lib=$(native_library)
    sh "$AUTH_SCRIPT" restore "$APK" "$lib" closed "$AUTH_BACKEND" none >/dev/null 2>&1 || true
    AUTH_PID=
    AUTH_KIND=
    AUTH_REQUEST=
    [ "$STATE" != AUTHENTICATING ] || STATE=ACTIVE
}

show_or_defer_chooser() {
    if [ "$CHOOSER_LOCKED" != 1 ] && is_device_locked; then
        STATE=WAIT_UNLOCK
        log_msg "chooser deferred until unlock"
    else
        if launch_chooser; then STATE=WAIT_UI; else STATE=WAIT_UI_RETRY; fi
    fi
}

finish_auth_worker() {
    [ -n "$AUTH_PID" ] || return 1
    kill -0 "$AUTH_PID" 2>/dev/null && return 1
    wait "$AUTH_PID" 2>/dev/null || true
    line=$(grep '^AUTH_RESULT ' "$AUTH_OUTPUT" 2>/dev/null | tail -n 1)
    value=${line#AUTH_RESULT }
    IFS='|' read -r outcome host_id host_label host_mode host_adb host_restore <<EOF
$value
EOF
    [ "$host_adb" = true ] && host_adb_bit=1 || host_adb_bit=0
    kind=$AUTH_KIND
    request=$AUTH_REQUEST
    AUTH_PID=
    AUTH_KIND=
    AUTH_REQUEST=
    if [ "$kind" = pair ]; then
        case "$outcome" in
            PAIRED|KNOWN)
                CURRENT_HOST_ID=$host_id
                if apply_usb_config "$host_mode" "$host_adb_bit"; then
                    write_response "$request" "OK|$outcome|$host_id|$host_label|$(now_ms)|$host_mode|$host_adb_bit"
                    STATE=ACTIVE
                    log_msg "pairing completed outcome=$outcome host=${host_id%${host_id#????????????}}"
                else
                    STATE=APPLY_FAILED
                    write_response "$request" "OK|$outcome|$host_id|$host_label|$(now_ms)|$host_mode|$host_adb_bit|APPLY_FAILED"
                    log_msg "pairing saved; configuration failed host=$host_id restore=${host_restore:-ok}"
                    capture_diagnostics
                fi
                ;;
            *)
                write_response "$request" "ERROR|${outcome:-FAILED}|pairing did not complete"
                STATE=ACTIVE
                log_msg "pairing failed outcome=${outcome:-missing}"
                capture_diagnostics
                ;;
        esac
        return 0
    fi
    case "$outcome" in
        KNOWN)
            CURRENT_HOST_ID=$host_id
            case "$host_mode" in none|mtp|ptp|rndis|midi) ;; *) host_mode=$DEFAULT_MODE ;; esac
            if apply_usb_config "$host_mode" "$host_adb_bit"; then
                STATE=ACTIVE
                log_msg "known computer applied host=${host_id%${host_id#????????????}} mode=$host_mode adb=$host_adb_bit"
                am broadcast --user "$CURRENT_USER" --include-stopped-packages \
                    -n "$APP_PACKAGE/.bridge.KnownComputerReceiver" \
                    -a "$APP_PACKAGE.KNOWN_COMPUTER" --es label "$host_label" >/dev/null 2>&1 &
            else
                STATE=APPLY_FAILED
                capture_diagnostics
            fi
            ;;
        *)
            log_msg "computer not recognized outcome=${outcome:-FAILED}; showing chooser"
            [ "$outcome" = UNKNOWN ] || capture_diagnostics
            show_or_defer_chooser
            ;;
    esac
    return 0
}

run_detect_job() {
    request=$1
    lib=$(native_library)
    log_msg "authentication capability detection started"
    output=$(sh "$AUTH_SCRIPT" detect "$APK" "$lib" closed none none 2>&1)
    backend=$(echo "$output" | sed -n 's/^BACKEND=//p' | tail -n 1)
    summary=$(echo "$output" | tr '\n' ' ' | cut -c1-500)
    case "$backend" in
        generic_configfs|nothing_qxr)
            log_msg "authentication capability detection passed backend=$backend output=$summary"
            write_response "$request" "OK|$backend"
            ;;
        *)
            log_msg "authentication capability detection failed output=$summary"
            write_response "$request" "ERROR|UNSUPPORTED|$summary"
            capture_diagnostics
            ;;
    esac
}

run_hosts_list_job() {
    request=$1
    lib=$(native_library)
    output=$(sh "$AUTH_SCRIPT" list "$APK" "$lib" closed "$AUTH_BACKEND" none 2>/dev/null)
    payload=OK
    while IFS='|' read -r id label seen mode adb; do
        echo "$id" | grep -qE '^[0-9a-f]{64}$' || continue
        [ "$adb" = true ] && adb=1 || adb=0
        payload="$payload
HOST|$id|$label|$seen|$mode|$adb"
    done <<EOF
$output
EOF
    write_response "$request" "$payload"
}

run_host_edit_job() {
    request=$1; id=$2; label=$3; mode=$4; adb=$5
    lib=$(native_library)
    [ "$adb" = 1 ] && adb_word=true || adb_word=false
    output=$(sh "$AUTH_SCRIPT" edit "$APK" "$lib" "$id" "$AUTH_BACKEND" "$label,$mode,$adb_word" 2>&1)
    if ! echo "$output" | grep -q '^UPDATED$'; then
        write_response "$request" "ERROR|UPDATE_FAILED"
        return
    fi
    if [ "$id" = "$CURRENT_HOST_ID" ] && physical_usb_online; then
        log_msg "host edit applying current computer id=$id mode=$mode adb=$adb"
        if apply_usb_config "$mode" "$adb"; then
            STATE=ACTIVE
            write_response "$request" "OK|APPLIED"
        else
            STATE=APPLY_FAILED
            write_response "$request" "SAVED|APPLY_FAILED"
        fi
    else
        write_response "$request" "OK|SAVED"
    fi
}

run_host_delete_job() {
    request=$1; id=$2
    lib=$(native_library)
    output=$(sh "$AUTH_SCRIPT" delete "$APK" "$lib" "$id" "$AUTH_BACKEND" none 2>&1)
    echo "$output" | grep -q '^DELETED$' && write_response "$request" OK || write_response "$request" "ERROR|DELETE_FAILED"
}

process_commands() {
    [ -d "$BRIDGE_DIR" ] || return 0
    for source in "$BRIDGE_DIR"/command.*; do
        [ -f "$source" ] || continue
        case "$source" in *.tmp) continue ;; esac
        if [ -L "$source" ]; then
            rm -f "$source"
            log_msg "rejected symlink command"
            continue
        fi
        command_size=$(wc -c < "$source" 2>/dev/null || echo 0)
        if [ "${command_size:-0}" -gt 4096 ]; then
            rm -f "$source"
            log_msg "rejected oversized command"
            continue
        fi
        claimed=$RUN/command.$$
        mv -f "$source" "$claimed" 2>/dev/null || continue
        line=
        IFS= read -r line < "$claimed"
        rm -f "$claimed"
        IFS='|' read -r version operation request a b c d e f extra <<EOF
$line
EOF
        echo "$request" | grep -qE '^[0-9a-f]{32}$' || { log_msg "rejected command with invalid request id"; continue; }
        [ "$version" = v1 ] || { write_response "$request" "ERROR|BAD_VERSION"; continue; }
        case "$operation" in
            uninstall)
                log_msg "uninstall request received id=$request user=$CURRENT_USER auth_pid=${AUTH_PID:-none}"
                if [ -n "$AUTH_PID" ] && ! kill -0 "$AUTH_PID" 2>/dev/null; then
                    wait "$AUTH_PID" 2>/dev/null || true
                    AUTH_PID=; AUTH_KIND=; AUTH_REQUEST=
                    log_msg "uninstall cleared completed auth worker"
                fi
                [ "$a" = CONFIRM_UNINSTALL_REBOOT ] || { write_response "$request" "ERROR|CONFIRMATION_REQUIRED"; continue; }
                [ "$CURRENT_USER" = 0 ] || { write_response "$request" "ERROR|OWNER_USER_REQUIRED"; continue; }
                [ -z "$AUTH_PID" ] || { write_response "$request" "ERROR|BUSY"; continue; }
                uninstall_owner=$(cat /data/adb/usbmanager-auth/operation.lock/pid 2>/dev/null || true)
                case "$uninstall_owner" in
                    ''|*[!0-9]*) ;;
                    *) if kill -0 "$uninstall_owner" 2>/dev/null; then write_response "$request" "ERROR|BUSY"; continue; fi ;;
                esac
                [ "$(readlink -f "$MODDIR")" = /data/adb/modules/usbmanager_root ] || { write_response "$request" "ERROR|MODULE_PATH"; continue; }
                cp "$MODDIR/uninstall.sh" "$DATA/uninstall-worker.sh" || { write_response "$request" "ERROR|COPY_FAILED"; continue; }
                chmod 700 "$DATA/uninstall-worker.sh"
                write_response "$request" OK
                log_msg "confirmed uninstall and reboot requested from UI"
                nohup sh "$DATA/uninstall-worker.sh" --app > "$LOG_DIR/uninstall.log" 2>&1 < /dev/null &
                exit 0
                ;;
            settings)
                case "$a" in none|mtp|ptp|rndis|midi) DEFAULT_MODE=$a ;; *) write_response "$request" "ERROR|BAD_MODE"; continue ;; esac
                [ "$b" = 1 ] && DEFAULT_ADB=1 || DEFAULT_ADB=0
                [ "$c" = 0 ] && AUTO_OFF_ADB=0 || AUTO_OFF_ADB=1
                [ "$d" = 1 ] && CHOOSER_LOCKED=1 || CHOOSER_LOCKED=0
                [ "$e" = 1 ] && AUTH_ENABLED=1 || AUTH_ENABLED=0
                case "$f" in generic_configfs|nothing_qxr) AUTH_BACKEND=$f ;; *) AUTH_BACKEND=none ;; esac
                save_settings
                [ "$AUTH_ENABLED" = 1 ] || cancel_auth_worker
                ;;
            apply)
                [ -z "$AUTH_PID" ] || { write_response "$request" "ERROR|BUSY"; continue; }
                session=$a; mode=$b; adb=$c
                expected=; [ -f "$RUN/session" ] && IFS= read -r expected < "$RUN/session"
                if [ -n "$expected" ] && [ "$session" = "$expected" ]; then
                    rm -f "$RUN/session"
                    if apply_usb_config "$mode" "$adb"; then
                        STATE=ACTIVE
                        write_response "$request" OK
                    else
                        STATE=APPLY_FAILED
                        write_response "$request" "ERROR|APPLY_FAILED"
                        capture_diagnostics
                    fi
                else
                    log_msg "ignored apply with stale session"
                    write_response "$request" "ERROR|STALE_SESSION"
                fi
                ;;
            close)
                [ -z "$AUTH_PID" ] || continue
                session=$a; outcome=$b
                expected=; [ -f "$RUN/session" ] && IFS= read -r expected < "$RUN/session"
                if [ -n "$expected" ] && [ "$session" = "$expected" ]; then
                    if [ "$outcome" = confirmed ]; then
                        # APPLY and CLOSE are separate atomic files with random
                        # names, so directory order is not message order. Keep the
                        # session alive until APPLY consumes it.
                        log_msg "confirmed close received; waiting for apply session=$session"
                    else
                        rm -f "$RUN/session"
                        apply_usb_config none 0
                        STATE=ACTIVE
                    fi
                fi
                ;;
            detect)
                if [ -n "$AUTH_PID" ] && kill -0 "$AUTH_PID" 2>/dev/null; then
                    write_response "$request" "ERROR|BUSY|authentication is still running"
                else
                    run_detect_job "$request" &
                fi
                ;;
            hosts_list) run_hosts_list_job "$request" & ;;
            host_edit)
                [ -z "$AUTH_PID" ] || { write_response "$request" "ERROR|BUSY"; continue; }
                if echo "$a" | grep -qE '^[0-9a-f]{64}$'; then
                    case "$c" in
                        none|mtp|ptp|rndis|midi) run_host_edit_job "$request" "$a" "$b" "$c" "$d" ;;
                        *) write_response "$request" "ERROR|BAD_ARGUMENT" ;;
                    esac
                else
                    write_response "$request" "ERROR|BAD_ARGUMENT"
                fi
                ;;
            host_delete)
                if echo "$a" | grep -qE '^[0-9a-f]{64}$'; then
                    run_host_delete_job "$request" "$a" &
                else
                    write_response "$request" "ERROR|BAD_ID"
                fi
                ;;
            pair)
                case "$a" in none|mtp|ptp|rndis|midi) ;; *) write_response "$request" "ERROR|BAD_MODE"; continue ;; esac
                if ! physical_usb_online || ! is_data_peer; then
                    write_response "$request" "ERROR|NO_USB"
                elif [ "$AUTH_BACKEND" = none ]; then
                    write_response "$request" "ERROR|UNSUPPORTED"
                elif [ -n "$AUTH_PID" ]; then
                    write_response "$request" "ERROR|BUSY"
                else
                    dismiss_chooser
                    ACTIVE=1
                    start_auth_worker pair "$request" "$a" "$b" || write_response "$request" "ERROR|START_FAILED"
                fi
                ;;
            *) write_response "$request" "ERROR|UNKNOWN_COMMAND" ;;
        esac
    done
}

handle_connect() {
    CURRENT_HOST_ID=
    ACTIVE=1
    DETAIL=
    if [ "$AUTH_ENABLED" = 1 ] && [ "$AUTH_BACKEND" != none ]; then
        start_auth_worker auto "" "$DEFAULT_MODE" "$DEFAULT_ADB" || show_or_defer_chooser
    else
        show_or_defer_chooser
    fi
}

handle_disconnect() {
    CURRENT_HOST_ID=
    log_msg "physical USB disconnect"
    cancel_auth_worker
    dismiss_chooser
    [ "$AUTO_OFF_ADB" = 1 ] && apply_usb_config none 0
    rm -f "$RUN/session"
    ACTIVE=0
    STATE=IDLE
    DETAIL=
}

log_msg "service starting"
echo $$ > "$RUN/service.pid"
while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 1; done
refresh_bridge_dir
load_settings
log_msg "boot ready user=$CURRENT_USER package=$(pm path "$APP_PACKAGE" 2>&1) bridge=$BRIDGE_DIR role=$(usb_role) type=$(usb_type) online=$(physical_usb_online && echo 1 || echo 0)"
STATE=IDLE
loop_count=0

while true; do
    loop_count=$((loop_count + 1))
    if [ $((loop_count % 10)) = 0 ]; then refresh_bridge_dir; fi
    process_commands

    if [ "$ACTIVE" = 0 ]; then
        if physical_usb_online && is_data_peer; then
            log_msg "computer USB connected role=$(usb_role) type=$(usb_type)"
            handle_connect
        fi
    elif ! physical_usb_online; then
        # A forced gadget takeover temporarily drops UDC, Type-C partner and
        # power-supply online signals even though the cable remains attached.
        # Never cancel the worker from those transient nodes; its FunctionFS
        # result/timeout is authoritative. Once it finishes, the next loop can
        # process a real disconnect normally.
        if [ "$STATE" = AUTHENTICATING ]; then
            finish_auth_worker || true
        else
            handle_disconnect
        fi
    else
        case "$STATE" in
            AUTHENTICATING) finish_auth_worker || true ;;
            WAIT_UNLOCK)
                if ! is_device_locked; then
                    if [ "$AUTH_ENABLED" = 1 ] && [ "$AUTH_BACKEND" != none ]; then
                        start_auth_worker auto "" "$DEFAULT_MODE" "$DEFAULT_ADB" || {
                            if launch_chooser; then STATE=WAIT_UI; else STATE=WAIT_UI_RETRY; fi
                        }
                    else
                        if launch_chooser; then STATE=WAIT_UI; else STATE=WAIT_UI_RETRY; fi
                    fi
                fi
                ;;
            WAIT_UI_RETRY)
                # PackageManager can report the freshly updated direct-boot
                # activity as missing for a few seconds after boot.
                if launch_chooser; then STATE=WAIT_UI; fi
                ;;
        esac
    fi
    write_status
    case "$STATE" in WAIT_UI|AUTHENTICATING) sleep 0.2 ;; *) sleep 1 ;; esac
done
