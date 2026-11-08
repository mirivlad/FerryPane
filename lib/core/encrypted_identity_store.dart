import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'identity_storage.dart';

/// Linux-only, explicitly selected alternative to Secret Service.
/// Never persists a password or an unencrypted identity seed.
/// Password derivation: PBKDF2-HMAC-SHA256 (240k rounds, 256-bit key).
/// Encryption: random 96-bit AES-256-GCM nonce; atomic 0600 file write.
class EncryptedFileIdentityStore implements IdentitySecretStore {
  final String passphrase;
  final String path;
  final bool requireExisting;

  EncryptedFileIdentityStore({
    required this.passphrase,
    String? path,
    this.requireExisting = true,
  }) : path = path ?? defaultPath() {
    if (!Platform.isLinux) {
      throw UnsupportedError('Encrypted identity files are Linux-only');
    }
  }

  static String defaultPath() {
    final home = Platform.environment['HOME'];
    final config = Platform.environment['XDG_CONFIG_HOME'];
    if ((config == null || config.isEmpty) &&
        (home == null || home.isEmpty)) {
      throw StateError('HOME or XDG_CONFIG_HOME is required');
    }
    final directory = config != null && config.isNotEmpty
        ? config : p.join(home!, '.config');
    return p.join(directory, 'ferrypane', 'identity.enc');
  }

  final _cipher = AesGcm.with256bits();
  final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 240000,
    bits: 256,
  );

  Future<SecretKey> _derive(List<int> salt) =>
      _pbkdf2.deriveKeyFromPassword(password: passphrase, nonce: salt);

  @override
  Future<String?> read() async {
    final file = File(path);
    if (!await file.exists()) {
      if (requireExisting) {
        throw StateError('Encrypted identity file is missing. '
            'Refusing to create a different identity.');
      }
      return null;
    }
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['version'] != 1) {
        throw const FormatException('Invalid encrypted identity format');
      }
      final salt = base64Decode(json['salt'] as String);
      final nonce = base64Decode(json['nonce'] as String);
      final mac = base64Decode(json['mac'] as String);
      final ciphertext = base64Decode(json['ciphertext'] as String);
      if (salt.length != 16 || nonce.length != 12 || mac.length != 16 ||
          ciphertext.length > 256) {
        throw const FormatException('Invalid encrypted identity lengths');
      }
      final key = await _derive(salt);
      final clear = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: utf8.encode('FerryPane encrypted identity v1'),
      );
      final seed = utf8.decode(clear);
      IdentityKeyMigration.parseSeed(seed);
      return seed;
    } catch (_) {
      // Deliberately indistinguishable: wrong password or corrupted file.
      throw StateError('Unable to unlock encrypted identity. '
          'Check the password and file integrity. Nothing was reset.');
    }
  }

  @override
  Future<void> write(String value) async {
    if (requireExisting || await File(path).exists()) {
      throw StateError('Refusing to replace an existing identity file');
    }
    if (passphrase.runes.length < 12) {
      throw const FormatException('Passphrase must contain at least 12 characters');
    }
    IdentityKeyMigration.parseSeed(value);

    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final nonce = List<int>.generate(12, (_) => random.nextInt(256));
    final key = await _derive(salt);
    final encrypted = await _cipher.encrypt(
      utf8.encode(value),
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode('FerryPane encrypted identity v1'),
    );
    final json = jsonEncode({
      'version': 1,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'mac': base64Encode(encrypted.mac.bytes),
      'ciphertext': base64Encode(encrypted.cipherText),
    });

    final directory = Directory(p.dirname(path));
    await directory.create(recursive: true);
    await _chmod('700', directory.path);
    final suffix = random.nextInt(1 << 30);
    final temporary = File('$path.$suffix.tmp');
    try {
      await temporary.create(exclusive: true);
      await _chmod('600', temporary.path);
      await temporary.writeAsString(json, flush: true);
      if (await File(path).exists()) {
        throw StateError('Identity file already exists');
      }
      await temporary.rename(path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<void> _chmod(String mode, String file) async {
    final result = await Process.run('/bin/chmod', [mode, file]);
    if (result.exitCode != 0) {
      throw FileSystemException('Could not protect encrypted identity', file);
    }
  }
}
