#!/usr/bin/env python3
"""Patch generated Flutter Android project for LAN and all-files permissions."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
manifest = root / "android/app/src/main/AndroidManifest.xml"
content = manifest.read_text()
permissions = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.CHANGE_WIFI_MULTICAST_STATE",
    "android.permission.MANAGE_EXTERNAL_STORAGE",
    "android.permission.ACCESS_LOCAL_NETWORK",
]
for perm in permissions:
    if f'android:name="{perm}"' not in content:
        content = content.replace("<application", f'    <uses-permission android:name="{perm}"/>\n    <application', 1)
# Local peers use an authenticated, AES-GCM protected WebSocket over TCP.
# Flutter does not allow insecure ws:// sockets when cleartext is disabled.
content = re.sub(r'<application(?![^>]*android:usesCleartextTraffic)', '<application android:usesCleartextTraffic="true"', content, count=1)
manifest.write_text(content)
print("Patched Android manifest:", manifest)

# The Flutter-generated MainActivity is minimal; add access to the Android model
# and a Wi-Fi multicast lock while the app is running for LAN discovery.
main_activity = root / "android/app/src/main/kotlin/top/mirv/ferrypane/MainActivity.kt"
main_activity.parent.mkdir(parents=True, exist_ok=True)
main_activity.write_text("""package top.mirv.ferrypane

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ferrypane/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "deviceModel") {
                    val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
                    val model = Build.MODEL
                    result.success(if (model.startsWith(manufacturer, true)) model else "$manufacturer $model")
                } else {
                    result.notImplemented()
                }
            }
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("FerryPane LAN discovery")
            multicastLock?.setReferenceCounted(false)
            multicastLock?.acquire()
        } catch (_: Exception) {
            // Manual IP entry remains available.
        }
    }

    override fun onDestroy() {
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } finally {
            super.onDestroy()
        }
    }
}
""")
print("Patched Android device name and Wi-Fi multicast discovery")
