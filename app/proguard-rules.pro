# Entry point launched by the root service through app_process.
-keep class com.tiger.usbmanager.auth.UsbAuthDaemon { *; }
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# Used by Kotlin enum iteration in the UI and file protocol.
-keep class com.tiger.usbmanager.policy.UsbMode { *; }
