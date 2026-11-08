import 'dart:io';
import 'package:path/path.dart' as p;

const _internalResumeDir = '.ferrypane-resume';

/// Wire paths always use slash separators and are relative to an exported root.
String sanitizeRelative(String value) {
  if (value.contains('\u0000')) throw const FormatException('NUL in path');
  if (value.length > 2048) {
    throw const FormatException('File path is too long');
  }
  final normalized = value.replaceAll('\\', '/');
  if (normalized.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(normalized)) {
    throw const FormatException('Absolute path is not permitted');
  }
  final parts = normalized.split('/');
  if (parts.length > 64 || parts.any((part) => part.length > 255)) {
    throw const FormatException('File path exceeds component limits');
  }
  if (parts.any((part) => part == _internalResumeDir)) {
    throw const FormatException('Internal resume metadata is not a shared path');
  }
  if (parts.any((part) => part == '..')) {
    throw const FormatException('Path traversal is not permitted');
  }
  return parts.where((part) => part.isNotEmpty && part != '.').join('/');
}

/// Reject Windows device aliases and path components that cannot be safely
/// created through ordinary Win32 APIs. Called only on the *receiving* side:
/// Linux/Android can continue transferring their legitimate filenames.
void validateDestinationPath(String relative, {required bool windows}) {
  if (!windows) return;
  final clean = sanitizeRelative(relative);
  final reserved = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$',
    caseSensitive: false,
  );
  final invalid = RegExp(r'[<>:"|?*\x00-\x1f]');
  for (final component in clean.split('/')) {
    if (component.isEmpty) continue;
    if (reserved.hasMatch(component) ||
        invalid.hasMatch(component) ||
        component.endsWith('.') ||
        component.endsWith(' ')) {
      throw const FormatException('Filename is not allowed on Windows');
    }
  }
}

/// Refuse symlinks even when their target points back under the root.
/// This deliberately prioritizes containment over following a user's links.
String containedPath(String root, String relative) {
  final clean = sanitizeRelative(relative);
  final base = p.normalize(p.absolute(root));
  if (FileSystemEntity.typeSync(base, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FileSystemException('Shared root cannot be a symbolic link');
  }
  final candidate = p.normalize(p.joinAll([base, ...clean.split('/').where((e) => e.isNotEmpty)]));
  if (candidate != base && !p.isWithin(base, candidate)) {
    throw const FormatException('Outside exported root');
  }
  var segment = base;
  final parts = clean.isEmpty ? <String>[] : clean.split('/');
  for (final part in parts) {
    segment = p.join(segment, part);
    if (FileSystemEntity.typeSync(segment, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Symbolic links are not exported');
    }
  }
  return candidate;
}

class FileEntry {
  final String name;
  final String path;
  final bool directory;
  final int size;
  final DateTime? modified;

  const FileEntry(this.name, this.path, this.directory, this.size,
      [this.modified]);

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        j['name'] as String,
        j['path'] as String,
        j['directory'] as bool,
        (j['size'] as num?)?.toInt() ?? 0,
        j['modified'] is num
            ? DateTime.fromMillisecondsSinceEpoch((j['modified'] as num).toInt())
            : null,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'directory': directory,
        'size': size,
        if (modified != null) 'modified': modified!.millisecondsSinceEpoch,
      };
}

Future<List<FileEntry>> listAt(String base, String relative) async {
  final dir = Directory(containedPath(base, relative));
  final output = <FileEntry>[];
  await for (final node in dir.list(followLinks: false)) {
    final type = await FileSystemEntity.type(node.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        p.basename(node.path) == _internalResumeDir ||
        p.basename(node.path).startsWith('.ferrypane-stage-') ||
        p.basename(node.path).startsWith('.ferrypane-backup-')) continue;
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.file) continue;
    final name = p.basename(node.path);
    final rel = relative.isEmpty ? name : '${sanitizeRelative(relative)}/$name';
    final isDir = type == FileSystemEntityType.directory;
    final stat = await node.stat();
    output.add(FileEntry(
      name, rel, isDir, isDir ? 0 : stat.size, stat.modified,
    ));
  }
  output.sort((a, b) {
    if (a.directory != b.directory) return a.directory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return output;
}

/// An entry in a transfer stream. All paths are relative to the selection,
/// not the machine's filesystem root.
class TransferFile {
  final String absolute;
  final String relative;
  final bool directory;
  const TransferFile(this.absolute, this.relative, this.directory);
}

Stream<TransferFile> walkSelection(String base, List<String> selected) async* {
  for (final relative in selected) {
    final clean = sanitizeRelative(relative);
    if (clean.isEmpty) throw const FormatException('Root transfer is not supported');
    final abs = containedPath(base, clean);
    final name = p.posix.basename(clean);
    final type = await FileSystemEntity.type(abs, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      yield* _walkDir(abs, name);
    } else if (type == FileSystemEntityType.file) {
      yield TransferFile(abs, name, false);
    } else {
      throw FileSystemException('Selected file unavailable', abs);
    }
  }
}

Stream<TransferFile> walkLocalSelection(List<String> selected) async* {
  for (final absolute in selected) {
    final name = p.basename(absolute);
    final type = await FileSystemEntity.type(absolute, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      yield* _walkDir(absolute, name);
    } else if (type == FileSystemEntityType.file) {
      yield TransferFile(absolute, name, false);
    } else {
      throw FileSystemException('Selected file unavailable', absolute);
    }
  }
}

Stream<TransferFile> _walkDir(String path, String relative) async* {
  yield TransferFile(path, sanitizeRelative(relative), true);
  await for (final item in Directory(path).list(followLinks: false)) {
    final type = await FileSystemEntity.type(item.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        p.basename(item.path) == _internalResumeDir) continue;
    final nested = '${sanitizeRelative(relative)}/${p.basename(item.path)}';
    if (type == FileSystemEntityType.directory) {
      yield* _walkDir(item.path, nested);
    } else if (type == FileSystemEntityType.file) {
      yield TransferFile(item.path, sanitizeRelative(nested), false);
    }
  }
}
