#!/system/bin/sh

DATA=/data/adb/usbmanager
mkdir -p "$DATA/run" "$DATA/hosts" "$DATA/logs"
chmod 0700 "$DATA" "$DATA/run" "$DATA/hosts" "$DATA/logs"

# Only volatile state is removed. Trusted-computer records live under
# /data/adb/usbmanager-auth/hosts and must survive every reboot.
rm -f "$DATA/run"/* 2>/dev/null
