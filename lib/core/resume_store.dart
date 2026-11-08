import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'files.dart';

/// Transfer state is scoped to (receiving directory, trusted sender key,
/// explicit source selection). It cannot be claimed by another paired device.
/// Stored within the destination so that a desktop/phone restart does not
/// destroy already verified bytes.
class ResumeStore {
  static const directoryName = '.ferrypane-resume';
  static const maxManifestBytes = 8 * 1024 * 1024;

  final String root;
  final String senderIdentity;
  final String scope;
  final Directory cache;
  final File manifestFile;
  final Map<String, dynamic> _manifest;

  ResumeStore._(
    this.root,
    this.senderIdentity,
    this.scope,
    this.cache,
    this.manifestFile,
    this._manifest,
  );

  static String fingerprint(String input) =>
      crypto.sha256.convert(utf8.encode(input)).toString();

  static String selectionScope(List<String> paths) =>
      fingerprint(jsonEncode(paths));

  static Future<ResumeStore> open(
    String receivingRoot,
    String senderIdentity,
    String scope,
  ) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(scope) ||
        senderIdentity.trim().isEmpty) {
      throw const FormatException('Invalid resume identity or selection');
    }
    final root = p.normalize(p.absolute(receivingRoot));
    if (!await Directory(root).exists()) {
      throw FileSystemException('Destination does not exist', root);
    }
    if (FileSystemEntity.typeSync(root, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Resume root must not be a symbolic link');
    }
    final storage = p.join(root, directoryName);
    if (FileSystemEntity.typeSync(storage, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Resume storage must not be a link');
    }
    final cache = Directory(p.join(
      storage,
      fingerprint('$senderIdentity\u0000$scope'),
    ));
    if (FileSystemEntity.typeSync(cache.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Resume job storage must not be a link');
    }
    await cache.create(recursive: true);
    final manifestFile = File(p.join(cache.path, 'manifest.json'));
    Map<String, dynamic> state = {
      'version': 1,
      'peer': senderIdentity,
      'scope': scope,
      'aliases': <String, String>{},
      'files': <String, dynamic>{},
    };
    if (await manifestFile.exists()) {
      if (await manifestFile.length() > maxManifestBytes) {
        throw const FormatException('Resume metadata is too large');
      }
      final decoded = jsonDecode(await manifestFile.readAsString());
      if (decoded is! Map) throw const FormatException('Invalid resume metadata');
      state = Map<String, dynamic>.from(decoded);
      if (state['version'] != 1 || state['peer'] != senderIdentity ||
          state['scope'] != scope ||
          state['aliases'] is! Map || state['files'] is! Map) {
        throw const FormatException('Resume metadata does not match this transfer');
      }
    }
    return ResumeStore._(
        root, senderIdentity, scope, cache, manifestFile, state);
  }

  Map<String, dynamic> get _files =>
      Map<String, dynamic>.from(_manifest['files'] as Map);

  Map<String, dynamic> get _aliases =>
      Map<String, dynamic>.from(_manifest['aliases'] as Map);

  /// Keep a root-directory alias stable between interrupted attempts.
  Future<String> directoryAlias(
    String original,
    Future<String> Function() chooseFresh,
  ) async {
    final name = sanitizeRelative(original);
    if (name.isEmpty || name.contains('/')) {
      throw const FormatException('Invalid directory root');
    }
    final aliases = _aliases;
    final old = aliases[name];
    if (old is String) {
      final existing = sanitizeRelative(old);
      if (existing.isEmpty || existing.contains('/')) {
        throw const FormatException('Invalid saved directory alias');
      }
      final target = containedPath(root, existing);
      if (await Directory(target).exists()) return existing;
    }
    final chosen = p.basename(await chooseFresh());
    validateDestinationPath(chosen, windows: Platform.isWindows);
    aliases[name] = chosen;
    _manifest['aliases'] = aliases;
    await _save();
    return chosen;
  }

  Map<String, dynamic>? entry(String relative) {
    final file = _files[sanitizeRelative(relative)];
    return file is Map ? Map<String, dynamic>.from(file) : null;
  }

  /// The returned relative path is validated again before every filesystem
  /// operation. A compromised manifest cannot escape the receiving root.
  String validatedTarget(String target) {
    final relative = sanitizeRelative(target);
    if (relative.isEmpty ||
        relative == directoryName ||
        relative.startsWith('$directoryName/')) {
      throw const FormatException('Invalid saved resume target');
    }
    validateDestinationPath(relative, windows: Platform.isWindows);
    return containedPath(root, relative);
  }

  File stageFor(String relative) {
    final key = fingerprint(sanitizeRelative(relative));
    final path = p.join(cache.path, '$key.part');
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Resume staging must not be a link');
    }
    return File(path);
  }

  Future<void> record(String relative, {
    required String target,
    required int size,
    required String sha256,
    required bool complete,
  }) async {
    validatedTarget(target);
    final name = sanitizeRelative(relative);
    if (name.isEmpty || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid file resume metadata');
    }
    final files = _files;
    files[name] = {
      'target': target,
      'size': size,
      'sha256': sha256,
      'complete': complete,
    };
    _manifest['files'] = files;
    await _save();
  }

  Future<void> _save() async {
    final encoded = jsonEncode(_manifest);
    if (encoded.length > maxManifestBytes) {
      throw const FormatException('Too much resume metadata');
    }
    final temp = File(p.join(cache.path, 'manifest.new'));
    if (FileSystemEntity.typeSync(temp.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Resume temporary metadata is a link');
    }
    await temp.writeAsString(encoded, flush: true);
    // Windows may reject replacing a file with rename; the metadata is
    // reconstructible from existing files, and we never delete user files.
    try {
      await temp.rename(manifestFile.path);
    } on FileSystemException {
      if (await manifestFile.exists()) await manifestFile.delete();
      await temp.rename(manifestFile.path);
    }
  }
}

/// Stream SHA-256; never read multi-gigabyte files into memory.
Future<String> hashFile(File file, {int? prefixBytes}) async {
  final stream = prefixBytes == null
      ? file.openRead()
      : file.openRead(0, prefixBytes);
  return (await crypto.sha256.bind(stream).first).toString();
}
