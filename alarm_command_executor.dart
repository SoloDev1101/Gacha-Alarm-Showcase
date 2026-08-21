import 'dart:convert';
import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

import '../models/alarm_action_result.dart';
import '../models/alarm_item.dart';
import '../utils/logger.dart';
import 'alarm_service.dart';
import 'alarm_snapshot_service.dart';
import 'database_service.dart';
import 'notification_service.dart';
import 'wearable_bridge_service.dart';
import 'wearable_sync_service.dart';

enum AlarmCommandSource {
  phoneUi,
  notificationBridge,
  wearOsMessage,
  wearOsDataEvent,
  autoSnooze,
}

enum AlarmCommandType {
  dismiss,
  snooze,
  ignore,
}

class AlarmCommandResult {
  final AlarmActionOutcome outcome;
  final bool shouldGrantReward;
  final bool shouldExitUi;
  final int alarmId;
  final String? partnerId;

  const AlarmCommandResult({
    required this.outcome,
    required this.shouldGrantReward,
    required this.shouldExitUi,
    required this.alarmId,
    this.partnerId,
  });
}

class AlarmCommandExecutor {
  static const String keyWearablePendingActionEvents =
      'wearable_pending_action_events';
  static const String keyPendingWearableRewards = 'pending_wearable_rewards';
  static const String keyWearableProcessedEventIds =
      'wearable_processed_event_ids';

  static Future<AlarmCommandResult> execute({
    required int alarmId,
    required AlarmCommandType command,
    required AlarmCommandSource source,
    String? eventId,
    DateTime? scheduledAt,
    DateTime? actionAt,
  }) async {
    appLog(
      '[AlarmCommand] Executing $command for alarm $alarmId '
      '(source: $source, eventId: $eventId)',
    );

    try {
      WidgetsFlutterBinding.ensureInitialized();
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    if (eventId != null && await _isProcessedEvent(prefs, eventId)) {
      appLog('[AlarmCommand] Duplicate eventId ignored: $eventId');
      return AlarmCommandResult(
        outcome: AlarmActionOutcome.cycleEnded,
        shouldGrantReward: false,
        shouldExitUi: false,
        alarmId: alarmId,
      );
    }

    try {
      await DatabaseService.initMinimalForBackground();
    } catch (e) {
      appLog('[AlarmCommand] Failed to open database: $e');
      if (source != AlarmCommandSource.phoneUi) {
        await _enqueueAction(prefs, alarmId, command, source, eventId);
      }
      return AlarmCommandResult(
        outcome: AlarmActionOutcome.cycleEnded,
        shouldGrantReward: false,
        shouldExitUi: false,
        alarmId: alarmId,
      );
    }

    await _stopCurrentRingingEffects(prefs, alarmId);

    final alarm = _findAlarm(alarmId);
    if (alarm == null) {
      appLog('[AlarmCommand] Alarm $alarmId not found in DB.');
      return AlarmCommandResult(
        outcome: AlarmActionOutcome.cycleEnded,
        shouldGrantReward: false,
        shouldExitUi: true,
        alarmId: alarmId,
      );
    }

    final result = command == AlarmCommandType.dismiss
        ? await _handleDismiss(prefs, alarm, source, eventId)
        : await _handleSnooze(prefs, alarm);

    if (eventId != null) {
      await _markProcessedEvent(prefs, eventId);
    }

    return result;
  }

  static AlarmItem? _findAlarm(int alarmId) {
    final box = Hive.box<AlarmItem>('alarmBox');
    for (final alarm in box.values) {
      if (alarm.notificationId == alarmId) return alarm;
    }
    return null;
  }

  static Future<void> _stopCurrentRingingEffects(
    SharedPreferences prefs,
    int alarmId,
  ) async {
    final audioPort = IsolateNameServer.lookupPortByName('alarm_isolate_port');
    audioPort?.send('stop_audio');
    await Vibration.cancel();
    await prefs.setBool('isRinging', false);

    final notifications = FlutterLocalNotificationsPlugin();
    await notifications.cancel(alarmId);
    await WearableBridgeService.cancelBridgeNotification(alarmId);
  }

  static Future<AlarmCommandResult> _handleDismiss(
    SharedPreferences prefs,
    AlarmItem alarm,
    AlarmCommandSource source,
    String? eventId,
  ) async {
    final baseAlarmId = alarm.notificationId;
    await prefs.setInt('snooze_count_$baseAlarmId', 0);
    await prefs.setBool('isSnoozed', false);
    await prefs.remove('has_snoozed_$baseAlarmId');

    if (!alarm.isRepeating) {
      alarm.isEnabled = false;
      await alarm.save();
      await AlarmService.cancelAlarm(baseAlarmId);
      await AndroidAlarmManager.cancel(baseAlarmId + 10000);
    } else {
      alarm.updateNextRingTime();
      await alarm.save();
      if (alarm.nextRingTime != null) {
        await AlarmService.scheduleAlarm(alarm.nextRingTime!, baseAlarmId);
        final preNotiTime =
            alarm.nextRingTime!.subtract(const Duration(minutes: 45));
        if (preNotiTime.isAfter(DateTime.now())) {
          await AndroidAlarmManager.oneShotAt(
            preNotiTime,
            baseAlarmId + 10000,
            preAlarmCallback,
            exact: true,
            wakeup: true,
            rescheduleOnReboot: true,
          );
        }
      }
    }

    await AlarmSnapshotService.updateSnapshot();
    await WearableSyncService.syncAlarm(alarm, reason: 'Dismissed');
    _notifyMainIsolate('ALARM_COMMAND_DISMISS_$baseAlarmId');

    final grantDirectly = source == AlarmCommandSource.phoneUi;
    final partnerId = await _resolvePartnerId(prefs);
    if (!grantDirectly) {
      await _enqueueReward(
        prefs,
        alarmId: baseAlarmId,
        sourceName: source.name,
        eventId: eventId,
        partnerId: partnerId,
      );
    }

    return AlarmCommandResult(
      outcome: AlarmActionOutcome.dismissWithReward,
      shouldGrantReward: grantDirectly,
      shouldExitUi: true,
      alarmId: baseAlarmId,
      partnerId: partnerId,
    );
  }

  static Future<AlarmCommandResult> _handleSnooze(
    SharedPreferences prefs,
    AlarmItem alarm,
  ) async {
    final baseAlarmId = alarm.notificationId;
    var currentSnoozeCount = prefs.getInt('snooze_count_$baseAlarmId') ?? 0;

    await prefs.setBool('isSnoozed', true);
    await prefs.setBool('has_snoozed_$baseAlarmId', true);

    if (currentSnoozeCount < 2) {
      currentSnoozeCount++;
      await prefs.setInt('snooze_count_$baseAlarmId', currentSnoozeCount);

      final rawSnooze = DateTime.now().add(const Duration(minutes: 10));
      final snoozeTime = DateTime(
        rawSnooze.year,
        rawSnooze.month,
        rawSnooze.day,
        rawSnooze.hour,
        rawSnooze.minute,
      );

      alarm.nextRingTime = snoozeTime;
      await alarm.save();
      await AlarmService.scheduleAlarm(snoozeTime, baseAlarmId);
      await AlarmSnapshotService.updateSnapshot();
      await WearableSyncService.syncAlarm(alarm, reason: 'Snoozed');
      _notifyMainIsolate('ALARM_COMMAND_SNOOZE_$baseAlarmId');

      appLog(
        '[AlarmCommand] Snooze $currentSnoozeCount/2 scheduled for '
        '${snoozeTime.hour}:${snoozeTime.minute.toString().padLeft(2, '0')}.',
      );

      return AlarmCommandResult(
        outcome: AlarmActionOutcome.snoozeScheduled,
        shouldGrantReward: false,
        shouldExitUi: true,
        alarmId: baseAlarmId,
      );
    }

    appLog('[AlarmCommand] Snooze limit reached. Ending current cycle.');
    await prefs.setInt('snooze_count_$baseAlarmId', 0);
    await prefs.setBool('isSnoozed', false);
    await prefs.remove('has_snoozed_$baseAlarmId');

    if (!alarm.isRepeating) {
      alarm.isEnabled = false;
      await alarm.save();
      await AlarmService.cancelAlarm(baseAlarmId);
      await AndroidAlarmManager.cancel(baseAlarmId + 10000);
    } else {
      alarm.updateNextRingTime();
      await alarm.save();
      if (alarm.nextRingTime != null) {
        await AlarmService.scheduleAlarm(alarm.nextRingTime!, baseAlarmId);
        final preNotiTime =
            alarm.nextRingTime!.subtract(const Duration(minutes: 45));
        if (preNotiTime.isAfter(DateTime.now())) {
          await AndroidAlarmManager.oneShotAt(
            preNotiTime,
            baseAlarmId + 10000,
            preAlarmCallback,
            exact: true,
            wakeup: true,
            rescheduleOnReboot: true,
          );
        }
      }
    }

    await AlarmSnapshotService.updateSnapshot();
    await WearableSyncService.syncAlarm(alarm, reason: 'Dismissed (snooze limit)');
    _notifyMainIsolate('ALARM_COMMAND_DISMISS_$baseAlarmId');

    return AlarmCommandResult(
      outcome: AlarmActionOutcome.cycleEnded,
      shouldGrantReward: false,
      shouldExitUi: true,
      alarmId: baseAlarmId,
    );
  }

  static void _notifyMainIsolate(String message) {
    final mainPort = IsolateNameServer.lookupPortByName('main_isolate_cmd');
    mainPort?.send(message);
  }

  static Future<bool> _isProcessedEvent(
    SharedPreferences prefs,
    String eventId,
  ) async {
    final processedIds = _decodeList(prefs.getString(keyWearableProcessedEventIds));
    return processedIds.contains(eventId);
  }

  static Future<void> _markProcessedEvent(
    SharedPreferences prefs,
    String eventId,
  ) async {
    final processedIds = _decodeList(prefs.getString(keyWearableProcessedEventIds));
    processedIds.add(eventId);
    while (processedIds.length > 100) {
      processedIds.removeAt(0);
    }
    await prefs.setString(
      keyWearableProcessedEventIds,
      jsonEncode(processedIds),
    );
  }

  static Future<void> _enqueueAction(
    SharedPreferences prefs,
    int alarmId,
    AlarmCommandType command,
    AlarmCommandSource source,
    String? eventId,
  ) async {
    final queue = _decodeList(prefs.getString(keyWearablePendingActionEvents));
    if (eventId != null && queue.any((entry) => entry['eventId'] == eventId)) {
      return;
    }

    queue.add({
      'alarmId': alarmId,
      'command': command.name,
      'source': source.name,
      'eventId': eventId,
      'actionAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString(keyWearablePendingActionEvents, jsonEncode(queue));
  }

  static Future<void> _enqueueReward(
    SharedPreferences prefs, {
    required int alarmId,
    required String sourceName,
    required String? eventId,
    required String? partnerId,
  }) async {
    final queue = _decodeList(prefs.getString(keyPendingWearableRewards));
    final id = eventId ?? 'reward:$alarmId:${DateTime.now().millisecondsSinceEpoch}';
    if (queue.any((entry) => entry['id'] == id || entry['eventId'] == eventId)) {
      return;
    }

    queue.add({
      'id': id,
      'alarmId': alarmId,
      'source': sourceName,
      'actionAt': DateTime.now().toIso8601String(),
      'eventId': eventId,
      'partnerId': partnerId,
    });
    await prefs.setString(keyPendingWearableRewards, jsonEncode(queue));
    appLog('[AlarmCommand] Queued pending reward for alarm $alarmId.');
  }

  static Future<String?> _resolvePartnerId(SharedPreferences prefs) async {
    final snapshot = await AlarmSnapshotService.getSnapshot();
    final snapshotPartnerId = snapshot?['partner_id']?.toString();
    if (snapshotPartnerId != null && snapshotPartnerId.isNotEmpty) {
      return snapshotPartnerId;
    }
    final currentPartnerId = prefs.getString('current_partner_id');
    if (currentPartnerId != null && currentPartnerId.isNotEmpty) {
      return currentPartnerId;
    }
    return null;
  }

  static List<dynamic> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return <dynamic>[];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : <dynamic>[];
    } catch (_) {
      return <dynamic>[];
    }
  }
}
