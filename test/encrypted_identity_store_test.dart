import 'dart:convert';
import 'dart:io';

import 'package:ferrypane/core/encrypted_identity_store.dart';
import 'package:ferrypane/core/identity_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('explicit Linux encrypted file survives restart and rejects bad password',
      () async {
    if (!Platform.isLinux) return;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = await Directory.systemTemp.createTemp('ferrypane_secret_');
    final encrypted = p.join(dir.path, 'ferrypane', 'identity.enc');
    final original = base64Url.encode(List<int>.generate(32, (i) => i));
    try {
      final store = EncryptedFileIdentityStore(
        path: encrypted, requireExisting: false,
        passphrase: 'my-long-test-passphrase-1234',
      );
      final seed = await IdentityKeyMigration.loadOrMigrate(prefs, store,
          newSeed: () => original);
      expect(seed, original);
      expect(await File(encrypted).exists(), isTrue);
      expect(await File(encrypted).readAsString(), isNot(contains(original)));
      final again = EncryptedFileIdentityStore(
        path: encrypted, requireExisting: true,
        passphrase: 'my-long-test-passphrase-1234',
      );
      expect(await again.read(), original);
      final wrong = EncryptedFileIdentityStore(
        path: encrypted, requireExisting: true,
        passphrase: 'wrong-password-12345',
      );
      await expectLater(wrong.read(), throwsA(isA<StateError>()));
      final missing = EncryptedFileIdentityStore(
        path: p.join(dir.path, 'missing.enc'), requireExisting: true,
        passphrase: 'my-long-test-passphrase-1234',
      );
      await expectLater(missing.read(), throwsA(isA<StateError>()));
      expect(await again.read(), original);
    } finally {
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('corrupt encrypted identity cannot silently create a new key', () async {
    if (!Platform.isLinux) return;
    final dir = await Directory.systemTemp.createTemp('ferrypane_bad_secret_');
    try {
      final path = p.join(dir.path, 'identity.enc');
      await File(path).writeAsString('not json');
      final store = EncryptedFileIdentityStore(path: path,
          passphrase: 'my-long-test-passphrase-1234');
      await expectLater(store.read(), throwsA(isA<StateError>()));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
