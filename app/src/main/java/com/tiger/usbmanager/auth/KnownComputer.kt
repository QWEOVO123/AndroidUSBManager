package com.tiger.usbmanager.auth

import com.tiger.usbmanager.policy.UsbMode

data class KnownComputer(
    val id: String,
    val label: String,
    val lastSeen: Long,
    val mode: UsbMode?,
    val adb: Boolean,
)
