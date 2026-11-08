import 'package:flutter_test/flutter_test.dart';
import 'package:ferrypane/core/files.dart';

void main() {
  test('rejects Windows reserved device aliases without affecting Linux', () {
    for (final path in [
      'CON', 'nul.txt', 'Aux.log', 'LPT1', 'photos/COM9.jpg',
      'folder/trailing.', 'folder/trailing ', 'folder/question?.txt',
      'folder/foo:bar.txt',
    ]) {
      expect(() => validateDestinationPath(path, windows: true),
          throwsFormatException, reason: path);
      expect(() => validateDestinationPath(path, windows: false),
          returnsNormally, reason: path);
    }
    for (final path in [
      'notes.txt', 'CONfig.json', 'AUXiliary.doc', 'photos/new photo (1).jpg',
      'folder/COM10.txt', 'unicode/журнал.txt',
    ]) {
      expect(() => validateDestinationPath(path, windows: true),
          returnsNormally, reason: path);
    }
  });

  test('remote paths reject traversal and absolute paths', () {
    expect(() => sanitizeRelative('../secret'), throwsFormatException);
    expect(() => sanitizeRelative('/etc/passwd'), throwsFormatException);
    expect(() => sanitizeRelative('folder/../../secret'), throwsFormatException);
    expect(() => sanitizeRelative('C:/Windows'), throwsFormatException);
    expect(sanitizeRelative('photos/2026/image.jpg'), 'photos/2026/image.jpg');
    expect(sanitizeRelative(''), '');
  });
}
