import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'secure_peer.dart';
import 'service.dart';

/// A *separate* Flutter engine owns the Android inbound listener while the
/// foreground service runs. It never opens a new pairing window or prompts
/// for contacts/SMS permissions. Only previously trusted keys are accepted.
@pragma('vm:entry-point')
void ferryBackgroundCallback() {
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_FerryBackgroundHandler());
}

class _FerryBackgroundHandler extends TaskHandler {
  FerryService? _listener;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      final identity = await PeerIdentity.load();
      // Never silently expand the root to all of /storage if the configured
      // root disappears after a storage mount or permission change.
      final root = identity.prefs.getString('ferrypane.export.root') ??
          '/storage/emulated/0';
      if (!await Directory(root).exists()) {
        throw FileSystemException('Shared directory unavailable', root);
      }
      final peerService = FerryService(
        identity,
        (_, __, ___) async => false,
        root,
      );
      await peerService.start();
      if (peerService.boundPort != ferryPort) {
        peerService.dispose();
        throw StateError('Could not open private LAN listener');
      }
      _listener = peerService;
      FlutterForegroundTask.sendDataToMain({'state': 'ready'});
    } catch (e) {
      FlutterForegroundTask.sendDataToMain({
        'state': 'error',
        'message': '$e',
      });
      await FlutterForegroundTask.updateService(
        notificationText: 'Ошибка фонового доступа: $e',
      );
      unawaited(FlutterForegroundTask.stopService());
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_refreshTrust());
  }

  Future<void> _refreshTrust() async {
    final service = _listener;
    if (service == null) return;
    try {
      // The Activity and this headless engine have different preference
      // caches. Refresh revocations and per-peer grants while running.
      await service.identity.prefs.reload();
      final peer = service.connected;
      if (peer != null &&
          (!service.identity.trusts(peer.remoteKey) ||
              !service.peerCanRead && !service.peerCanWrite)) {
        await service.disconnectPeer();
      }
    } catch (_) {
      // A failed refresh must not grant any new permission.
      await service.disconnectPeer();
    }
  }

  @override
  void onReceiveData(Object data) {
    if (data == 'refresh-trust') unawaited(_refreshTrust());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _listener?.dispose();
    _listener = null;
  }
}

class AndroidForegroundAccess {
  static void initialize() {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: const AndroidNotificationOptions(
        channelId: 'ferrypane_recovery',
        channelName: 'FerryPane — фоновый доступ',
        channelDescription: 'Приём файлов и разрешённых резервных копий '
            'с ранее доверенных устройств',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowAutoRestart: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<bool> get isRunning async =>
      Platform.isAndroid && await FlutterForegroundTask.isRunningService;

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    var notifications = await FlutterForegroundTask.checkNotificationPermission();
    if (notifications != NotificationPermission.granted) {
      notifications = await FlutterForegroundTask.requestNotificationPermission();
    }
    if (notifications != NotificationPermission.granted) {
      throw StateError('Разрешите уведомления для фоновой службы FerryPane');
    }
    // Service start is not proof the headless listener actually bound.
    final ready = Completer<void>();
    void onWorkerData(Object data) {
      if (data is! Map) return;
      if (data['state'] == 'ready' && !ready.isCompleted) {
        ready.complete();
      } else if (data['state'] == 'error' && !ready.isCompleted) {
        ready.completeError(StateError(data['message'].toString()));
      }
    }
    FlutterForegroundTask.addTaskDataCallback(onWorkerData);
    try {
      final result = await FlutterForegroundTask.startService(
        serviceId: 47655,
        serviceTypes: [ForegroundServiceTypes.connectedDevice],
        notificationTitle: 'FerryPane',
        notificationText: 'Фоновый доступ для доверенных устройств включён',
        callback: ferryBackgroundCallback,
      );
      if (result is! ServiceRequestSuccess) {
        throw StateError('Не удалось запустить фоновый сервис: $result');
      }
      await ready.future.timeout(const Duration(seconds: 25));
    } finally {
      FlutterForegroundTask.removeTaskDataCallback(onWorkerData);
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid || !await isRunning) return;
    final result = await FlutterForegroundTask.stopService();
    if (result is! ServiceRequestSuccess) {
      throw StateError('Не удалось остановить фоновый сервис: $result');
    }
  }

  static void refreshPermissions() {
    if (Platform.isAndroid) {
      FlutterForegroundTask.sendDataToTask('refresh-trust');
    }
  }
}
