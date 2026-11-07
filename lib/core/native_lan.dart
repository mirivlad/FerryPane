import 'dart:io';

import 'package:flutter/services.dart';

/// Android supports per-Network UDP sockets. They are needed when a VPN is
/// the default route but the physical Wi-Fi still hosts LAN peers.
class AndroidLanNetwork {
  static const _channel = MethodChannel('ferrypane/network');

  static Future<List<Map<String, String>>> scan(
    String probe,
    int port,
  ) async {
    if (!Platform.isAndroid) return const [];
    try {
      final response = await _channel.invokeListMethod<dynamic>(
        'scanNetworks',
        {'payload': probe, 'port': port},
      );
      if (response == null) return const [];
      return response.whereType<Map>().map((raw) {
        return raw.map((key, value) =>
            MapEntry(key.toString(), value.toString()));
      }).toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Bind only when the selected peer is on a directly attached physical LAN.
  /// Otherwise leave the system/VPN route active.
  static Future<String?> routeTo(String host) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>(
        'bindForPeer',
        {'host': host},
      );
    } on PlatformException catch (e) {
      return 'Маршрут LAN: ${e.message ?? e.code}';
    } on MissingPluginException {
      return null;
    }
  }
}
