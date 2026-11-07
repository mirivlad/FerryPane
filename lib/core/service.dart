import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'files.dart';
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
  Completer<void>? _flowAck;
  int _nextId = 0;
  bool _sending = false;
  String exportRoot;
  String lastMessage = 'Ready';
  String connectionStatus = 'Not connected';
  bool broadcasting = false;
  final Map<String, NearbyPeer> nearby = {};

  FerryService(this.identity, this.onPairing, this.exportRoot);

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
      _http = await HttpServer.bind(InternetAddress.anyIPv4, ferryPort, shared: true);
      broadcasting = true;
      _http!.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        try {
          final socket = await WebSocketTransformer.upgrade(request);
          _attach(socket, false);
        } catch (e) {
          _status('Incoming connection rejected: $e');
        }
      });
      _status('Sharing available on port $ferryPort');
    } catch (e) {
      _status('Could not listen on port $ferryPort: $e');
    }
    await _refreshAddresses();
    await _startDiscovery();
  }

  Future<void> _refreshAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      _ipAddresses = interfaces.expand((i) => i.addresses.map((a) => a.address)).toList();
      notifyListeners();
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
        final packet = _udp!.receive();
        if (packet == null) return;
        final text = utf8.decode(packet.data, allowMalformed: true);
        if (text == 'FERRYPANE_DISCOVER_V1') {
          _announce(packet.address, packet.port);
        } else {
          try {
            final data = jsonDecode(text) as Map<String, dynamic>;
            if (data['type'] != 'ferrypane_peer' ||
                data['identity'] == identity.publicString) return;
            nearby[data['identity'] as String] = NearbyPeer(
              data['name'] as String,
              packet.address.address,
              data['identity'] as String,
              DateTime.now(),
            );
            notifyListeners();
          } catch (_) {}
        }
      });
      _beacon = Timer.periodic(const Duration(seconds: 3), (_) {
        _udp?.send(
          utf8.encode('FERRYPANE_DISCOVER_V1'),
          InternetAddress('255.255.255.255'),
          discoveryPort,
        );
        _refreshAddresses();
        nearby.removeWhere(
          (_, peer) => DateTime.now().difference(peer.seen).inSeconds > 20,
        );
      });
      _udp!.send(
        utf8.encode('FERRYPANE_DISCOVER_V1'),
        InternetAddress('255.255.255.255'),
        discoveryPort,
      );
    } catch (e) {
      _status('Auto-discovery unavailable; manual IP still works: $e');
    }
  }

  void _announce(InternetAddress to, int port) {
    _udp?.send(
      utf8.encode(jsonEncode({
        'type': 'ferrypane_peer',
        'name': name,
        'identity': publicIdentity,
        'port': ferryPort,
      })),
      to,
      port,
    );
  }

  Future<void> connect(String ipOrHost) async {
    final host = ipOrHost.trim();
    if (host.isEmpty) throw const FormatException('Enter device IP address');
    connectionStatus = 'Connecting to $host';
    notifyListeners();
    final uri = Uri.parse(host.contains('://') ? host : 'ws://$host:$ferryPort');
    final socket = await WebSocket.connect(uri.toString());
    _attach(socket, true);
  }

  void _attach(WebSocket socket, bool initiator) {
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
          _listRequest?.completeError(StateError('Disconnected: $reason'));
          _listRequest = null;
          _flowAck?.completeError(StateError('Disconnected'));
          _flowAck = null;
          connected = null;
          connectionStatus = 'Disconnected';
          _status('Disconnected: $reason');
        }
      },
      onReady: () {
        if (connected == peer) {
          connectionStatus = 'Connected: ${peer.remoteName}';
          _status(connectionStatus);
        }
      },
    );
    connected = peer;
    connectionStatus = 'Pairing…';
    notifyListeners();
    unawaited(peer.run());
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
    _incoming = IncomingTransfer(localDirectory, _status);
    await peer.sendJson({
      'type': 'download',
      'paths': remotePaths.map(sanitizeRelative).toList(),
    });
    _status('Downloading ${remotePaths.length} selections');
  }

  Future<void> upload(List<String> localPaths, String remoteDirectory) async {
    final peer = connected;
    if (peer == null || !peer.ready) throw StateError('No connected device');
    if (_sending || _incoming != null) throw StateError('Another transfer is in progress');
    _sending = true;
    try {
    await peer.sendJson({
      'type': 'upload_start',
      'dest': sanitizeRelative(remoteDirectory),
    });
    _status('Uploading ${localPaths.length} selections');
    await streamTransfer(walkLocalSelection(localPaths), peer, _status, _waitForFlowAck);
    } finally { _sending = false; notifyListeners(); }
  }

  Future<void> _waitForFlowAck() async {
    final ack = Completer<void>();
    _flowAck = ack;
    try {
      await ack.future.timeout(const Duration(seconds: 45));
    } finally {
      if (_flowAck == ack) _flowAck = null;
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
          if (_incoming != null) {
            await _incoming!.abort();
            _incoming = null;
          }
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
          unawaited(_sendExport(peer, List<String>.from(msg['paths'] as List)));
          break;
        case 'upload_start':
          if (_incoming != null || _sending) throw StateError('Receiver busy');
          final destination = containedPath(exportRoot, msg['dest'] as String);
          await Directory(destination).create(recursive: true);
          _incoming = IncomingTransfer(destination, _status);
          _status('Receiving incoming upload');
          break;
        case 'dir':
        case 'file_begin':
        case 'file_end':
        case 'transfer_end':
          final incoming = _incoming;
          if (incoming == null) throw const FormatException('Unexpected transfer frame');
          await incoming.consume(msg, peer);
          if (msg['type'] == 'transfer_end') _incoming = null;
          break;
        case 'flow_ack':
          final waiter = _flowAck;
          if (waiter != null && !waiter.isCompleted) waiter.complete();
          break;
        default:
          throw FormatException('Unknown operation ${msg['type']}');
      }
    } catch (e) {
      _status('Transfer error: $e');
      await peer.sendJson({'type': 'error', 'message': '$e'});
      await _incoming?.abort();
      _incoming = null;
    }
  }

  Future<void> _onChunk(SecurePeer peer, Uint8List bytes) async {
    final incoming = _incoming;
    if (incoming == null) throw const FormatException('Unexpected data frame');
    await incoming.consumeChunk(bytes, peer);
  }

  Future<void> _sendExport(SecurePeer peer, List<String> selected) async {
    if (_sending || _incoming != null) {
      await peer.sendJson({'type': 'error', 'message': 'Transfer already active'});
      return;
    }
    _sending = true;
    try {
      _status('Sending ${selected.length} selections');
      await streamTransfer(walkSelection(exportRoot, selected), peer, _status, _waitForFlowAck);
    } catch (e) {
      _status('Send failed: $e');
      await peer.sendJson({'type': 'error', 'message': '$e'});
    } finally { _sending = false; notifyListeners(); }
  }

  void _status(String text) {
    lastMessage = text;
    notifyListeners();
  }

  @override
  void dispose() {
    _beacon?.cancel();
    _udp?.close();
    _http?.close(force: true);
    connected?.disconnect();
    super.dispose();
  }
}
