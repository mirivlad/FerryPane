import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ferrypane/core/identity_storage.dart';
import 'package:ferrypane/core/secure_peer.dart';
import 'package:ferrypane/core/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_identity_store.dart';

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 150; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  throw TimeoutException('Condition was not reached');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migrates identity into OS store, preserves trust, removes legacy seed',
      () async {
    final legacy = base64Url.encode(List.generate(32, (i) => i + 1));
    SharedPreferences.setMockInitialValues({
      IdentityKeyMigration.legacyName: legacy,
      'trusted.some-known-peer': 'Trusted PC',
    });
    final secure = MemoryIdentityStore();
    final first = await PeerIdentity.load(secretStore: secure);
    final before = first.publicString;
    final prefs = await SharedPreferences.getInstance();
    expect(secure.value, legacy);
    expect(prefs.containsKey(IdentityKeyMigration.legacyName), isFalse);
    expect(prefs.getString('trusted.some-known-peer'), 'Trusted PC');
    final again = await PeerIdentity.load(secretStore: secure);
    expect(again.publicString, before);
    expect(prefs.containsKey(IdentityKeyMigration.legacyName), isFalse);
  });

  test('never discards legacy key when OS keyring is locked', () async {
    final legacy = base64Url.encode(List.generate(32, (i) => i));
    SharedPreferences.setMockInitialValues({
      IdentityKeyMigration.legacyName: legacy,
    });
    final secure = MemoryIdentityStore()..throwOnWrite = true;
    await expectLater(
      PeerIdentity.load(secretStore: secure),
      throwsA(isA<StateError>()),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(IdentityKeyMigration.legacyName), legacy);
    expect(secure.value, isNull);
  });

  test('unknown secure key loss with existing trust refuses identity reset',
      () async {
    SharedPreferences.setMockInitialValues({
      'trusted.some-known-peer': 'Trusted PC',
    });
    final store = MemoryIdentityStore();
    await expectLater(
      PeerIdentity.load(secretStore: store),
      throwsA(isA<StateError>()),
    );
    expect(store.value, isNull);
  });

  test('conflicting OS and legacy seeds fail closed', () async {
    final legacy = base64Url.encode(List.filled(32, 11));
    final secureSeed = base64Url.encode(List.filled(32, 22));
    SharedPreferences.setMockInitialValues({
      IdentityKeyMigration.legacyName: legacy,
    });
    final store = MemoryIdentityStore()..value = secureSeed;
    await expectLater(
      PeerIdentity.load(secretStore: store),
      throwsA(isA<StateError>()),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(IdentityKeyMigration.legacyName), legacy);
    expect(store.value, secureSeed);
  });

  test('reject non-local addresses and public IP destinations', () {
    expect(FerryService.isAllowedSource('10.0.1.4'), isTrue);
    expect(FerryService.isAllowedSource('192.168.1.5'), isTrue);
    expect(FerryService.isAllowedSource('127.0.0.1'), isTrue);
    expect(FerryService.isAllowedSource('8.8.8.8'), isFalse);
    expect(FerryService.isAllowedSource('0.0.0.0'), isFalse);
    expect(FerryService.isAllowedSource('localhost'), isFalse);
  });

  test('unapproved socket cannot disconnect existing authenticated session',
      () async {
    SharedPreferences.setMockInitialValues({});
    final aliceIdentity = await PeerIdentity.load(
      secretStore: MemoryIdentityStore(),
    );
    SharedPreferences.setMockInitialValues({});
    final bobIdentity = await PeerIdentity.load(
      secretStore: MemoryIdentityStore(),
    );
    SharedPreferences.setMockInitialValues({});
    final eveIdentity = await PeerIdentity.load(
      secretStore: MemoryIdentityStore(),
    );
    final dir = await Directory.systemTemp.createTemp('ferrypane_security_');
    var bobPrompts = 0;
    final alice = FerryService(
      aliceIdentity, (_, __, ___) async => true, dir.path,
      listenPort: 0, enableDiscovery: false,
    );
    final bob = FerryService(
      bobIdentity, (_, __, ___) async {
        bobPrompts++;
        return true;
      }, dir.path,
      listenPort: 0, enableDiscovery: false,
    );
    final eve = FerryService(
      eveIdentity, (_, __, ___) async => true, dir.path,
      listenPort: 0, enableDiscovery: false,
    );
    try {
      await alice.start();
      await bob.start();
      await eve.start();

      // Pairing window is closed by default: even a correct client cannot
      // make the receiver display a pairing dialog.
      await eve.connect('ws://127.0.0.1:${bob.boundPort}');
      await until(() => eve.lastMessage.contains('Подключение отклонено') ||
          eve.lastMessage.contains('Connection rejected'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(bobPrompts, 0);
      expect(bob.connected, isNull);

      bob.setPairingOpen(true);
      await alice.connect('ws://127.0.0.1:${bob.boundPort}');
      await until(() => alice.connected?.ready == true &&
          bob.connected?.ready == true);
      expect(bobPrompts, 1);
      expect(bob.pairingOpen, isFalse);

      // Another incoming socket (whether honest or adversarial) cannot
      // replace an active session, not even momentarily.
      // Raw TCP avoids flutter_test's HttpClient interception (which returns
      // a synthetic HTTP 400 for all ordinary HttpClient requests).
      final probe = await Socket.connect('127.0.0.1', bob.boundPort!);
      probe.write('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          'Connection: close\r\n\r\n');
      final responseBytes = await probe.first.timeout(
        const Duration(seconds: 5),
      );
      final statusLine = utf8.decode(responseBytes).split('\r\n').first;
      expect(statusLine, contains('409'));
      probe.destroy();
      final browser = await Socket.connect('127.0.0.1', bob.boundPort!);
      browser.write('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          'Origin: https://untrusted.example\r\n'
          'Connection: close\r\n\r\n');
      final browserResponse = await browser.first.timeout(
        const Duration(seconds: 5),
      );
      expect(utf8.decode(browserResponse).split('\r\n').first,
          contains('403'));
      browser.destroy();
      expect(alice.connected?.ready, isTrue);
      expect(bob.connected?.ready, isTrue);
      expect(bob.connected?.remoteKey, aliceIdentity.publicString);
      expect(bobPrompts, 1);

      // All missing grants deny, including when profiles are incomplete.
      expect(bob.peerCanRead, isTrue);
      expect(bob.peerCanManage, isFalse);
      await bob.identity.prefs.remove(
          'access.read.' + aliceIdentity.publicString);
      expect(bob.peerCanRead, isFalse);
      await bob.identity.prefs.remove(
          'access.write.' + aliceIdentity.publicString);
      expect(bob.peerCanWrite, isFalse);
      await bob.setPeerAccess(read: true, write: false);
      expect(bob.peerCanRead, isTrue);
      expect(bob.peerCanWrite, isFalse);
      await bob.setPeerAccess(read: true, write: true);
      expect(bob.peerCanWrite, isTrue);
      await bob.setPeerAccess(read: false, write: true);
      expect(bob.peerCanRead, isFalse);
      await bob.setPeerAccess(read: true, write: false);
      expect(bob.peerCanRead, isTrue);
      expect(bob.peerCanWrite, isFalse);
    } finally {
      alice.dispose();
      bob.dispose();
      eve.dispose();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
