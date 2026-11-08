import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as digest;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

typedef PairApproval = Future<bool> Function(String peerName, String code, String identity);
typedef JsonHandler = Future<void> Function(Map<String, dynamic> command);
typedef ChunkHandler = Future<void> Function(Uint8List bytes);

final _rng = Random.secure();

Uint8List randomBytes(int count) =>
    Uint8List.fromList(List.generate(count, (_) => _rng.nextInt(256)));

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> fromB64(String encoded) => base64Url.decode(base64Url.normalize(encoded));

class PeerIdentity {
  final SharedPreferences prefs;
  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;
  final String systemName;

  PeerIdentity._(this.prefs, this.keyPair, this.publicKey, this.systemName);

  static Future<PeerIdentity> load() async {
    final prefs = await SharedPreferences.getInstance();
    var privateSeed = prefs.getString('ferrypane.identity.seed');
    if (privateSeed == null) {
      privateSeed = b64(randomBytes(32));
      await prefs.setString('ferrypane.identity.seed', privateSeed);
    }
    final pair = await X25519().newKeyPairFromSeed(fromB64(privateSeed));
    var deviceName = Platform.localHostname;
    if (Platform.isWindows) {
      deviceName = Platform.environment['COMPUTERNAME'] ?? deviceName;
    } else if (Platform.isLinux) {
      deviceName = Platform.environment['HOSTNAME'] ?? deviceName;
    } else if (Platform.isAndroid) {
      try {
        deviceName = await const MethodChannel('ferrypane/device')
                .invokeMethod<String>('deviceModel') ??
            deviceName;
      } catch (_) {
        deviceName = 'Android';
      }
    }
    if (deviceName.trim().isEmpty || deviceName.toLowerCase() == 'localhost') {
      deviceName = Platform.isAndroid ? 'Android' : 'FerryPane PC';
    }
    return PeerIdentity._(prefs, pair, await pair.extractPublicKey(), deviceName);
  }

  String get publicString => b64(publicKey.bytes);

  bool trusts(String remoteKey) => prefs.getString('trusted.$remoteKey') != null;

  Future<void> trust(String remoteKey, String name) =>
      prefs.setString('trusted.$remoteKey', name);

  Future<void> forget(String remoteKey) => prefs.remove('trusted.$remoteKey');

  String get displayName {
    final configured = prefs.getString('ferrypane.device.name');
    if (configured != null && configured.trim().isNotEmpty) return configured;
    return systemName;
  }

  Future<void> rename(String value) =>
      prefs.setString('ferrypane.device.name', value);
}

class SecurePeer {
  final WebSocket socket;
  final PeerIdentity identity;
  final bool initiator;
  final PairApproval approve;
  final JsonHandler onJson;
  final ChunkHandler onChunk;
  final void Function(String) onDisconnected;
  final void Function() onReady;

  late String remoteName;
  String remotePlatform = 'unknown';
  late String remoteKey;
  SecretKey? _transmitKey;
  SecretKey? _receiveKey;
  int _sendCounter = 0;
  int _recvCounter = 0;
  Future<void> _sendTail = Future<void>.value();
  final _cipher = AesGcm.with256bits();
  bool ready = false;
  String? _disconnectReason;

  SecurePeer({
    required this.socket,
    required this.identity,
    required this.initiator,
    required this.approve,
    required this.onJson,
    required this.onChunk,
    required this.onDisconnected,
    required this.onReady,
  });

  Future<void> run() async {
    final iterator = StreamIterator<dynamic>(socket);
    try {
      final ephemeral = await X25519().newKeyPair();
      final nonce = randomBytes(16);
      final ownHello = <String, dynamic>{
        'type': 'hello',
        'version': 2,
        'name': identity.displayName,
        'platform': Platform.operatingSystem,
        'identity': identity.publicString,
        'ephemeral': b64((await ephemeral.extractPublicKey()).bytes),
        'nonce': b64(nonce),
      };

      Map<String, dynamic> otherHello;
      if (initiator) {
        socket.add(jsonEncode(ownHello));
        if (!await iterator.moveNext()) throw const SocketException('No handshake');
        otherHello = Map<String, dynamic>.from(jsonDecode(iterator.current as String) as Map);
      } else {
        if (!await iterator.moveNext()) throw const SocketException('No handshake');
        otherHello = Map<String, dynamic>.from(jsonDecode(iterator.current as String) as Map);
        socket.add(jsonEncode(ownHello));
      }

      if (otherHello['type'] != 'hello' || otherHello['version'] != 2) {
        throw const FormatException('Несовместимая версия протокола. Обновите FerryPane на обоих устройствах.');
      }
      remoteName = otherHello['name'] as String;
      remotePlatform = otherHello['platform'] is String
          ? otherHello['platform'] as String
          : 'unknown';
      remoteKey = otherHello['identity'] as String;
      final remoteIdentity = SimplePublicKey(fromB64(remoteKey), type: KeyPairType.x25519);
      final remoteEphemeral = SimplePublicKey(
        fromB64(otherHello['ephemeral'] as String),
        type: KeyPairType.x25519,
      );
      final staticSecret = await X25519().sharedSecretKey(
        keyPair: identity.keyPair,
        remotePublicKey: remoteIdentity,
      );
      final ephSecret = await X25519().sharedSecretKey(
        keyPair: ephemeral,
        remotePublicKey: remoteEphemeral,
      );
      final otherNonce = fromB64(otherHello['nonce'] as String);
      final salt = initiator ? [...nonce, ...otherNonce] : [...otherNonce, ...nonce];

      final material = <int>[
        ...await staticSecret.extractBytes(),
        ...await ephSecret.extractBytes(),
      ];
      final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 64).deriveKey(
        secretKey: SecretKey(material),
        nonce: salt,
        info: utf8.encode('FerryPane session v1'),
      );
      final keys = await derived.extractBytes();
      _transmitKey = SecretKey(initiator ? keys.sublist(0, 32) : keys.sublist(32));
      _receiveKey = SecretKey(initiator ? keys.sublist(32) : keys.sublist(0, 32));

      if (!identity.trusts(remoteKey)) {
        // Short authentication string (SAS) must match on BOTH screens.
        final sasDigest = digest.sha256.convert([...keys, ...salt]).bytes;
        final sas = ((sasDigest[0] << 16) | (sasDigest[1] << 8) | sasDigest[2]) %
            1000000;
        final accepted = await approve(remoteName, sas.toString().padLeft(6, '0'), remoteKey);
        if (!accepted) throw const SocketException('Pairing was rejected');
        await identity.trust(remoteKey, remoteName);
      }

      await sendJson({'type': 'ready'});
      if (!await iterator.moveNext()) throw const SocketException('Peer closed before ready');
      final receivedReady = await _decrypt(Uint8List.fromList(iterator.current as List<int>));
      final peerReady = jsonDecode(utf8.decode(receivedReady.sublist(1))) as Map<String, dynamic>;
      if (receivedReady.first != 0 || peerReady['type'] != 'ready') {
        throw const FormatException('Unexpected handshake confirmation');
      }
      ready = true;
      onReady();

      while (await iterator.moveNext()) {
        final raw = iterator.current;
        if (raw is! List<int>) throw const FormatException('Unexpected unencrypted message');
        final clear = await _decrypt(Uint8List.fromList(raw));
        if (clear.isEmpty) throw const FormatException('Empty secure packet');
        if (clear.first == 0) {
          final message = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(clear.sublist(1))) as Map,
          );
          await onJson(message);
        } else if (clear.first == 1) {
          await onChunk(Uint8List.fromList(clear.sublist(1)));
        } else {
          throw const FormatException('Unknown encrypted frame type');
        }
      }
    } catch (e) {
      _disconnectReason = '$e';
    } finally {
      ready = false;
      try {
        await iterator.cancel();
      } finally {
        await socket.close();
        onDisconnected(_disconnectReason ?? 'Peer closed the connection');
      }
    }
  }

  Future<Uint8List> _decrypt(Uint8List frame) async {
    if (frame.length < 28) throw const FormatException('Truncated AEAD frame');
    final nonce = frame.sublist(0, 12);
    final seq = ByteData.sublistView(nonce).getUint64(4, Endian.big);
    if (seq != _recvCounter++) throw const FormatException('Replay or reordered packet');
    final box = SecretBox.fromConcatenation(
      frame,
      nonceLength: 12,
      macLength: 16,
    );
    return Uint8List.fromList(await _cipher.decrypt(box, secretKey: _receiveKey!));
  }

  Future<void> sendJson(Map<String, dynamic> message) =>
      _enqueue(Uint8List.fromList([0, ...utf8.encode(jsonEncode(message))]));

  Future<void> sendChunk(Uint8List bytes) =>
      _enqueue(Uint8List.fromList([1, ...bytes]));

  Future<void> _enqueue(Uint8List clear) {
    final previous = _sendTail;
    final completer = Completer<void>();
    _sendTail = completer.future;
    return () async {
      try {
        await previous;
        final nonce = Uint8List(12);
        ByteData.sublistView(nonce).setUint64(4, _sendCounter++, Endian.big);
        final box = await _cipher.encrypt(clear, secretKey: _transmitKey!, nonce: nonce);
        socket.add(box.concatenation());
        completer.complete();
      } catch (e, s) {
        completer.completeError(e, s);
        rethrow;
      }
    }();
  }

  Future<void> disconnect() => socket.close();
}
