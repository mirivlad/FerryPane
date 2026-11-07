import 'dart:convert';
import 'dart:io';

/// Network-interface IPv4 address and mask. Only directly attached local
/// address ranges are eligible for automatic discovery. Never scan Internet
/// hosts, enumerate arbitrary subnets, or send traffic via public interfaces.
class LocalSubnet {
  final String address;
  final int? prefix;
  final String interfaceName;

  const LocalSubnet(this.address, this.prefix, this.interfaceName);

  static int? parseIPv4(String input) {
    final parts = input.split('.');
    if (parts.length != 4) return null;
    var result = 0;
    for (final part in parts) {
      if (part.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(part)) return null;
      final n = int.tryParse(part);
      if (n == null || n > 255) return null;
      result = (result << 8) | n;
    }
    return result;
  }

  static String formatIPv4(int ip) =>
      '${(ip >> 24) & 255}.${(ip >> 16) & 255}.${(ip >> 8) & 255}.${ip & 255}';

  static bool isLocal(String address) {
    final ip = parseIPv4(address);
    if (ip == null) return false;
    final a = (ip >> 24) & 255;
    final b = (ip >> 16) & 255;
    // RFC1918, link-local, shared CGNAT and network-device benchmarking
    // networks. Never broadcast on a public IP, loopback or cellular network.
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254) ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 198 && (b == 18 || b == 19));
  }

  int? get _mask {
    if (prefix == null || prefix! < 8 || prefix! > 30) return null;
    return (0xffffffff << (32 - prefix!)) & 0xffffffff;
  }

  String? get broadcast {
    final ip = parseIPv4(address);
    final mask = _mask;
    if (ip == null || mask == null) return null;
    final result = ((ip & mask) | (~mask & 0xffffffff)) & 0xffffffff;
    return formatIPv4(result);
  }

  bool contains(String host) {
    final ip = parseIPv4(address);
    final peer = parseIPv4(host);
    final mask = _mask;
    return ip != null && peer != null && mask != null &&
        (ip & mask) == (peer & mask);
  }

  @override
  String toString() => '$interfaceName: $address/${prefix ?? '?'}';
}

bool _looksLikeMobile(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('rmnet') || lower.startsWith('wwan') ||
      lower.startsWith('pdp') || lower.contains('cellular') ||
      lower.contains('mobile broadband');
}

/// Discover actual interface prefixes instead of assuming /24. This matters
/// on VPNs, /23 home networks and multiple active Ethernet/Wi-Fi adapters.
Future<List<LocalSubnet>> listLocalSubnets() async {
  final entries = <LocalSubnet>[];
  try {
    if (Platform.isWindows) {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Get-NetIPAddress -AddressFamily IPv4 | '
            'Select-Object IPAddress,PrefixLength,InterfaceAlias | '
            'ConvertTo-Json -Compress',
      ]).timeout(const Duration(seconds: 6));
      if (result.exitCode == 0) {
        final value = jsonDecode(result.stdout.toString());
        for (final item in value is List ? value : [value]) {
          if (item is! Map) continue;
          final address = item['IPAddress']?.toString();
          final prefix = (item['PrefixLength'] as num?)?.toInt();
          final label = item['InterfaceAlias']?.toString() ?? '';
          if (address != null && !_looksLikeMobile(label) &&
              LocalSubnet.isLocal(address)) {
            entries.add(LocalSubnet(address, prefix, label));
          }
        }
      }
    } else if (Platform.isLinux) {
      final result = await Process.run('ip', ['-j', '-4', 'address', 'show'])
          .timeout(const Duration(seconds: 5));
      if (result.exitCode == 0) {
        final value = jsonDecode(result.stdout.toString());
        if (value is List) {
          for (final item in value) {
            if (item is! Map) continue;
            final label = item['ifname']?.toString() ?? '';
            if (_looksLikeMobile(label) || label == 'lo') continue;
            final addresses = item['addr_info'];
            if (addresses is! List) continue;
            for (final addr in addresses) {
              if (addr is! Map) continue;
              final ip = addr['local']?.toString();
              final prefix = (addr['prefixlen'] as num?)?.toInt();
              if (ip != null && LocalSubnet.isLocal(ip)) {
                entries.add(LocalSubnet(ip, prefix, label));
              }
            }
          }
        }
      }
    }
  } catch (_) {
    // Reduced distributions may lack iproute2; a limited-broadcast fallback
    // still works for an address explicitly bound to an interface.
  }
  if (entries.isEmpty) {
    try {
      final available = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in available) {
        if (_looksLikeMobile(iface.name)) continue;
        for (final addr in iface.addresses) {
          if (LocalSubnet.isLocal(addr.address)) {
            entries.add(LocalSubnet(addr.address, null, iface.name));
          }
        }
      }
    } catch (_) {}
  }
  // Interfaces can share aliases/addresses due to network namespaces.
  final byIp = <String, LocalSubnet>{};
  for (final subnet in entries) {
    byIp[subnet.address] = subnet;
  }
  return byIp.values.take(32).toList();
}
