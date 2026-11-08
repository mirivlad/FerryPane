import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'files.dart';
import 'flow_acknowledgements.dart';
import 'lan_networks.dart';
import 'localization.dart';
import 'native_lan.dart';
import 'personal_data.dart';
import 'resume_store.dart';
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

class TransferProgress {
  final String file;
  final int done;
  final int total;
  final double bytesPerSecond;

  const TransferProgress(this.file, this.done, this.total, this.bytesPerSecond);

  double get fraction => total > 0 ? (done / total).clamp(0.0, 1.0).toDouble() : 0.0;
  Duration? get remaining => bytesPerSecond > 0 && done < total
      ? Duration(seconds: ((total - done) / bytesPerSecond).ceil())
      : null;
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
  SecurePeer? _pendingPeer;
  final Map<String, List<DateTime>> _inboundAttempts = {};
  DateTime? _pairingDeadline;
  Timer? _pairingTimer;

  bool get pairingOpen =>
      _pairingDeadline != null && DateTime.now().isBefore(_pairingDeadline!);

  /// Short opt-in window for FIRST pairing. Never persisted; reconnecting
  /// devices must prove ownership of an already trusted identity.
  void setPairingOpen(bool allowed) {
    _pairingTimer?.cancel();
    _pairingDeadline = allowed
        ? DateTime.now().add(const Duration(minutes: 2))
        : null;
    if (allowed) {
      _pairingTimer = Timer(const Duration(minutes: 2), () {
        _pairingDeadline = null;
        _notify();
      });
    }
    _notify();
  }

  Future<void> disconnectPeer() async {
    _retrySuppressed = true;
    _retryTimer?.cancel();
    await connected?.disconnect();
    _notify();
  }

  /// Public TCP listener must not accept Internet-sourced connections.
  static bool isAllowedSource(String ip) =>
      ip == '127.0.0.1' || LocalSubnet.isLocal(ip);

  bool _acceptAttempt(String source) {
    final now = DateTime.now();
    final recent = _inboundAttempts.putIfAbsent(source, () => <DateTime>[]);
    recent.removeWhere((at) => now.difference(at) > const Duration(minutes: 1));
    if (recent.length >= 6) return false;
    recent.add(now);
    if (_inboundAttempts.length > 512) {
      _inboundAttempts.removeWhere((_, values) {
        values.removeWhere((at) =>
            now.difference(at) > const Duration(minutes: 1));
        return values.isEmpty;
      });
    }
    return true;
  }

  IncomingTransfer? _incoming;
  Timer? _incomingIdleTimer;

  /// A stalled sender must not leave a .part file open indefinitely. This
  /// checks actual data/protocol progress, not transfer duration or file size,
  /// so large legitimate copies remain unlimited in overall duration.
  void _setIncoming(IncomingTransfer? transfer) {
    _incoming = transfer;
    _touchIncoming();
  }

  void _touchIncoming() {
    _incomingIdleTimer?.cancel();
    final transfer = _incoming;
    if (transfer == null) return;
    _incomingIdleTimer = Timer(const Duration(minutes: 5), () {
      if (_incoming != transfer) return;
      _incomingIdleTimer = null;
      _incoming = null;
      _discardingTransfer = true;
      _contactsImportDir = null;
      _contactsImportName = null;
      final error = StateError('Передача прервана: 5 минут без данных');
      final waiting = _personalBackupWaiter;
      if (_personalBackupId == transfer.transferId &&
          waiting != null && !waiting.isCompleted) {
        waiting.completeError(error);
      }
      _status('$error');
      unawaited(() async {
        try {
          await transfer.abort(preserve: transfer.resumeStore != null);
        } catch (_) {}
        final peer = connected;
        if (peer != null && peer.ready) {
          try {
            await peer.sendJson({
              'type': 'error',
              'transferId': transfer.transferId,
              'message': '$error',
            });
          } catch (_) {}
        }
      }());
    });
  }

  Completer<List<FileEntry>>? _listRequest;
  int? _pendingListId;
  final FlowAcknowledgements _flowAcks = FlowAcknowledgements();
  Completer<void>? _transferComplete;
  Completer<ResumeReply>? _resumeWaiter;
  String? _resumeWaitPath;
  String? _resumeWaitTransfer;
  Map<String, dynamic>? _pendingJob;
  Timer? _retryTimer;
  bool _retryingJob = false;
  bool _retrySuppressed = false;
  int _retryCount = 0;
  bool _cancelRequested = false;
  TransferProgress? transferProgress;
  Future<void> _previousIncomingClose = Future<void>.value();

  DateTime _progressSample = DateTime.fromMillisecondsSinceEpoch(0);
  int _progressLastBytes = 0;
  double _progressRate = 0;

  bool get hasPendingCopy => _pendingJob != null;
  bool get copyPaused => _pendingJob?['paused'] == true;
  bool get copyActive => _sending || _incoming != null;
  bool get canPauseCopy => _pendingJob != null && copyActive;
  final void Function(String path, int done, int total)? onTransferProgress;

  void _onFileProgress(String path, int done, int total) {
    onTransferProgress?.call(path, done, total);
    final now = DateTime.now();
    final delta = now.difference(_progressSample).inMilliseconds;
    if (delta >= 300 || transferProgress == null ||
        transferProgress!.file != path) {
      if (delta > 0 && done >= _progressLastBytes) {
        final rate = (done - _progressLastBytes) * 1000 / delta;
        _progressRate = _progressRate == 0
            ? rate : _progressRate * 0.65 + rate * 0.35;
      } else {
        _progressRate = 0;
      }
      _progressSample = now;
      _progressLastBytes = done;
      transferProgress = TransferProgress(path, done, total, _progressRate);
      _notify();
    }
  }

  Future<ResumeReply> _requestResume(
    SecurePeer peer, String transferId, String path, int size, String digest, {
    bool reset = false,
  }) async {
    if (_resumeWaiter != null) throw StateError('Resume negotiation in progress');
    final waiting = Completer<ResumeReply>();
    _resumeWaiter = waiting;
    _resumeWaitTransfer = transferId;
    _resumeWaitPath = path;
    try {
      await peer.sendJson(reset ? {
        'type': 'file_reset',
        'transferId': transferId,
        'path': path,
      } : {
        'type': 'file_begin',
        'transferId': transferId,
        'path': path,
        'size': size,
        'sha256': digest,
      });
      return await waiting.future.timeout(const Duration(seconds: 60));
    } finally {
      if (_resumeWaiter == waiting) {
        _resumeWaiter = null;
        _resumeWaitPath = null;
        _resumeWaitTransfer = null;
      }
    }
  }

  String _hostFor(SecurePeer peer) {
    final stored = _lastConnectionUrl;
    if (stored != null) return stored;
    final known = nearby[peer.remoteKey]?.host ??
        identity.prefs.getString('known.host.${peer.remoteKey}');
    if (known == null || known.isEmpty) return '';
    return 'ws://$known:$ferryPort';
  }
  String? _lastConnectionUrl;

  Future<void> _saveJob(Map<String, dynamic> job) async {
    _pendingJob = job;
    if (!await identity.prefs.setString(
      'ferrypane.resume.pending', jsonEncode(job),
    )) {
      throw StateError('Could not save pending copy');
    }
    _retrySuppressed = false;
    _retryCount = 0;
    _notify();
  }

  Future<void> _finishJob() async {
    _pendingJob = null;
    _retryTimer?.cancel();
    _retryCount = 0;
    transferProgress = null;
    _progressRate = 0;
    await identity.prefs.remove('ferrypane.resume.pending');
    _notify();
  }

  Future<void> _restoreJob() async {
    final raw = identity.prefs.getString('ferrypane.resume.pending');
    if (raw == null) return;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) throw const FormatException('Invalid transfer job');
      final job = Map<String, dynamic>.from(parsed);
      if (job['version'] != 1 || job['peer'] is! String ||
          !identity.trusts(job['peer'] as String) ||
          job['paths'] is! List || job['destination'] is! String ||
          !['upload', 'download'].contains(job['mode']) ||
          job['scope'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(job['scope'])) {
        throw const FormatException('Invalid persisted transfer');
      }
      _pendingJob = job;
      _status('Есть незавершённая передача — можно продолжить');
      if (job['paused'] != true) _scheduleRetry();
    } catch (e) {
      _status('Невозможно восстановить сохранённое задание: $e');
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_disposed || _retrySuppressed || _pendingJob == null ||
        _pendingJob!['paused'] == true || _retryingJob ||
        _retryCount >= 12) return;
    final delay = _retryCount == 0 ? 2 : min(40, 2 << min(4, _retryCount));
    _retryTimer = Timer(Duration(seconds: delay), () {
      unawaited(_retryPending());
    });
  }

  Future<void> _retryPending() async {
    final job = _pendingJob;
    if (_disposed || _retryingJob || _retrySuppressed ||
        job == null || job['paused'] == true) return;
    _retryingJob = true;
    try {
      final peer = connected;
      if (peer == null || !peer.ready || peer.remoteKey != job['peer']) {
        if (_pendingPeer != null) return;
        final address = job['host'] as String?;
        if (address == null || address.isEmpty) {
          _status('Адрес устройства неизвестен: подключитесь вручную для докачки');
          return;
        }
        _retryCount++;
        await connect(address);
        // The authenticated onReady callback will repeat the saved job.
        return;
      }
      if (_sending || _incoming != null) {
        _retryTimer?.cancel();
        _retryTimer = Timer(const Duration(milliseconds: 600), () {
          if (!_disposed) unawaited(_retryPending());
        });
        return;
      }
      _status('Восстанавливаем передачу…');
      final paths = List<String>.from(job['paths'] as List);
      if (job['mode'] == 'upload') {
        await upload(paths, job['destination'] as String, replay: true);
      } else {
        await download(paths, job['destination'] as String, replay: true);
      }
    } catch (e) {
      if (_disposed) return;
      _status('Не удалось продолжить: $e');
    } finally {
      _retryingJob = false;
      if (connected?.ready != true && _pendingJob != null) _scheduleRetry();
    }
  }

  /// Pause retains verified pieces and the persisted operation; no network
  /// reconnection occurs until the user explicitly resumes it.
  Future<void> pauseCopy() async {
    final job = _pendingJob;
    if (job == null) return;
    job['paused'] = true;
    _retryTimer?.cancel();
    _retrySuppressed = true;
    await identity.prefs.setString(
      'ferrypane.resume.pending', jsonEncode(job),
    );
    _cancelRequested = true;
    final incoming = _incoming;
    if (incoming != null) {
      _discardingTransfer = true;
      await incoming.abort(preserve: true);
      _setIncoming(null);
    }
    final peer = connected;
    final id = _outgoingTransferId ?? incoming?.transferId;
    if (peer != null && peer.ready && id != null) {
      await peer.sendJson({'type': 'transfer_pause', 'transferId': id});
    }
    _flowAcks.cancel(StateError('Transfer paused'));
    _status('Передача приостановлена, докачка сохранена');
    _notify();
  }

  Future<void> resumeCopy() async {
    if (_pendingJob == null) return;
    _pendingJob!['paused'] = false;
    _retrySuppressed = false;
    _retryCount = 0;
    _cancelRequested = false;
    await identity.prefs.setString(
      'ferrypane.resume.pending', jsonEncode(_pendingJob),
    );
    if (connected?.ready == true) {
      unawaited(_retryPending());
    } else {
      _scheduleRetry();
    }
    _notify();
  }

  Future<void> cancelCopy() async {
    _retryTimer?.cancel();
    _retrySuppressed = true;
    _cancelRequested = true;
    final incoming = _incoming;
    if (incoming != null) {
      _discardingTransfer = true;
      await incoming.abort();
      _setIncoming(null);
    }
    final id = _outgoingTransferId ?? incoming?.transferId;
    final peer = connected;
    if (peer != null && peer.ready && id != null) {
      await peer.sendJson({'type': 'transfer_cancel', 'transferId': id});
    }
    _flowAcks.cancel(StateError('Transfer cancelled'));
    await _finishJob();
    _status('Передача отменена. Готовые файлы сохранены.');
  }

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
    this.onTransferProgress,
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
        final source = request.connectionInfo?.remoteAddress.address ?? '';
        if (!isAllowedSource(source)) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        // Browser-origin WebSocket calls have no purpose in the native
        // FerryPane protocol. Refusing them prevents a webpage from tying up
        // the pending-pairing slot on localhost or another private interface.
        // dart:io native clients do not send an Origin header by default.
        if (request.headers['origin']?.isNotEmpty == true) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        if (connected?.ready == true || _pendingPeer != null) {
          request.response.statusCode = HttpStatus.conflict;
          await request.response.close();
          return;
        }
        if (!_acceptAttempt(source)) {
          request.response.statusCode = HttpStatus.tooManyRequests;
          await request.response.close();
          return;
        }
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        try {
          final socket = await WebSocketTransformer.upgrade(
            request,
            compression: CompressionOptions.compressionOff,
          );
          _attach(socket, false, source);
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
    await _restoreJob();
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
    if (_pendingPeer != null) {
      throw StateError('Another connection is being authenticated');
    }
    final uri = Uri.parse(host.contains('://') ? host : 'ws://$host:$ferryPort');
    if (uri.scheme != 'ws' || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery || uri.hasFragment) {
      throw const FormatException('Only direct LAN WebSocket connections are allowed');
    }
    final resolved = await InternetAddress.lookup(uri.host)
        .timeout(const Duration(seconds: 5));
    if (resolved.isEmpty ||
        resolved.any((ip) => !isAllowedSource(ip.address))) {
      throw const FormatException('The destination is outside the local network');
    }
    _status(tr('Подключение к {device}', {'device': host}));
    if (Platform.isAndroid) {
      final routeInfo = await AndroidLanNetwork.routeTo(uri.host);
      if (routeInfo != null) _status(routeInfo);
    }
    final socket = await WebSocket.connect(uri.toString(),
      compression: CompressionOptions.compressionOff,
    ).timeout(const Duration(seconds: 10));
    _lastConnectionUrl = uri.toString();
    _attach(socket, true, uri.host);
  }

  void _attach(WebSocket socket, bool initiator, String? remoteAddress) {
    if (_pendingPeer != null || (!initiator && connected?.ready == true)) {
      unawaited(socket.close(WebSocketStatus.policyViolation, 'Busy'));
      return;
    }
    socket.pingInterval = const Duration(seconds: 20);
    late SecurePeer peer;
    peer = SecurePeer(
      socket: socket,
      identity: identity,
      initiator: initiator,
      allowHello: (remoteKey) =>
          identity.trusts(remoteKey) || initiator || pairingOpen,
      approve: (name, code, key) async {
        if (!identity.trusts(key) && !initiator && !pairingOpen) {
          return false;
        }
        final allowed = await onPairing(name, code, key);
        // A timed-out, revoked or closed window cannot be accepted after
        // the prompt; manually initiated outgoing connects are an exception.
        return allowed &&
            (identity.trusts(key) || initiator || pairingOpen);
      },
      onJson: (msg) => _onJson(peer, msg),
      onChunk: (chunk) => _onChunk(peer, chunk),
      onDisconnected: (reason) {
        if (_pendingPeer == peer) {
          _pendingPeer = null;
          if (initiator) {
            _status(tr('Подключение отклонено: {reason}', {'reason': reason}));
          }
          _notify();
        }
        if (connected == peer) {
          final interrupted = _incoming;
          _previousIncomingClose = interrupted == null
              ? Future<void>.value()
              : interrupted.abort(preserve: true);
          _setIncoming(null);
          _contactsImportDir = null;
          _contactsImportName = null;
          _discardingTransfer = false;
          _listRequest?.completeError(StateError('Disconnected: $reason'));
          _listRequest = null;
          _pendingListId = null;
          _flowAcks.cancel(StateError('Disconnected: $reason'));
          final waitResume = _resumeWaiter;
          if (waitResume != null && !waitResume.isCompleted) {
            waitResume.completeError(StateError('Disconnected: $reason'));
          }
          _resumeWaiter = null;
          if (_pendingJob != null && !_retrySuppressed &&
              _pendingJob!['paused'] != true) _scheduleRetry();
          final completed = _transferComplete;
          if (completed != null && !completed.isCompleted) {
            completed.completeError(StateError('Disconnected: $reason'));
          }
          _transferComplete = null;
          final waitingBackup = _personalBackupWaiter;
          if (waitingBackup != null && !waitingBackup.isCompleted) {
            waitingBackup.completeError(
              StateError('Устройство отключилось до завершения резервной копии'),
            );
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
        if (_pendingPeer != peer) {
          unawaited(peer.disconnect());
          return;
        }
        // An untrusted connection may never replace an existing session.
        if (!initiator && connected?.ready == true) {
          _pendingPeer = null;
          unawaited(peer.disconnect());
          return;
        }
        final previous = connected;
        _pendingPeer = null;
        connected = peer;
        if (previous != null && previous != peer) {
          unawaited(previous.disconnect());
        }
        if (!identity.trusts(peer.remoteKey)) {
          // Defensive; SecurePeer will already have stored trust.
          unawaited(peer.disconnect());
          return;
        }
        setPairingOpen(false);
        connectionStatus =
            tr('Подключено к {device}', {'device': peer.remoteName});
        if (remoteAddress != null && remoteAddress.isNotEmpty) {
          nearby[peer.remoteKey] = NearbyPeer(
            peer.remoteName, remoteAddress, peer.remoteKey, DateTime.now(),
          );
          unawaited(identity.prefs.setString(
            'known.host.${peer.remoteKey}', remoteAddress,
          ));
        }
        _status(tr('Можно передавать файлы'));
        if (_pendingJob != null && peer.remoteKey == _pendingJob!['peer'] &&
            _pendingJob!['paused'] != true && !_retrySuppressed) {
          Future<void>.delayed(const Duration(milliseconds: 150), () {
            if (!_disposed) unawaited(_retryPending());
          });
        }
      },
    );
    _pendingPeer = peer;
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
      await identity.prefs.remove('access.read.$peerKey');
      await identity.prefs.remove('access.write.$peerKey');
    }
    nearby.clear();
    await connected?.disconnect();
    _notify();
  }

  bool get peerCanRead {
    final peer = connected;
    return peer != null && peer.ready && identity.trusts(peer.remoteKey) &&
        (identity.prefs.getBool('access.read.${peer.remoteKey}') ?? true);
  }

  bool get peerCanWrite {
    final peer = connected;
    return peer != null && peer.ready && identity.trusts(peer.remoteKey) &&
        (identity.prefs.getBool('access.write.${peer.remoteKey}') ?? true);
  }

  Future<void> setPeerAccess({required bool read, required bool write}) async {
    final peer = connected;
    if (peer == null || !peer.ready || !identity.trusts(peer.remoteKey)) {
      throw StateError('No paired device connected');
    }
    if (!await identity.prefs.setBool('access.read.${peer.remoteKey}', read) ||
        !await identity.prefs.setBool('access.write.${peer.remoteKey}', write)) {
      throw StateError('Unable to save access permissions');
    }
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
    final id = ++_nextId;
    _listRequest = request;
    _pendingListId = id;
    try {
      await peer.sendJson({
        'type': 'list',
        'id': id,
        'path': sanitizeRelative(path),
      });
      return await request.future.timeout(const Duration(seconds: 20));
    } finally {
      if (_listRequest == request) {
        _listRequest = null;
        _pendingListId = null;
      }
    }
  }

  Future<void> download(
    List<String> remotePaths, String localDirectory, {
    bool replay = false,
  }) async {
    final peer = connected;
    if (peer == null || !peer.ready) throw StateError('No connected device');
    if (_incoming != null || _sending) {
      throw StateError('Another transfer is in progress');
    }
    await Directory(localDirectory).create(recursive: true);
    final paths = remotePaths.map(sanitizeRelative).toList();
    final scope = ResumeStore.selectionScope(paths);
    if (!replay) {
      await _saveJob({
        'version': 1,
        'mode': 'download',
        'peer': peer.remoteKey,
        'host': _hostFor(peer),
        'paths': paths,
        'destination': localDirectory,
        'scope': scope,
        'paused': false,
      });
    }
    final transferId = _newTransferId();
    await _previousIncomingClose;
    final store = await ResumeStore.open(
      localDirectory, peer.remoteKey, scope,
    );
    _cancelRequested = false;
    _discardingTransfer = false;
    _setIncoming(IncomingTransfer(
      localDirectory, _status, transferId,
      resumeStore: store,
      onProgress: _onFileProgress,
    ));
    try {
      await peer.sendJson({
        'type': 'download',
        'transferId': transferId,
        'paths': paths,
        'scope': scope,
      });
      _status('Передача началась; докачка включена');
    } catch (e) {
      await _incoming?.abort(preserve: true);
      _setIncoming(null);
      if (_pendingJob != null && peer.ready) await _finishJob();
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
    _setIncoming(IncomingTransfer(localDirectory, _status, transferId));
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
      _setIncoming(null);
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
        negotiate: (path, size, digest, {bool reset = false}) =>
            _requestResume(
              peer, transferId, path, size, digest, reset: reset,
            ),
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

  Future<void> upload(
    List<String> localPaths, String remoteDirectory, {
    bool replay = false,
  }) async {
    final peer = connected;
    if (peer == null || !peer.ready) throw StateError('No connected device');
    if (_sending || _incoming != null) {
      throw StateError('Another transfer is in progress');
    }
    final selected = localPaths.map((path) => p.normalize(p.absolute(path))).toList();
    final scope = ResumeStore.selectionScope(selected);
    if (!replay) {
      await _saveJob({
        'version': 1,
        'mode': 'upload',
        'peer': peer.remoteKey,
        'host': _hostFor(peer),
        'paths': selected,
        'destination': sanitizeRelative(remoteDirectory),
        'scope': scope,
        'paused': false,
      });
    }
    final transferId = _newTransferId();
    _sending = true;
    _cancelRequested = false;
    _outgoingTransferId = transferId;
    _transferComplete = Completer<void>();
    _flowAcks.begin(transferId);
    try {
      await peer.sendJson({
        'type': 'upload_start',
        'transferId': transferId,
        'dest': sanitizeRelative(remoteDirectory),
        'scope': scope,
      });
      _status(tr('Загрузка {count} объектов на устройство',
          {'count': selected.length}));
      await streamTransfer(
        walkLocalSelection(selected), peer, _status,
        (chunks) => _flowAcks.waitFor(transferId, chunks),
        transferId: transferId,
        negotiate: (path, size, digest, {bool reset = false}) =>
            _requestResume(
              peer, transferId, path, size, digest, reset: reset,
            ),
        onProgress: _onFileProgress,
        cancelled: () => _cancelRequested,
      );
      await _transferComplete!.future.timeout(const Duration(seconds: 45));
      _status(tr('Загрузка завершена и подтверждена получателем'));
      if (_pendingJob != null) await _finishJob();
    } catch (e) {
      if (_pendingJob != null && peer.ready && !_cancelRequested &&
          _pendingJob!['paused'] != true) {
        await _finishJob();
        rethrow;
      }
      if (_pendingJob != null && _pendingJob!['paused'] != true) {
        _status('Связь прервана, задание сохранено для докачки');
      }
    } finally {
      _flowAcks.finish();
      _transferComplete = null;
      _outgoingTransferId = null;
      _sending = false;
      if (_pendingJob == null) transferProgress = null;
      _notify();
    }
  }

  Future<void> _onJson(SecurePeer peer, Map<String, dynamic> msg) async {
    try {
      if (connected != peer || !peer.ready || !identity.trusts(peer.remoteKey)) {
        throw StateError('Message from unauthenticated peer');
      }
      final type = msg['type'];
      if ((type == 'list' || type == 'download') && !peerCanRead) {
        throw StateError('This device has no permission to read shared files');
      }
      if ((type == 'upload_start' || type == 'personal_contacts_import_start') &&
          !peerCanWrite) {
        throw StateError('This device has no permission to write shared files');
      }
      switch (type) {
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
          // Old, duplicated, or unsolicited results must not complete a
          // newer folder listing. This is especially important after timeouts.
          if (msg['id'] == _pendingListId &&
              request != null && !request.isCompleted) {
            request.complete(
              (msg['entries'] as List)
                  .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e as Map)))
                  .toList(),
            );
          }
          break;
        case 'error':
          final reason = StateError(
            msg['message'] is String
                ? msg['message'] as String
                : 'Remote operation failed',
          );
          final transferId = msg['transferId'];
          final requestId = msg['id'];
          var handled = false;

          final request = _listRequest;
          if (requestId != null && requestId == _pendingListId &&
              request != null && !request.isCompleted) {
            request.completeError(reason);
            handled = true;
          }
          final pendingBackup = _personalBackupWaiter;
          if (transferId != null && transferId == _personalBackupId &&
              pendingBackup != null && !pendingBackup.isCompleted) {
            pendingBackup.completeError(reason);
            handled = true;
          }
          final waitingResume = _resumeWaiter;
          if (transferId != null && transferId == _resumeWaitTransfer &&
              waitingResume != null && !waitingResume.isCompleted) {
            waitingResume.completeError(reason);
            handled = true;
          }
          final outgoing = _transferComplete;
          if (transferId != null && transferId == _outgoingTransferId &&
              outgoing != null && !outgoing.isCompleted) {
            outgoing.completeError(reason);
            _flowAcks.cancel(reason);
            handled = true;
          }
          final incoming = _incoming;
          if (transferId != null && incoming != null &&
              transferId == incoming.transferId) {
            await incoming.abort();
            _setIncoming(null);
            _discardingTransfer = true;
            if (_pendingJob != null &&
                _pendingJob!['peer'] == peer.remoteKey) {
              await _finishJob();
            }
            _contactsImportDir = null;
            _contactsImportName = null;
            handled = true;
          }
          if (handled || (requestId == null && transferId == null)) {
            // Report current errors, but ignore stale ID-bearing diagnostics.
            // Neither case may abort a different operation.
            _status(tr('Ошибка удалённого устройства: {error}',
                {'error': msg['message']}));
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
          _setIncoming(IncomingTransfer(dir, _status, msg['transferId'] as String));
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
          await _previousIncomingClose;
          final resume = await ResumeStore.open(
            destination, peer.remoteKey, msg['scope'] as String,
          );
          _discardingTransfer = false;
          _setIncoming(IncomingTransfer(
            destination, _status, msg['transferId'] as String,
            resumeStore: resume,
            onProgress: _onFileProgress,
          ));
          _status(tr('Получение файлов'));
          break;
        case 'transfer_keepalive':
          if (msg['transferId'] == _incoming?.transferId) _touchIncoming();
          break;
        case 'file_resume':
          if (msg['transferId'] == _resumeWaitTransfer &&
              msg['path'] == _resumeWaitPath &&
              _resumeWaiter != null && !_resumeWaiter!.isCompleted) {
            _resumeWaiter!.complete(ResumeReply.fromJson(msg));
          }
          break;
        case 'transfer_pause':
        case 'transfer_cancel':
          final current = _incoming;
          final transferId = msg['transferId'];
          final paused = type == 'transfer_pause';
          if (current != null && current.transferId == transferId) {
            await current.abort(preserve: paused);
            _setIncoming(null);
            _discardingTransfer = true;
          }
          if (transferId == _outgoingTransferId) {
            _cancelRequested = true;
            _flowAcks.cancel(StateError(paused ? 'Paused' : 'Cancelled'));
            final waiting = _resumeWaiter;
            if (waiting != null && !waiting.isCompleted) {
              waiting.completeError(StateError(paused ? 'Paused' : 'Cancelled'));
            }
            final result = _transferComplete;
            if (result != null && !result.isCompleted) {
              result.completeError(StateError(paused ? 'Paused' : 'Cancelled'));
            }
          }
          _status(paused ? 'Передача приостановлена' : 'Передача отменена');
          break;
        case 'dir':
        case 'file_begin':
        case 'file_reset':
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
          if (msg['type'] != 'transfer_end') _touchIncoming();
          if (msg['type'] == 'transfer_end') {
            _setIncoming(null);
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
            if (_pendingJob != null && _pendingJob!['mode'] == 'download' &&
                _pendingJob!['peer'] == peer.remoteKey &&
                _pendingJob!['scope'] == incoming.resumeStore?.scope &&
                _pendingJob!['paused'] != true) {
              await _finishJob();
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
          // Forward-compatible unknown commands must not abort a valid
          // transfer or start an endless error-response loop.
          break;
      }
    } catch (e) {
      _status(tr('Ошибка передачи: {error}', {'error': e}));
      if (peer.ready) {
        final response = <String, dynamic>{'type': 'error', 'message': '$e'};
        if (msg['transferId'] is String) {
          response['transferId'] = msg['transferId'];
        }
        if (msg['id'] is int) {
          response['id'] = msg['id'];
        }
        await peer.sendJson(response);
      }
      final incoming = _incoming;
      // Only an error in *this transfer* can discard that transfer's data.
      if (incoming != null && msg['transferId'] == incoming.transferId) {
        await incoming.abort();
        _setIncoming(null);
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
      _touchIncoming();
    } catch (e) {
      _status(tr('Ошибка файловой передачи: {error}', {'error': e}));
      await incoming.abort();
      _setIncoming(null);
      _discardingTransfer = true;
      if (_pendingJob != null && _pendingJob!['peer'] == peer.remoteKey) {
        await _finishJob();
      }
      if (peer.ready) {
        await peer.sendJson({
          'type': 'error',
          'transferId': incoming.transferId,
          'message': '$e',
        });
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
      if (_sending || _incoming != null) {
        throw StateError('Другая передача уже выполняется');
      }
      // No pop-up while recovering from a phone with a broken screen.
      // Sensitive backups are opt-in and individually authorized beforehand.
      if (!canPeerBackup(kind)) {
        throw StateError(
          'На телефоне заранее не разрешено резервное копирование $kind для этого ПК',
        );
      }
      // Claim the outgoing slot BEFORE asynchronous ContactsProvider/SMS
      // export. A second request cannot race the first while it prepares data.
      _sending = true;
      _outgoingTransferId = transferId;
      _transferComplete = Completer<void>();
      _flowAcks.begin(transferId);
      tempFile = await PersonalDataBridge.makeBackup(kind);
      await peer.sendJson({
        'type': 'personal_backup_started',
        'transferId': transferId,
      });
      await streamTransfer(
        walkLocalSelection([tempFile]), peer, _status,
        (chunks) => _flowAcks.waitFor(transferId, chunks),
        transferId: transferId,
        negotiate: (path, size, digest, {bool reset = false}) =>
            _requestResume(
              peer, transferId, path, size, digest, reset: reset,
            ),
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
      await peer.sendJson({
        'type': 'error',
        'transferId': transferId,
        'message': 'Transfer already active',
      });
      return;
    }
    _sending = true;
    _cancelRequested = false;
    _outgoingTransferId = transferId;
    _transferComplete = Completer<void>();
    _flowAcks.begin(transferId);
    try {
      _status(tr('Отправлено {count} объектов', {'count': selected.length}));
      await streamTransfer(
        walkSelection(exportRoot, selected), peer, _status,
        (chunks) => _flowAcks.waitFor(transferId, chunks),
        transferId: transferId,
        negotiate: (path, size, digest, {bool reset = false}) =>
            _requestResume(
              peer, transferId, path, size, digest, reset: reset,
            ),
        onProgress: _onFileProgress,
        cancelled: () => _cancelRequested,
      );
      await _transferComplete!.future.timeout(const Duration(seconds: 45));
      _status(tr('Передача завершена и подтверждена получателем'));
    } catch (e) {
      _status(tr('Ошибка отправки: {error}', {'error': e}));
      if (peer.ready && !_cancelRequested) {
        await peer.sendJson({
          'type': 'error',
          'transferId': transferId,
          'message': '$e',
        });
      }
    } finally {
      _flowAcks.finish();
      _transferComplete = null;
      _outgoingTransferId = null;
      _sending = false;
      if (_pendingJob == null) transferProgress = null;
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
    _pairingTimer?.cancel();
    _incomingIdleTimer?.cancel();
    _retryTimer?.cancel();
    _udp?.close();
    _http?.close(force: true);
    connected?.disconnect();
    _pendingPeer?.disconnect();
    super.dispose();
  }
}
