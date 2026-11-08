import 'dart:io';

import 'package:ferrypane/core/file_operations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String at(Directory root, String relative) => p.join(root.path, relative);

void main() {
  test('create, rename, copy, move, delete and conflict policies', () async {
    final root = await Directory.systemTemp.createTemp('ferrypane_manager_');
    try {
      final a = Directory(at(root, 'A'))..createSync();
      final b = Directory(at(root, 'B'))..createSync();
      final item = File(at(a, 'note.txt'))..writeAsStringSync('original');
      await FileManagerOps.local('mkdir', path: at(a, 'new-folder'));
      expect(await Directory(at(a, 'new-folder')).exists(), isTrue);
      await FileManagerOps.local('rename',
          path: at(a, 'new-folder'), target: at(a, 'renamed'));
      expect(await Directory(at(a, 'renamed')).exists(), isTrue);

      await FileManagerOps.local('copy',
          path: item.path, target: at(b, 'note.txt'));
      expect(await File(at(b, 'note.txt')).readAsString(), 'original');
      final extra = await FileManagerOps.local('copy',
          path: item.path, target: at(b, 'note.txt'),
          conflict: 'keepBoth');
      expect(extra.path, at(b, 'note (1).txt'));
      expect(await File(extra.path).readAsString(), 'original');

      await item.writeAsString('changed');
      final skipped = await FileManagerOps.local('copy',
          path: item.path, target: at(b, 'note.txt'),
          conflict: 'skip');
      expect(skipped.skipped, isTrue);
      expect(await File(at(b, 'note.txt')).readAsString(), 'original');
      await FileManagerOps.local('copy', path: item.path,
          target: at(b, 'note.txt'), conflict: 'replace');
      expect(await File(at(b, 'note.txt')).readAsString(), 'changed');
      expect(await item.readAsString(), 'changed');

      await File(at(a, 'renamed/child.txt')).writeAsString('child');
      await FileManagerOps.local('move',
          path: at(a, 'renamed'), target: at(b, 'moved'));
      expect(await Directory(at(a, 'renamed')).exists(), isFalse);
      expect(await File(at(b, 'moved/child.txt')).readAsString(), 'child');
      await FileManagerOps.local('delete', path: at(b, 'moved'));
      expect(await Directory(at(b, 'moved')).exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('rejects traversal, root deletion, symlinks and recursive copies',
      () async {
    final root = await Directory.systemTemp.createTemp('ferrypane_secure_');
    try {
      await File(at(root, 'safe.txt')).writeAsString('safe');
      await expectLater(
        FileManagerOps.remote(root.path, 'delete', path: ''),
        throwsFormatException,
      );
      await expectLater(
        FileManagerOps.remote(root.path, 'delete', path: '../safe.txt'),
        throwsFormatException,
      );
      await expectLater(
        FileManagerOps.remote(root.path, 'copy', path: 'safe.txt',
            target: '../escape.txt'),
        throwsFormatException,
      );
      await Directory(at(root, 'folder')).create();
      await expectLater(
        FileManagerOps.remote(root.path, 'copy', path: 'folder',
            target: 'folder/nested'),
        throwsFormatException,
      );
      if (!Platform.isWindows) {
        await Link(at(root, 'linked')).create(at(root, 'safe.txt'));
        await expectLater(
          FileManagerOps.remote(root.path, 'delete', path: 'linked'),
          throwsA(isA<FileSystemException>()),
        );
        expect(await File(at(root, 'safe.txt')).exists(), isTrue);
      }
      await expectLater(
        FileManagerOps.remote(root.path, 'mkdir',
            path: '.ferrypane-resume/forbidden'),
        throwsFormatException,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('bounded recursive search reports nested matches', () async {
    final root = await Directory.systemTemp.createTemp('ferrypane_search_');
    try {
      await Directory(at(root, 'deep')).create();
      await File(at(root, 'deep/sample.txt')).writeAsString('ok');
      await File(at(root, 'ignored.txt')).writeAsString('no');
      final result = await FileManagerOps.search(root.path, '', 'sample');
      expect(result.map((x) => x.path), ['deep/sample.txt']);
      expect(result.single.size, 2);
      expect(result.single.modified, isNotNull);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
