import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ferrypane/core/secure_peer.dart';
import 'package:ferrypane/core/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_identity_store.dart';

Future<void> waitUntil(bool Function() condition) async {
  for (var i = 0; i < 150; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException('Expected session state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stale list/error frames cannot corrupt another operation or connection',
      () async {
    SharedPreferences.setMockInitialValues({});
    final aliceId =
        await PeerIdentity.load(secretStore: MemoryIdentityStore());
    SharedPreferences.setMockInitialValues({});
    final bobId =
        await PeerIdentity.load(secretStore: MemoryIdentityStore());
    final base = await Directory.systemTemp.createTemp('ferrypane_protocol_');
    final alice = FerryService(
      aliceId, (_, __, ___) async => true, base.path,
      listenPort: 0, enableDiscovery: false,
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    SecurePeer? serverPeer;
    final firstDownloadReceived = Completer<void>();
    final allowTargetedError = Completer<void>();
    var downloadRequests = 0;
    final sessionReady = Completer<void>();

    final entries = (String name) => [
      {'name': name, 'path': name, 'directory': false, 'size': 4}
    ];

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      late SecurePeer peer;
      peer = SecurePeer(
        socket: socket,
        identity: bobId,
        initiator: false,
        approve: (_, __, ___) async => true,
        onJson: (msg) async {
          if (msg['type'] == 'list') {
            final id = msg['id'] as int;
            // A plausible stale response and error from a prior operation.
            await peer.sendJson({
              'type': 'list_result', 'id': id - 1,
              'entries': entries('obsolete.txt'),
            });
            await peer.sendJson({
              'type': 'error', 'id': id - 1,
              'message': 'old list failed',
            });
            await peer.sendJson({
              'type': 'future_extension', 'ignored': true,
            });
            await peer.sendJson({
              'type': 'list_result', 'id': id,
              'entries': entries('actual-$id.txt'),
            });
          } else if (msg['type'] == 'download') {
            downloadRequests++;
            final transferId = msg['transferId'] as String;
            await peer.sendJson({
              'type': 'error',
              'transferId': 'unrelated-stale-transfer',
              'message': 'stale transfer error',
            });
            // Legacy diagnostic without a transfer ID should not cancel an
            // ongoing copy, even though the human-readable status updates.
            await peer.sendJson({
              'type': 'error', 'message': 'diagnostic only',
            });
            if (downloadRequests == 1) {
              firstDownloadReceived.complete();
              await allowTargetedError.future;
            }
            await peer.sendJson({
              'type': 'error', 'transferId': transferId,
              'message': 'requested file not found',
            });
          }
        },
        onChunk: (_) async {},
        onDisconnected: (_) {},
        onReady: () {
          if (!sessionReady.isCompleted) sessionReady.complete();
        },
      );
      serverPeer = peer;
      unawaited(peer.run());
    });

    try {
      await alice.start();
      await alice.connect('ws://127.0.0.1:${server.port}');
      await sessionReady.future.timeout(const Duration(seconds: 10));
      await waitUntil(() => alice.connected?.ready == true);

      final first = await alice.remoteList('');
      expect(first.single.name, 'actual-1.txt');
      final second = await alice.remoteList('');
      expect(second.single.name, 'actual-2.txt');
      expect(alice.connected?.ready, isTrue);

      await expectLater(
        serverPeer!.sendChunk(
          Uint8List(SecurePeer.maxEncryptedChunkBytes),
        ),
        throwsFormatException,
      );
      expect(alice.connected?.ready, isTrue,
          reason: 'Local oversized-send rejection must not disconnect');

      await alice.download(['missing.txt'], base.path);
      await firstDownloadReceived.future.timeout(
        const Duration(seconds: 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await expectLater(
        alice.download(['next.txt'], base.path),
        throwsA(isA<StateError>()),
        reason: 'Stale error must not cancel the first in-flight transfer',
      );
      expect(alice.connected?.ready, isTrue);

      allowTargetedError.complete();
      await waitUntil(() =>
          alice.lastMessage.contains('requested file not found') ||
          alice.lastMessage.contains('Remote operation failed'));
      // The targeted error frees the transfer slot, permitting a new copy
      // attempt without disconnect/re-pairing.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await alice.download(['another.txt'], base.path);
      await waitUntil(() => downloadRequests == 2);
      expect(alice.connected?.ready, isTrue);
    } finally {
      if (!allowTargetedError.isCompleted) allowTargetedError.complete();
      alice.dispose();
      await serverPeer?.disconnect();
      await server.close(force: true);
      await base.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
