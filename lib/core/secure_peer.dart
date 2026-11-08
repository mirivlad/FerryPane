import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as digest;
import 'package:shared_preferences/shared_preferences.dart';

import 'identity_storage.dart';
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

  static Future<PeerIdentity> load({
    IdentitySecretStore secretStore = const SystemIdentitySecretStore(),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final privateSeed = await IdentityKeyMigration.loadOrMigrate(
      prefs,
      secretStore,
      newSeed: () => b64(randomBytes(32)),
    );
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

  Future<void> trust(String remoteKey, String name) async {
    // Existing users keep their original permissions when upgrading.
    // Freshly paired devices get read-only access by default; writable
    // access must be explicitly enabled by the receiving device's owner.
    if (!trusts(remoteKey)) {
      if (!await prefs.setBool('access.write.$remoteKey', false)) {
        throw StateError('Could not save new device access permissions');
      }
    }
    if (!await prefs.setString('trusted.$remoteKey', name)) {
      throw StateError('Could not persist device trust');
    }
  }

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
  final bool Function(String remoteKey)? allowHello;
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

  static const maxHelloBytes = 8192;
  static const maxEncryptedCommandBytes = 1024 * 1024;
  static const maxEncryptedChunkBytes = 256 * 1024;
  static const handshakeTimeout = Duration(seconds: 12);
  static const approvalTimeout = Duration(minutes: 2);


  SecurePeer({
    required this.socket,
    required this.identity,
    required this.initiator,
    required this.approve,
    this.allowHello,
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
        'version': 5,
        'name': identity.displayName,
        'platform': Platform.operatingSystem,
        'identity': identity.publicString,
        'ephemeral': b64((await ephemeral.extractPublicKey()).bytes),
        'nonce': b64(nonce),
      };

      Map<String, dynamic> otherHello;
      if (initiator) {
        socket.add(jsonEncode(ownHello));
        if (!await iterator.moveNext().timeout(handshakeTimeout)) {
          throw const SocketException('No handshake');
        }
        otherHello = _readHello(iterator.current);
      } else {
        if (!await iterator.moveNext().timeout(handshakeTimeout)) {
          throw const SocketException('No handshake');
        }
        otherHello = _readHello(iterator.current);
        socket.add(jsonEncode(ownHello));
      }

      if (otherHello['type'] != 'hello' || otherHello['version'] != 5) {
        throw const FormatException('Несовместимая версия протокола. Обновите FerryPane на обоих устройствах.');
      }
      remoteName = otherHello['name'] as String;
      if (remoteName.isEmpty || remoteName.length > 120) {
        throw const FormatException('Invalid peer name');
      }
      remotePlatform = otherHello['platform'] is String
          ? otherHello['platform'] as String
          : 'unknown';
      remoteKey = otherHello['identity'] as String;
      if (fromB64(remoteKey).length != 32 ||
          fromB64(otherHello['ephemeral'] as String).length != 32 ||
          fromB64(otherHello['nonce'] as String).length != 16) {
        throw const FormatException('Invalid peer cryptographic hello');
      }
      if (allowHello != null && !allowHello!(remoteKey)) {
        throw const SocketException('Pairing is closed for unknown devices');
      }
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
      // Bind the full role-ordered, versioned peer hellos to the session
      // derivation. A man-in-the-middle cannot substitute hostnames, identities,
      // ephemeral public keys or protocol capabilities without changing
      // authenticated session keys and the six-digit SAS.
      final transcript = initiator
          ? [...utf8.encode(jsonEncode(ownHello)), ...utf8.encode(jsonEncode(otherHello))]
          : [...utf8.encode(jsonEncode(otherHello)), ...utf8.encode(jsonEncode(ownHello))];
      final transcriptHash = digest.sha256.convert(transcript).bytes;

      final material = <int>[
        ...await staticSecret.extractBytes(),
        ...await ephSecret.extractBytes(),
      ];
      final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 64).deriveKey(
        secretKey: SecretKey(material),
        nonce: salt,
        info: [...utf8.encode('FerryPane session v5'), ...transcriptHash],
      );
      final keys = await derived.extractBytes();
      _transmitKey = SecretKey(initiator ? keys.sublist(0, 32) : keys.sublist(32));
      _receiveKey = SecretKey(initiator ? keys.sublist(32) : keys.sublist(0, 32));

      var newlyAccepted = false;
      if (!identity.trusts(remoteKey)) {
        // Short authentication string (SAS) must match on BOTH screens.
        final sasDigest = digest.sha256.convert([...keys, ...transcriptHash]).bytes;
        final sas = ((sasDigest[0] << 16) | (sasDigest[1] << 8) | sasDigest[2]) %
            1000000;
        final accepted = await approve(
          remoteName, sas.toString().padLeft(6, '0'), remoteKey,
        ).timeout(approvalTimeout, onTimeout: () => false);
        if (!accepted) throw const SocketException('Pairing was rejected');
        newlyAccepted = true;
      }

      await sendJson({'type': 'ready'});
      if (!await iterator.moveNext().timeout(handshakeTimeout)) {
        throw const SocketException('Peer closed before ready');
      }
      if (iterator.current is! List<int> ||
          (iterator.current as List<int>).length > maxHelloBytes) {
        throw const FormatException('Invalid ready frame');
      }
      final receivedReady = await _decrypt(Uint8List.fromList(iterator.current as List<int>));
      final peerReady = jsonDecode(utf8.decode(receivedReady.sublist(1))) as Map<String, dynamic>;
      if (receivedReady.first != 0 || peerReady['type'] != 'ready') {
        throw const FormatException('Unexpected handshake confirmation');
      }
      // Persist trust only after the peer proved possession of the complete
      // secret via an authenticated ready frame. An aborted handshake does not
      // leave a trusted entry behind.
      if (newlyAccepted) await identity.trust(remoteKey, remoteName);
      ready = true;
      onReady();

      while (await iterator.moveNext()) {
        final raw = iterator.current;
        if (raw is! List<int>) {
          throw const FormatException('Unexpected unencrypted message');
        }
        if (raw.length > maxEncryptedCommandBytes + 29) {
          throw const FormatException('Incoming encrypted packet too large');
        }
        final clear = await _decrypt(Uint8List.fromList(raw));
        if (clear.isEmpty) throw const FormatException('Empty secure packet');
        if (clear.first == 0) {
          if (clear.length > maxEncryptedCommandBytes) {
            throw const FormatException('Command too large');
          }
          final message = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(clear.sublist(1))) as Map,
          );
          await onJson(message);
        } else if (clear.first == 1) {
          if (clear.length > maxEncryptedChunkBytes) {
            throw const FormatException('Transfer chunk too large');
          }
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

  Map<String, dynamic> _readHello(dynamic frame) {
    if (frame is! String || frame.length > maxHelloBytes) {
      throw const FormatException('Invalid handshake message size or type');
    }
    final object = jsonDecode(frame);
    if (object is! Map) throw const FormatException('Invalid peer hello');
    return Map<String, dynamic>.from(object);
  }

  Future<Uint8List> _decrypt(Uint8List frame) async {
    if (frame.length < 28) throw const FormatException('Truncated AEAD frame');
    if (frame.length > maxEncryptedCommandBytes + 29) {
      throw const FormatException('Encrypted frame exceeds protocol limit');
    }
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
    // Check before encryption rather than asking the recipient to reject a
    // message that our own sender should never have emitted.
    if (clear.isEmpty ||
        clear.length > (clear.first == 1
            ? maxEncryptedChunkBytes
            : maxEncryptedCommandBytes)) {
      return Future<void>.error(
        const FormatException('Outgoing message exceeds protocol limit'),
      );
    }
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
        // _sendTail is an internal serialization barrier with no error
        // listener of its own. Propagate the error to the actual caller,
        // but never poison that barrier or generate an uncaught secondary
        // asynchronous error when a socket closes during transfer.
        if (!completer.isCompleted) completer.complete();
        Error.throwWithStackTrace(e, s);
      }
    }();
  }

  Future<void> disconnect() => socket.close();
}
