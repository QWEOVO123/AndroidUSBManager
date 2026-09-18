#!/system/bin/sh

# Manager hook must not reboot from inside a module-manager operation.
# The in-app path runs a private copy outside the module with --app.
umask 077
APP_MODE=0
[ "${1:-}" != --app ] || APP_MODE=1
[ "$(id -u)" = 0 ] || exit 1
MODULE=/data/adb/modules/usbmanager_root
PENDING=/data/adb/modules_update/usbmanager_root
if [ "$APP_MODE" = 1 ]; then
    # If an operation fails before removal, make the retained module usable again.
    trap 'status=$?; if [ "$status" != 0 ] && [ -f /data/adb/modules/usbmanager_root/service.sh ]; then nohup sh /data/adb/modules/usbmanager_root/service.sh >/dev/null 2>&1 < /dev/null & fi' EXIT
fi
if [ "$APP_MODE" = 1 ]; then
    [ ! -L "$MODULE" ] && [ "$(readlink -f "$MODULE")" = "$MODULE" ] || exit 2
    sleep 2
fi
echo "USBManager uninstall started app_mode=$APP_MODE"
if [ "$APP_MODE" = 0 ]; then
    SERVICE_PID=$(cat /data/adb/usbmanager/run/service.pid 2>/dev/null || true)
    case "$SERVICE_PID" in
        ''|*[!0-9]*) ;;
        *)
            SERVICE_CMD=$(tr '\000' ' ' < "/proc/$SERVICE_PID/cmdline" 2>/dev/null || true)
            case "$SERVICE_CMD" in *'/usbmanager_root/service.sh'*) kill "$SERVICE_PID" 2>/dev/null || true ;; esac
            ;;
    esac
fi
AUTH_OWNER=$(cat /data/adb/usbmanager-auth/operation.lock/pid 2>/dev/null || true)
case "$AUTH_OWNER" in
    ''|*[!0-9]*) ;;
    *)
        AUTH_CMD=$(tr '\000' ' ' < "/proc/$AUTH_OWNER/cmdline" 2>/dev/null || true)
        case "$AUTH_CMD" in
            *usb_auth_root.sh*|*/usbmanager-auth/session/script*)
                kill -TERM "$AUTH_OWNER" 2>/dev/null || true
                for attempt in 1 2 3 4 5 6 7 8 9 10; do
                    kill -0 "$AUTH_OWNER" 2>/dev/null || break
                    sleep 1
                done
                kill -0 "$AUTH_OWNER" 2>/dev/null && { echo 'Authentication worker still active; aborting'; exit 5; }
                ;;
        esac
        ;;
esac
if [ -d /data/adb/usbmanager-auth/session ] && [ -f "$MODULE/usb_auth_root.sh" ]; then
    ABI=$(getprop ro.product.cpu.abi)
    sh "$MODULE/usb_auth_root.sh" restore "$MODULE/usbmanager.apk" "$MODULE/lib/$ABI/libusbmanager_auth.so" || {
        # Returning to an old MTP/ADB profile is not a prerequisite for removal.
        # No auth owner is alive; continue with charging reset and reboot.
        echo 'WARN: old USB profile restore failed; continuing charging reset';
    }
fi
am force-stop com.tiger.usbmanager 2>/dev/null || true
if pm list packages | grep -qx 'package:com.tiger.usbmanager'; then
    pm uninstall com.tiger.usbmanager || { echo 'APP uninstall failed; module retained, no reboot'; exit 3; }
fi
settings put global adb_enabled 0 || true
setprop persist.sys.usb.config none || true
setprop persist.vendor.usb.config.extra none || true
setprop ctl.stop adbd || true
/system/bin/svc usb setScreenUnlockedFunctions || true
/system/bin/svc usb setFunctions >/dev/null 2>&1 || true
# Some ROMs retain a restricted MTP function. Disconnect the gadget before
# reboot; the framework's persistent default is reset above.
if [ -w /config/usb_gadget/g1/UDC ]; then
    echo '' > /config/usb_gadget/g1/UDC || true
fi
if [ "$APP_MODE" = 1 ]; then
    [ "$(readlink -f "$MODULE")" = /data/adb/modules/usbmanager_root ] || exit 4
    if [ -e "$PENDING" ]; then
        [ ! -L "$PENDING" ] && [ "$(readlink -f "$PENDING")" = /data/adb/modules_update/usbmanager_root ] || exit 4
        rm -rf /data/adb/modules_update/usbmanager_root || exit 4
    fi
    touch "$MODULE/disable" "$MODULE/remove"
    rm -rf /data/adb/modules/usbmanager_root || exit 4
    # Keep identity records and diagnostic logs; never erase /data/adb itself.
    sync
    echo 'Module removed; rebooting'
    /system/bin/reboot || setprop sys.powerctl reboot
fi
