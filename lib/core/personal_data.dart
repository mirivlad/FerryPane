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

  /// Preview and restore inside FerryPane using ContactsProvider. READ_CONTACTS
  /// and WRITE_CONTACTS must be granted; nothing is imported during preview.
  static Future<Map<String, dynamic>> previewContactsImport(String file) async {
    if (!available) throw UnsupportedError('Import requires Android');
    final granted = await Permission.contacts.request();
    if (!granted.isGranted) {
      throw StateError('Android не разрешил чтение и запись контактов');
    }
    final value = await _native.invokeMapMethod<String, dynamic>(
      'previewContactsImport', {'path': file},
    );
    if (value == null) throw StateError('Не удалось прочитать vCard');
    return value;
  }

  static Future<Map<String, dynamic>> restoreContactsImport(String file) async {
    if (!available) throw UnsupportedError('Import requires Android');
    final value = await _native.invokeMapMethod<String, dynamic>(
      'restoreContactsImport', {'path': file},
    );
    if (value == null) throw StateError('Контакты не импортированы');
    return value;
  }
}
