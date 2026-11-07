import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ferrypane/core/files.dart';
import 'package:ferrypane/core/secure_peer.dart';
import 'package:ferrypane/core/transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('two fresh peers pair and transfer a directory with small and large files',
      () async {
    SharedPreferences.setMockInitialValues({});
    final alice = await PeerIdentity.load();
    SharedPreferences.setMockInitialValues({});
    final bob = await PeerIdentity.load();
    expect(alice.publicString, isNot(bob.publicString));

    final base = await Directory.systemTemp.createTemp('ferrypane_lan_');
    final sourceDir = Directory('${base.path}/album');
    final nested = Directory('${sourceDir.path}/nested');
    await nested.create(recursive: true);
    await File('${sourceDir.path}/hello.txt').writeAsString('Привет, FerryPane!');
    await File('${nested.path}/empty.txt').writeAsBytes([]);
    final payload = List<int>.generate(720000, (i) => (i * 7) % 256);
    await File('${nested.path}/large.bin').writeAsBytes(payload);
    for (var i = 0; i < 30; i++) {
      await File('${nested.path}/small-$i.txt').writeAsString('file:$i');
    }
    final destDir = Directory('${base.path}/received');
    await destDir.create();

    final aReady = Completer<void>();
    final bReady = Completer<void>();
    final complete = Completer<void>();
    String? codeA;
    String? codeB;
    SecurePeer? sender;
    SecurePeer? receiver;
    IncomingTransfer? incoming;
    Completer<void>? flowWaiter;

    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      late SecurePeer b;
      b = SecurePeer(
        socket: ws,
        identity: bob,
        initiator: false,
        approve: (name, code, key) async {
          codeB = code;
          return true;
        },
        onJson: (msg) async {
          if (msg['type'] == 'upload_start') {
            incoming = IncomingTransfer(destDir.path, (_) {});
          } else if (const {
            'dir',
            'file_begin',
            'file_end',
            'transfer_end',
          }.contains(msg['type'])) {
            await incoming!.consume(msg, b);
            if (msg['type'] == 'transfer_end' && !complete.isCompleted) {
              complete.complete();
            }
          }
        },
        onChunk: (Uint8List bytes) async => incoming!.consumeChunk(bytes, b),
        onDisconnected: (_) {},
        onReady: () => bReady.complete(),
      );
      receiver = b;
      unawaited(b.run());
    });

    try {
      final ws = await WebSocket.connect('ws://127.0.0.1:${http.port}');
      late SecurePeer a;
      a = SecurePeer(
        socket: ws,
        identity: alice,
        initiator: true,
        approve: (name, code, key) async {
          codeA = code;
          return true;
        },
        onJson: (msg) async {
          if (msg['type'] == 'flow_ack') {
            final waiter = flowWaiter;
            if (waiter != null && !waiter.isCompleted) waiter.complete();
          }
        },
        onChunk: (_) async {},
        onDisconnected: (_) {},
        onReady: () => aReady.complete(),
      );
      sender = a;
      unawaited(a.run());

      await Future.wait([aReady.future, bReady.future])
          .timeout(const Duration(seconds: 20));
      expect(codeA, isNotNull);
      expect(codeA, codeB);
      expect(a.ready, isTrue);
      expect(receiver!.ready, isTrue);

      await a.sendJson({'type': 'upload_start', 'dest': ''});
      await streamTransfer(
        walkLocalSelection([sourceDir.path]),
        a,
        (_) {},
        () async {
          final waiter = Completer<void>();
          flowWaiter = waiter;
          await waiter.future.timeout(const Duration(seconds: 15));
          flowWaiter = null;
        },
      );
      await complete.future.timeout(const Duration(seconds: 20));
      expect(
        await File('${destDir.path}/album/hello.txt').readAsString(),
        'Привет, FerryPane!',
      );
      expect(
        await File('${destDir.path}/album/nested/large.bin').readAsBytes(),
        payload,
      );
      expect(
        await File('${destDir.path}/album/nested/empty.txt').length(),
        0,
      );
      for (var i = 0; i < 30; i++) {
        expect(
          await File('${destDir.path}/album/nested/small-$i.txt')
              .readAsString(),
          'file:$i',
        );
      }
    } finally {
      await sender?.disconnect();
      await receiver?.disconnect();
      await http.close(force: true);
      await base.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
