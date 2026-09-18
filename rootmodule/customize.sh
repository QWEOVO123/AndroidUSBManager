#!/system/bin/sh

ui_print "- Installing USBManager root backend"
ui_print "- 作者：TigerSpirit217&QWEOVO"
ui_print "- 正确卸载方式：打开 APP，点击「卸载并重启」"
[ -f "$MODPATH/usbmanager.apk" ] || abort "! usbmanager.apk is missing from the module"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0755
set_perm "$MODPATH/usb_auth_root.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

if pm list packages -u | grep -qx 'package:com.tiger.usbmanager'; then
    ui_print "- 检测到旧版同包名 APP，先卸载（APP 设置和通知授权将清除）"
    OLD_APP_RESULT=$(pm uninstall com.tiger.usbmanager 2>&1)
    echo "$OLD_APP_RESULT" | grep -qx 'Success' || abort "! 旧 APP 卸载失败，安装已停止：$OLD_APP_RESULT"
fi

ui_print "- Installing the unprivileged UI APK"
if ! pm install -r "$MODPATH/usbmanager.apk" >/dev/null 2>&1; then
    abort "! UI APK install failed. Reinstall the module to retry."
fi
ui_print "- 安装完成，重启后首次打开 APP 并允许通知"
# A clean APP install must not race an old root-side auth_enabled=1 at boot.
# Keep host identity records, but reset the matching module preferences.
if [ -f /data/adb/usbmanager/settings.conf ]; then
    cp /data/adb/usbmanager/settings.conf /data/adb/usbmanager/settings.before-ui16.conf
    rm -f /data/adb/usbmanager/settings.conf
    ui_print "- 已重置模块设置以匹配新 APP，电脑记录保留"
fi
