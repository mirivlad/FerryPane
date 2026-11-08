import 'package:ferrypane/core/identity_storage.dart';

class MemoryIdentityStore implements IdentitySecretStore {
  String? value;
  bool throwOnRead = false;
  bool throwOnWrite = false;

  @override
  Future<String?> read() async {
    if (throwOnRead) throw StateError('Keyring is locked');
    return value;
  }

  @override
  Future<void> write(String candidate) async {
    if (throwOnWrite) throw StateError('Keyring is locked');
    value = candidate;
  }
}
