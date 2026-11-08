import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ferrypane/core/secure_peer.dart';
import 'package:ferrypane/core/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_identity_store.dart';

Future<void> waitUntil(bool Function() condition, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final until = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(until)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
  throw TimeoutException('Wait for transfer condition timed out');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('repeating a folder copy skips complete files, changed file gets suffix',
      () async {
    SharedPreferences.setMockInitialValues({});
    final aId = await PeerIdentity.load(secretStore: MemoryIdentityStore());
    SharedPreferences.setMockInitialValues({});
    final bId = await PeerIdentity.load(secretStore: MemoryIdentityStore());
    final root = await Directory.systemTemp.createTemp('ferrypane_repeat_');
    final aRoot = Directory('${root.path}/A')..createSync();
    final bRoot = Directory('${root.path}/B')..createSync();
    final folder = Directory('${aRoot.path}/Photos')..createSync();
    await File('${folder.path}/a.txt').writeAsString('original-A');
    await File('${folder.path}/b.txt').writeAsString('original-B');
    final a = FerryService(
      aId, (_, __, ___) async => true, aRoot.path,
      listenPort: 0, enableDiscovery: false,
    );
    final b = FerryService(
      bId, (_, __, ___) async => true, bRoot.path,
      listenPort: 0, enableDiscovery: false,
    );
    try {
      await a.start();
      await b.start();
      b.setPairingOpen(true);
      await a.connect('ws://127.0.0.1:${b.boundPort}');
      await waitUntil(() =>
          a.connected?.ready == true && b.connected?.ready == true);
      await b.setPeerAccess(read: true, write: true);
      await a.upload([folder.path], '');
      expect(await File('${bRoot.path}/Photos/a.txt').readAsString(),
          'original-A');

      // Repeat the same task. No Photos (1), no a (1).txt.
      await a.upload([folder.path], '');
      expect(await Directory('${bRoot.path}/Photos (1)').exists(), isFalse);
      expect(await File('${bRoot.path}/Photos/a (1).txt').exists(), isFalse);
      final visible = await a.remoteList('');
      expect(visible.where((e) => e.name == 'Photos').length, 1);
      expect(visible.any((e) => e.name == '.ferrypane-resume'), isFalse);

      // A source revision is never appended to the old copy or overwritten
      // over the previous successful file. Only the changed entry is copied.
      await File('${folder.path}/a.txt').writeAsString('updated-A');
      await a.upload([folder.path], '');
      expect(await File('${bRoot.path}/Photos/a.txt').readAsString(),
          'original-A');
      expect(await File('${bRoot.path}/Photos/a (1).txt').readAsString(),
          'updated-A');
      expect(await File('${bRoot.path}/Photos/b (1).txt').exists(), isFalse);
    } finally {
      a.dispose();
      b.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('interrupted folder copy resumes saved bytes across app restart',
      () async {
    SharedPreferences.setMockInitialValues({});
    final aId = await PeerIdentity.load(secretStore: MemoryIdentityStore());
    SharedPreferences.setMockInitialValues({});
    final bId = await PeerIdentity.load(secretStore: MemoryIdentityStore());
    final root = await Directory.systemTemp.createTemp('ferrypane_resume_');
    final aRoot = Directory('${root.path}/A')..createSync();
    final bRoot = Directory('${root.path}/B')..createSync();
    final folder = Directory('${aRoot.path}/Documents')..createSync();
    await File('${folder.path}/first.txt').writeAsString('ready');
    final big = File('${folder.path}/large.bin');
    await big.writeAsBytes(List<int>.filled(12 * 1024 * 1024, 0x54));
    await File('${folder.path}/last.txt').writeAsString('last');

    var disconnected = false;
    var sawResume = false;
    var observedRestartBegin = false;
    var restarting = false;
    late FerryService server;
    void onProgress(String path, int done, int total) {
      if (restarting && path.endsWith('large.bin') &&
          !observedRestartBegin) {
        observedRestartBegin = true;
        sawResume = done > 0;
      }
      if (!disconnected && !restarting &&
          path.endsWith('large.bin') && done >= 1024 * 1024 &&
          done < total) {
        disconnected = true;
        unawaited(server.connected?.disconnect() ?? Future<void>.value());
      }
    }

    final a = FerryService(
      aId, (_, __, ___) async => true, aRoot.path,
      listenPort: 0, enableDiscovery: false,
    );
    server = FerryService(
      bId, (_, __, ___) async => true, bRoot.path,
      listenPort: 0, enableDiscovery: false,
      onTransferProgress: onProgress,
    );
    FerryService? a2;
    FerryService? b2;
    try {
      await a.start();
      await server.start();
      server.setPairingOpen(true);
      await a.connect('ws://127.0.0.1:${server.boundPort}');
      await waitUntil(() =>
          a.connected?.ready == true && server.connected?.ready == true);
      await server.setPeerAccess(read: true, write: true);

      final firstTry = a.upload([folder.path], '');
      await waitUntil(() => disconnected);
      await waitUntil(() =>
          a.connected == null && server.connected == null);
      await firstTry;
      expect(a.hasPendingCopy, isTrue);
      expect(await File('${bRoot.path}/Documents/first.txt').exists(), isTrue);

      // Simulate a full process stop on both ends, rather than only a
      // temporary network interruption. The destination journal and sender's
      // persisted pending selection both survive service reconstruction.
      a.dispose();
      server.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      restarting = true;
      b2 = FerryService(
        bId, (_, __, ___) async => true, bRoot.path,
        listenPort: 0, enableDiscovery: false,
        onTransferProgress: onProgress,
      );
      a2 = FerryService(
        aId, (_, __, ___) async => true, aRoot.path,
        listenPort: 0, enableDiscovery: false,
      );
      await b2.start();
      await a2.start();
      expect(a2.hasPendingCopy, isTrue,
          reason: 'Selection and destination must survive restart');
      await a2.connect('ws://127.0.0.1:${b2.boundPort}');
      await waitUntil(() => !a2!.hasPendingCopy &&
          File('${bRoot.path}/Documents/large.bin').existsSync());
      expect(sawResume, isTrue,
          reason: 'The resumed prefix should be reused, not retransmitted');
      expect(await File('${bRoot.path}/Documents/last.txt').readAsString(),
          'last');
      expect(await File('${bRoot.path}/Documents/first.txt').readAsString(),
          'ready');
      expect(await Directory('${bRoot.path}/Documents (1)').exists(), isFalse);
      final originalHash = await crypto.sha256.bind(big.openRead()).first;
      final transferredHash = await crypto.sha256.bind(
          File('${bRoot.path}/Documents/large.bin').openRead()).first;
      expect(transferredHash, originalHash);
    } finally {
      a.dispose();
      server.dispose();
      a2?.dispose();
      b2?.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
