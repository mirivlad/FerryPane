import 'dart:io';

import 'package:path/path.dart' as p;

/// Ask the desktop file manager to reveal a downloaded file.
/// Windows Explorer selects it; common Linux file managers implement
/// freedesktop.org FileManager1.ShowItems. Other managers fall back to opening
/// the containing folder.
class FileReveal {
  static Future<void> show(String filePath) async {
    if (Platform.isAndroid) {
      throw UnsupportedError('A desktop file manager is required');
    }
    final path = p.normalize(p.absolute(filePath));
    if (!await File(path).exists()) {
      throw FileSystemException('Saved file not found', path);
    }
    if (Platform.isWindows) {
      await Process.start(
        'explorer.exe',
        ['/select,$path'],
        mode: ProcessStartMode.detached,
      );
      return;
    }
    if (Platform.isLinux) {
      final uri = Uri.file(path).toString();
      try {
        final result = await Process.run(
          'gdbus',
          [
            'call',
            '--session',
            '--dest', 'org.freedesktop.FileManager1',
            '--object-path', '/org/freedesktop/FileManager1',
            '--method', 'org.freedesktop.FileManager1.ShowItems',
            "['$uri']",
            '',
          ],
        ).timeout(const Duration(seconds: 4));
        if (result.exitCode == 0) return;
      } catch (_) {
        // FileManager1 is optional on Linux desktops.
      }
      await Process.start(
        'xdg-open', [p.dirname(path)], mode: ProcessStartMode.detached,
      );
      return;
    }
    throw UnsupportedError('No file manager integration for this system');
  }
}
