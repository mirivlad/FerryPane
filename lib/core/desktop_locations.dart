import 'dart:convert';
import 'dart:io';

class DesktopDrive {
  final String label;
  final String root;
  const DesktopDrive(this.label, this.root);
}

Future<List<DesktopDrive>> listWindowsDrives() async {
  if (!Platform.isWindows) return const [];
  final found = <String, DesktopDrive>{};
  try {
    final process = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Get-PSDrive -PSProvider FileSystem | Select-Object Name,Root,Description | ConvertTo-Json -Compress',
    ]).timeout(const Duration(seconds: 8));
    if (process.exitCode == 0) {
      final data = jsonDecode(process.stdout.toString());
      for (final item in (data is List ? data : [data])) {
        if (item is! Map) continue;
        final root = item['Root']?.toString();
        if (root == null || root.isEmpty || !root.contains('\\')) continue;
        final name = item['Name']?.toString() ?? root;
        final description = item['Description']?.toString().trim() ?? '';
        found[root.toLowerCase()] = DesktopDrive(
          description.isEmpty ? root : '$name — $description ($root)',
          root,
        );
      }
    }
  } catch (_) {
    // Powershell is not guaranteed to be installed in slim Windows images.
  }
  if (found.isEmpty) {
    // Fallback also supports USB sticks with dynamically assigned drive letters.
    for (var code = 65; code <= 90; code++) {
      final root = '${String.fromCharCode(code)}:\\';
      if (await Directory(root).exists()) {
        found[root.toLowerCase()] = DesktopDrive(root, root);
      }
    }
  }
  return found.values.toList()..sort((a, b) => a.root.compareTo(b.root));
}
