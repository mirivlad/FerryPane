import 'package:ferrypane/core/localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Russian and English localization have stable placeholders', () async {
    SharedPreferences.setMockInitialValues({});
    await AppLanguage.initialize();
    await AppLanguage.set('ru');
    expect(tr('Выделить всё'), 'Выделить всё');
    expect(tr('Из правой в левую ({count})', {'count': 42}),
        'Из правой в левую (42)');
    await AppLanguage.set('en');
    expect(tr('Выделить всё'), 'Select all');
    expect(tr('Из правой в левую ({count})', {'count': 42}),
        'Right to left (42)');
    expect(tr('Бэкап SMS'), 'Back up SMS');
    expect(tr('Резервное копирование контактов'), 'Contacts backup');
    expect(tr('Не удалось открыть папку: {error}', {'error': 'denied'}),
        'Could not open folder: denied');
  });

  test('language selection persists and invalid values are sanitized', () async {
    SharedPreferences.setMockInitialValues({});
    await AppLanguage.initialize();
    await AppLanguage.set('en');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ferrypane.language'), 'en');
    AppLanguage.choice.value = 'ru';
    await AppLanguage.initialize();
    expect(AppLanguage.choice.value, 'en');
    expect(() => AppLanguage.set('de'), throwsArgumentError);
    await AppLanguage.set('ru');
  });
}
