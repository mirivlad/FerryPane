import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The identity key is never persisted as plain text in application settings.
/// This interface is injectable so migration can be tested without OS keyrings.
abstract class IdentitySecretStore {
  Future<String?> read();
  Future<void> write(String value);
}

/// Platform-backed encryption/secret storage:
/// Android Keystore, Windows-protected storage, Linux Secret Service.
class SystemIdentitySecretStore implements IdentitySecretStore {
  const SystemIdentitySecretStore();

  static const _name = 'ferrypane.identity.seed.v1';
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _name);

  @override
  Future<void> write(String value) => _storage.write(key: _name, value: value);
}

/// Read-only migration of the original plaintext SharedPreferences key.
/// We never erase it before verifying secure-storage readback, and never fall
/// back to SharedPreferences if the operating system keyring fails.
class IdentityKeyMigration {
  static const legacyName = 'ferrypane.identity.seed';

  static List<int> parseSeed(String value) {
    late List<int> bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(value));
    } catch (_) {
      throw StateError('The FerryPane identity seed is invalid; no new identity was created.');
    }
    if (bytes.length != 32) {
      throw StateError('The FerryPane identity seed has an invalid length.');
    }
    return bytes;
  }

  static bool _sameSeed(String a, String b) {
    final left = parseSeed(a);
    final right = parseSeed(b);
    return crypto.sha256.convert(left) == crypto.sha256.convert(right);
  }

  static Future<String> loadOrMigrate(
    SharedPreferences prefs,
    IdentitySecretStore secure, {
    required String Function() newSeed,
  }) async {
    // IMPORTANT: Any keyring exception is fatal; silently making a new identity
    // here would break pairing and possibly trust the wrong device.
    var stored = await secure.read();
    final old = prefs.getString(legacyName);
    if (stored != null) {
      parseSeed(stored);
      if (old != null) {
        if (!_sameSeed(stored, old)) {
          throw StateError(
            'Conflicting identity keys in secure storage and legacy settings. '
            'Refusing to replace either identity.',
          );
        }
        if (!await prefs.remove(legacyName)) {
          throw StateError('Unable to remove old unprotected identity seed.');
        }
      }
      return stored;
    }

    if (old == null) {
      if (prefs.getKeys().any((key) => key.startsWith('trusted.'))) {
        throw StateError(
          'The saved identity key is unavailable but paired devices exist. '
          'Unlock or restore the operating-system keyring; no new key was created.',
        );
      }
    }

    final candidate = old ?? newSeed();
    parseSeed(candidate);
    await secure.write(candidate);
    stored = await secure.read();
    if (stored == null || !_sameSeed(stored, candidate)) {
      throw StateError(
        'The OS keyring did not confirm the identity key; '
        'legacy data has been preserved.',
      );
    }
    if (old != null && !await prefs.remove(legacyName)) {
      throw StateError('Secure migration completed but legacy cleanup failed.');
    }
    return stored;
  }
}
