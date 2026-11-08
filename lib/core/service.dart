import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'files.dart';
import 'flow_acknowledgements.dart';
import 'lan_networks.dart';
import 'localization.dart';
import 'native_lan.dart';
import 'personal_data.dart';
import 'secure_peer.dart';
import 'sms_archive.dart';
import 'transfer.dart';

const ferryPort = 47655;
const discoveryPort = 47656;

class NearbyPeer {
  final String name;
  final String host;
  final String identity;
  final DateTime seen;
  const NearbyPeer(this.name, this.host, this.identity, this.seen);
}

class FerryService extends ChangeNotifier {
  final PeerIdentity identity;
  Future<bool> Function(String, String, String) onPairing;

  /// Restoring contacts always requires approval on the Android device.
  /// Exports instead rely on pre-granted permission for each paired key.
  Future<bool> Function(
      String fileName, String requester, Map<String, dynamic> preview)?
      onContactsImportConsent;
  String? _contactsImportDir;
  String? _contactsImportName;

  HttpServer? _http;
  RawDatagramSocket? _udp;
  bool _networkScanActive = false;
  DateTime _lastSubnetRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  List<LocalSubnet> _subnets = [];
  Timer? _beacon;
  SecurePeer? connected;
  IncomingTransfer? _incoming;
  Completer<List<FileEntry>>? _listRequest;
  final FlowAcknowledgements _flowAcks = FlowAcknowledgements();
  Completer<void>? _transferComplete;
  Completer<List<String>>? _personalBackupWaiter;
  String? _personalBackupId;
  String? _personalBackupKind;
  String? _outgoingTransferId;
  int _transferSequence = 0;

  String _newTransferId() => '${DateTime.now().microsecondsSinceEpoch}-${++_transferSequence}';
  int _nextId = 0;
  bool _disposed = false;
  bool _sending = false;
  bool _discardingTransfer = false;
  String exportRoot;
  String lastMessage = tr('Готово');
  String connectionStatus = tr('Соединение закрыто');
  bool broadcasting = false;
  final Map<String, NearbyPeer> nearby = {};

  final int listenPort;
  final bool enableDiscovery;
  FerryService(this.identity, this.onPairing, this.exportRoot, {
    this.listenPort = ferryPort,
    this.enableDiscovery = true,
  });
  int? get boundPort => _http?.port;

  static Future<FerryService> initialize(
    Future<bool> Function(String, String, String) approval,
    String initialRoot,
  ) async {
    final id = await PeerIdentity.load();
    final root = id.prefs.getString('ferrypane.export.root') ?? initialRoot;
    final result = FerryService(id, approval, root);
    await result.start();
    return result;
  }

  String get name => identity.displayName;
  String get publicIdentity => identity.publicString;

  List<String> get ipAddresses => _ipAddresses;
  List<String> _ipAddresses = [];

  Future<void> start() async {
    try {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, listenPort, shared: true);
      broadcasting = true;
      _http!.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        try {
          final socket = await WebSocketTransformer.upgrade(request);
          _attach(socket, false, request.connectionInfo?.remoteAddress.address);
        } catch (e) {
          _status(tr('Входящее подключение отклонено: {error}', {'error': e}));
        }
      });
      _status(tr('Сервис доступен на порту {port}', {'port': _http!.port}));
    } catch (e) {
      _status(tr('Ошибка открытия порта {port}: {error}', {'port': ferryPort, 'error': e}));
    }
    // Previously paired devices remain selectable when broadcast discovery
    // is blocked, as can happen on some Windows firewall/Wi-Fi profiles.
    for (final key in identity.prefs.getKeys()) {
      if (!key.startsWith('known.host.')) continue;
      final peerId = key.substring('known.host.'.length);
      final knownName = identity.prefs.getString('trusted.$peerId');
      final knownHost = identity.prefs.getString(key);
      if (knownName != null && knownHost != null && knownHost.isNotEmpty) {
        nearby[peerId] = NearbyPeer(
          knownName, knownHost, peerId, DateTime.fromMillisecondsSinceEpoch(0),
        );
      }
    }
    await _refreshAddresses();
    if (enableDiscovery) await _startDiscovery();
  }

  Future<void> _refreshAddresses() async {
    try {
      final subnets = await listLocalSubnets();
      _subnets = subnets;
      _lastSubnetRefresh = DateTime.now();
      _ipAddresses = subnets.map((s) => s.address).toList();
      _notify();
    } catch (_) {
      // Manual IP entry remains available.
    }
  }

  Future<void> _startDiscovery() async {
    try {
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      _udp!.broadcastEnabled = true;
      _udp!.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = _udp!.receive()) != null) {
          final current = packet!;
          final sender = current.address;
          final port = current.port;
          final text = utf8.decode(current.data, allowMalformed: true);
          if (text == 'FERRYPANE_DISCOVER_V1') {
            _announce(sender, port); // legacy discovery fallback
            continue;
          }
          _receiveDiscovery(text, sender.address, port);
        }
      });
      _beacon = Timer.periodic(const Duration(seconds: 3), (_) {
        scanNow();
        nearby.removeWhere(
          (key, peer) =>
              !identity.trusts(key) &&
              DateTime.now().difference(peer.seen).inSeconds > 45,
        );
      });
      scanNow();
    } catch (e) {
      _status('Auto-discovery unavailable; manual IP still works: $e');
    }
  }

  Map<String, dynamic> _discoveryMessage(String type) => {
        'type': type,
        'name': name,
        'identity': publicIdentity,
        'port': ferryPort,
      };

  void _receiveDiscovery(String payload, String host, int port) {
    if (!LocalSubnet.isLocal(host)) return;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final type = data['type'];
      if (type != 'ferrypane_probe' && type != 'ferrypane_peer') return;
      final peerId = data['identity'];
      final peerName = data['name'];
      if (peerId is! String || peerId.isEmpty ||
          peerName is! String || peerName.trim().isEmpty ||
          peerId == publicIdentity) return;
      nearby[peerId] = NearbyPeer(
        peerName, host, peerId, DateTime.now(),
      );
      _notify();
      if (type == 'ferrypane_probe') {
        _announce(InternetAddress(host), port);
      }
    } catch (_) {
      // Unrelated network traffic is not a valid discovery announcement.
    }
  }

  void _announce(InternetAddress to, int port) {
    final data = utf8.encode(jsonEncode(_discoveryMessage('ferrypane_peer')));
    // Send unicast responses with a source address on the same network
    // whenever possible, rather than relying on the system default route.
    final candidates = _subnets.where((s) => s.contains(to.address)).toList();
    if (candidates.isNotEmpty) {
      unawaited(_sendBound(candidates.first, to.address, port, data));
    } else {
      _udp?.send(data, to, port);
    }
  }

  Future<void> _sendBound(
      LocalSubnet subnet, String destination, int port, List<int> payload) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress(subnet.address), 0);
      socket.broadcastEnabled = true;
      socket.send(payload, InternetAddress(destination), port);
    } catch (_) {
      // The interface may have vanished or may not permit broadcasts.
    } finally {
      socket?.close();
    }
  }

  Future<void> _scanAllNetworks() async {
    if (_networkScanActive || _disposed) return;
    _networkScanActive = true;
    try {
      if (DateTime.now().difference(_lastSubnetRefresh).inSeconds > 25) {
        await _refreshAddresses();
      }
      final payload = utf8.encode(jsonEncode(_discoveryMessage('ferrypane_probe')));
      for (final subnet in _subnets) {
        // Directed broadcast only within the interface's actual subnet.
        // When the prefix is unavailable, limited broadcast is still scoped
        // by binding the socket to the interface's local address.
        final address = subnet.broadcast ?? '255.255.255.255';
        await _sendBound(subnet, address, discoveryPort, payload);
      }
      // On Android, a VPN can become the default route. The platform helper
      // sends a UDP probe using Network.bindSocket for each LAN Network, and
      // receives its replies on that same underlying socket.
      if (Platform.isAndroid) {
        final replies = await AndroidLanNetwork.scan(utf8.decode(payload), discoveryPort);
        for (final reply in replies) {
          final host = reply['host'];
          final message = reply['payload'];
          if (host != null && message != null) {
            _receiveDiscovery(message, host, discoveryPort);
          }
        }
      }
    } catch (e) {
      _status(tr('Поиск в локальных сетях: {error}', {'error': e}));
    } finally {
      _networkScanActive = false;
      _notify();
    }
  }

  /// Search every eligible local IPv4 interface; never probe public networks.
  void scanNow() {
    if (_udp == null) {
      _status(tr('Автопоиск недоступен. Подключитесь вручную по IP.'));
      return;
    }
    unawaited(_scanAllNetworks());
    _notify();
  }

  Future<void> connect(String ipOrHost) async {
    final host = ipOrHost.trim();
    if (host.isEmpty) throw const FormatException('Enter device IP address');
    connectionStatus = tr('Подключение к {device}', {'device': host});
    _notify();
    final uri = Uri.parse(host.contains('://') ? host : 'ws://$host:$ferryPort');
    if (Platform.isAndroid) {
      final routeInfo = await AndroidLanNetwork.routeTo(uri.host);
      if (routeInfo != null) _status(routeInfo);
    }
    final socket = await WebSocket.connect(uri.toString())
        .timeout(const Duration(seconds: 10));
    _attach(socket, true, uri.host);
  }

  void _attach(WebSocket socket, bool initiator, String? remoteAddress) {
    socket.pingInterval = const Duration(seconds: 20);
    final old = connected;
    if (old != null) {
      old.disconnect();
    }
    late SecurePeer peer;
    peer = SecurePeer(
      socket: socket,
      identity: identity,
      initiator: initiator,
      approve: onPairing,
      onJson: (msg) => _onJson(peer, msg),
      onChunk: (chunk) => _onChunk(peer, chunk),
      onDisconnected: (reason) {
        if (connected == peer) {
          _incoming?.abort();
          _incoming = null;
          _contactsImportDir = null;
          _contactsImportName = null;
          _discardingTransfer = false;
          _listRequest?.completeError(StateError('Disconnected: $reason'));
          _listRequest = null;
          _flowAcks.cancel(StateError('Disconnected: $reason'));
          final completed = _transferComplete;
          if (completed != null && !completed.isCompleted) {
            completed.completeError(StateError('Disconnected: $reason'));
          }
          _transferComplete = null;
          final waitingBackup = _personalBackupWaiter;
          if (waitingBackup != null && !waitingBackup.isCompleted) {
            waitingBackup.completeError(StateError('Устройство отключилось до завершения резервной копии'));
          }
          _personalBackupWaiter = null;
          _personalBackupId = null;
          _personalBackupKind = null;
          _outgoingTransferId = null;
          connected = null;
          connectionStatus = tr('Соединение закрыто');
          _status(tr('Соединение разорвано: {reason}', {'reason': reason}));
        }
      },
      onReady: () {
        if (connected == peer) {
          connectionStatus = tr('Подключено к {device}', {'device': peer.remoteName});
          if (remoteAddress != null && remoteAddress.isNotEmpty) {
            nearby[peer.remoteKey] = NearbyPeer(
              peer.remoteName, remoteAddress, peer.remoteKey, DateTime.now(),
            );
            unawaited(identity.prefs.setString(
              'known.host.${peer.remoteKey}', remoteAddress,
            ));
          }
          _status(tr('Можно передавать файлы'));
        }
      },
    );
    connected = peer;
    connectionStatus = tr('Сопряжение…');
    _notify();
    unawaited(peer.run());
  }

  Future<void> forgetAllTrusted() async {
    final trustedKeys = identity.prefs.getKeys()
        .where((key) => key.startsWith('trusted.')).toList();
    for (final key in trustedKeys) {
      await identity.prefs.remove(key);
      final peerKey = key.substring('trusted.'.length);
      await identity.prefs.remove('known.host.$peerKey');
      await identity.prefs.remove('backup.contacts.$peerKey');
      await identity.prefs.remove('backup.sms.$peerKey');
    }
    nearby.clear();
    await connected?.disconnect();
    _notify();
  }

  bool canPeerBackup(String kind) {
    final peer = connected;
    if (!Platform.isAndroid || peer == null || !peer.ready) return false;
    if (kind != 'contacts' && kind != 'sms') return false;
    if (!identity.trusts(peer.remoteKey)) return false;
    return identity.prefs.getBool('backup.$kind.${peer.remoteKey}') ?? false;
  }

  Future<void> allowPeerBackup(String kind, bool allowed) async {
    final peer = connected;
    if (!Platform.isAndroid || peer == null || !peer.ready ||
        !identity.trusts(peer.remoteKey)) {
      throw StateError('Сначала выполните сопряжение с доверенным устройством');
    }
    if (kind != 'contacts' && kind != 'sms') {
      throw ArgumentError.value(kind, 'kind');
    }
    await identity.prefs.setBool('backup.$kind.${peer.remoteKey}', allowed);
    _notify();
  }

  Future<void> setExportRoot(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw FileSystemException('Directory not found', path);
    }
    exportRoot = p.normalize(p.absolute(path));
    await identity.prefs.setString('ferrypane.export.root', exportRoot);
    _status(tr('Корневая общая папка: {path}', {'path': exportRoot}));
  }

  Future<List<FileEntry>> remoteList(String path) async {
    final peer = connected;
    if (peer == null || !peer.ready) throw StateError('No connected device');
    if (_listRequest != null) throw StateError('Directory listing already in progress');
    final request = Completer<List<FileEntry>>();
    _listRequest = request;
    final id = ++_nextId;
    await peer.sendJson({'type': 'list', 'id': id, 'path': sanitizeRelative(path)});
    try {
      return await request.future.timeout(const Duration(seconds: 20));
    } finally {
      if (_listRequest == request) _listRequest = null;
    }
  }

  Future<void> download(List<String> remotePaths, String localDirectory) async {
    final peer = connected;
    if (peer == null || !peer.ready) throw StateError('No connected device');
    if (_incoming != null || _sending) throw StateError('Another transfer is in progress');
    await Directory(localDirectory).create(recursive: true);
    final transferId = _newTransferId();
    _discardingTransfer = false;
    _incoming = IncomingTransfer(localDirectory, _status, transferId);
    try {
      await peer.sendJson({
        'type': 'download',
        'transferId': transferId,
        'paths': remotePaths.map(sanitizeRelative).toList(),
      });
      _status(tr('Загрузка {count} объектов', {'count': remotePaths.length}));
    } catch (_) {
      await _incoming?.abort();
      _incoming = null;
      rethrow;
    }
  }

  /// Returns only after a complete verified archive is on the desktop disk.
  /// A request sent successfully is NOT a completed backup.
  Future<List<String>> requestPhoneBackup(
      String kind, String localDirectory) async {
    if (kind != 'contacts' && kind != 'sms') throw ArgumentError.value(kind);
    final peer = connected;
    if (peer == null || !peer.ready || peer.remotePlatform != 'android') {
      throw StateError('Подключите Android-устройство');
    }
    if (_incoming != null || _sending || _personalBackupWaiter != null) {
      throw StateError('Передача уже выполняется');
    }
    final folder = Directory(localDirectory);
    if (!await folder.exists()) {
      throw FileSystemException('Нет каталога для резервной копии', localDirectory);
    }
    final transferId = _newTransferId();
    final waiter = Completer<List<String>>();
    _discardingTransfer = false;
    _incoming = IncomingTransfer(localDirectory, _status, transferId);
    _personalBackupWaiter = waiter;
    _personalBackupId = transferId;
    _personalBackupKind = kind;
    try {
      await peer.sendJson({
        'type': 'personal_backup_request',
        'kind': kind,
        'transferId': transferId,
      });
      _status('Телефон готовит резервную копию ${kind == 'contacts' ? 'контактов' : 'SMS'}…');
      return await waiter.future.timeout(const Duration(minutes: 4));
    } catch (e) {
      _status(tr('Резервное копирование не выполнено: {error}', {'error': e}));
      await _incoming?.abort();
      _incoming = null;
      rethrow;
    } finally {
      if (_personalBackupWaiter == waiter) {
        _personalBackupWaiter = null;
        _personalBackupId = null;
        _personalBackupKind = null;
      }
    }
  }

  Future<void> sendContactsToPhone(String filePath) async {
    final peer = connected;
    if (peer == null || !peer.ready || peer.remotePlatform != 'android') {
      throw StateError('Подключите Android-устройство');
    }
    if (_incoming != null || _sending) throw StateError('Передача уже выполняется');
    final source = File(filePath);
    if (p.extension(filePath).toLowerCase() != '.vcf' ||
        !await source.exists() || await source.length() > 100 * 1024 * 1024 ||
        await source.length() == 0) {
      throw const FormatException('Выберите непустой файл .vcf размером до 100 МБ');
    }
    final transferId = _newTransferId();
    _sending = true;
    _outgoingTransferId = transferId;
    _transferComplete = Completer<void>();
    _flowAcks.begin(transferId);
    try {
      await peer.sendJson({
        'type': 'personal_contacts_import_start',
        'transferId': transferId,
        'fileName': p.basename(filePath),
      });
      await streamTransfer(
        walkLocalSelection([filePath]), peer, _status,
        (chunks) => _flowAcks.waitFor(transferId, chunks),
        transferId: transferId,
      );
      await _transferComplete!.future.timeout(const Duration(seconds: 45));
      _status(tr('Файл контактов передан. Подтвердите импорт на Android.'));
    } finally {
      _flowAcks.finish();
      _outgoingTransferId = null;
      _transferComplete = null;
      _sending = false;
      _notify();
    }
  }

  Future<void> upload(List<String> localPaths, String remoteDirectory) async {
    final peer = connected;
    if (peer == null || !peer.ready) throw StateError('No connected device');
    if (_sending || _incoming != null) throw StateError('Another transfer is in progress');
    final transferId = _newTransferId();
    _sending = true;
    _outgoingTransferId = transferId;
    _transferComplete = Completer<void>();
    _flowAcks.begin(transferId);
    try {
      await peer.sendJson({
        'type': 'upload_start',
        'transferId': transferId,
        'dest': sanitizeRelative(remoteDirectory),
      });
      _status(tr('Загрузка {count} объектов на устройство', {'count': localPaths.length}));
      await streamTransfer(
        walkLocalSelection(localPaths), peer, _status,
        (chunks) => _flowAcks.waitFor(transferId, chunks),
        transferId: transferId,
      );
      await _transferComplete!.future.timeout(const Duration(seconds: 45));
      _status(tr('Загрузка завершена и подтверждена получателем'));
    } finally {
      _flowAcks.finish();
      _transferComplete = null;
      _outgoingTransferId = null;
      _sending = false;
      _notify();
    }
  }

  Future<void> _onJson(SecurePeer peer, Map<String, dynamic> msg) async {
    try {
      switch (msg['type']) {
        case 'list':
          final id = msg['id'];
          try {
            final files = await listAt(exportRoot, msg['path'] as String);
            await peer.sendJson({
              'type': 'list_result',
              'id': id,
              'entries': files.map((e) => e.toJson()).toList(),
            });
          } catch (e) {
            await peer.sendJson({'type': 'error', 'id': id, 'message': '$e'});
          }
          break;
        case 'list_result':
          final request = _listRequest;
          if (request != null && !request.isCompleted) {
            request.complete(
              (msg['entries'] as List)
                  .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e as Map)))
                  .toList(),
            );
          }
          break;
        case 'error':
          final pendingBackup = _personalBackupWaiter;
          if (pendingBackup != null && !pendingBackup.isCompleted &&
              (msg['transferId'] == null ||
                  msg['transferId'] == _personalBackupId)) {
            pendingBackup.completeError(
              StateError('Телефон: ${msg['message']}'),
            );
          }
          final outgoing = _transferComplete;
          if (outgoing != null && !outgoing.isCompleted) {
            outgoing.completeError(StateError(msg['message'] as String));
          }
          if (_incoming != null) {
            await _incoming!.abort();
            _incoming = null;
            _discardingTransfer = true;
            _contactsImportDir = null;
            _contactsImportName = null;
          }
          _flowAcks.cancel(StateError(msg['message'] as String));
          final request = _listRequest;
          if (request != null && !request.isCompleted) {
            request.completeError(StateError(msg['message'] as String));
          } else {
            _status(tr('Ошибка удалённого устройства: {error}', {'error': msg['message']}));
          }
          break;
        case 'download':
          // Never block the incoming message loop: flow acknowledgements
          // must continue to be processed while a transfer is running.
          unawaited(_sendExport(
            peer,
            List<String>.from(msg['paths'] as List),
            msg['transferId'] as String,
          ));
          break;
        case 'personal_backup_request':
          unawaited(_sendPhonePersonalBackup(
            peer,
            msg['kind'] as String,
            msg['transferId'] as String,
          ));
          break;
        case 'personal_contacts_import_start':
          if (!Platform.isAndroid || peer.remotePlatform == 'unknown') {
            throw StateError('Импорт контактов доступен только на Android');
          }
          if (_incoming != null || _sending) throw StateError('Передача уже выполняется');
          final fileName = sanitizeRelative(msg['fileName'] as String);
          if (fileName.isEmpty || fileName.contains('/') ||
              p.extension(fileName).toLowerCase() != '.vcf') {
            throw const FormatException('Неверное имя файла контактов');
          }
          final dir = await PersonalDataBridge.prepareContactsImport();
          _contactsImportDir = dir;
          _contactsImportName = fileName;
          _incoming = IncomingTransfer(dir, _status, msg['transferId'] as String);
          _discardingTransfer = false;
          _status(tr('Получаем адресную книгу из {name}', {'name': peer.remoteName}));
          break;
        case 'personal_status':
          _status(msg['message']?.toString() ?? 'Операция на телефоне завершена');
          break;
        case 'personal_backup_started':
          if (msg['transferId'] == _personalBackupId) {
            _status('Телефон отправляет ${_personalBackupKind == 'contacts' ? 'контакты' : 'SMS'}…');
          }
          break;
        case 'upload_start':
          if (_incoming != null || _sending) throw StateError('Receiver busy');
          final destination = containedPath(exportRoot, msg['dest'] as String);
          await Directory(destination).create(recursive: true);
          _discardingTransfer = false;
          _incoming = IncomingTransfer(destination, _status, msg['transferId'] as String);
          _status(tr('Получение файлов'));
          break;
        case 'dir':
        case 'file_begin':
        case 'file_end':
        case 'transfer_end':
          if (_discardingTransfer) {
            if (msg['type'] == 'transfer_end') _discardingTransfer = false;
            break;
          }
          final incoming = _incoming;
          if (incoming == null) throw const FormatException('Unexpected transfer frame');
          if (_contactsImportDir != null) {
            if (msg['type'] == 'dir') {
              throw const FormatException('Импорт контактов не принимает папки');
            }
            if (msg['type'] == 'file_begin' &&
                (msg['path'] != _contactsImportName ||
                 (msg['size'] as num).toInt() > 100 * 1024 * 1024)) {
              throw const FormatException('Импорт контактов: неверный файл');
            }
          }
          await incoming.consume(msg, peer);
          if (msg['type'] == 'transfer_end') {
            _incoming = null;
            await peer.sendJson({
              'type': 'transfer_complete',
              'transferId': incoming.transferId,
            });
            if (_personalBackupId == incoming.transferId) {
              final pending = _personalBackupWaiter;
              try {
                if (incoming.savedPaths.length != 1) {
                  throw StateError('Ожидался один файл резервной копии, получено: ${incoming.savedPaths.length}');
                }
                final file = incoming.savedPaths.single;
                final expectedExt = _personalBackupKind == 'contacts'
                    ? '.vcf' : '.json';
                if (p.extension(file).toLowerCase() != expectedExt) {
                  throw StateError('Получен файл неподходящего формата: $file');
                }
                final files = <String>[file];
                String? htmlFailure;
                if (_personalBackupKind == 'sms') {
                  try {
                    files.add(await SmsArchive.createViewer(File(file)));
                  } catch (e) {
                    // An HTML rendering failure must not conceal or discard a
                    // fully verified JSON backup that is already on disk.
                    htmlFailure = '$e';
                  }
                }
                _status(htmlFailure == null
                    ? 'Готово. Резервная копия сохранена: ${files.join(' и ')}'
                    : 'SMS JSON сохранён: $file. HTML не создан: $htmlFailure');
                if (pending != null && !pending.isCompleted) pending.complete(files);
              } catch (e) {
                _status(tr('Ошибка обработки резервной копии: {error}', {'error': e}));
                if (pending != null && !pending.isCompleted) pending.completeError(e);
              }
            }
            final importDir = _contactsImportDir;
            final importName = _contactsImportName;
            _contactsImportDir = null;
            _contactsImportName = null;
            if (importDir != null && importName != null) {
              unawaited(_offerContactsImport(
                peer,
                containedPath(importDir, importName),
              ));
            }
          }
          break;
        case 'flow_ack':
          _flowAcks.accept(
            msg['transferId'] as String,
            (msg['chunks'] as num).toInt(),
          );
          break;
        case 'transfer_complete':
          final receipt = _transferComplete;
          if (msg['transferId'] == _outgoingTransferId &&
              receipt != null && !receipt.isCompleted) {
            receipt.complete();
          }
          break;
        default:
          throw FormatException('Unknown operation ${msg['type']}');
      }
    } catch (e) {
      _status(tr('Ошибка передачи: {error}', {'error': e}));
      if (peer.ready) {
        await peer.sendJson({'type': 'error', 'message': '$e'});
      }
      if (_incoming != null) {
        await _incoming!.abort();
        _incoming = null;
        _discardingTransfer = true;
        _contactsImportDir = null;
        _contactsImportName = null;
      }
    }
  }

  Future<void> _onChunk(SecurePeer peer, Uint8List bytes) async {
    if (_discardingTransfer) return;
    final incoming = _incoming;
    if (incoming == null) throw const FormatException('Unexpected data frame');
    try {
      await incoming.consumeChunk(bytes, peer);
    } catch (e) {
      _status(tr('Ошибка файловой передачи: {error}', {'error': e}));
      await incoming.abort();
      _incoming = null;
      _discardingTransfer = true;
      if (peer.ready) {
        await peer.sendJson({'type': 'error', 'message': '$e'});
      }
    }
  }

  Future<void> _sendPhonePersonalBackup(
    SecurePeer peer,
    String kind,
    String transferId,
  ) async {
    String? tempFile;
    try {
      if (!Platform.isAndroid || peer.remotePlatform == 'unknown' ||
          (kind != 'contacts' && kind != 'sms')) {
        throw StateError('Резервное копирование поддерживается только на Android');
      }
      if (_sending || _incoming != null) throw StateError('Другая передача уже выполняется');
      // No pop-up while recovering from a phone with a broken screen.
      // Sensitive backups are opt-in and individually authorized beforehand.
      if (!canPeerBackup(kind)) {
        throw StateError('На телефоне заранее не разрешено резервное копирование $kind для этого ПК');
      }
      tempFile = await PersonalDataBridge.makeBackup(kind);
      _sending = true;
      _outgoingTransferId = transferId;
      _transferComplete = Completer<void>();
      _flowAcks.begin(transferId);
      await peer.sendJson({
        'type': 'personal_backup_started',
        'transferId': transferId,
      });
      await streamTransfer(
        walkLocalSelection([tempFile]), peer, _status,
        (chunks) => _flowAcks.waitFor(transferId, chunks),
        transferId: transferId,
      );
      await _transferComplete!.future.timeout(const Duration(seconds: 45));
      _status('Резервная копия ${kind == 'contacts' ? 'контактов' : 'SMS'} передана');
    } catch (e) {
      _status(tr('Резервная копия: {error}', {'error': e}));
      if (peer.ready) {
        await peer.sendJson({
          'type': 'error',
          'transferId': transferId,
          'message': '$e',
        });
      }
    } finally {
      if (_outgoingTransferId == transferId) {
        _flowAcks.finish();
        _outgoingTransferId = null;
        _transferComplete = null;
        _sending = false;
      }
      if (tempFile != null) {
        try { await File(tempFile).delete(); } catch (_) {}
      }
      _notify();
    }
  }

  Future<void> _offerContactsImport(SecurePeer peer, String filePath) async {
    try {
      if (!await File(filePath).exists()) {
        throw StateError('Файл контактов не был полностью получен');
      }
      final preview = await PersonalDataBridge.previewContactsImport(filePath);
      final consent = onContactsImportConsent;
      if (consent == null ||
          !await consent(p.basename(filePath), peer.remoteName, preview)) {
        await peer.sendJson({
          'type': 'personal_status',
          'message': 'Восстановление контактов отменено на телефоне',
        });
        return;
      }
      _status(tr('FerryPane восстанавливает контакты…'));
      final result = await PersonalDataBridge.restoreContactsImport(filePath);
      final summary = 'Контакты: добавлено ${result['created']}, '
          'объединено ${result['expanded']}, '
          'без изменений ${result['unchanged']}, '
          'ошибок ${result['failed']}';
      _status(summary);
      await peer.sendJson({'type': 'personal_status', 'message': summary});
    } catch (e) {
      _status(tr('Не удалось восстановить контакты: {error}', {'error': e}));
      if (peer.ready) {
        await peer.sendJson({
          'type': 'personal_status',
          'message': 'Ошибка восстановления контактов: $e',
        });
      }
    } finally {
      // The vCard is deliberately confined to the private import cache.
      try { await File(filePath).delete(); } catch (_) {}
    }
  }

  Future<void> _sendExport(
    SecurePeer peer,
    List<String> selected,
    String transferId,
  ) async {
    if (_sending || _incoming != null) {
      await peer.sendJson({'type': 'error', 'message': 'Transfer already active'});
      return;
    }
    _sending = true;
    _outgoingTransferId = transferId;
    _transferComplete = Completer<void>();
    _flowAcks.begin(transferId);
    try {
      _status(tr('Отправлено {count} объектов', {'count': selected.length}));
      await streamTransfer(
        walkSelection(exportRoot, selected), peer, _status,
        (chunks) => _flowAcks.waitFor(transferId, chunks),
        transferId: transferId,
      );
      await _transferComplete!.future.timeout(const Duration(seconds: 45));
      _status(tr('Передача завершена и подтверждена получателем'));
    } catch (e) {
      _status(tr('Ошибка отправки: {error}', {'error': e}));
      if (peer.ready) {
        await peer.sendJson({'type': 'error', 'message': '$e'});
      }
    } finally {
      _flowAcks.finish();
      _transferComplete = null;
      _outgoingTransferId = null;
      _sending = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) super.notifyListeners();
  }

  void _status(String text) {
    lastMessage = text;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _beacon?.cancel();
    _udp?.close();
    _http?.close(force: true);
    connected?.disconnect();
    super.dispose();
  }
}
