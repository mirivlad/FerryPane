import 'package:ferrypane/core/files.dart';
import 'package:ferrypane/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Select all selects files and folders in one panel only', () {
    final left = BrowserPane(remote: false, location: '/local')
      ..entries = const [
        FileEntry('hello.txt', '/local/hello.txt', false, 16),
        FileEntry('photos', '/local/photos', true, 0),
      ];
    final right = BrowserPane(remote: true, location: 'documents')
      ..entries = const [FileEntry('remote.txt', 'documents/remote.txt', false, 3)];
    left.selectAll();
    expect(left.selected, {'/local/hello.txt', '/local/photos'});
    expect(right.selected, isEmpty);
    left.selected.clear();
    expect(left.selected, isEmpty);
    right.selectAll();
    expect(right.selected, {'documents/remote.txt'});
  });

  test('Select all does not manufacture a selection for empty folders', () {
    final panel = BrowserPane(remote: false, location: '/empty');
    panel.selectAll();
    expect(panel.selected, isEmpty);
  });
}
