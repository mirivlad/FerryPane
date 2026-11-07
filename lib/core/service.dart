import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'files.dart';
import 'flow_acknowledgements.dart';
import 'lan_networks.dart';
import 'native_lan.dart';
import 'secure_peer.dart';
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
  String? _outgoingTransferId;
  int _transferSequence = 0;

  String _newTransferId() => '${DateTime.now().microsecondsSinceEpoch}-${++_transferSequence}';
  int _nextId = 0;
  bool _disposed = false;
  bool _sending = false;
  bool _discardingTransfer = false;
  String exportRoot;
  String lastMessage = 'Ready';
  String connectionStatus = 'Not connected';
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
          _status('Incoming connection rejected: $e');
        }
      });
      _status('Sharing available on port ${_http!.port}');
    } catch (e) {
      _status('Could not listen on port $ferryPort: $e');
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
      _status('Поиск в локальных сетях: $e');
    } finally {
      _networkScanActive = false;
      _notify();
    }
  }

  /// Search every eligible local IPv4 interface; never probe public networks.
  void scanNow() {
    if (_udp == null) {
      _status('Автопоиск недоступен. Подключитесь вручную по IP.');
      return;
    }
    unawaited(_scanAllNetworks());
    _notify();
  }

  Future<void> connect(String ipOrHost) async {
    final host = ipOrHost.trim();
    if (host.isEmpty) throw const FormatException('Enter device IP address');
    connectionStatus = 'Connecting to $host';
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
          _discardingTransfer = false;
          _listRequest?.completeError(StateError('Disconnected: $reason'));
          _listRequest = null;
          _flowAcks.cancel(StateError('Disconnected: $reason'));
          final completed = _transferComplete;
          if (completed != null && !completed.isCompleted) {
            completed.completeError(StateError('Disconnected: $reason'));
          }
          _transferComplete = null;
          _outgoingTransferId = null;
          connected = null;
          connectionStatus = 'Disconnected';
          _status('Disconnected: $reason');
        }
      },
      onReady: () {
        if (connected == peer) {
          connectionStatus = 'Connected: ${peer.remoteName}';
          if (remoteAddress != null && remoteAddress.isNotEmpty) {
            nearby[peer.remoteKey] = NearbyPeer(
              peer.remoteName, remoteAddress, peer.remoteKey, DateTime.now(),
            );
            unawaited(identity.prefs.setString(
              'known.host.${peer.remoteKey}', remoteAddress,
            ));
          }
          _status('Можно передавать файлы');
        }
      },
    );
    connected = peer;
    connectionStatus = 'Pairing…';
    _notify();
    unawaited(peer.run());
  }

  Future<void> forgetAllTrusted() async {
    final trustedKeys = identity.prefs.getKeys()
        .where((key) => key.startsWith('trusted.')).toList();
    for (final key in trustedKeys) {
      await identity.prefs.remove(key);
      await identity.prefs.remove('known.host.${key.substring('trusted.'.length)}');
    }
    nearby.clear();
    await connected?.disconnect();
    _notify();
  }

  Future<void> setExportRoot(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw FileSystemException('Directory not found', path);
    }
    exportRoot = p.normalize(p.absolute(path));
    await identity.prefs.setString('ferrypane.export.root', exportRoot);
    _status('Export root: $exportRoot');
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
      _status('Downloading ${remotePaths.length} selections');
    } catch (_) {
      await _incoming?.abort();
      _incoming = null;
      rethrow;
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
      _status('Uploading ${localPaths.length} selections');
      await streamTransfer(
        walkLocalSelection(localPaths), peer, _status,
        (chunks) => _flowAcks.waitFor(transferId, chunks),
        transferId: transferId,
      );
      await _transferComplete!.future.timeout(const Duration(seconds: 45));
      _status('Загрузка завершена и подтверждена получателем');
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
          final outgoing = _transferComplete;
          if (outgoing != null && !outgoing.isCompleted) {
            outgoing.completeError(StateError(msg['message'] as String));
          }
          if (_incoming != null) {
            await _incoming!.abort();
            _incoming = null;
            _discardingTransfer = true;
          }
          _flowAcks.cancel(StateError(msg['message'] as String));
          final request = _listRequest;
          if (request != null && !request.isCompleted) {
            request.completeError(StateError(msg['message'] as String));
          } else {
            _status('Remote error: ${msg['message']}');
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
        case 'upload_start':
          if (_incoming != null || _sending) throw StateError('Receiver busy');
          final destination = containedPath(exportRoot, msg['dest'] as String);
          await Directory(destination).create(recursive: true);
          _discardingTransfer = false;
          _incoming = IncomingTransfer(destination, _status, msg['transferId'] as String);
          _status('Receiving incoming upload');
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
          await incoming.consume(msg, peer);
          if (msg['type'] == 'transfer_end') {
            _incoming = null;
            await peer.sendJson({
              'type': 'transfer_complete',
              'transferId': incoming.transferId,
            });
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
      _status('Transfer error: $e');
      if (peer.ready) {
        await peer.sendJson({'type': 'error', 'message': '$e'});
      }
      if (_incoming != null) {
        await _incoming!.abort();
        _incoming = null;
        _discardingTransfer = true;
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
      _status('File transfer error: $e');
      await incoming.abort();
      _incoming = null;
      _discardingTransfer = true;
      if (peer.ready) {
        await peer.sendJson({'type': 'error', 'message': '$e'});
      }
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
      _status('Sending ${selected.length} selections');
      await streamTransfer(
        walkSelection(exportRoot, selected), peer, _status,
        (chunks) => _flowAcks.waitFor(transferId, chunks),
        transferId: transferId,
      );
      await _transferComplete!.future.timeout(const Duration(seconds: 45));
      _status('Передача завершена и подтверждена получателем');
    } catch (e) {
      _status('Send failed: $e');
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
