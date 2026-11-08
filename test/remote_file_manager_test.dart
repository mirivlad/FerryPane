import 'dart:async';
import 'dart:io';

import 'package:ferrypane/core/secure_peer.dart';
import 'package:ferrypane/core/file_operations.dart';
import 'package:ferrypane/core/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_identity_store.dart';

Future<void> waitUntil(bool Function() check) async {
  final until = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(until)) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  throw TimeoutException('Peer handshake was not completed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('encrypted remote CRUD and search enforce peer write grant', () async {
    SharedPreferences.setMockInitialValues({});
    final alice = await PeerIdentity.load(secretStore: MemoryIdentityStore());
    SharedPreferences.setMockInitialValues({});
    final bob = await PeerIdentity.load(secretStore: MemoryIdentityStore());
    final root = await Directory.systemTemp.createTemp('ferrypane_ops_');
    final aRoot = Directory(p.join(root.path, 'A'))..createSync();
    final bRoot = Directory(p.join(root.path, 'B'))..createSync();
    final a = FerryService(
      alice, (_, __, ___) async => true, aRoot.path,
      listenPort: 0, enableDiscovery: false,
    );
    final b = FerryService(
      bob, (_, __, ___) async => true, bRoot.path,
      listenPort: 0, enableDiscovery: false,
    );
    try {
      await a.start();
      await b.start();
      b.setPairingOpen(true);
      await a.connect('ws://127.0.0.1:' + b.boundPort.toString());
      await waitUntil(() =>
          a.connected?.ready == true && b.connected?.ready == true);

      // Fresh peers have read-only permission.
      await expectLater(
        a.remoteFileOp('mkdir', path: 'created'),
        throwsA(isA<StateError>()),
      );
      await b.setPeerAccess(read: true, write: true);
      await a.remoteFileOp('mkdir', path: 'created');
      await File(p.join(bRoot.path, 'created', 'report.txt'))
          .writeAsString('hello');
      expect((await a.remoteSearch('', 'report')).single.path,
          'created/report.txt');
      await a.remoteFileOp('copy', path: 'created/report.txt',
          target: 'created/report-backup.txt');
      expect(await File(p.join(bRoot.path, 'created',
          'report-backup.txt')).readAsString(), 'hello');
      await a.remoteFileOp('rename', path: 'created/report-backup.txt',
          target: 'created/renamed.txt');
      await a.remoteFileOp('delete', path: 'created/renamed.txt');
      expect(await File(p.join(bRoot.path, 'created',
          'renamed.txt')).exists(), isFalse);

      final expectedDigest =
          await a.remoteTreeDigest(['created/report.txt']);
      expect(expectedDigest,
          await FileManagerOps.digestLocal([
            p.join(bRoot.path, 'created', 'report.txt'),
          ]));
      await File(p.join(bRoot.path, 'created', 'report.txt'))
          .writeAsString('changed');
      await expectLater(
        a.remoteFileOp('deleteVerified',
            path: 'created/report.txt', expectedDigest: expectedDigest),
        throwsA(isA<StateError>()),
      );

      await b.setPeerAccess(read: true, write: false);
      await expectLater(
        a.remoteFileOp('delete', path: 'created/report.txt'),
        throwsA(isA<StateError>()),
      );
      expect(await File(p.join(bRoot.path, 'created',
          'report.txt')).readAsString(), 'changed');
    } finally {
      a.dispose();
      b.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
