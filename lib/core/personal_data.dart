import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// This bridge runs only on Android. Contact/SMS operations never happen
/// automatically: FerryService first asks for one-time UI consent.
class PersonalDataBridge {
  static const MethodChannel _native = MethodChannel('ferrypane/personal');

  static bool get available => Platform.isAndroid;

  static Future<String> makeBackup(String type) async {
    if (!available) throw UnsupportedError('Backup requires Android');
    if (type != 'contacts' && type != 'sms') {
      throw ArgumentError.value(type, 'type', 'Unknown personal data format');
    }
    // Never open an Android permission dialog during a remote request:
    // unattended recovery must use permission granted while the screen worked.
    final status = type == 'contacts'
        ? await Permission.contacts.status
        : await Permission.sms.status;
    if (!status.isGranted) {
      throw StateError('Android не предоставил разрешение на чтение ${type == 'contacts' ? 'контактов' : 'SMS'}');
    }
    final filename = await _native.invokeMethod<String>(
      type == 'contacts' ? 'exportContacts' : 'exportSms',
    );
    if (filename == null || filename.isEmpty) {
      throw StateError('Android did not return an export file');
    }
    return filename;
  }

  static Future<String> prepareContactsImport() async {
    if (!available) throw UnsupportedError('Import requires Android');
    final folder = await _native.invokeMethod<String>('prepareContactsImport');
    if (folder == null || folder.isEmpty) {
      throw StateError('Android did not create a temporary import folder');
    }
    return folder;
  }

  static Future<String> launchContactsImport(String file) async {
    if (!available) throw UnsupportedError('Import requires Android');
    final result = await _native.invokeMethod<String>(
      'openContactsImport', {'path': file},
    );
    return result ?? 'Запущен штатный импорт контактов';
  }
}
