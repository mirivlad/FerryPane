import 'dart:async';
import 'dart:io';

import 'package:ferrypane/core/secure_peer.dart';
import 'package:ferrypane/core/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_identity_store.dart';

Future<void> waitForCondition(bool Function() condition) async {
  for (var n = 0; n < 200; n++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  throw TimeoutException('Expected network condition did not become true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('two FerryServices can upload, browse and download without disconnecting',
      () async {
    SharedPreferences.setMockInitialValues({});
    final aIdentity = await PeerIdentity.load(secretStore: MemoryIdentityStore());
    SharedPreferences.setMockInitialValues({});
    final bIdentity = await PeerIdentity.load(secretStore: MemoryIdentityStore());
    final temp = await Directory.systemTemp.createTemp('ferrypane_service_');
    final aRoot = Directory('${temp.path}/A')..createSync();
    final bRoot = Directory('${temp.path}/B')..createSync();
    final dest = Directory('${temp.path}/receive')..createSync();

    final aFile = File('${aRoot.path}/a.txt');
    await aFile.writeAsString('From A');
    final bFile = File('${bRoot.path}/b.txt');
    await bFile.writeAsString('From B');

    final a = FerryService(aIdentity, (name, code, key) async => true, aRoot.path,
        listenPort: 0, enableDiscovery: false);
    final b = FerryService(bIdentity, (name, code, key) async => true, bRoot.path,
        listenPort: 0, enableDiscovery: false);
    try {
      await a.start();
      await b.start();
      expect(a.boundPort, greaterThan(0));
      expect(b.boundPort, greaterThan(0));

      b.setPairingOpen(true);
      await a.connect('ws://127.0.0.1:${b.boundPort}');
      await waitForCondition(() =>
          (a.connected?.ready ?? false) && (b.connected?.ready ?? false));

      // New peers cannot write until explicitly permitted on the destination.
      expect(b.peerCanWrite, isFalse);
      await b.setPeerAccess(read: true, write: true);
      await a.setPeerAccess(read: true, write: true);

      final initialFiles = await a.remoteList('');
      expect(initialFiles.any((x) => x.name == 'b.txt'), isTrue);

      await a.upload([aFile.path], '');
      expect(await File('${bRoot.path}/a.txt').readAsString(), 'From A');
      expect(a.connected?.ready, isTrue);
      expect(b.connected?.ready, isTrue);

      // A second transfer must not require reconnecting or re-pairing.
      await b.upload([bFile.path], '');
      expect(await File('${aRoot.path}/b.txt').readAsString(), 'From B');
      expect(a.connected?.ready, isTrue);
      expect(b.connected?.ready, isTrue);

      await a.download(['b.txt'], dest.path);
      await waitForCondition(
          () => File('${dest.path}/b.txt').existsSync());
      expect(await File('${dest.path}/b.txt').readAsString(), 'From B');

      // Verify that a successful download also leaves the session reusable.
      final remoteFiles = await a.remoteList('');
      expect(remoteFiles.any((x) => x.name == 'a.txt'), isTrue);
      expect(a.connected?.ready, isTrue);
      expect(b.connected?.ready, isTrue);
    } finally {
      a.dispose();
      b.dispose();
      await temp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
