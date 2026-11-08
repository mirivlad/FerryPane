import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'core/files.dart';
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

class BrowserPane {
  bool remote;
  String location;
  List<FileEntry> entries = [];
  Set<String> selected = {};
  bool busy = false;
  String error = '';

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

  Future<void> _copy(BrowserPane from, BrowserPane to) async {
    final paths = from.selected.toList();
    if (paths.isEmpty) {
      _notice(tr('Сначала выделите файлы или папки.'));
      return;
    }
    try {
      if (!from.remote && to.remote) {
        await _service!.upload(paths, to.location);
      } else if (from.remote && !to.remote) {
        await _service!.download(paths, to.location);
      } else if (!from.remote && !to.remote) {
        await _copyLocal(paths, to.location);
      } else {
        _notice(tr('Копирование между двумя удалёнными панелями пока не поддерживается.'));
        return;
      }
      from.selected.clear();
      if (!from.remote && !to.remote) await _load(to);
      _notice(tr(_service?.hasPendingCopy == true
          ? 'Передача запущена. Докачка включена.'
          : 'Передача завершена'));
    } catch (e) {
      _notice(tr('Ошибка копирования: {error}', {'error': e}));
    }
  }

  Future<void> _copyLocal(List<String> paths, String destination) async {
    await for (final item in walkLocalSelection(paths)) {
      final target = containedPath(destination, item.relative);
      if (item.directory) {
        await Directory(target).create(recursive: true);
      } else {
        await Directory(p.dirname(target)).create(recursive: true);
        if (await File(target).exists()) {
          throw FileSystemException('Целевой файл уже существует', target);
        }
        await File(item.absolute).copy(target);
      }
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
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                pane.remote ? '/${pane.location}' : pane.location,
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
                        itemCount: pane.entries.length + 1,
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
                          final entry = pane.entries[i - 1];
                          final selected = pane.selected.contains(entry.path);
                          return ListTile(
                            dense: true,
                            selected: selected,
                            leading: Icon(
                              entry.directory ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
                              color: entry.directory ? Theme.of(context).colorScheme.primary : null,
                            ),
                            title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: entry.directory ? null : Text(_humanSize(entry.size)),
                            trailing: Checkbox(
                              value: selected,
                              onChanged: (value) => setState(() {
                                if (value == true) {
                                  pane.selected.add(entry.path);
                                } else {
                                  pane.selected.remove(entry.path);
                                }
                              }),
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
