import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'files.dart';
import 'flow_acknowledgements.dart';
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
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      _ipAddresses = interfaces.expand((i) => i.addresses.map((a) => a.address)).toList();
      _notify();
    } catch (_) {}
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
            _announce(sender, port); // compatibility with preview.1
            continue;
          }
          try {
            final data = jsonDecode(text) as Map<String, dynamic>;
            final type = data['type'];
            if (type != 'ferrypane_probe' && type != 'ferrypane_peer') continue;
            final peerId = data['identity'];
            final peerName = data['name'];
            if (peerId is! String || peerId.isEmpty ||
                peerName is! String || peerName.trim().isEmpty ||
                peerId == publicIdentity) {
              continue;
            }
            nearby[peerId] = NearbyPeer(
              peerName,
              sender.address,
              peerId,
              DateTime.now(),
            );
            _notify();
            // The probe itself carries the full identity, so the receiver
            // learns about its sender even if the response is blocked by
            // one device's firewall or asymmetric Wi-Fi broadcasts.
            if (type == 'ferrypane_probe') _announce(sender, port);
          } catch (_) {
            // Ignore unrelated LAN broadcasts.
          }
        }
      });
      _beacon = Timer.periodic(const Duration(seconds: 3), (_) {
        scanNow();
        _refreshAddresses();
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

  void _announce(InternetAddress to, int port) {
    _udp?.send(utf8.encode(jsonEncode(_discoveryMessage('ferrypane_peer'))), to, port);
  }

  /// Both requests and announcements carry our identity. This prevents
  /// asymmetric discovery on networks filtering unicast replies.
  void scanNow() {
    final udp = _udp;
    if (udp == null) {
      _status('Автопоиск недоступен. Подключитесь вручную по IP.');
      return;
    }
    final destination = InternetAddress('255.255.255.255');
    udp.send(
      utf8.encode(jsonEncode(_discoveryMessage('ferrypane_probe'))),
      destination,
      discoveryPort,
    );
    udp.send(
      utf8.encode(jsonEncode(_discoveryMessage('ferrypane_peer'))),
      destination,
      discoveryPort,
    );
    _notify();
  }

  Future<void> connect(String ipOrHost) async {
    final host = ipOrHost.trim();
    if (host.isEmpty) throw const FormatException('Enter device IP address');
    connectionStatus = 'Connecting to $host';
    _notify();
    final uri = Uri.parse(host.contains('://') ? host : 'ws://$host:$ferryPort');
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
