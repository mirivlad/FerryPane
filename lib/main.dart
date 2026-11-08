import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'core/files.dart';
import 'core/file_operations.dart';
import 'core/desktop_locations.dart';
import 'core/service.dart';
import 'core/personal_data.dart';
import 'core/localization.dart';
import 'core/reveal_file.dart';
import 'core/android_foreground.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLanguage.initialize();
  AndroidForegroundAccess.initialize();
  runApp(const FerryPaneApp());
}

class FerryPaneApp extends StatelessWidget {
  const FerryPaneApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: AppLanguage.choice,
    builder: (context, selectedLanguage, child) => MaterialApp(
        title: 'FerryPane',
        locale: selectedLanguage == 'system' ? null : Locale(selectedLanguage),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3569B5)),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6D9AF6),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const FerryHome(),
      ),
  );
}

enum PaneSort { name, size, date, type }

class FileClipboard {
  final bool remote;
  final bool cut;
  final List<String> paths;
  final String? peerIdentity;
  FileClipboard(this.remote, this.cut, this.paths, this.peerIdentity);
}

class BrowserPane {
  bool remote;
  String location;
  List<FileEntry> entries = [];
  Set<String> selected = {};
  bool busy = false;
  String error = '';
  PaneSort sort = PaneSort.name;
  bool descending = false;
  bool searchResults = false;

  BrowserPane({required this.remote, required this.location});

  /// Select all entries shown in this panel (not the virtual '..' row).
  void selectAll() {
    selected.addAll(entries.map((entry) => entry.path));
  }
}

class FerryHome extends StatefulWidget {
  const FerryHome({super.key});

  @override
  State<FerryHome> createState() => _FerryHomeState();
}

class _FerryHomeState extends State<FerryHome> with WidgetsBindingObserver {
  FerryService? _service;
  late final BrowserPane _left;
  late final BrowserPane _right;
  int _active = 0;
  FileClipboard? _clipboard;
  bool _fileOperationBusy = false;
  String _knownConnection = '';
  String _startup = tr('Запуск…');
  bool _androidStorageGranted = !Platform.isAndroid;
  bool _foregroundActive = false;
  bool _changingForeground = false;
  final _ip = TextEditingController();
  Map<String, bool> _systemBackupPermissions =
      const {'contacts': false, 'sms': false};
  String _lastShownStatus = '';
  bool _showTemporaryStatus = false;
  Timer? _statusTimer;

  static String get _initialLocal {
    if (Platform.isAndroid) return '/storage/emulated/0';
    if (Platform.isWindows) return Platform.environment['USERPROFILE'] ?? 'C:\\';
    return Platform.environment['HOME'] ?? '/';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _left = BrowserPane(remote: false, location: _initialLocal);
    _right = BrowserPane(remote: true, location: '');
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_refreshSystemBackupPermissions());
      unawaited(_syncForegroundStatus());
    }
  }

  Future<void> _syncForegroundStatus() async {
    if (!Platform.isAndroid) return;
    final running = await AndroidForegroundAccess.isRunning;
    if (!mounted) return;
    if (_foregroundActive && !running) {
      setState(() => _foregroundActive = false);
      await _service?.resumeIncoming();
      _notice(tr('Фоновая служба остановилась. Обычный приём восстановлен.'));
    }
  }

  Future<void> _setForegroundAccess(bool enabled) async {
    final service = _service;
    if (!Platform.isAndroid || service == null || _changingForeground) return;
    if (enabled && (service.copyActive ||
        service.connected?.ready == true)) {
      _notice(tr('Завершите текущее соединение перед включением фоновой службы.'));
      return;
    }
    setState(() => _changingForeground = true);
    try {
      if (enabled) {
        // Never run two independent listeners on the same LAN port.
        await service.suspendIncoming();
        try {
          await AndroidForegroundAccess.start();
        } catch (_) {
          await AndroidForegroundAccess.stop();
          await service.resumeIncoming();
          rethrow;
        }
      } else {
        await AndroidForegroundAccess.stop();
        await service.resumeIncoming();
      }
      if (mounted) setState(() => _foregroundActive = enabled);
      _notice(enabled
          ? tr('Фоновая служба запущена. Доступ имеют только доверенные устройства.')
          : tr('Фоновая служба остановлена.'));
    } catch (e) {
      _notice(tr('Не удалось изменить фоновый доступ: {error}', {'error': e}));
    } finally {
      if (mounted) setState(() => _changingForeground = false);
    }
  }

  Future<void> _refreshSystemBackupPermissions() async {
    if (!Platform.isAndroid) return;
    try {
      final current = await PersonalDataBridge.grantedPermissions();
      if (mounted) setState(() => _systemBackupPermissions = current);
    } catch (e) {
      // On older preview installs the native bridge may not be present.
      if (mounted) setState(() => _systemBackupPermissions =
          const {'contacts': false, 'sms': false});
    }
  }

  Future<void> _initialize() async {
    try {
      if (Platform.isAndroid) {
        _androidStorageGranted = await Permission.manageExternalStorage.isGranted;
      }
      final defaultShare = Platform.isAndroid
          ? '/storage/emulated/0'
          : p.join(_initialLocal, 'Downloads');
      final root = await Directory(defaultShare).exists()
          ? defaultShare
          : _initialLocal;
      _foregroundActive = await AndroidForegroundAccess.isRunning;
      final service = await FerryService.initialize(
          _confirmPairing, root, incomingEnabled: !_foregroundActive);
      service.addListener(_serviceChanged);
      service.onContactsImportConsent = _confirmContactsImport;
      if (Platform.isAndroid) {
        await _refreshSystemBackupPermissions();
      }
      if (!mounted) {
        service.dispose();
        return;
      }
      setState(() {
        _service = service;
        _startup = tr('Готово');
      });
      await _load(_left);
    } catch (e) {
      if (mounted) setState(() => _startup = tr('Ошибка запуска: {error}', {'error': e}));
    }
  }

  void _serviceChanged() {
    if (!mounted) return;
    final service = _service;
    if (service == null) return;
    if (service.lastMessage != _lastShownStatus) {
      _lastShownStatus = service.lastMessage;
      _showTemporaryStatus = true;
      _statusTimer?.cancel();
      _statusTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showTemporaryStatus = false);
      });
    }
    final state = service.connectionStatus;
    if (state != _knownConnection) {
      _knownConnection = state;
      if (service.connected?.ready ?? false) {
        _right.location = '';
        unawaited(_load(_right));
      } else {
        _right.entries = [];
        _right.selected.clear();
      }
    }
    // Post-frame refresh avoids setState during UI build, e.g. prompt opening.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  Future<bool> _confirmPairing(String name, String code, String key) async {
    if (!mounted) return false;
    final reply = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(tr('Подтвердить соединение')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Устройство: {name}', {'name': name})),
            const SizedBox(height: 12),
            Text(tr('Сравните этот код на ОБОИХ устройствах:')),
            const SizedBox(height: 10),
            SelectableText(
              code,
              style: const TextStyle(fontSize: 33, fontWeight: FontWeight.bold, letterSpacing: 5),
            ),
            const SizedBox(height: 8),
            Text(tr('Разрешайте подключение только если коды совпадают.')),
            const SizedBox(height: 8),
            Text(tr(
              'Подтверждённое устройство сможет читать и записывать файлы в общем каталоге этого устройства. Доступ к контактам и SMS включается отдельно в настройках Android.',
            )),
            const SizedBox(height: 12),
            Text(tr('Ключ: {key}…', {'key': key.substring(0, key.length < 16 ? key.length : 16)}),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отклонить')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Коды совпадают')),
          ),
        ],
      ),
    );
    return reply ?? false;
  }

  Future<bool> _confirmContactsImport(
      String fileName, String requester, Map<String, dynamic> preview) async {
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Восстановить контакты в FerryPane?')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('Источник: {name}', {'name': requester})),
              Text(tr('Файл: {file}', {'file': fileName})),
              const SizedBox(height: 12),
              Text(tr('Всего записей: {count}', {'count': preview['total']})),
              Text(tr('Новых контактов: {count}', {'count': preview['new']})),
              Text(tr('Совпадают по телефону или email: {count}', {'count': preview['matched']})),
              const SizedBox(height: 12),
              Text(tr('FerryPane добавит недостающие контакты и телефоны/email к совпадающим. Существующие данные не удаляются. Фото и редкие поля vCard пока не импортируются.')),
              const SizedBox(height: 8),
              Text(tr(
                'FerryPane не удаляет существующие контакты. Создание записей изменит адресную книгу этого телефона.',
              )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('Добавить и объединить')),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  Future<void> _setBackupAccess(
    FerryService service,
    String kind,
    bool allowed,
    void Function(void Function()) updateDialog,
  ) async {
    try {
      if (allowed) {
        final permission = kind == 'contacts'
            ? await Permission.contacts.request()
            : await Permission.sms.request();
        if (!permission.isGranted) {
          if (permission.isPermanentlyDenied) {
            await openAppSettings();
          }
          _notice(tr('Android не выдал разрешение на чтение {kind}. Для SMS действуют особые ограничения Android.', {
            'kind': kind == 'contacts' ? tr('контактов') : 'SMS',
          }));
          await _refreshSystemBackupPermissions();
          if (mounted) updateDialog(() {});
          return;
        }
      }
      await _refreshSystemBackupPermissions();
      if (allowed && _systemBackupPermissions[kind] != true) {
        _notice(tr('Android отозвал доступ. Включите разрешение повторно.'));
        if (mounted) updateDialog(() {});
        return;
      }
      await service.allowPeerBackup(kind, allowed);
      AndroidForegroundAccess.refreshPermissions();
      if (mounted) updateDialog(() {});
    } catch (e) {
      _notice(tr('Не удалось изменить разрешение: {error}', {'error': e}));
    }
  }

  Future<void> _grantAndroidPermission() async {
    final result = await Permission.manageExternalStorage.request();
    if (!mounted) return;
    setState(() => _androidStorageGranted = result.isGranted);
    if (_androidStorageGranted) {
      await _load(_left);
      final root = _service?.exportRoot;
      if (root != null) await _service!.setExportRoot(root);
    }
  }

  Future<void> _load(BrowserPane pane) async {
    if (_service == null) return;
    setState(() {
      pane.busy = true;
      pane.error = '';
      pane.selected.clear();
      pane.searchResults = false;
    });
    try {
      List<FileEntry> files;
      if (pane.remote) {
        files = await _service!.remoteList(pane.location);
      } else {
        final local = await listAt(pane.location, '');
        files = local
            .map((item) => FileEntry(
                  item.name,
                  p.join(pane.location, item.name),
                  item.directory,
                  item.size,
                  item.modified,
                ))
            .toList();
      }
      if (mounted) setState(() => pane.entries = files);
    } catch (e) {
      if (mounted) {
        setState(() {
          pane.entries = [];
          pane.error = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => pane.busy = false);
    }
  }

  void _open(BrowserPane pane, FileEntry entry) {
    if (!entry.directory) {
      setState(() {
        if (!pane.selected.add(entry.path)) pane.selected.remove(entry.path);
      });
      return;
    }
    pane.location = entry.path;
    unawaited(_load(pane));
  }

  void _goUp(BrowserPane pane) {
    if (pane.remote) {
      final components = pane.location.split('/')..removeWhere((s) => s.isEmpty);
      if (components.isEmpty) return;
      components.removeLast();
      pane.location = components.join('/');
    } else {
      pane.location = p.dirname(pane.location);
    }
    unawaited(_load(pane));
  }

  Future<void> _chooseDrive(BrowserPane pane) async {
    final drives = await listWindowsDrives();
    if (!mounted) return;
    if (drives.isEmpty) {
      _notice(tr('Не удалось получить список дисков Windows'));
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr('Выбрать диск')),
        children: drives
            .map((drive) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, drive.root),
                  child: Row(
                    children: [
                      const Icon(Icons.storage),
                      const SizedBox(width: 12),
                      Flexible(child: Text(drive.label)),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
    if (choice != null && mounted) {
      pane.location = choice;
      await _load(pane);
    }
  }


  List<FileEntry> _sorted(BrowserPane pane) {
    final entries = List<FileEntry>.from(pane.entries);
    entries.sort((a, b) {
      if (a.directory != b.directory) return a.directory ? -1 : 1;
      int n;
      switch (pane.sort) {
        case PaneSort.name:
          n = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case PaneSort.size:
          n = a.size.compareTo(b.size);
        case PaneSort.date:
          n = (a.modified ?? DateTime(1970))
              .compareTo(b.modified ?? DateTime(1970));
        case PaneSort.type:
          n = p.extension(a.name).compareTo(p.extension(b.name));
      }
      if (n == 0) n = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return pane.descending ? -n : n;
    });
    return entries;
  }

  String _panePath(BrowserPane pane, String filename) =>
      pane.remote ? p.posix.join(pane.location, filename) :
          p.join(pane.location, filename);

  String _basename(bool remote, String filename) =>
      remote ? p.posix.basename(filename) : p.basename(filename);

  Future<String?> _textDialog(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr(title)),
          content: TextField(
            autofocus: true, controller: controller,
            decoration: InputDecoration(labelText: tr('Название')),
            onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext),
                child: Text(tr('Отмена'))),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
              child: Text(tr('ОК')),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  bool _validName(String name) =>
      name.isNotEmpty && name != '.' && name != '..' &&
      !name.contains('/') && !name.contains('\\') && !name.contains('\u0000');

  Future<FileOperationResult> _runFileOp(BrowserPane pane,
      String op, String path, {String? target, String conflict = 'keepBoth'}) =>
      pane.remote
          ? _service!.remoteFileOp(op, path: path,
              target: target, conflict: conflict)
          : FileManagerOps.local(op, path: path,
              target: target, conflict: conflict);

  Future<void> _newFolder(BrowserPane pane) async {
    final name = await _textDialog('Новая папка', '');
    if (name == null) return;
    if (!_validName(name)) { _notice(tr('Недопустимое имя')); return; }
    try {
      await _runFileOp(pane, 'mkdir', _panePath(pane, name));
      await _load(pane);
    } catch (e) {
      _notice(tr('Не удалось создать папку: {error}', {'error': e}));
    }
  }

  Future<String?> _conflict() async => showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr('Имя уже занято')),
      content: Text(tr('Выберите действие при совпадении имён.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, 'skip'),
            child: Text(tr('Пропустить'))),
        TextButton(onPressed: () => Navigator.pop(dialogContext, 'keepBoth'),
            child: Text(tr('Сохранить оба'))),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, 'replace'),
            child: Text(tr('Заменить'))),
      ],
    ),
  );

  Future<void> _renameFile(BrowserPane pane, FileEntry entry) async {
    final name = await _textDialog('Переименовать', entry.name);
    if (name == null || name == entry.name) return;
    if (!_validName(name)) { _notice(tr('Недопустимое имя')); return; }
    final parent = pane.remote
        ? p.posix.dirname(entry.path) : p.dirname(entry.path);
    final destination = pane.remote
        ? p.posix.join(parent, name) : p.join(parent, name);
    try {
      String conflict = 'keepBoth';
      if (pane.entries.any((e) => e.path == destination)) {
        final choice = await _conflict();
        if (choice == null) return;
        conflict = choice;
      }
      await _runFileOp(pane, 'rename', entry.path,
          target: destination, conflict: conflict);
      await _load(pane);
    } catch (e) {
      _notice(tr('Ошибка переименования: {error}', {'error': e}));
    }
  }

  Future<void> _deleteFiles(BrowserPane pane, List<FileEntry> entries) async {
    if (entries.isEmpty) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Удалить навсегда?')),
        content: Text(tr('Удаление без корзины, включая содержимое папок. '
            'Объектов: {count}', {'count': entries.length})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr('Удалить'))),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      for (final entry in entries) {
        await _runFileOp(pane, 'delete', entry.path);
      }
      await _load(pane);
    } catch (e) {
      await _load(pane);
      _notice(tr('Ошибка удаления: {error}', {'error': e}));
    }
  }

  Future<void> _properties(FileEntry entry) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Свойства')),
        content: SelectableText([
          entry.name, entry.path,
          entry.directory ? tr('Папка') : tr('Файл'),
          if (!entry.directory) _humanSize(entry.size),
          if (entry.modified != null) entry.modified!.toLocal().toString(),
        ].join('\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr('Закрыть'))),
        ],
      ),
    );
  }

  Future<void> _search(BrowserPane pane) async {
    final query = await _textDialog('Поиск файлов и папок', '');
    if (query == null || query.trim().isEmpty) return;
    setState(() => pane.busy = true);
    try {
      final result = pane.remote
          ? await _service!.remoteSearch(pane.location, query)
          : (await FileManagerOps.search(pane.location, '', query))
              .map((entry) => FileEntry(entry.name,
                  p.join(pane.location, entry.path.replaceAll('/', p.separator)),
                  entry.directory, entry.size, entry.modified))
              .toList();
      if (mounted) setState(() {
        pane.entries = result;
        pane.searchResults = true;
        pane.selected.clear();
      });
    } catch (e) {
      _notice(tr('Ошибка поиска: {error}', {'error': e}));
    } finally {
      if (mounted) setState(() => pane.busy = false);
    }
  }

  void _clipboardCopy(BrowserPane pane, bool cut) {
    if (pane.selected.isEmpty) return;
    setState(() => _clipboard =
        FileClipboard(pane.remote, cut, pane.selected.toList(),
            pane.remote ? _service?.connected?.remoteKey : null));
    _notice(tr(cut ? 'Вырезано. Выберите каталог назначения.' :
        'Скопировано. Выберите каталог назначения.'));
  }


  /// Cross-device move: copy, await authenticated transfer completion, verify
  /// each tree on both endpoints, then delete only the original matching
  /// the pre-copy SHA-256 tree digest. Failed/partial copies retain originals.
  Future<void> _moveAcross(BrowserPane from, BrowserPane to,
      List<String> sourcePaths) async {
    final service = _service!;
    if (service.hasPendingCopy || sourcePaths.isEmpty ||
        sourcePaths.length > 64) {
      throw StateError('Finish the previous transfer or select up to 64 items');
    }
    final destinations = sourcePaths
        .map((source) => _panePath(to, _basename(from.remote, source)))
        .toList();
    for (var i = 0; i < sourcePaths.length; i++) {
      for (var j = 0; j < sourcePaths.length; j++) {
        if (i == j) continue;
        if ((from.remote ? p.posix : p).isWithin(
            sourcePaths[i], sourcePaths[j])) {
          throw StateError('Nested selected sources cannot be moved together');
        }
      }
    }
    if (destinations.map((x) => x.toLowerCase()).toSet().length !=
        destinations.length) {
      throw StateError('Selected files contain duplicate names');
    }
    // Never permit a partial merge or receiver suffix to masquerade as move.
    final existing = to.remote
        ? await service.remoteList(to.location)
        : await listAt(to.location, '');
    final names = existing.map((item) => item.name.toLowerCase()).toSet();
    if (destinations.any((path) =>
        names.contains(_basename(to.remote, path).toLowerCase()))) {
      throw StateError('Destination already contains selected names. '
          'Choose an empty destination folder for a safe move.');
    }

    final originalDigests = <String, String>{};
    for (final source in sourcePaths) {
      originalDigests[source] = from.remote
          ? await service.remoteTreeDigest([source])
          : await FileManagerOps.digestLocal([source]);
    }

    if (from.remote) {
      await service.downloadAndWait(sourcePaths, to.location);
    } else {
      if (!await service.uploadVerified(sourcePaths, to.location)) {
        throw StateError('Transfer not verified; original files preserved');
      }
    }

    // Verify receiver bytes and ensure the original was not modified by
    // another application during the transfer.
    for (var i = 0; i < sourcePaths.length; i++) {
      final source = sourcePaths[i];
      final target = destinations[i];
      final expected = originalDigests[source]!;
      final received = to.remote
          ? await service.remoteTreeDigest([target])
          : await FileManagerOps.digestLocal([target]);
      final current = from.remote
          ? await service.remoteTreeDigest([source])
          : await FileManagerOps.digestLocal([source]);
      if (received != expected || current != expected) {
        throw StateError('Content changed or destination mismatched; '
            'original files were preserved');
      }
    }

    // Each destructive command independently rechecks the expected digest.
    for (final source in sourcePaths) {
      if (from.remote) {
        await service.remoteFileOp('deleteVerified',
            path: source, expectedDigest: originalDigests[source]);
      } else {
        await FileManagerOps.local('deleteVerified',
            path: source, expectedDigest: originalDigests[source]);
      }
    }
  }

  Future<void> _paste(BrowserPane pane) async {
    final item = _clipboard;
    if (item == null || _fileOperationBusy) return;
    if (item.remote &&
        item.peerIdentity != _service?.connected?.remoteKey) {
      _notice(tr('Устройство изменилось. Скопируйте файлы заново.'));
      return;
    }
    setState(() => _fileOperationBusy = true);
    try {
      if (item.cut && item.remote != pane.remote) {
        final source = BrowserPane(remote: item.remote, location: '');
        await _moveAcross(source, pane, item.paths);
      } else if (item.remote == pane.remote) {
        for (final source in item.paths) {
          final dest = _panePath(pane, _basename(item.remote, source));
          var conflict = 'keepBoth';
          final exists = pane.entries.any((e) => e.path == dest) ||
              (!pane.remote && await FileSystemEntity.type(
                  dest, followLinks: false) != FileSystemEntityType.notFound);
          if (exists) {
            final choice = await _conflict();
            if (choice == null) return;
            conflict = choice;
          }
          await _runFileOp(pane, item.cut ? 'move' : 'copy', source,
              target: dest, conflict: conflict);
        }
      } else if (item.remote) {
        await _service!.download(item.paths, pane.location);
      } else {
        await _service!.upload(item.paths, pane.location);
      }
      if (item.cut) setState(() => _clipboard = null);
      await _load(pane);
    } catch (e) {
      _notice(tr('Ошибка файловой операции: {error}', {'error': e}));
    } finally {
      if (mounted) setState(() => _fileOperationBusy = false);
    }
  }

  Future<void> _copy(BrowserPane from, BrowserPane to, {bool move = false}) async {
    if (from.selected.isEmpty || _fileOperationBusy) return;
    setState(() => _fileOperationBusy = true);
    try {
      final selected = from.selected.toList();
      if (move && from.remote != to.remote) {
        await _moveAcross(from, to, selected);
        await _load(to);
        await _load(from);
      } else if (from.remote == to.remote) {
        for (final source in selected) {
          final dest = _panePath(to, _basename(from.remote, source));
          var conflict = 'keepBoth';
          final exists = to.entries.any((e) => e.path == dest) ||
              (!to.remote && await FileSystemEntity.type(
                  dest, followLinks: false) != FileSystemEntityType.notFound);
          if (exists) {
            final choice = await _conflict();
            if (choice == null) return;
            conflict = choice;
          }
          await _runFileOp(to, move ? 'move' : 'copy', source,
              target: dest, conflict: conflict);
        }
        await _load(to);
        if (move) await _load(from);
      } else if (from.remote) {
        await _service!.download(selected, to.location);
      } else {
        await _service!.upload(selected, to.location);
      }
      from.selected.clear();
      _notice(tr('Операция выполнена или передача запущена'));
    } catch (e) {
      _notice(tr('Ошибка копирования: {error}', {'error': e}));
    } finally {
      if (mounted) setState(() => _fileOperationBusy = false);
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        content: InkWell(
          onTap: messenger.hideCurrentSnackBar,
          child: Row(
            children: [
              Expanded(child: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              const Icon(Icons.close, color: Colors.white, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _connect(String address) async {
    try {
      await _service?.connect(address);
    } catch (e) {
      _notice(tr('Не удалось подключиться: {error}', {'error': e}));
    }
  }

  Future<void> _connectDialog() async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Подключиться к устройству')),
        content: TextField(
          controller: _ip,
          decoration: InputDecoration(
            labelText: tr('IP-адрес или имя компьютера'),
            hintText: '192.168.1.23',
            prefixIcon: Icon(Icons.lan),
          ),
          onSubmitted: Navigator.of(context).pop,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Отмена'))),
          FilledButton(
            onPressed: () => Navigator.pop(context, _ip.text.trim()),
            child: Text(tr('Подключиться')),
          ),
        ],
      ),
    );
    if (value != null && value.isNotEmpty) await _connect(value);
  }

  Future<void> _shareDialog() async {
    final service = _service;
    if (service == null) return;
    await _refreshSystemBackupPermissions();
    if (!mounted) return;
    final controller = TextEditingController(text: service.exportRoot);
    final nameController = TextEditingController(text: service.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Доступ к файлам этого устройства')),
        content: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Сопряжённые устройства могут просматривать, скачивать и загружать файлы внутри выбранного каталога.')),
            if (Platform.isAndroid)
              StatefulBuilder(
                builder: (dialogContext, refresh) => SwitchListTile(
                  dense: true,
                  title: Text(tr('Фоновый доступ к телефону')),
                  subtitle: Text(tr('Постоянное уведомление. Только ранее сопряжённые устройства; без новых запросов на телефоне. После перезагрузки проверьте запуск вручную.')),
                  value: _foregroundActive,
                  onChanged: _changingForeground ? null : (enabled) async {
                    await _setForegroundAccess(enabled);
                    if (dialogContext.mounted) refresh(() {});
                  },
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: Text(tr('Язык интерфейса'))),
                DropdownButton<String>(
                  value: AppLanguage.choice.value,
                  items: [
                    DropdownMenuItem(value: 'system', child: Text(tr('Система'))),
                    DropdownMenuItem(value: 'ru', child: Text(tr('Русский'))),
                    DropdownMenuItem(value: 'en', child: Text(tr('Английский'))),
                  ],
                  onChanged: (language) async {
                    if (language == null) return;
                    await AppLanguage.set(language);
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: nameController,
              maxLength: 64,
              decoration: InputDecoration(
                labelText: tr('Имя этого устройства'),
                helperText: tr('Будет отображаться в списке устройств'),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    readOnly: !Platform.isAndroid,
                    decoration: InputDecoration(
                      labelText: tr('Общий каталог'),
                      helperText: tr('Папка, доступная с других устройств'),
                    ),
                  ),
                ),
                if (!Platform.isAndroid)
                  IconButton(
                    tooltip: tr('Выбрать папку…'),
                    icon: const Icon(Icons.folder_open_outlined),
                    onPressed: () async {
                      try {
                        final selected = await getDirectoryPath(
                          initialDirectory: controller.text,
                        );
                        if (selected != null) controller.text = selected;
                      } catch (e) {
                        if (mounted) _notice(tr('Не удалось выбрать папку: {error}', {'error': e}));
                      }
                    },
                  ),
              ],
            ),
            if (service.connected?.ready == true) ...[
              const SizedBox(height: 14),
              Text(tr('Права устройства {name}', {
                'name': service.connected!.remoteName,
              }), style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(tr('Для новых сопряжений доступ на запись отключён по умолчанию. Старые разрешения сохраняются.')),
              StatefulBuilder(
                builder: (context, refresh) => Column(
                  children: [
                    SwitchListTile(
                      dense: true,
                      title: Text(tr('Разрешить чтение файлов')),
                      value: service.peerCanRead,
                      onChanged: (allowed) async {
                        await service.setPeerAccess(
                          read: allowed, write: service.peerCanWrite,
                        );
                        AndroidForegroundAccess.refreshPermissions();
                        if (context.mounted) refresh(() {});
                      },
                    ),
                    SwitchListTile(
                      dense: true,
                      title: Text(tr('Разрешить запись файлов')),
                      value: service.peerCanWrite,
                      onChanged: (allowed) async {
                        await service.setPeerAccess(
                          read: service.peerCanRead, write: allowed,
                        );
                        AndroidForegroundAccess.refreshPermissions();
                        if (context.mounted) refresh(() {});
                      },
                    ),
                  ],
                ),
              ),
            ],
            if (Platform.isAndroid && service.connected?.ready == true) ...[
              const SizedBox(height: 16),
              Text(tr('Права доверенного устройства {name}:', {'name': service.connected!.remoteName}),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(tr(
                'При включении разрешений этот компьютер сможет получать резервные копии без подтверждений на телефоне, даже если сенсор или дисплей перестанет работать.',
              )),
              StatefulBuilder(
                builder: (context, refresh) => Column(
                  children: [
                    SwitchListTile(
                      dense: true,
                      title: Text(tr('Резервное копирование контактов')),
                      subtitle: _systemBackupPermissions['contacts'] == true
                          ? null
                          : Text(tr('Системное разрешение отсутствует')),
                      value: service.canPeerBackup('contacts') &&
                          _systemBackupPermissions['contacts'] == true,
                      onChanged: (allowed) => _setBackupAccess(
                        service, 'contacts', allowed, refresh,
                      ),
                    ),
                    SwitchListTile(
                      dense: true,
                      title: Text(tr('Резервное копирование SMS')),
                      subtitle: Text(
                        _systemBackupPermissions['sms'] == true
                          ? tr('Может требовать отдельного доступа Android')
                          : tr('Системное разрешение отсутствует'),
                      ),
                      value: service.canPeerBackup('sms') &&
                          _systemBackupPermissions['sms'] == true,
                      onChanged: (allowed) => _setBackupAccess(
                        service, 'sms', allowed, refresh,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await _refreshSystemBackupPermissions();
                        if (mounted) refresh(() {});
                      },
                      icon: const Icon(Icons.verified_user_outlined, size: 18),
                      label: Text(tr('Проверить разрешения')),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(tr('IP: {addresses}', {'addresses': '${service.ipAddresses.join(', ')}:$ferryPort'})),
          ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await service.forgetAllTrusted();
              AndroidForegroundAccess.refreshPermissions();
              if (!context.mounted) return;
              Navigator.pop(context);
              _notice(tr('Все доверенные устройства забыты'));
            },
            child: Text(tr('Забыть доверенные устройства')),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Отмена'))),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    if (result != null) {
      try {
        if (_foregroundActive && result != service.exportRoot) {
          throw StateError(tr('Чтобы изменить общий каталог, сначала выключите фоновую службу.'));
        }
        await service.setExportRoot(result);
        AndroidForegroundAccess.refreshPermissions();
        await service.identity.rename(nameController.text.trim());
        service.scanNow();
        _notice(tr('Имя устройства и общий каталог сохранены'));
      } catch (e) {
        _notice(tr('Нельзя открыть каталог: {error}', {'error': e}));
      }
    }
    controller.dispose();
    nameController.dispose();
  }

  Widget _pane(BrowserPane pane, int index) {
    final service = _service;
    final ready = service?.connected?.ready ?? false;
    final disabled = pane.remote && !ready;
    final entries = _sorted(pane);
    return Card(
      margin: const EdgeInsets.all(4),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(pane.remote ? Icons.devices : Icons.computer, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<bool>(
                      isExpanded: true,
                      value: pane.remote,
                      items: [
                        DropdownMenuItem(value: false, child: Text(tr('Этот компьютер / телефон'))),
                        DropdownMenuItem(
                          value: true,
                          child: Text(ready
                              ? tr('Удалённое: {name}', {'name': service!.connected!.remoteName})
                              : tr('Удалённое устройство')),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        pane.remote = value;
                        pane.location = value ? '' : _initialLocal;
                        unawaited(_load(pane));
                      },
                    ),
                  ),
                ),
                if (Platform.isWindows && !pane.remote)
                  IconButton(
                    tooltip: tr('Выбрать диск'),
                    onPressed: () => _chooseDrive(pane),
                    icon: const Icon(Icons.storage_outlined),
                  ),
                IconButton(
                  tooltip: tr('Вверх'),
                  onPressed: disabled ? null : () => _goUp(pane),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: tr('Обновить'),
                  onPressed: disabled ? null : () => _load(pane),
                  icon: const Icon(Icons.refresh),
                ),
                PopupMenuButton<String>(
                  enabled: !disabled,
                  tooltip: tr('Файловые операции'),
                  icon: const Icon(Icons.more_vert),
                  onSelected: (value) {
                    if (value == 'folder') {
                      unawaited(_newFolder(pane));
                    } else if (value == 'search') {
                      unawaited(_search(pane));
                    } else if (value == 'rename' && pane.selected.length == 1) {
                      final entry = pane.entries.firstWhere(
                          (e) => pane.selected.contains(e.path));
                      unawaited(_renameFile(pane, entry));
                    } else if (value == 'delete') {
                      unawaited(_deleteFiles(pane, pane.entries
                          .where((e) => pane.selected.contains(e.path)).toList()));
                    } else if (value == 'copy') {
                      _clipboardCopy(pane, false);
                    } else if (value == 'cut') {
                      _clipboardCopy(pane, true);
                    } else if (value == 'paste') {
                      unawaited(_paste(pane));
                    } else if (value == 'reverse') {
                      setState(() => pane.descending = !pane.descending);
                    } else if (value.startsWith('sort_')) {
                      setState(() => pane.sort = PaneSort.values.firstWhere(
                          (e) => e.name == value.substring(5)));
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'folder', child: Text(tr('Новая папка'))),
                    PopupMenuItem(value: 'search', child: Text(tr('Поиск…'))),
                    PopupMenuItem(value: 'rename',
                        enabled: pane.selected.length == 1,
                        child: Text(tr('Переименовать'))),
                    PopupMenuItem(value: 'delete',
                        enabled: pane.selected.isNotEmpty,
                        child: Text(tr('Удалить'))),
                    PopupMenuItem(value: 'copy',
                        enabled: pane.selected.isNotEmpty,
                        child: Text(tr('Копировать'))),
                    PopupMenuItem(value: 'cut',
                        enabled: pane.selected.isNotEmpty,
                        child: Text(tr('Вырезать'))),
                    PopupMenuItem(value: 'paste',
                        enabled: _clipboard != null,
                        child: Text(tr('Вставить'))),
                    const PopupMenuDivider(),
                    ...PaneSort.values.map((mode) => PopupMenuItem(
                      value: 'sort_' + mode.name,
                      child: Text(tr('Сортировка: ') + mode.name),
                    )),
                    PopupMenuItem(value: 'reverse',
                        child: Text(tr('Обратный порядок'))),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                (pane.remote ? '/' + pane.location : pane.location) +
                    (pane.searchResults ? ' • ' + tr('Результаты поиска') : ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          if (pane.busy) const LinearProgressIndicator(minHeight: 2),
          if (!disabled && pane.entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Text(tr('Выбрано: {selected} / {total}', {'selected': pane.selected.length, 'total': pane.entries.length}),
                      style: Theme.of(context).textTheme.bodySmall),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: pane.selected.length == pane.entries.length
                        ? null
                        : () => setState(() {
                              pane.selectAll();
                            }),
                    icon: const Icon(Icons.select_all, size: 18),
                    label: Text(tr('Выделить всё')),
                  ),
                  TextButton(
                    onPressed: pane.selected.isEmpty
                        ? null
                        : () => setState(() => pane.selected.clear()),
                    child: Text(tr('Снять')),
                  ),
                ],
              ),
            ),
          Expanded(
            child: disabled
                ? Center(child: Text(tr('Подключите другое устройство')))
                : pane.error.isNotEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: SelectableText(pane.error, textAlign: TextAlign.center),
                        ),
                      )
                    : ListView.builder(
                        itemCount: entries.length + 1,
                        itemBuilder: (context, i) {
                          if (i == 0) {
                            final root = pane.remote
                                ? pane.location.isEmpty
                                : p.dirname(pane.location) == pane.location;
                            return ListTile(
                              dense: true,
                              enabled: !root,
                              leading: const Icon(Icons.folder_open_outlined),
                              title: const Text('..'),
                              onTap: root ? null : () => _goUp(pane),
                            );
                          }
                          final entry = entries[i - 1];
                          final selected = pane.selected.contains(entry.path);
                          return ListTile(
                            dense: true,
                            selected: selected,
                            leading: Icon(
                              entry.directory ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
                              color: entry.directory ? Theme.of(context).colorScheme.primary : null,
                            ),
                            title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              pane.searchResults ? entry.path :
                                  (entry.directory ? '' : _humanSize(entry.size)),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Checkbox(
                                  value: selected,
                                  onChanged: (value) => setState(() {
                                    if (value == true) {
                                      pane.selected.add(entry.path);
                                    } else {
                                      pane.selected.remove(entry.path);
                                    }
                                  }),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: tr('Действия с файлом'),
                                  icon: const Icon(Icons.more_vert, size: 18),
                                  onSelected: (action) {
                                    if (action == 'rename') {
                                      unawaited(_renameFile(pane, entry));
                                    } else if (action == 'delete') {
                                      unawaited(_deleteFiles(pane, [entry]));
                                    } else if (action == 'properties') {
                                      unawaited(_properties(entry));
                                    } else if (action == 'copy' || action == 'cut') {
                                      setState(() => pane.selected = {entry.path});
                                      _clipboardCopy(pane, action == 'cut');
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    PopupMenuItem(value: 'rename',
                                        child: Text(tr('Переименовать'))),
                                    PopupMenuItem(value: 'delete',
                                        child: Text(tr('Удалить'))),
                                    PopupMenuItem(value: 'copy',
                                        child: Text(tr('Копировать'))),
                                    PopupMenuItem(value: 'cut',
                                        child: Text(tr('Вырезать'))),
                                    PopupMenuItem(value: 'properties',
                                        child: Text(tr('Свойства'))),
                                  ],
                                ),
                              ],
                            ),
                            onTap: () => _open(pane, entry),
                          );
                        },
                      ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            alignment: Alignment.centerLeft,
            child: Text(
              tr('{count} объектов', {'count': pane.entries.length}),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  static String _humanSize(int size) {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / 1048576).toStringAsFixed(1)} MB';
    return '${(size / 1073741824).toStringAsFixed(1)} GB';
  }

  BrowserPane? get _localDestination {
    if (!_left.remote) return _left;
    if (!_right.remote) return _right;
    return null;
  }

  Future<void> _backupPersonal(String kind) async {
    final service = _service;
    final target = _localDestination;
    if (service == null || target == null) {
      _notice(tr('Выберите локальную папку для сохранения резервной копии.'));
      return;
    }
    try {
      final files = await service.requestPhoneBackup(kind, target.location);
      if (!mounted) return;
      await _load(target); // Show the freshly received file(s) immediately.
      if (!mounted) return;
      _notice(tr('Готово. Сохранено в {folder}: {files}', {
        'folder': target.location,
        'files': files.map(p.basename).join(', '),
      }));
      final highlighted = files.last; // Prefer the readable HTML for SMS.
      try {
        await FileReveal.show(highlighted);
      } catch (e) {
        _notice(tr('Не удалось открыть папку: {error}', {'error': e}));
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Резервная копия сохранена')),
          content: SelectableText(files.join('\n')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Закрыть')),
            ),
          ],
        ),
      );
    } catch (e) {
      _notice(tr('Не удалось создать резервную копию: {error}', {'error': e}));
    }
  }

  Future<void> _restoreContacts() async {
    final service = _service;
    if (service == null) return;
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Контакты vCard', extensions: ['vcf']),
        ],
      );
      if (file == null) return;
      await service.sendContactsToPhone(file.path);
      _notice(tr('Файл доставлен. На Android подтвердите восстановление в окне FerryPane. Результат появится внизу окна.'));
    } catch (e) {
      _notice(tr('Восстановление контактов: {error}', {'error': e}));
    }
  }

  Widget _phoneTools() {
    final service = _service;
    final available = service?.connected?.ready == true &&
        service?.connected?.remotePlatform == 'android';
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(tr('Данные телефона:')),
          ),
          OutlinedButton.icon(
            onPressed: available ? () => _backupPersonal('contacts') : null,
            icon: const Icon(Icons.contacts_outlined, size: 18),
            label: Text(tr('Бэкап контактов')),
          ),
          OutlinedButton.icon(
            onPressed: available ? () => _backupPersonal('sms') : null,
            icon: const Icon(Icons.sms_outlined, size: 18),
            label: Text(tr('Бэкап SMS')),
          ),
          OutlinedButton.icon(
            onPressed: available ? _restoreContacts : null,
            icon: const Icon(Icons.contact_phone_outlined, size: 18),
            label: Text(tr('Восстановить контакты')),
          ),
        ],
      ),
    );
  }

  Widget _resumableCopyBar() {
    final service = _service!;
    final progress = service.transferProgress;
    if (!service.hasPendingCopy && progress == null) {
      return const SizedBox.shrink();
    }
    final speed = progress?.bytesPerSecond ?? 0;
    final remaining = progress?.remaining;
    final speedText = speed > 0
        ? '${_humanSize(speed.round())}/s'
        : '—';
    final eta = remaining == null
        ? '—'
        : remaining.inHours > 0
          ? '${remaining.inHours}ч ${remaining.inMinutes.remainder(60)}м'
          : '${remaining.inMinutes}м ${remaining.inSeconds.remainder(60)}с';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (progress != null) ...[
            Text('${progress.file} — ${_humanSize(progress.done)} / '
              '${_humanSize(progress.total)} · $speedText · ETA $eta',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 3),
            LinearProgressIndicator(value: progress.total == 0
                ? 1 : progress.fraction, minHeight: 4),
          ] else
            Text(service.copyPaused
                ? tr('Передача приостановлена; файлы для докачки сохранены')
                : tr('Ожидание восстановления связи для докачки'),
                style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (service.copyPaused || (!service.copyActive && service.hasPendingCopy))
                TextButton.icon(
                  onPressed: () => service.resumeCopy(),
                  icon: const Icon(Icons.play_arrow, size: 17),
                  label: Text(tr('Продолжить')),
                )
              else if (service.canPauseCopy)
                TextButton.icon(
                  onPressed: () => service.pauseCopy(),
                  icon: const Icon(Icons.pause, size: 17),
                  label: Text(tr('Пауза')),
                ),
              if (service.hasPendingCopy)
                TextButton.icon(
                  onPressed: () => service.cancelCopy(),
                  icon: const Icon(Icons.close, size: 17),
                  label: Text(tr('Отмена передачи')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _body(bool compact) {
    if (_service == null) {
      return Center(child: Text(_startup));
    }
    return Column(
      children: [
        if (!Platform.isAndroid) _phoneTools(),
        if (Platform.isAndroid && !_androidStorageGranted)
          MaterialBanner(
            content: Text(tr('Для просмотра общих папок Android разрешите доступ ко всем файлам в системных настройках.')),
            actions: [
              TextButton(
                onPressed: _grantAndroidPermission,
                child: Text(tr('Разрешить')),
              ),
            ],
          ),
        if (compact)
          SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, icon: Icon(Icons.folder), label: Text(tr('Панель 1'))),
              ButtonSegment(value: 1, icon: Icon(Icons.folder_shared), label: Text(tr('Панель 2'))),
            ],
            selected: {_active},
            onSelectionChanged: (newValue) => setState(() => _active = newValue.first),
          ),
        Expanded(
          child: compact
              ? _pane(_active == 0 ? _left : _right, _active)
              : Row(
                  children: [
                    Expanded(child: _pane(_left, 0)),
                    Expanded(child: _pane(_right, 1)),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Wrap(
            spacing: 10,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _right.selected.isEmpty
                    ? null
                    : () => _copy(_right, _left),
                icon: const Icon(Icons.arrow_back),
                label: Text(compact
                    ? tr('Из 2 в 1 ({count})', {'count': _right.selected.length})
                    : tr('Из правой в левую ({count})', {'count': _right.selected.length})),
              ),
              OutlinedButton.icon(
                onPressed: _left.selected.isEmpty || _fileOperationBusy
                    ? null : () => _copy(_left, _right, move: true),
                icon: const Icon(Icons.drive_file_move_outline),
                label: Text(tr('Переместить вправо')),
              ),
              OutlinedButton.icon(
                onPressed: _right.selected.isEmpty || _fileOperationBusy
                    ? null : () => _copy(_right, _left, move: true),
                icon: const Icon(Icons.drive_file_move),
                label: Text(tr('Переместить влево')),
              ),
              OutlinedButton.icon(
                onPressed: _clipboard == null || _fileOperationBusy
                    ? null : () => _paste(_active == 0 ? _left : _right),
                icon: const Icon(Icons.content_paste),
                label: Text(tr('Вставить')),
              ),
              OutlinedButton.icon(
                onPressed: _left.selected.isEmpty
                    ? null
                    : () => _copy(_left, _right),
                icon: const Icon(Icons.arrow_forward),
                label: Text(compact
                    ? tr('Из 1 в 2 ({count})', {'count': _left.selected.length})
                    : tr('Из левой в правую ({count})', {'count': _left.selected.length})),
              ),
            ],
          ),
        ),
        _resumableCopyBar(),
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: InkWell(
            onTap: () {
              _statusTimer?.cancel();
              setState(() => _showTemporaryStatus = false);
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _service!.pairingOpen
                        ? tr('Сопряжение открыто на 2 минуты')
                        : _showTemporaryStatus
                          ? '${_service!.connectionStatus}  •  ${_service!.lastMessage}'
                          : _service!.connectionStatus,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (_showTemporaryStatus)
                    const Icon(Icons.close, size: 16),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          return Scaffold(
            appBar: AppBar(
              title: const Text('FerryPane'),
              actions: [
                if (_service != null)
                  IconButton(
                    tooltip: tr('Повторить поиск устройств'),
                    onPressed: () {
                      _service!.scanNow();
                      _notice(tr('Поиск устройств запущен. Если телефон не виден, используйте подключение по IP.'));
                    },
                    icon: const Icon(Icons.refresh),
                  ),
                if (_service != null)
                  PopupMenuButton<NearbyPeer>(
                    tooltip: tr('Устройства в локальной сети'),
                    icon: const Icon(Icons.wifi_find),
                    onSelected: (peer) => _connect(peer.host),
                    itemBuilder: (context) => _service!.nearby.isEmpty
                        ? <PopupMenuEntry<NearbyPeer>>[
                            PopupMenuItem(
                              enabled: false,
                              child: Text(tr('Нет найденных устройств')),
                            ),
                          ]
                        : _service!.nearby.values
                            .map((peer) => PopupMenuItem<NearbyPeer>(
                                  value: peer,
                                  child: Text(
                                    '${peer.name} • ${peer.host}'
                                    '${DateTime.now().difference(peer.seen).inSeconds > 45 ? ' (${tr('Сохранённый адрес')})' : ''}',
                                  ),
                                ))
                            .toList(),
                  ),
                IconButton(
                  tooltip: _foregroundActive
                      ? tr('Выключите фоновый доступ для нового сопряжения')
                      : _service?.pairingOpen == true
                      ? tr('Закрыть сопряжение')
                      : tr('Разрешить новое сопряжение на 2 минуты'),
                  onPressed: _service == null || _foregroundActive ||
                          (_service!.connected?.ready ?? false)
                      ? null
                      : () {
                          final service = _service!;
                          service.setPairingOpen(!service.pairingOpen);
                          _notice(service.pairingOpen
                              ? tr('Сопряжение открыто на 2 минуты. Сравните коды на обоих устройствах.')
                              : tr('Приём новых сопряжений закрыт'));
                        },
                  icon: Icon(_service?.pairingOpen == true
                      ? Icons.lock_open_rounded
                      : Icons.lock_outline_rounded),
                  color: _service?.pairingOpen == true
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                if (_service?.connected?.ready == true)
                  IconButton(
                    tooltip: tr('Отключиться'),
                    onPressed: () => _service!.disconnectPeer(),
                    icon: const Icon(Icons.link_off),
                  ),
                IconButton(
                  tooltip: tr('Подключиться по IP'),
                  onPressed: _service == null ? null : _connectDialog,
                  icon: const Icon(Icons.add_link),
                ),
                IconButton(
                  tooltip: tr('Общий каталог'),
                  onPressed: _service == null ? null : _shareDialog,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
            body: _body(compact),
          );
        },
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _service?.removeListener(_serviceChanged);
    _service?.dispose();
    _ip.dispose();
    super.dispose();
  }
}
