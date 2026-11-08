import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'files.dart';
import 'resume_store.dart';
import 'secure_peer.dart';

/// File-level response to file_begin. All fields are in the encrypted session.
class ResumeReply {
  final int offset;
  final String prefixHash;
  final bool skip;

  const ResumeReply(this.offset, this.prefixHash, {this.skip = false});

  factory ResumeReply.fromJson(Map<String, dynamic> data) {
    final offset = data['offset'];
    final hash = data['prefixHash'];
    if (offset is! int || offset < 0 || hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) || data['skip'] is! bool) {
      throw const FormatException('Invalid file resume response');
    }
    return ResumeReply(offset, hash, skip: data['skip'] as bool);
  }
}

/// Receiver checks and stages all incoming data under a trusted destination.
/// A resume store is opt-in for ordinary file copies, not personal backups.
class IncomingTransfer {
  final String destinationRoot;
  final String transferId;
  final void Function(String) progress;
  final void Function(String, int, int)? onProgress;
  final ResumeStore? resumeStore;

  RandomAccessFile? _openedFile;
  String? _temporaryPath;
  String? _finalPath;
  String? _currentRelative;
  String? _sourceDigest;
  bool _skippedCurrent = false;
  int _expected = 0;
  int _received = 0;
  AccumulatorSink<crypto.Digest>? _digest;
  ByteConversionSink? _hasher;
  int _chunkCounter = 0;
  final Map<String, String> _directoryAliases = {};
  final List<String> savedPaths = [];
  int skippedFiles = 0;
  int resumedBytes = 0;
  int receivedBytes = 0;
  static const maxFileSize = 64 * 1024 * 1024 * 1024;
  static const maxTotalBytes = 128 * 1024 * 1024 * 1024;
  static const maxEntries = 100000;
  static const maxPathLength = 2048;
  int _totalDeclared = 0;
  int _entries = 0;
  final Random _random = Random.secure();

  IncomingTransfer(
    this.destinationRoot,
    this.progress,
    this.transferId, {
    this.resumeStore,
    this.onProgress,
  });

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
          if (resumeStore != null) {
            final alias = await resumeStore!.directoryAlias(
              relative,
              () => _unusedName(containedPath(destinationRoot, relative)),
            );
            _directoryAliases[relative] = alias;
          } else {
            final available = await _unusedName(
              containedPath(destinationRoot, relative),
            );
            _directoryAliases[relative] = p.basename(available);
          }
        }
        final target = _destinationPath(relative);
        await Directory(target).create(recursive: true);
        break;

      case 'file_begin':
        if (_openedFile != null || _currentRelative != null) {
          throw const FormatException('Nested file_begin');
        }
        final relative = sanitizeRelative(msg['path'] as String);
        final sourceDigest = msg['sha256'];
        if (sourceDigest is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceDigest)) {
          throw const FormatException('Missing source checksum');
        }
        final rawSize = msg['size'];
        if (rawSize is! int) throw const FormatException('Invalid file size');
        _recordEntry(relative, fileSize: rawSize);
        final requested = _destinationPath(relative);
        await Directory(p.dirname(requested)).create(recursive: true);

        _currentRelative = relative;
        _sourceDigest = sourceDigest;
        _expected = rawSize;
        _received = 0;
        _skippedCurrent = false;
        _digest = AccumulatorSink<crypto.Digest>();
        _hasher = crypto.sha256.startChunkedConversion(_digest!);

        if (resumeStore == null) {
          _finalPath = await _unusedName(requested);
          _temporaryPath = '${_finalPath!}.ferrypane-'
              '${_random.nextInt(1 << 32).toRadixString(16)}-'
              '${DateTime.now().microsecondsSinceEpoch}.part';
        } else {
          await _prepareResumable(relative, requested, rawSize, sourceDigest);
        }

        if (_skippedCurrent) {
          skippedFiles++;
          progress('Уже скопировано: $relative');
          onProgress?.call(relative, rawSize, rawSize);
          await peer.sendJson({
            'type': 'file_resume',
            'transferId': transferId,
            'path': relative,
            'offset': rawSize,
            'prefixHash': sourceDigest,
            'skip': true,
          });
          break;
        }

        final temporary = File(_temporaryPath!);
        final already = await temporary.exists() ? await temporary.length() : 0;
        if (already < 0 || already > rawSize) {
          throw const FormatException('Invalid partial file size');
        }
        // Hash the durable prefix into the final-file hash state before new
        // chunks arrive; the sender independently verifies prefixHash.
        if (already > 0) {
          await for (final bytes in temporary.openRead()) {
            _hasher!.add(bytes);
          }
        }
        _received = already;
        resumedBytes += already;
        _openedFile = await temporary.open(
          mode: already > 0 ? FileMode.append : FileMode.write,
        );
        final prefixHash = already == 0
            ? crypto.sha256.convert(const <int>[]).toString()
            : await hashFile(temporary);
        progress(already > 0
            ? 'Докачка: $relative с $already из $rawSize'
            : 'Получение: $relative');
        onProgress?.call(relative, already, rawSize);
        await peer.sendJson({
          'type': 'file_resume',
          'transferId': transferId,
          'path': relative,
          'offset': already,
          'prefixHash': prefixHash,
          'skip': false,
        });
        break;

      case 'file_reset':
        if (_currentRelative == null || _openedFile == null ||
            msg['path'] != _currentRelative) {
          throw const FormatException('Unexpected file reset');
        }
        await _openedFile!.close();
        _received = 0;
        _digest = AccumulatorSink<crypto.Digest>();
        _hasher = crypto.sha256.startChunkedConversion(_digest!);
        _openedFile = await File(_temporaryPath!).open(mode: FileMode.write);
        onProgress?.call(_currentRelative!, 0, _expected);
        await peer.sendJson({
          'type': 'file_resume',
          'transferId': transferId,
          'path': _currentRelative,
          'offset': 0,
          'prefixHash': crypto.sha256.convert(const <int>[]).toString(),
          'skip': false,
        });
        break;

      case 'file_end':
        if (_currentRelative == null ||
            msg['sha256'] != _sourceDigest ||
            _received != _expected) {
          throw const FormatException('Incomplete or mismatched file');
        }
        if (!_skippedCurrent) {
          if (_openedFile == null || _hasher == null) {
            throw const FormatException('No active file');
          }
          _hasher!.close();
          final got = _digest!.events.single.toString();
          if (got != _sourceDigest) {
            throw const FormatException('SHA256 mismatch');
          }
          await _openedFile!.flush();
          await _openedFile!.close();
          _openedFile = null;

          // A manifest is saved before creating its stage, so a retry after
          // a crash between rename and journal completion can still recognize
          // the already-complete file without duplicating it.
          final target = File(_finalPath!);
          if (await target.exists()) {
            throw const FileSystemException(
              'Destination appeared during transfer; refusing overwrite',
            );
          }
          await File(_temporaryPath!).rename(_finalPath!);
          if (resumeStore != null) {
            await resumeStore!.record(
              _currentRelative!,
              target: p.relative(_finalPath!, from: destinationRoot)
                  .replaceAll('\\', '/'),
              size: _expected,
              sha256: _sourceDigest!,
              complete: true,
            );
          }
          savedPaths.add(_finalPath!);
          progress('Сохранено: ${_finalPath!}');
        } else {
          savedPaths.add(_finalPath!);
        }
        _temporaryPath = null;
        _finalPath = null;
        _currentRelative = null;
        _sourceDigest = null;
        _hasher = null;
        _digest = null;
        _skippedCurrent = false;
        break;

      case 'transfer_end':
        if (_openedFile != null || _currentRelative != null) {
          throw const FormatException('Transfer ended mid-file');
        }
        progress('Передача завершена. Файлов: ${savedPaths.length}, '
            'уже готовых: $skippedFiles, докачано: $resumedBytes байт');
        break;
    }
  }

  Future<void> _prepareResumable(
    String relative,
    String requested,
    int size,
    String digest,
  ) async {
    final store = resumeStore!;
    final previous = store.entry(relative);
    var target = requested;
    var eligible = false;
    if (previous != null &&
        previous['size'] == size &&
        previous['sha256'] == digest &&
        previous['target'] is String) {
      final remembered = store.validatedTarget(previous['target'] as String);
      target = remembered;
      eligible = true;
    } else {
      target = await _unusedName(requested);
    }

    // Before skipping, hash the actual final file. Size/mtime alone are not
    // sufficient: a file can change while retaining its name and length.
    final existing = File(target);
    if (eligible && await existing.exists() &&
        await existing.length() == size &&
        await hashFile(existing) == digest) {
      _finalPath = target;
      _skippedCurrent = true;
      _received = size;
      return;
    }
    if (await existing.exists()) {
      target = await _unusedName(requested);
      eligible = false;
    }
    final relativeTarget = p.relative(target, from: destinationRoot)
        .replaceAll('\\', '/');
    final stage = store.stageFor(relative);
    // A stale stage belongs to a different source revision; never append to
    // it even if the file name and size happen to match.
    if (!eligible && await stage.exists()) await stage.delete();
    if (eligible && await stage.exists() && await stage.length() > size) {
      await stage.delete();
    }
    await store.record(
      relative,
      target: relativeTarget,
      size: size,
      sha256: digest,
      complete: false,
    );
    _finalPath = target;
    _temporaryPath = stage.path;
  }

  Future<void> consumeChunk(Uint8List bytes, SecurePeer peer) async {
    if (bytes.length > SecurePeer.maxEncryptedChunkBytes - 1) {
      throw const FormatException('Transfer chunk exceeds protocol limit');
    }
    if (_openedFile == null) {
      throw const FormatException('Chunk without file_begin');
    }
    _received += bytes.length;
    if (_received > _expected) {
      throw const FormatException('File exceeds declared size');
    }
    await _openedFile!.writeFrom(bytes);
    _hasher!.add(bytes);
    receivedBytes += bytes.length;
    _chunkCounter++;
    onProgress?.call(_currentRelative!, _received, _expected);
    if (_chunkCounter % 8 == 0) {
      try {
        await peer.sendJson({
          'type': 'flow_ack',
          'transferId': transferId,
          'chunks': _chunkCounter,
        });
      } catch (_) {
        // This file chunk was already written. Failure to acknowledge a
        // disconnected sender is a network interruption, NOT a reason to
        // delete the staged bytes. Sender times out/reconnects and
        // independently verifies the retained prefix before using it.
      }
    }
  }

  /// The only operation that retains a partial file is unexpected interruption
  /// of an ordinary resumable copy. Explicit cancel and integrity failures
  /// discard their staged data. Personal backups never use a ResumeStore.
  Future<void> abort({bool preserve = false}) async {
    try {
      await _openedFile?.flush();
      await _openedFile?.close();
    } catch (_) {}
    _openedFile = null;
    final temporary = _temporaryPath;
    if (temporary != null && (!preserve || resumeStore == null)) {
      final temp = File(temporary);
      if (await temp.exists()) await temp.delete();
    }
    _temporaryPath = null;
    _currentRelative = null;
  }

  static Future<String> _unusedName(String requested) async {
    if (!await File(requested).exists() &&
        !await Directory(requested).exists()) {
      return requested;
    }
    final parent = p.dirname(requested);
    final extension = p.extension(requested);
    final stem = p.basenameWithoutExtension(requested);
    for (var n = 1; n <= 9999; n++) {
      final candidate = p.join(parent, '$stem ($n)$extension');
      if (!await File(candidate).exists() &&
          !await Directory(candidate).exists()) {
        return candidate;
      }
    }
    throw const FileSystemException('Too many files with the same name');
  }
}

/// Streams files without loading them into RAM. Each file begins with an
/// encrypted resume negotiation and a verified source SHA-256. Full hashing
/// costs one sequential disk read but allows exact skip/restart decisions.
Future<void> streamTransfer(
  Stream<TransferFile> files,
  SecurePeer peer,
  void Function(String) progress,
  Future<void> Function(int) awaitFlowAck, {
  required String transferId,
  required Future<ResumeReply> Function(
    String path, int size, String sha256, {required bool reset}
  ) negotiate,
  void Function(String, int, int)? onProgress,
  bool Function()? cancelled,
}) async {
  var chunks = 0;
  var count = 0;
  var skipped = 0;
  await for (final file in files) {
    if (cancelled?.call() == true) throw StateError('Transfer paused or cancelled');
    final relative = sanitizeRelative(file.relative);
    if (file.directory) {
      await peer.sendJson({
        'type': 'dir',
        'transferId': transferId,
        'path': relative,
      });
      continue;
    }
    final source = File(file.absolute);
    final before = await source.stat();
    if (before.type != FileSystemEntityType.file) {
      throw FileSystemException('Source file unavailable', source.path);
    }
    progress('Проверка исходного файла: $relative');
    // Hashing a huge source can take longer than the receiver's idle watchdog.
    // These encrypted heartbeats contain no file contents or extra rights.
    final heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      if (cancelled?.call() == true) return;
      unawaited(peer.sendJson({
        'type': 'transfer_keepalive',
        'transferId': transferId,
      }).catchError((Object _) {}));
    });
    late String digest;
    try {
      digest = await hashFile(source);
    } finally {
      heartbeat.cancel();
    }
    if (cancelled?.call() == true) {
      throw StateError('Transfer paused or cancelled');
    }
    final afterHash = await source.stat();
    if (afterHash.size != before.size ||
        afterHash.modified != before.modified) {
      throw FileSystemException('Source changed while hashing', source.path);
    }
    var reply = await negotiate(
      relative, before.size, digest, reset: false,
    );
    if (reply.offset > before.size) {
      throw const FormatException('Resume offset exceeds source file size');
    }
    if (reply.skip) {
      if (reply.offset != before.size || reply.prefixHash != digest) {
        throw const FormatException('Invalid receiver skip response');
      }
      skipped++;
      progress('Уже скопировано: $relative');
      onProgress?.call(relative, before.size, before.size);
    } else {
      if (reply.offset > 0) {
        final localPrefix = await hashFile(source, prefixBytes: reply.offset);
        if (localPrefix != reply.prefixHash) {
          // A changed or corrupted stage must be reset, not combined with the
          // new source. No dialog or extra pairing is needed.
          reply = await negotiate(
            relative, before.size, digest, reset: true,
          );
          if (reply.offset != 0 || reply.skip) {
            throw const FormatException('Receiver did not reset partial file');
          }
        }
      }
      onProgress?.call(relative, reply.offset, before.size);
      var sentThisFile = reply.offset;
      await for (final raw in source.openRead(reply.offset)) {
        for (var offset = 0; offset < raw.length; offset += 65536) {
          if (cancelled?.call() == true) {
            throw StateError('Transfer paused or cancelled');
          }
          final end = min(offset + 65536, raw.length);
          final data = Uint8List.fromList(raw.sublist(offset, end));
          await peer.sendChunk(data);
          chunks++;
          sentThisFile += data.length;
          if (chunks % 8 == 0) await awaitFlowAck(chunks);
          onProgress?.call(relative, sentThisFile, before.size);
        }
      }
      final afterSend = await source.stat();
      if (afterSend.size != before.size ||
          afterSend.modified != before.modified) {
        throw FileSystemException('Source changed during transfer', source.path);
      }
    }
    if (cancelled?.call() == true) throw StateError('Transfer paused or cancelled');
    await peer.sendJson({
      'type': 'file_end',
      'transferId': transferId,
      'sha256': digest,
    });
    count++;
    progress('Файлов обработано: $count, уже готовых: $skipped');
  }
  await peer.sendJson({'type': 'transfer_end', 'transferId': transferId});
  progress('Передано файлов: $count, пропущено готовых: $skipped');
}
