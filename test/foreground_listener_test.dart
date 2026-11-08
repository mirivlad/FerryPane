import 'dart:io';

import 'package:ferrypane/core/secure_peer.dart';
import 'package:ferrypane/core/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_identity_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('foreground handoff never leaves two listeners on the same port',
      () async {
    SharedPreferences.setMockInitialValues({});
    final identity =
        await PeerIdentity.load(secretStore: MemoryIdentityStore());
    final folder = await Directory.systemTemp.createTemp('ferry_handoff_');
    final freePort = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = freePort.port;
    await freePort.close();

    final ui = FerryService(
      identity,
      (_, __, ___) async => false,
      folder.path,
      listenPort: port,
      enableDiscovery: false,
    );
    FerryService? headless;
    try {
      await ui.start();
      expect(ui.boundPort, port);
      await ui.suspendIncoming();
      expect(ui.boundPort, isNull);
      expect(ui.incomingEnabled, isFalse);

      headless = FerryService(
        identity,
        (_, __, ___) async => false,
        folder.path,
        listenPort: port,
        enableDiscovery: false,
      );
      await headless.start();
      expect(headless.boundPort, port);
      headless.dispose();
      headless = null;
      await Future<void>.delayed(const Duration(milliseconds: 300));

      await ui.resumeIncoming();
      expect(ui.incomingEnabled, isTrue);
      expect(ui.boundPort, port);
    } finally {
      headless?.dispose();
      ui.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await folder.delete(recursive: true);
    }
  });
}
