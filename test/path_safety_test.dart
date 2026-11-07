import 'package:flutter_test/flutter_test.dart';
import 'package:ferrypane/core/files.dart';

void main() {
  test('remote paths reject traversal and absolute paths', () {
    expect(() => sanitizeRelative('../secret'), throwsFormatException);
    expect(() => sanitizeRelative('/etc/passwd'), throwsFormatException);
    expect(() => sanitizeRelative('folder/../../secret'), throwsFormatException);
    expect(() => sanitizeRelative('C:/Windows'), throwsFormatException);
    expect(sanitizeRelative('photos/2026/image.jpg'), 'photos/2026/image.jpg');
    expect(sanitizeRelative(''), '');
  });
}
