import 'dart:convert';
import 'dart:io';

import 'package:ferrypane/core/sms_archive.dart';
import 'package:ferrypane/core/localization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SMS archive viewer translates its offline UI independently', () {
    AppLanguage.choice.value = 'en';
    final english = SmsArchive.template('W10=');
    expect(english, contains('SMS archive'));
    expect(english, contains('Search by name, number or text'));
    expect(english, contains('Select a conversation'));
    AppLanguage.choice.value = 'ru';
    final russian = SmsArchive.template('W10=');
    expect(russian, contains('Архив SMS'));
    expect(russian, contains('Поиск по имени, номеру, тексту'));
  });

  test('SMS export produces standalone offline HTML without raw HTML injection',
      () async {
    final folder = await Directory.systemTemp.createTemp('ferrypane_sms_');
    try {
      final source = File('${folder.path}/sms.json');
      final maliciousText =
          '<script>globalThis.attacked = true</script><img src=x onerror=alert(1)>';
      await source.writeAsString(jsonEncode({
        'format': 'ferrypane.sms.v1',
        'exportedAtUtc': '2026-11-08T12:00:00Z',
        'messages': [
          {
            'address': '+79995550123',
            'contactName': '<img src=x onerror=alert(1)>',
            'body': maliciousText,
            'date': 1762600000000,
            'type': 1,
          },
          {
            'address': '+79995550123',
            'body': 'Ответ',
            'date': 1762600030000,
            'type': 2,
          },
        ],
      }));
      final result = await SmsArchive.createViewer(source);
      expect(result, endsWith('.html'));
      final html = await File(result).readAsString();
      expect(html, contains('SMS'));
      expect(html, contains('textContent'));
      expect(html, contains('default-src \'none\''));
      expect(html, isNot(contains(maliciousText)));
      expect(html, isNot(contains('<img src=x onerror=alert(1)>')));
      expect(html, isNot(contains('https://')));
      // We can decode the embedded archive independently of the JavaScript UI.
      final payload = RegExp(r'atob\("([A-Za-z0-9+/=]+)"\)').firstMatch(html);
      expect(payload, isNotNull);
      final decoded = jsonDecode(utf8.decode(base64Decode(payload!.group(1)!)));
      expect(decoded['messages'][0]['body'], maliciousText);
      final another = await SmsArchive.createViewer(source);
      expect(another, isNot(equals(result)));
      expect(await File(result).exists(), isTrue);
    } finally {
      await folder.delete(recursive: true);
    }
  });

  test('refuse non-SMS JSON rather than producing misleading HTML', () async {
    final folder = await Directory.systemTemp.createTemp('ferrypane_sms_bad_');
    try {
      final source = File('${folder.path}/bad.json');
      await source.writeAsString('{"other":"data"}');
      expect(SmsArchive.createViewer(source), throwsFormatException);
    } finally {
      await folder.delete(recursive: true);
    }
  });
}
