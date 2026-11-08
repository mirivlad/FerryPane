#!/usr/bin/env python3
"""Patch generated Flutter Android project for LAN discovery and secure builds."""
from pathlib import Path
import re
import shutil
import os

root = Path(__file__).resolve().parent.parent
manifest = root / "android/app/src/main/AndroidManifest.xml"
content = manifest.read_text()
permissions = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.CHANGE_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.CHANGE_WIFI_MULTICAST_STATE",
    "android.permission.MANAGE_EXTERNAL_STORAGE",
    "android.permission.ACCESS_LOCAL_NETWORK",
    "android.permission.READ_CONTACTS",
    "android.permission.WRITE_CONTACTS",
    "android.permission.READ_SMS",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.WAKE_LOCK",
]
for perm in permissions:
    if f'android:name="{perm}"' not in content:
        content = content.replace(
            "<application",
            f'    <uses-permission android:name="{perm}"/>\n    <application',
            1,
        )
# Prevent Android cloud/device backups from restoring encrypted preferences
# without their Android Keystore key. The original plaintext identity is
# migrated and deleted in-app before network services become available.
content = re.sub(
    r'<application(?![^>]*android:allowBackup)',
    '<application android:allowBackup="false"',
    content,
    count=1,
)
content = re.sub(
    r'<application(?![^>]*android:usesCleartextTraffic)',
    '<application android:usesCleartextTraffic="true"',
    content,
    count=1,
)
# A user-enabled connected-device service, not a perpetual dataSync job.
# It is private, visibly notified and may only answer trusted LAN peers.
if 'com.pravera.flutter_foreground_task.service.ForegroundService' not in content:
    content = content.replace(
        '</application>',
        '    <service android:name="com.pravera.flutter_foreground_task.service.ForegroundService"\n'
        '        android:foregroundServiceType="connectedDevice"\n'
        '        android:exported="false" android:stopWithTask="false" />\n'
        '</application>',
        1,
    )
manifest.write_text(content, encoding="utf-8")


main_activity = root / "android/app/src/main/kotlin/top/mirv/ferrypane/MainActivity.kt"
main_activity.parent.mkdir(parents=True, exist_ok=True)
main_activity.write_text('''package top.mirv.ferrypane

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity()
''', encoding="utf-8")
# Use the official Gradle CDN's smaller binary archive, not the generated
# GitHub-redirecting *all* archive (intermittent HTTP 504 on CI runners).
wrapper = root / "android/gradle/wrapper/gradle-wrapper.properties"
if not wrapper.exists():
    raise RuntimeError("Flutter Gradle wrapper missing")
wrapper_lines = wrapper.read_text(encoding="utf-8").splitlines()
found_wrapper = False
for index, line in enumerate(wrapper_lines):
    if line.startswith("distributionUrl="):
        match = re.search(r"gradle-([0-9.]+)-(?:all|bin)\.zip", line)
        if not match:
            raise RuntimeError("Unrecognized generated Gradle wrapper URL")
        version = match.group(1)
        if os.environ.get("GITHUB_ACTIONS") == "true" and version == "9.3.1":
            # The upstream release download currently redirects to GitHub
            # and returns 504 on Actions. Use an independent mirror only with
            # the pinned, independently published upstream SHA-256.
            wrapper_lines[index] = (
                "distributionUrl=https\\://mirrors.aliyun.com/gradle/"
                + "distributions/v9.3.1/gradle-9.3.1-bin.zip"
            )
            wrapper_lines.append(
                "distributionSha256Sum="
                + "b266d5ff6b90eada6dc3b20cb090e3731302e553a27c5d3e4df1f0d76beaff06"
            )
        else:
            wrapper_lines[index] = (
                "distributionUrl=https\\://downloads.gradle.org/distributions/"
                + "gradle-" + version + "-bin.zip"
            )
        found_wrapper = True
if not found_wrapper:
    raise RuntimeError("Generated Gradle wrapper has no distributionUrl")
wrapper.write_text("\n".join(wrapper_lines) + "\n", encoding="utf-8")


# On GitHub Actions Kotlin compiler artifacts sometimes redirect from Maven
# Central to GitHub Releases and return HTTP 504. Prefer a secondary mirror
# for Android builds; keep standard Maven repositories as fallbacks.
if os.environ.get("GITHUB_ACTIONS") == "true":
    for rel in ["android/settings.gradle.kts", "android/build.gradle.kts"]:
        gradle_repos = root / rel
        if not gradle_repos.exists():
            raise RuntimeError("Generated Gradle repositories missing: " + rel)
        gradle_text = gradle_repos.read_text(encoding="utf-8")
        mirror = 'maven { url = uri("https://maven.aliyun.com/repository/central") }'
        if mirror not in gradle_text:
            if "mavenCentral()" not in gradle_text:
                raise RuntimeError("Generated Gradle Maven repositories changed: " + rel)
            gradle_text = gradle_text.replace("mavenCentral()", mirror + "\n        mavenCentral()")
            gradle_repos.write_text(gradle_text, encoding="utf-8")

print("Patched Android LAN, native contacts/SMS backup, and vCard importer")

# Flutter create generates release build signing with a random runner debug
# key. Never distribute that unstable identity as a release.
gradle = root / "android/app/build.gradle.kts"
if gradle.exists():
    text = gradle.read_text()
    header = '''import java.io.FileInputStream
import java.util.Properties

val ferrySigning = Properties()
val ferrySigningFile = rootProject.file("key.properties")
if (ferrySigningFile.exists()) {
    ferrySigning.load(FileInputStream(ferrySigningFile))
}

'''
    if "val ferrySigning =" not in text:
        text = header + text
    target = "    buildTypes {"
    insert = '''    signingConfigs {
        create("ferrypaneRelease") {
            keyAlias = ferrySigning.getProperty("keyAlias")
            keyPassword = ferrySigning.getProperty("keyPassword")
            storePassword = ferrySigning.getProperty("storePassword")
            storeFile = ferrySigning.getProperty("storeFile")?.let { file(it) }
        }
    }
'''
    if 'create("ferrypaneRelease")' not in text:
        if target not in text:
            raise RuntimeError("Generated Gradle layout changed: buildTypes not found")
        text = text.replace(target, insert + target, 1)
    text = re.sub(
        r'signingConfig = signingConfigs.getByName\("debug"\)',
        'signingConfig = signingConfigs.getByName("ferrypaneRelease")',
        text,
        count=1,
    )
    if 'com.googlecode.ez-vcard:ez-vcard:' not in text:
        text += '\n// Standard vCard 2.1/3.0/4.0 parser for in-app contact import.\n'
        text += 'dependencies {\n    implementation("com.googlecode.ez-vcard:ez-vcard:0.12.2")\n}\n'
    gradle.write_text(text, encoding="utf-8")
    print("Configured deterministic release signing and Android vCard parser")
else:
    raise RuntimeError("Flutter Android Gradle build file missing")
