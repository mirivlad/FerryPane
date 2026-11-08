import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A lightweight first-party translation catalog, shared by Android and PC.
/// All user-facing GUI keys are in Russian; English values are kept here.
/// Unknown keys remain readable and are never silently discarded.
class AppLanguage {
  static const _preferenceKey = 'ferrypane.language';
  static final ValueNotifier<String> choice = ValueNotifier<String>('system');

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_preferenceKey) ?? 'system';
    choice.value = ['system', 'ru', 'en'].contains(stored) ? stored : 'system';
  }

  static Future<void> set(String language) async {
    if (!['system', 'ru', 'en'].contains(language)) {
      throw ArgumentError.value(language);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_preferenceKey, language);
    choice.value = language;
  }

  static String get active => choice.value == 'system'
      ? (ui.PlatformDispatcher.instance.locale.languageCode == 'ru' ? 'ru' : 'en')
      : choice.value;

  static String tr(String russian, [Map<String, Object?> values = const {}]) {
    var text = active == 'ru' ? russian : (_en[russian] ?? russian);
    for (final entry in values.entries) {
      text = text.replaceAll('{'+entry.key+'}', entry.value?.toString() ?? '');
    }
    return text;
  }

  static const Map<String, String> _en = {
    'Система': 'System',
    'Русский': 'Russian',
    'Английский': 'English',
    'Язык интерфейса': 'Interface language',
    'Запуск…': 'Starting…',
    'Готово': 'Ready',
    'Ошибка запуска: {error}': 'Startup error: {error}',
    'Подтвердить соединение': 'Confirm connection',
    'Устройство: {name}': 'Device: {name}',
    'Сравните этот код на ОБОИХ устройствах:':
        'Compare this code on BOTH devices:',
    'Разрешайте подключение только если коды совпадают.':
        'Approve connection only if the codes match.',
    'Подтверждённое устройство сможет читать и записывать файлы в общем каталоге этого устройства. Доступ к контактам и SMS включается отдельно в настройках Android.':
        'The approved device can browse and transfer files within this device’s shared folder. Grant contacts and SMS access separately in Android settings.',
    'Ключ: {key}…': 'Key: {key}…',
    'Отклонить': 'Reject',
    'Коды совпадают': 'Codes match',
    'Восстановить контакты в FerryPane?': 'Restore contacts in FerryPane?',
    'Источник: {name}': 'Source: {name}',
    'Файл: {file}': 'File: {file}',
    'Всего записей: {count}': 'Total entries: {count}',
    'Новых контактов: {count}': 'New contacts: {count}',
    'Совпадают по телефону или email: {count}':
        'Matching phone or email: {count}',
    'FerryPane добавит недостающие контакты и телефоны/email к совпадающим. Существующие данные не удаляются. Фото и редкие поля vCard пока не импортируются.':
        'FerryPane will add missing contacts and phone/email fields to matches. Existing data will not be deleted. Photos and uncommon vCard fields are not imported yet.',
    'FerryPane не удаляет существующие контакты. Создание записей изменит адресную книгу этого телефона.':
        'FerryPane never removes existing contacts. Adding entries changes this phone’s address book.',
    'Отмена': 'Cancel',
    'Добавить и объединить': 'Add and merge',
    'Android не выдал разрешение на чтение {kind}. Для SMS действуют особые ограничения Android.':
        'Android did not grant access to {kind}. Additional Android restrictions apply to SMS.',
    'контактов': 'contacts',
    'Не удалось изменить разрешение: {error}':
        'Could not change permission: {error}',
    'Не удалось получить список дисков Windows':
        'Could not list Windows drives',
    'Выбрать диск': 'Choose drive',
    'Сначала выделите файлы или папки.':
        'Select files or folders first.',
    'Копирование между двумя удалёнными панелями пока не поддерживается.':
        'Copying between two remote panels is not supported yet.',
    'Передача запущена. Прогресс отображается внизу окна.':
        'Transfer started. Progress appears at the bottom.',
    'Ошибка копирования: {error}': 'Copy failed: {error}',
    'Закрыть': 'Close',
    'Не удалось подключиться: {error}':
        'Could not connect: {error}',
    'Подключиться к устройству': 'Connect to device',
    'IP-адрес или имя компьютера': 'IP address or computer name',
    'Подключиться': 'Connect',
    'Подключиться по IP': 'Connect by IP',
    'Доступ к файлам этого устройства':
        'Share files from this device',
    'Сопряжённые устройства могут просматривать, скачивать и загружать файлы внутри выбранного каталога.':
        'Paired devices can browse, download and upload files inside the selected folder.',
    'Имя этого устройства': 'This device’s name',
    'Будет отображаться в списке устройств':
        'Shown in the device list',
    'Общий каталог': 'Shared folder',
    'Папка, доступная с других устройств':
        'Folder accessible to paired devices',
    'Выбрать папку…': 'Choose folder…',
    'Не удалось выбрать папку: {error}':
        'Could not choose folder: {error}',
    'Права доверенного устройства {name}:':
        'Permissions for trusted device {name}:',
    'При включении разрешений этот компьютер сможет получать резервные копии без подтверждений на телефоне, даже если сенсор или дисплей перестанет работать.':
        'Once enabled, this computer can download backups without phone confirmation, even if the touchscreen or display stops working.',
    'Резервное копирование контактов': 'Contacts backup',
    'Резервное копирование SMS': 'SMS backup',
    'Может требовать отдельного доступа Android':
        'May require additional Android permission',
    'Системное разрешение отсутствует':
        'System permission missing',
    'Доступ предоставлен': 'Access granted',
    'Выдать разрешение': 'Grant permission',
    'Проверить разрешения': 'Check permissions',
    'Android отозвал доступ. Включите разрешение повторно.':
        'Android revoked access. Grant permission again.',
    'IP: {addresses}': 'IP: {addresses}',
    'Забыть доверенные устройства': 'Forget trusted devices',
    'Сохранить': 'Save',
    'Все доверенные устройства забыты':
        'All trusted devices forgotten',
    'Имя устройства и общий каталог сохранены':
        'Device name and shared folder saved',
    'Нельзя открыть каталог: {error}': 'Cannot open folder: {error}',
    'Этот компьютер / телефон': 'This computer / phone',
    'Удалённое: {name}': 'Remote: {name}',
    'Удалённое устройство': 'Remote device',
    'Вверх': 'Up',
    'Обновить': 'Refresh',
    'Выбрано: {selected} / {total}': 'Selected: {selected} / {total}',
    'Выделить всё': 'Select all',
    'Снять': 'Clear',
    'Подключите другое устройство': 'Connect another device',
    '{count} объектов': '{count} items',
    'Выберите локальную папку для сохранения резервной копии.':
        'Select a local folder for the backup.',
    'Готово. Сохранено в {folder}: {files}':
        'Saved in {folder}: {files}',
    'Резервная копия сохранена': 'Backup saved',
    'Не удалось создать резервную копию: {error}':
        'Backup failed: {error}',
    'Файл доставлен. На Android подтвердите восстановление в окне FerryPane. Результат появится внизу окна.':
        'File delivered. Confirm contact restoration in FerryPane on Android. The result will appear in the status bar.',
    'Восстановление контактов: {error}':
        'Contact restoration: {error}',
    'Данные телефона:': 'Phone data:',
    'Бэкап контактов': 'Back up contacts',
    'Бэкап SMS': 'Back up SMS',
    'Восстановить контакты': 'Restore contacts',
    'Для просмотра общих папок Android разрешите доступ ко всем файлам в системных настройках.':
        'To browse shared Android folders, grant All files access in system settings.',
    'Разрешить': 'Allow',
    'Панель 1': 'Pane 1',
    'Панель 2': 'Pane 2',
    'Из 2 в 1 ({count})': 'From 2 to 1 ({count})',
    'Из 1 в 2 ({count})': 'From 1 to 2 ({count})',
    'Из правой в левую ({count})': 'Right to left ({count})',
    'Из левой в правую ({count})': 'Left to right ({count})',
    'Повторить поиск устройств': 'Refresh device discovery',
    'Поиск устройств запущен. Если телефон не виден, используйте подключение по IP.':
        'Device discovery started. If your phone is missing, connect by IP.',
    'Настройки доступа и языка': 'Sharing and language settings',
    'Нет найденных устройств': 'No devices found',
    'Устройства в локальной сети': 'Devices on LAN',
    'Сохранённый адрес': 'Saved address',
    'Сканировать устройства': 'Scan devices',
    'Соединение закрыто': 'Disconnected',
    'Сопряжение…': 'Pairing…',
    'Соединение разорвано: {reason}': 'Disconnected: {reason}',
    'Сервис доступен на порту {port}': 'Service available on port {port}',
    'Ошибка открытия порта {port}: {error}': 'Cannot listen on port {port}: {error}',
    'Входящее подключение отклонено: {error}': 'Incoming connection rejected: {error}',
    'Можно передавать файлы': 'You can now transfer files',
    'Автопоиск недоступен. Подключитесь вручную по IP.':
        'Discovery unavailable. Connect manually by IP.',
    'Поиск в локальных сетях: {error}': 'LAN search: {error}',
    'Корневая общая папка: {path}': 'Shared root: {path}',
    'Отправлено {count} объектов': 'Sending {count} selections',
    'Загрузка {count} объектов': 'Downloading {count} selections',
    'Загрузка {count} объектов на устройство': 'Uploading {count} selections',
    'Получение файлов': 'Receiving files',
    'Ошибка удалённого устройства: {error}': 'Remote device error: {error}',
    'Файл контактов передан. Подтвердите импорт на Android.':
        'Contacts sent. Confirm import on Android.',
    'Передача завершена и подтверждена получателем':
        'Transfer completed and confirmed by recipient',
    'Загрузка завершена и подтверждена получателем':
        'Upload completed and confirmed by recipient',
    'Ошибка передачи: {error}': 'Transfer error: {error}',
    'Ошибка отправки: {error}': 'Send failed: {error}',
    'Ошибка файловой передачи: {error}': 'File transfer error: {error}',
    'Получаем адресную книгу из {name}': 'Receiving contacts from {name}',
    'Резервное копирование не выполнено: {error}':
        'Backup failed: {error}',
    'Резервная копия {kind} передана': '{kind} backup transferred',
    'Резервная копия: {error}': 'Backup: {error}',
    'Резервная копия сохранена: {files}': 'Backup saved: {files}',
    'SMS JSON сохранён: {path}. HTML не создан: {error}':
        'SMS JSON saved: {path}. HTML could not be created: {error}',
    'Ошибка обработки резервной копии: {error}':
        'Could not process backup: {error}',
    'FerryPane восстанавливает контакты…': 'FerryPane is restoring contacts…',
    'Контакты: добавлено {new}, объединено {merge}, без изменений {unchanged}, ошибок {failed}':
        'Contacts: added {new}, merged {merge}, unchanged {unchanged}, errors {failed}',
    'Не удалось восстановить контакты: {error}':
        'Could not restore contacts: {error}',
    'Ошибка восстановления контактов: {error}':
        'Contact restoration failed: {error}',

    'Уведомление можно закрыть нажатием': 'Tap to dismiss',
    'Показать в проводнике': 'Show in file manager',
    'Показать папку': 'Open containing folder',
    'Не удалось открыть папку: {error}': 'Could not open folder: {error}',
    'Проводник открыт': 'File manager opened',
    'Сбой передачи: {error}': 'Transfer failed: {error}',
    'Выполнение': 'Working',
    'Передача файлов': 'File transfer',
    'Настройки': 'Settings',
    'Поиск': 'Search',
    'Готово. Резервная копия сохранена: {files}':
        'Backup saved: {files}',
    'Ожидание передачи…': 'Waiting for transfer…',
    'Телефон готовит резервную копию контактов…':
        'Phone is preparing contacts backup…',
    'Телефон готовит резервную копию SMS…':
        'Phone is preparing SMS backup…',
    'Телефон отправляет контакты…': 'Phone is sending contacts…',
    'Телефон отправляет SMS…': 'Phone is sending SMS…',
    'Передача завершена': 'Transfer completed',
    'Подключено к {device}': 'Connected to {device}',
    'Подключение к {device}': 'Connecting to {device}',
  };
}


/// Short form for widget code and device status messages.
String tr(String source, [Map<String, Object?> values = const {}]) =>
    AppLanguage.tr(source, values);
