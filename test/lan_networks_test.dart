import 'package:ferrypane/core/lan_networks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only local IPv4 addresses are eligible for automatic discovery', () {
    for (final ip in [
      '10.0.8.4', '172.18.12.8', '192.168.50.1', '169.254.3.5',
      '100.96.4.7', '198.18.0.8',
    ]) {
      expect(LocalSubnet.isLocal(ip), isTrue, reason: ip);
    }
    for (final ip in [
      '8.8.8.8', '1.1.1.1', '172.32.0.1', '192.0.2.2',
      '127.0.0.1', '0.0.0.0', '224.0.0.1', '255.255.255.255',
      '2001:db8::1', '192.168.1.999',
    ]) {
      expect(LocalSubnet.isLocal(ip), isFalse, reason: ip);
    }
  });

  test('directed broadcasts honor the actual prefix', () {
    expect(const LocalSubnet('192.168.10.25', 24, 'wlan').broadcast,
        '192.168.10.255');
    expect(const LocalSubnet('192.168.10.25', 23, 'wlan').broadcast,
        '192.168.11.255');
    expect(const LocalSubnet('10.8.10.22', 20, 'wg').broadcast,
        '10.8.15.255');
    expect(const LocalSubnet('10.0.0.2', 32, 'tun').broadcast, isNull);
    expect(const LocalSubnet('192.168.10.25', null, 'fallback').broadcast,
        isNull);
  });

  test('same subnet routing excludes distant/private or public peers', () {
    const lan = LocalSubnet('192.168.10.25', 23, 'Ethernet');
    expect(lan.contains('192.168.11.9'), isTrue);
    expect(lan.contains('192.168.12.1'), isFalse);
    expect(lan.contains('8.8.8.8'), isFalse);
    expect(const LocalSubnet('10.2.0.1', 16, 'VPN').contains('10.2.19.8'),
        isTrue);
  });
}
