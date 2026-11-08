import 'dart:async';
import 'dart:io';

import 'package:ferrypane/core/file_operations.dart';
import 'package:ferrypane/core/secure_peer.dart';
import 'package:ferrypane/core/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_identity_store.dart';

Future<void> ready(bool Function() condition) async {
  final until = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(until)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  throw TimeoutException('Secure LAN handshake timeout');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('verified upload and download allow safe two-phase move', () async {
    SharedPreferences.setMockInitialValues({});
    final aId = await PeerIdentity.load(secretStore: MemoryIdentityStore());
    SharedPreferences.setMockInitialValues({});
    final bId = await PeerIdentity.load(secretStore: MemoryIdentityStore());
    final root = await Directory.systemTemp.createTemp('ferrypane_move_');
    final aRoot = Directory(p.join(root.path, 'A'))..createSync();
    final bRoot = Directory(p.join(root.path, 'B'))..createSync();
    final a = FerryService(
      aId, (_, __, ___) async => true, aRoot.path,
      listenPort: 0, enableDiscovery: false,
    );
    final b = FerryService(
      bId, (_, __, ___) async => true, bRoot.path,
      listenPort: 0, enableDiscovery: false,
    );
    try {
      final source = File(p.join(aRoot.path, 'from-a.txt'));
      await source.writeAsString('A to B verified content');
      final backwards = File(p.join(bRoot.path, 'from-b.txt'));
      await backwards.writeAsString('B to A verified content');
      await a.start();
      await b.start();
      b.setPairingOpen(true);
      await a.connect('ws://127.0.0.1:' + b.boundPort.toString());
      await ready(() =>
          a.connected?.ready == true && b.connected?.ready == true);
      await a.setPeerAccess(read: true, write: true, manage: true);
      await b.setPeerAccess(read: true, write: true, manage: true);

      final before = await FileManagerOps.digestLocal([source.path]);
      expect(await a.uploadVerified([source.path], ''), isTrue);
      expect(await a.remoteTreeDigest(['from-a.txt']), before);
      await FileManagerOps.local('deleteVerified', path: source.path,
          expectedDigest: before);
      expect(await source.exists(), isFalse);
      expect(await File(p.join(bRoot.path, 'from-a.txt')).readAsString(),
          'A to B verified content');

      final reverseDigest = await a.remoteTreeDigest(['from-b.txt']);
      await a.downloadAndWait(['from-b.txt'], aRoot.path);
      expect(await FileManagerOps.digestLocal([
        p.join(aRoot.path, 'from-b.txt'),
      ]), reverseDigest);
      await a.remoteFileOp('deleteVerified', path: 'from-b.txt',
          expectedDigest: reverseDigest);
      expect(await backwards.exists(), isFalse);
      expect(await File(p.join(aRoot.path, 'from-b.txt')).readAsString(),
          'B to A verified content');
    } finally {
      a.dispose();
      b.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
