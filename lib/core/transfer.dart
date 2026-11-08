import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'files.dart';
import 'secure_peer.dart';

/// Receiver writes into .part files and publishes only after SHA256 verification.
class IncomingTransfer {
  final String destinationRoot;
  final String transferId;
  final void Function(String) progress;

  RandomAccessFile? _openedFile;
  String? _temporaryPath;
  String? _finalPath;
  int _expected = 0;
  int _received = 0;
  AccumulatorSink<crypto.Digest>? _digest;
  ByteConversionSink? _hasher;
  int _chunkCounter = 0;
  final Map<String, String> _directoryAliases = {};
  final List<String> savedPaths = [];
  static const maxFileSize = 64 * 1024 * 1024 * 1024;
  static const maxTotalBytes = 128 * 1024 * 1024 * 1024;
  static const maxEntries = 100000;
  static const maxPathLength = 2048;
  int _totalDeclared = 0;
  int _entries = 0;
  final Random _random = Random.secure();

  void _recordEntry(String path, {int? fileSize}) {
    if (path.length > maxPathLength || path.isEmpty) {
      throw const FormatException('Transfer path exceeds safety limit');
    }
    if (++_entries > maxEntries) {
      throw const FormatException('Too many files and directories in transfer');
    }
    if (fileSize != null) {
      if (fileSize < 0 || fileSize > maxFileSize ||
          _totalDeclared > maxTotalBytes - fileSize) {
        throw const FormatException('Transfer size exceeds configured safety limits');
      }
      _totalDeclared += fileSize;
    }
  }


  String _destinationPath(String remoteRelative) {
    final clean = sanitizeRelative(remoteRelative);
    validateDestinationPath(clean, windows: Platform.isWindows);
    final components = clean.split('/');
    if (components.isNotEmpty &&
        _directoryAliases.containsKey(components.first)) {
      components[0] = _directoryAliases[components.first]!;
    }
    return containedPath(destinationRoot, components.join('/'));
  }

  IncomingTransfer(this.destinationRoot, this.progress, this.transferId);

  Future<void> consume(Map<String, dynamic> msg, SecurePeer peer) async {
    if (msg['transferId'] != transferId) {
      throw const FormatException('Wrong transfer ID');
    }
    switch (msg['type']) {
      case 'dir':
        final relative = sanitizeRelative(msg['path'] as String);
        _recordEntry(relative);
        validateDestinationPath(relative, windows: Platform.isWindows);
        if (!relative.contains('/')) {
          // A second copy of a whole directory gets its own root,
          // rather than mixing renamed files into the existing folder.
          final available = await _unusedName(
            containedPath(destinationRoot, relative),
          );
          _directoryAliases[relative] = p.basename(available);
        }
        final path = _destinationPath(relative);
        await Directory(path).create(recursive: true);
        break;
      case 'file_begin':
        if (_openedFile != null) throw const FormatException('Nested file_begin');
        final relative = sanitizeRelative(msg['path'] as String);
        final size = (msg['size'] as num).toInt();
        _recordEntry(relative, fileSize: size);
        final path = _destinationPath(relative);
        await Directory(p.dirname(path)).create(recursive: true);
        _finalPath = await _unusedName(path);
        _temporaryPath = '${_finalPath!}.ferrypane-'
            '${_random.nextInt(1 << 32).toRadixString(16)}-'
            '${DateTime.now().microsecondsSinceEpoch}.part';
        _openedFile = await File(_temporaryPath!).open(mode: FileMode.write);
        _received = 0;
        _expected = size;
        _digest = AccumulatorSink<crypto.Digest>();
        _hasher = crypto.sha256.startChunkedConversion(_digest!);
        progress('Receiving: ${msg['path']}');
        break;
      case 'file_end':
        if (_openedFile == null || _received != _expected) {
          throw const FormatException('Incomplete file');
        }
        _hasher!.close();
        final got = _digest!.events.single.toString();
        if (got != msg['sha256']) {
          throw const FormatException('SHA256 mismatch');
        }
        await _openedFile!.flush();
        await _openedFile!.close();
        _openedFile = null;
        await File(_temporaryPath!).rename(_finalPath!);
        savedPaths.add(_finalPath!);
        progress('Сохранено: ${_finalPath!}');
        _temporaryPath = null;
        _finalPath = null;
        break;
      case 'transfer_end':
        if (_openedFile != null) throw const FormatException('Transfer ended mid-file');
        progress(
          savedPaths.isEmpty
              ? 'Передача завершена: файлов не получено'
              : 'Получено ${savedPaths.length} файл(ов). Последний: ${savedPaths.last}',
        );
        break;
    }
  }

  Future<void> consumeChunk(Uint8List bytes, SecurePeer peer) async {
    if (bytes.length > SecurePeer.maxEncryptedChunkBytes - 1) {
      throw const FormatException('Transfer chunk exceeds protocol limit');
    }
    if (_openedFile == null) throw const FormatException('Chunk without file_begin');
    _received += bytes.length;
    if (_received > _expected) throw const FormatException('File exceeds declared size');
    await _openedFile!.writeFrom(bytes);
    _hasher!.add(bytes);
    _chunkCounter++;
    if (_chunkCounter % 8 == 0) {
      await peer.sendJson({'type': 'flow_ack', 'transferId': transferId, 'chunks': _chunkCounter});
    }
  }

  Future<void> abort() async {
    try {
      await _openedFile?.close();
    } catch (_) {}
    _openedFile = null;
    final temp = _temporaryPath;
    if (temp != null && await File(temp).exists()) {
      await File(temp).delete();
    }
  }

  static Future<String> _unusedName(String requested) async {
    if (!await File(requested).exists() && !await Directory(requested).exists()) {
      return requested;
    }
    final parent = p.dirname(requested);
    final extension = p.extension(requested);
    final stem = p.basenameWithoutExtension(requested);
    for (var n = 1; n <= 9999; n++) {
      final candidate = p.join(parent, '$stem ($n)$extension');
      if (!await File(candidate).exists() && !await Directory(candidate).exists()) {
        return candidate;
      }
    }
    throw const FileSystemException('Too many files with the same name');
  }
}

/// Send many files as one continuous encrypted stream, with bounded flow control.
Future<void> streamTransfer(
  Stream<TransferFile> files,
  SecurePeer peer,
  void Function(String) progress,
  Future<void> Function(int) awaitFlowAck, {
  required String transferId,
}) async {
  var chunks = 0;
  var count = 0;
  await for (final file in files) {
    final relative = sanitizeRelative(file.relative);
    if (file.directory) {
      await peer.sendJson({'type': 'dir', 'transferId': transferId, 'path': relative});
      continue;
    }
    final length = await File(file.absolute).length();
    await peer.sendJson({'type': 'file_begin', 'transferId': transferId, 'path': relative, 'size': length});
    final output = AccumulatorSink<crypto.Digest>();
    final hasher = crypto.sha256.startChunkedConversion(output);
    await for (final raw in File(file.absolute).openRead()) {
      // openRead produces chunks; subdivide to control memory use.
      for (var offset = 0; offset < raw.length; offset += 65536) {
        final end = offset + 65536 < raw.length ? offset + 65536 : raw.length;
        final data = Uint8List.fromList(raw.sublist(offset, end));
        hasher.add(data);
        await peer.sendChunk(data);
        chunks++;
        if (chunks % 8 == 0) await awaitFlowAck(chunks);
      }
    }
    hasher.close();
    await peer.sendJson({
      'type': 'file_end',
      'transferId': transferId,
      'sha256': output.events.single.toString(),
    });
    count++;
    progress('Sent $count files: ${file.relative}');
  }
  await peer.sendJson({'type': 'transfer_end', 'transferId': transferId});
  progress('Sent $count files');
}
