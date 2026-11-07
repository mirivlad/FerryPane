#!/usr/bin/env python3
"""Patch generated Flutter Android project for LAN discovery and secure builds."""
from pathlib import Path
import re

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
]
for perm in permissions:
    if f'android:name="{perm}"' not in content:
        content = content.replace(
            "<application",
            f'    <uses-permission android:name="{perm}"/>\n    <application',
            1,
        )
content = re.sub(
    r'<application(?![^>]*android:usesCleartextTraffic)',
    '<application android:usesCleartextTraffic="true"',
    content,
    count=1,
)
manifest.write_text(content)

main_activity = root / "android/app/src/main/kotlin/top/mirv/ferrypane/MainActivity.kt"
main_activity.parent.mkdir(parents=True, exist_ok=True)
main_activity.write_text(r'''package top.mirv.ferrypane

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val connectivity by lazy {
        applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ferrypane/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "deviceModel") {
                    val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
                    val model = Build.MODEL
                    result.success(
                        if (model.startsWith(manufacturer, true)) model else "$manufacturer $model"
                    )
                } else result.notImplemented()
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ferrypane/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanNetworks" -> {
                        val payload = call.argument<String>("payload") ?: ""
                        val port = call.argument<Int>("port") ?: 47656
                        executor.execute {
                            val matches = try {
                                scanLocalNetworks(payload, port)
                            } catch (_: Exception) {
                                emptyList()
                            }
                            runOnUiThread { result.success(matches) }
                        }
                    }
                    "bindForPeer" -> {
                        val host = call.argument<String>("host") ?: ""
                        val status = try {
                            bindForLocalPeer(host)
                        } catch (e: Exception) {
                            "Ошибка маршрута LAN: ${e.message}"
                        }
                        result.success(status)
                    }
                    else -> result.notImplemented()
                }
            }

        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("FerryPane LAN discovery")
            multicastLock?.setReferenceCounted(false)
            multicastLock?.acquire()
        } catch (_: Exception) {
            // Manual connection by IP continues to work.
        }
    }

    // Exclude public Internet and carrier networks from broadcast discovery.
    private fun localIpv4(ip: InetAddress): Boolean {
        if (ip !is Inet4Address) return false
        val a = ip.address[0].toInt() and 255
        val b = ip.address[1].toInt() and 255
        return a == 10 ||
            (a == 172 && b in 16..31) ||
            (a == 192 && b == 168) ||
            (a == 169 && b == 254) ||
            (a == 100 && b in 64..127) ||
            (a == 198 && b in 18..19)
    }

    private fun addressNumber(ip: InetAddress): Long {
        return ip.address.fold(0L) { acc, part -> (acc shl 8) or (part.toLong() and 255) }
    }

    private fun isSameSubnet(ip: InetAddress, other: InetAddress, prefix: Int): Boolean {
        if (prefix !in 1..32) return false
        val mask = (0xffffffffL shl (32 - prefix)) and 0xffffffffL
        return (addressNumber(ip) and mask) == (addressNumber(other) and mask)
    }

    private fun broadcast(ip: InetAddress, prefix: Int): InetAddress? {
        if (prefix !in 8..30) return null
        val mask = (0xffffffffL shl (32 - prefix)) and 0xffffffffL
        val result = ((addressNumber(ip) and mask) or (mask.inv() and 0xffffffffL))
        return InetAddress.getByAddress(
            byteArrayOf(
                (result shr 24).toByte(),
                (result shr 16).toByte(),
                (result shr 8).toByte(),
                result.toByte()
            )
        )
    }

    private fun eligibleNetworks(): List<Network> {
        return connectivity.allNetworks.filter { network ->
            val caps = connectivity.getNetworkCapabilities(network) ?: return@filter false
            // Physical Wi-Fi/Ethernet are essential under a local VPN.
            // VPN networks with RFC1918 interfaces can be tried opportunistically.
            val usable = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            usable && !caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        }
    }

    private fun scanLocalNetworks(payload: String, port: Int): List<Map<String, String>> {
        if (payload.isEmpty() || port !in 1..65535) return emptyList()
        val output = mutableListOf<Map<String, String>>()
        val seen = mutableSetOf<String>()
        val bytes = payload.toByteArray(Charsets.UTF_8)
        for (network in eligibleNetworks().take(16)) {
            val links = connectivity.getLinkProperties(network)?.linkAddresses ?: continue
            for (link in links) {
                if (!localIpv4(link.address)) continue
                val target = broadcast(link.address, link.prefixLength) ?: continue
                try {
                    // Network.bindSocket selects the underlying Wi-Fi/Ethernet
                    // route even if the system default route is a VPN.
                    DatagramSocket(null).use { socket ->
                        socket.reuseAddress = true
                        socket.broadcast = true
                        socket.bind(InetSocketAddress(0))
                        network.bindSocket(socket)
                        socket.soTimeout = 700
                        socket.send(DatagramPacket(bytes, bytes.size, target, port))
                        // Replies go to the socket's ephemeral source port;
                        // listening on the Dart wildcard socket alone is not
                        // sufficient when Android has a VPN tunnel active.
                        val deadline = System.currentTimeMillis() + 700
                        while (System.currentTimeMillis() < deadline) {
                            val buffer = ByteArray(4096)
                            val response = DatagramPacket(buffer, buffer.size)
                            try {
                                socket.receive(response)
                                val host = response.address.hostAddress ?: continue
                                val body = String(response.data, 0, response.length, Charsets.UTF_8)
                                if (body.length > 4000 || !body.contains("ferrypane_peer")) continue
                                val json = JSONObject(body)
                                if (json.optString("type") != "ferrypane_peer") continue
                                if (!localIpv4(response.address) || !seen.add(json.optString("identity") + ":" + host)) {
                                    continue
                                }
                                output.add(mapOf("host" to host, "payload" to body))
                            } catch (_: SocketTimeoutException) {
                                break
                            }
                        }
                    }
                } catch (_: Exception) {
                    // A VPN with lockdown or without allowBypass() may block
                    // physical-network sockets. We must not weaken that policy.
                }
            }
        }
        return output
    }

    private fun bindForLocalPeer(host: String): String {
        val remote = try { InetAddress.getByName(host) } catch (_: Exception) { return "Неизвестный адрес" }
        if (!localIpv4(remote)) return "Подключение по стандартному маршруту"
        for (network in eligibleNetworks()) {
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
            val links = connectivity.getLinkProperties(network)?.linkAddresses ?: continue
            if (links.any { link ->
                    localIpv4(link.address) && isSameSubnet(link.address, remote, link.prefixLength)
                }) {
                if (connectivity.bindProcessToNetwork(network)) {
                    return "LAN через Wi-Fi/Ethernet"
                }
                return "Android VPN не разрешил отдельный LAN-маршрут"
            }
        }
        // VPN-private subnets are still reachable via the system default
        // route if configured by the VPN; do not bypass them.
        connectivity.bindProcessToNetwork(null)
        return "Стандартный маршрут сети/VPN"
    }

    override fun onDestroy() {
        try {
            executor.shutdownNow()
            connectivity.bindProcessToNetwork(null)
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } finally {
            super.onDestroy()
        }
    }
}
''')
print("Patched Android LAN permissions, network selection and model name")

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
    gradle.write_text(text)
    print("Configured deterministic release signing from private key.properties")
else:
    raise RuntimeError("Flutter Android Gradle build file missing")
