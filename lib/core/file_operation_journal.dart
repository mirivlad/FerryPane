import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A bounded, durable receiver-side log of authenticated remote filesystem
/// operations. A "started" record survives a crash before a completion record.
/// Entries are scoped to this app's private preferences, not exported roots.
class FileOperationJournal {
  static const key = 'ferrypane.fileops.audit.v1';
  static const limit = 400;
  static Future<void> _queue = Future<void>.value();

  static Future<void> append(
      SharedPreferences prefs, Map<String, dynamic> event) {
    final next = _queue.then((_) => _append(prefs, event));
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  static Future<void> _append(
      SharedPreferences prefs, Map<String, dynamic> event) async {
    await prefs.reload();
    final previous = _parse(prefs.getString(key));
    final clean = <String, dynamic>{
      ...event,
      'at': DateTime.now().toUtc().toIso8601String(),
    };
    previous.add(clean);
    if (previous.length > limit) {
      previous.removeRange(0, previous.length - limit);
    }
    if (!await prefs.setString(key, jsonEncode(previous))) {
      throw StateError('Remote file operation journal could not be saved');
    }
  }

  static Future<List<Map<String, dynamic>>> read(
      SharedPreferences prefs) async {
    await _queue;
    await prefs.reload();
    return _parse(prefs.getString(key));
  }

  static List<Map<String, dynamic>> _parse(String? raw) {
    if (raw == null) return [];
    final parsed = jsonDecode(raw);
    if (parsed is! List || parsed.length > limit) {
      throw const FormatException('File operation journal is damaged');
    }
    return parsed.map((entry) {
      if (entry is! Map) {
        throw const FormatException('Invalid file operation audit event');
      }
      return Map<String, dynamic>.from(entry);
    }).toList();
  }
}
