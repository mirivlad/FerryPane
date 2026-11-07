import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'core/files.dart';
import 'core/service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FerryPaneApp());
}

class FerryPaneApp extends StatelessWidget {
  const FerryPaneApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'FerryPane',
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
}

class FerryHome extends StatefulWidget {
  const FerryHome({super.key});

  @override
  State<FerryHome> createState() => _FerryHomeState();
}

class _FerryHomeState extends State<FerryHome> {
  FerryService? _service;
  late final BrowserPane _left;
  late final BrowserPane _right;
  int _active = 0;
  String _knownConnection = '';
  String _startup = 'Запуск…';
  bool _androidStorageGranted = !Platform.isAndroid;
  final _ip = TextEditingController();

  static String get _initialLocal {
    if (Platform.isAndroid) return '/storage/emulated/0';
    if (Platform.isWindows) return Platform.environment['USERPROFILE'] ?? 'C:\\';
    return Platform.environment['HOME'] ?? '/';
  }

  @override
  void initState() {
    super.initState();
    _left = BrowserPane(remote: false, location: _initialLocal);
    _right = BrowserPane(remote: true, location: '');
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
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
      final service = await FerryService.initialize(_confirmPairing, root);
      service.addListener(_serviceChanged);
      if (!mounted) {
        service.dispose();
        return;
      }
      setState(() {
        _service = service;
        _startup = 'Готово';
      });
      await _load(_left);
    } catch (e) {
      if (mounted) setState(() => _startup = 'Ошибка запуска: $e');
    }
  }

  void _serviceChanged() {
    if (!mounted) return;
    final service = _service;
    if (service == null) return;
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
        title: const Text('Подтвердить соединение'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Устройство: $name'),
            const SizedBox(height: 12),
            const Text('Сравните этот код на ОБОИХ устройствах:'),
            const SizedBox(height: 10),
            SelectableText(
              code,
              style: const TextStyle(fontSize: 33, fontWeight: FontWeight.bold, letterSpacing: 5),
            ),
            const SizedBox(height: 8),
            const Text('Разрешайте подключение только если коды совпадают.'),
            const SizedBox(height: 8),
            const Text(
              'Подтверждённое устройство сможет читать и записывать файлы '
              'в общем каталоге этого устройства.',
            ),
            const SizedBox(height: 12),
            Text('Ключ: ${key.substring(0, key.length < 16 ? key.length : 16)}…',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отклонить'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Коды совпадают'),
          ),
        ],
      ),
    );
    return reply ?? false;
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

  Future<void> _copy(BrowserPane from, BrowserPane to) async {
    final paths = from.selected.toList();
    if (paths.isEmpty) {
      _notice('Сначала выделите файлы или папки.');
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
        _notice('Копирование между двумя удалёнными панелями пока не поддерживается.');
        return;
      }
      from.selected.clear();
      if (!from.remote && !to.remote) await _load(to);
      _notice('Передача запущена. Прогресс отображается внизу окна.');
    } catch (e) {
      _notice('Ошибка копирования: $e');
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  Future<void> _connect(String address) async {
    try {
      await _service?.connect(address);
    } catch (e) {
      _notice('Не удалось подключиться: $e');
    }
  }

  Future<void> _connectDialog() async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Подключиться к устройству'),
        content: TextField(
          controller: _ip,
          decoration: const InputDecoration(
            labelText: 'IP-адрес или имя компьютера',
            hintText: '192.168.1.23',
            prefixIcon: Icon(Icons.lan),
          ),
          onSubmitted: Navigator.of(context).pop,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(context, _ip.text.trim()),
            child: const Text('Подключиться'),
          ),
        ],
      ),
    );
    if (value != null && value.isNotEmpty) await _connect(value);
  }

  Future<void> _shareDialog() async {
    final service = _service;
    if (service == null) return;
    final controller = TextEditingController(text: service.exportRoot);
    final nameController = TextEditingController(text: service.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Доступ к файлам этого устройства'),
        content: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Сопряжённые устройства могут просматривать, скачивать и загружать файлы внутри выбранного каталога.'),
            const SizedBox(height: 14),
            TextField(
              controller: nameController,
              maxLength: 64,
              decoration: const InputDecoration(
                labelText: 'Имя этого устройства',
                helperText: 'Будет отображаться в списке устройств',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Общий каталог',
                helperText: 'Путь на этом устройстве',
              ),
            ),
            const SizedBox(height: 10),
            Text('IP: ${service.ipAddresses.join(', ')}:$ferryPort'),
          ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final prefs = service.identity.prefs;
              final trustedKeys = prefs.getKeys()
                  .where((key) => key.startsWith('trusted.')).toList();
              for (final key in trustedKeys) {
                await prefs.remove(key);
                await prefs.remove('known.host.${key.substring('trusted.'.length)}');
              }
              service.nearby.clear();
              service.notifyListeners();
              await service.connected?.disconnect();
              if (!context.mounted) return;
              Navigator.pop(context);
              _notice('Все доверенные устройства забыты');
            },
            child: const Text('Забыть доверенные устройства'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (result != null) {
      try {
        await service.setExportRoot(result);
        await service.identity.rename(nameController.text.trim());
        service.scanNow();
        _notice('Имя устройства и общий каталог сохранены');
      } catch (e) {
        _notice('Нельзя открыть каталог: $e');
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
                        const DropdownMenuItem(value: false, child: Text('Этот компьютер / телефон')),
                        DropdownMenuItem(
                          value: true,
                          child: Text(ready
                              ? 'Удалённое: ${service!.connected!.remoteName}'
                              : 'Удалённое устройство'),
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
                IconButton(
                  tooltip: 'Вверх',
                  onPressed: disabled ? null : () => _goUp(pane),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: 'Обновить',
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
          if (pane.selected.isNotEmpty)
            Row(
              children: [
                const SizedBox(width: 10),
                Text('Выбрано: ${pane.selected.length}'),
                TextButton(
                  onPressed: () => setState(() => pane.selected.clear()),
                  child: const Text('Снять'),
                ),
              ],
            ),
          Expanded(
            child: disabled
                ? const Center(child: Text('Подключите другое устройство'))
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
              '${pane.entries.length} объектов',
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

  Widget _body(bool compact) {
    if (_service == null) {
      return Center(child: Text(_startup));
    }
    return Column(
      children: [
        if (Platform.isAndroid && !_androidStorageGranted)
          MaterialBanner(
            content: const Text('Для просмотра общих папок Android разрешите доступ ко всем файлам в системных настройках.'),
            actions: [
              TextButton(
                onPressed: _grantAndroidPermission,
                child: const Text('Разрешить'),
              ),
            ],
          ),
        if (compact)
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.folder), label: Text('Панель 1')),
              ButtonSegment(value: 1, icon: Icon(Icons.folder_shared), label: Text('Панель 2')),
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
                onPressed: () => _copy(_right, _left),
                icon: const Icon(Icons.arrow_back),
                label: Text(compact ? 'В панель 1' : 'F5  ← Копировать'),
              ),
              FilledButton.icon(
                onPressed: () => _copy(_left, _right),
                icon: const Icon(Icons.arrow_forward),
                label: Text(compact ? 'В панель 2' : 'F5  Копировать →'),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            '${_service!.connectionStatus}  •  ${_service!.lastMessage}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
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
                    tooltip: 'Повторить поиск устройств',
                    onPressed: () {
                      _service!.scanNow();
                      _notice('Поиск устройств запущен. Если телефон не виден, используйте подключение по IP.');
                    },
                    icon: const Icon(Icons.refresh),
                  ),
                if (_service != null)
                  PopupMenuButton<NearbyPeer>(
                    tooltip: 'Устройства в сети',
                    icon: const Icon(Icons.wifi_find),
                    onSelected: (peer) => _connect(peer.host),
                    itemBuilder: (context) => _service!.nearby.isEmpty
                        ? <PopupMenuEntry<NearbyPeer>>[
                            const PopupMenuItem(
                              enabled: false,
                              child: Text('Устройства не найдены'),
                            ),
                          ]
                        : _service!.nearby.values
                            .map((peer) => PopupMenuItem<NearbyPeer>(
                                  value: peer,
                                  child: Text(
                                    '${peer.name} • ${peer.host}'
                                    '${DateTime.now().difference(peer.seen).inSeconds > 45 ? ' (сохранённый адрес)' : ''}',
                                  ),
                                ))
                            .toList(),
                  ),
                IconButton(
                  tooltip: 'Подключиться по IP',
                  onPressed: _service == null ? null : _connectDialog,
                  icon: const Icon(Icons.add_link),
                ),
                IconButton(
                  tooltip: 'Общий каталог',
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
    _service?.removeListener(_serviceChanged);
    _service?.dispose();
    _ip.dispose();
    super.dispose();
  }
}
