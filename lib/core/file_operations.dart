import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'files.dart';

class FileOperationResult {
  final String path;
  final bool skipped;
  const FileOperationResult(this.path, {this.skipped = false});
}

/// Common local and encrypted-peer operations. No silent overwrite, root
/// deletion, path traversal or symlink traversal.
class FileManagerOps {
  static const actions = {'mkdir', 'rename', 'delete', 'move', 'copy'};
  static const conflicts = {'skip', 'keepBoth', 'replace'};

  static Future<FileOperationResult> remote(String root, String action,
      {required String path, String? target,
      String conflict = 'keepBoth'}) async {
    _validateRequest(action, conflict);
    final source = sanitizeRelative(path);
    if (source.isEmpty) throw const FormatException('Root mutation denied');
    final absolute = containedPath(root, source);
    String? destination;
    if (target != null) {
      final rel = sanitizeRelative(target);
      if (rel.isEmpty) throw const FormatException('Invalid destination');
      validateDestinationPath(rel, windows: Platform.isWindows);
      destination = containedPath(root, rel);
    }
    final result = await _perform(action, absolute, destination, conflict);
    return FileOperationResult(
        p.relative(result.path, from: p.normalize(p.absolute(root)))
            .replaceAll('\\', '/'),
        skipped: result.skipped);
  }

  static Future<FileOperationResult> local(String action,
      {required String path, String? target,
      String conflict = 'keepBoth'}) async {
    _validateRequest(action, conflict);
    return _perform(action, _localPath(path),
        target == null ? null : _localPath(target), conflict);
  }

  static void _validateRequest(String action, String conflict) {
    if (!actions.contains(action) || !conflicts.contains(conflict)) {
      throw const FormatException('Unsupported file operation');
    }
  }

  static String _localPath(String path) {
    final absolute = p.normalize(p.absolute(path));
    final parent = p.dirname(absolute);
    if (parent == absolute) {
      throw const FormatException('Cannot modify filesystem root');
    }
    final name = p.basename(absolute);
    validateDestinationPath(name, windows: Platform.isWindows);
    return containedPath(parent, name);
  }

  static Future<FileOperationResult> _perform(
      String action, String source, String? target, String conflict) async {
    if (action == 'mkdir') {
      if (await _exists(source)) {
        throw FileSystemException('Directory already exists', source);
      }
      if (!await Directory(p.dirname(source)).exists()) {
        throw FileSystemException('Parent directory missing', source);
      }
      await Directory(source).create();
      return FileOperationResult(source);
    }

    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      throw FileSystemException('File not found or unsafe symlink', source);
    }
    if (action == 'delete') {
      await _remove(source);
      return FileOperationResult(source);
    }
    if (target == null) throw const FormatException('Destination required');
    if (target == source) {
      if (action == 'rename') return FileOperationResult(source);
      if (action == 'copy' && conflict == 'keepBoth') {
        target = await _unused(target);
      } else if (action == 'copy' && conflict == 'skip') {
        return FileOperationResult(target, skipped: true);
      } else {
        throw const FormatException('Identical source and destination');
      }
    }
    if (p.isWithin(target, source) ||
        (type == FileSystemEntityType.directory && p.isWithin(source, target))) {
      throw const FormatException('Cannot replace an ancestor or copy into itself');
    }
    if (!await Directory(p.dirname(target)).exists()) {
      throw FileSystemException('Destination directory missing', target);
    }
    if (action == 'rename' && p.dirname(source) != p.dirname(target)) {
      throw const FormatException('Rename must stay within same directory');
    }
    var finalTarget = target;
    if (await _exists(finalTarget)) {
      if (conflict == 'skip') {
        return FileOperationResult(finalTarget, skipped: true);
      }
      if (conflict == 'keepBoth') finalTarget = await _unused(finalTarget);
    }
    if (action == 'rename' && !await _exists(finalTarget)) {
      await _rename(source, finalTarget);
      return FileOperationResult(finalTarget);
    }

    if (action != 'copy' && action != 'move' && action != 'rename') {
      throw const FormatException('Unsupported operation');
    }
    // Stage and SHA256-verify before touching the old destination.
    final random = Random.secure().nextInt(1 << 30);
    final stageName = '.ferrypane-stage-' +
        DateTime.now().microsecondsSinceEpoch.toString() + '-$random';
    final stage = p.join(p.dirname(finalTarget), stageName);
    String? backup;
    var staged = false;
    var committed = false;
    try {
      staged = true;
      await _copyTree(source, stage);
      await _verifyTree(source, stage);
      if (await _exists(finalTarget)) {
        if (conflict != 'replace') {
          throw FileSystemException('Destination appeared', finalTarget);
        }
        backup = p.join(p.dirname(finalTarget),
            '.ferrypane-backup-' + DateTime.now().microsecondsSinceEpoch.toString()
                + '-$random');
        await _rename(finalTarget, backup);
      }
      try {
        await _rename(stage, finalTarget);
        staged = false;
        committed = true;
      } catch (_) {
        if (backup != null) {
          await _rename(backup, finalTarget);
          backup = null;
        }
        rethrow;
      }
      if (backup != null) {
        await _remove(backup);
        backup = null;
      }
      if (action == 'move' || action == 'rename') {
        await _remove(source);
      }
      return FileOperationResult(finalTarget);
    } finally {
      if (staged && await _exists(stage)) await _remove(stage);
      // Never roll back an already committed copy when source cleanup fails.
      if (!committed && backup != null && await _exists(backup) &&
          !await _exists(finalTarget)) {
        await _rename(backup, finalTarget);
      }
    }
  }

  static Future<bool> _exists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound;

  static Future<void> _rename(String from, String to) async {
    final type = await FileSystemEntity.type(from, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(from).rename(to);
    } else if (type == FileSystemEntityType.file) {
      await File(from).rename(to);
    } else {
      throw FileSystemException('Invalid source', from);
    }
  }

  static Future<void> _remove(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else {
      throw FileSystemException('Refusing symlink or missing target', path);
    }
  }

  static Future<String> _unused(String target) async {
    if (!await _exists(target)) return target;
    final parent = p.dirname(target);
    final stem = p.basenameWithoutExtension(target);
    final ext = p.extension(target);
    for (var i = 1; i <= 9999; i++) {
      final candidate = p.join(parent, '$stem ($i)$ext');
      if (!await _exists(candidate)) return candidate;
    }
    throw FileSystemException('No available filename', target);
  }


  /// Bounded recursive filename search. Search results have normal wire paths
  /// and can be opened from either panel. Do not scan unbounded trees.
  static Future<List<FileEntry>> search(String root, String relative,
      String query) async {
    final term = query.trim().toLowerCase();
    if (term.isEmpty || term.length > 120) {
      throw const FormatException('Search requires 1-120 characters');
    }
    final initial = containedPath(root, relative);
    final results = <FileEntry>[];
    var visited = 0;
    Future<void> walk(String directory, int depth) async {
      if (depth > 12 || visited >= 10000 || results.length >= 250) return;
      await for (final node in Directory(directory).list(followLinks: false)) {
        if (++visited >= 10000 || results.length >= 250) return;
        final name = p.basename(node.path);
        if (_internal(name)) continue;
        final type = await FileSystemEntity.type(node.path, followLinks: false);
        if (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.directory) continue;
        if (name.toLowerCase().contains(term)) {
          final stat = await node.stat();
          final rel = p.relative(node.path, from: root).replaceAll('\\', '/');
          results.add(FileEntry(name, rel,
              type == FileSystemEntityType.directory,
              type == FileSystemEntityType.directory ? 0 : stat.size,
              stat.modified));
        }
        if (type == FileSystemEntityType.directory) {
          await walk(node.path, depth + 1);
        }
      }
    }
    await walk(initial, 0);
    return results;
  }

  static bool _internal(String name) =>
      name == '.ferrypane-resume' ||
      name.startsWith('.ferrypane-stage-') ||
      name.startsWith('.ferrypane-backup-');

  static Future<void> _copyTree(String source, String destination) async {
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(source).copy(destination);
    } else if (type == FileSystemEntityType.directory) {
      await Directory(destination).create();
      await for (final node in Directory(source).list(followLinks: false)) {
        final name = p.basename(node.path);
        if (_internal(name)) continue;
        await _copyTree(node.path, p.join(destination, name));
      }
    } else {
      throw FileSystemException('Refusing to copy symlink or special file', source);
    }
  }

  static Future<void> _verifyTree(String source, String destination) async {
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.file) {
      if (await File(source).length() != await File(destination).length() ||
          await crypto.sha256.bind(File(source).openRead()).first !=
              await crypto.sha256.bind(File(destination).openRead()).first) {
        throw FileSystemException('SHA256 copy mismatch', source);
      }
    } else if (type == FileSystemEntityType.directory) {
      await for (final node in Directory(source).list(followLinks: false)) {
        final name = p.basename(node.path);
        if (_internal(name)) continue;
        await _verifyTree(node.path, p.join(destination, name));
      }
    } else {
      throw FileSystemException('Source changed during copy', source);
    }
  }
}
