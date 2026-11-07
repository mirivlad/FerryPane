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
