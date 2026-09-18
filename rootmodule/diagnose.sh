#!/system/bin/sh

MODDIR=${0%/*}
OUTPUT=/data/adb/usbmanager/logs/diagnose.txt

if [ "${USBMANAGER_DIAG_WRITER:-0}" != 1 ]; then
    mkdir -p "${OUTPUT%/*}"
    temp=$OUTPUT.$$
    USBMANAGER_DIAG_WRITER=1 sh "$0" > "$temp" 2>&1
    chmod 0600 "$temp"
    mv -f "$temp" "$OUTPUT"
    echo "Saved diagnostics to $OUTPUT"
    exit 0
fi

section() {
    echo
    echo "===== $* ====="
}

section basic
date
id
echo "module=$MODDIR"
echo "boot_completed=$(getprop sys.boot_completed)"
echo "current_user=$(am get-current-user 2>&1)"
echo "package=$(pm path com.tiger.usbmanager 2>&1)"
echo "sys.usb.config=$(getprop sys.usb.config)"
echo "sys.usb.state=$(getprop sys.usb.state)"
echo "persist.sys.usb.config=$(getprop persist.sys.usb.config)"
echo "adbd=$(getprop init.svc.adbd)"

section processes
ps -A 2>&1 | grep -E 'usbmanager|service.sh' || true

section power_supply
for supply in /sys/class/power_supply/*; do
    [ -e "$supply" ] || continue
    echo "-- $supply"
    for leaf in type online present usb_type real_type status; do
        [ -r "$supply/$leaf" ] || continue
        printf '%s=' "$leaf"
        cat "$supply/$leaf" 2>&1
    done
done

section usb_role
for path in /sys/class/usb_role/*/role /sys/class/typec/port*/data_role \
    /sys/class/typec/port*/power_role; do
    [ -r "$path" ] || continue
    printf '%s=' "$path"
    cat "$path" 2>&1
done

section typec
ls -la /sys/class/typec 2>&1 || true

section extcon
for path in /sys/class/extcon/*/state; do
    [ -r "$path" ] || continue
    printf '%s=' "$path"
    tr '\n' ' ' < "$path"
    echo
done

section udc
for path in /sys/class/android_usb/android0/state /sys/class/udc/*/state; do
    [ -r "$path" ] || continue
    printf '%s=' "$path"
    cat "$path" 2>&1
done

section gadget_hal
getprop 2>&1 | grep -i -E 'usb|gadget' || true
ps -AZ 2>&1 | grep -i -E 'usb|gadget' || true

section configfs
for path in /config/usb_gadget/g1/UDC /config/usb_gadget/g1/idVendor \
    /config/usb_gadget/g1/idProduct; do
    [ -r "$path" ] || continue
    printf '%s=' "$path"
    cat "$path" 2>&1
done
ls -la /config/usb_gadget/g1/configs/b.1 2>&1 || true
ls -la /config/usb_gadget/g1/functions 2>&1 || true

section functionfs
ls -la /dev/usb-ffs 2>&1 || true
ls -la /dev/usb-ffs/qxr 2>&1 || true

section qxr_compositions
for path in /odm/etc/usb_compositions.conf /product/etc/usb_compositions.conf \
    /vendor/etc/usb_compositions.conf; do
    [ -r "$path" ] || continue
    echo "-- $path"
    grep -n 'qxr' "$path" 2>&1 || true
done

section activity_resolution
cmd package resolve-activity --brief -a android.intent.action.MAIN \
    -c android.intent.category.LAUNCHER com.tiger.usbmanager 2>&1 || true
cmd package resolve-activity --brief -n \
    com.tiger.usbmanager/.ui.UsbChooserActivity 2>&1 || true

section module_files
ls -la "$MODDIR" 2>&1

section settings
cat /data/adb/usbmanager/settings.conf 2>&1 || true

section lifecycle
readlink -f "$MODDIR" 2>&1 || true
cat /data/adb/usbmanager-auth/operation.lock/pid 2>&1 || true
for status_file in /data/user_de/*/com.tiger.usbmanager/files/root_bridge/backend.status; do
    [ ! -f "$status_file" ] || cat "$status_file"
done
tail -n 80 /data/adb/usbmanager/logs/uninstall.log 2>&1 || true

section service_log
tail -n 300 /data/adb/usbmanager/logs/service.log 2>&1 || true

section auth_session_log
tail -n 300 /data/adb/usbmanager-auth/last-session.log 2>&1 || true

section auth_gadget_log
tail -n 800 /data/adb/usbmanager/logs/auth-gadget.log 2>&1 || true

section auth_daemon_log
tail -n 300 /data/adb/usbmanager/logs/auth-daemon.log 2>&1 || true

section auth_session
ls -la /data/adb/usbmanager-auth/session 2>&1 || true
for file in /data/adb/usbmanager-auth/session/daemon.pid \
    /data/adb/usbmanager-auth/session/daemon.log \
    /data/adb/usbmanager-auth/session/auth-result \
    /data/adb/usbmanager/run/auth.output; do
    echo "-- $file"
    tail -n 80 "$file" 2>&1 || true
done

section auth_probe_log
tail -n 300 /data/adb/usbmanager-auth/nothing-probe.log 2>&1 || true
