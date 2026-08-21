import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/alarm_item.dart';
import '../utils/logger.dart';
import 'alarm_snapshot_service.dart';
import 'alarm_command_executor.dart';
import 'wearable_bridge_service.dart';

class WearableSyncService {
  static const String _keyEnabled = 'wearable_alarm_enabled';
  static const MethodChannel _channel = MethodChannel('gacha_alarm/wear_os');

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyEnabled) ?? false;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, enabled);
    appLog("⚙️ [WearableSync] Set wearable_alarm_enabled = $enabled");

    await sendConfig();

    if (!enabled) {
      await WearableBridgeService.cancelAllBridgeNotifications();
    } else {
      await syncAllAlarms(reason: 'Settings toggled to ON');
    }
  }

  static Future<void> sendConfig() async {
    try {
      final enabled = await isEnabled();
      final configJson = jsonEncode({
        "schemaVersion": 1,
        "enabled": enabled,
        "updatedAt": DateTime.now().toUtc().toIso8601String(),
        "phonePackage": "com.solodev.gacha_alarm"
      });
      await _channel.invokeMethod('sendConfig', {'json': configJson});
    } catch (e) {
      appLog("⚠️ [WearableSync] sendConfig error: $e");
    }
  }

  static Future<void> syncAllAlarms({String reason = ''}) async {
    if (!await isEnabled()) return;
    try {
      appLog("🔄 [WearableSync] Syncing all alarms. Reason: $reason");
      final box = Hive.box<AlarmItem>('alarmBox');
      for (var alarm in box.values) {
        await syncAlarm(alarm, reason: 'Bulk sync');
      }
    } catch (e) {
      appLog("⚠️ [WearableSync] syncAllAlarms error: $e");
    }
  }

  static Future<void> syncAlarm(AlarmItem alarm, {String reason = ''}) async {
    if (!await isEnabled()) return;
    try {
      final fullSnapshot = await AlarmSnapshotService.getSnapshot();
      String partnerName = 'Gacha Alarm';
      String partnerId = '';
      String wakeUp = "Time to wake up!";
      String snooze = "Snoozing...";
      String ignored = "Dismissed.";
      
      if (fullSnapshot != null) {
        partnerName = fullSnapshot['partner_name'] ?? partnerName;
        partnerId = fullSnapshot['partner_id'] ?? partnerId;
        final wakeUpD3 = AlarmSnapshotService.findRingingDialogue(fullSnapshot, alarm.notificationId, 'WakeUp');
        final snoozeD3 = AlarmSnapshotService.findRingingDialogue(fullSnapshot, alarm.notificationId, 'Snooze');
        final ignoredD3 = AlarmSnapshotService.findRingingDialogue(fullSnapshot, alarm.notificationId, 'Ignored');
        if (wakeUpD3 != null) wakeUp = wakeUpD3;
        if (snoozeD3 != null) snooze = snoozeD3;
        if (ignoredD3 != null) ignored = ignoredD3;
      }

      final prefs = await SharedPreferences.getInstance();
      final snoozeCount = prefs.getInt('snooze_count_${alarm.notificationId}') ?? 0;
      
      String eventType = "WakeUp";
      if (snoozeCount == 1) {
        eventType = "Snooze";
      } else if (snoozeCount >= 2) {
        eventType = "Ignored";
      }

      final jsonPayload = jsonEncode({
        "schemaVersion": 1,
        "alarmId": alarm.notificationId,
        "enabled": alarm.isEnabled,
        "hour": alarm.hour,
        "minute": alarm.minute,
        "isRepeating": alarm.isRepeating,
        "repeatDays": alarm.repeatDays,
        "tag": alarm.tag,
        "nextRingTime": alarm.nextRingTime?.toUtc().toIso8601String() ?? "",
        "nextRingTimeMillis": alarm.nextRingTime?.millisecondsSinceEpoch ?? 0,
        "timeZoneName": DateTime.now().timeZoneName,
        "timeZoneOffsetMinutes": DateTime.now().timeZoneOffset.inMinutes,
        "partnerId": partnerId,
        "partnerName": partnerName,
        "snoozeCount": snoozeCount,
        "eventType": eventType,
        "dialogues": {
          "WakeUp": wakeUp,
          "Snooze": snooze,
          "Ignored": ignored
        },
        "updatedAt": DateTime.now().toUtc().toIso8601String(),
      });
      appLog("[WearableSync] syncAlarm id=${alarm.notificationId} nextRingTime=${alarm.nextRingTime?.toUtc().toIso8601String() ?? ''} millis=${alarm.nextRingTime?.millisecondsSinceEpoch ?? 0} enabled=${alarm.isEnabled}");
      await _channel.invokeMethod('syncAlarm', {'alarmId': alarm.notificationId, 'json': jsonPayload});
    } catch (e) {
      appLog("⚠️ [WearableSync] syncAlarm error: $e");
    }
  }

  static Future<void> deleteAlarm(int alarmId, {String reason = ''}) async {
    try {
      // Use tombstone instead of deleting DataItem directly as requested
      final tombstoneJson = jsonEncode({
        "schemaVersion": 1,
        "alarmId": alarmId,
        "enabled": false,
        "deleted": true,
        "updatedAt": DateTime.now().toUtc().toIso8601String()
      });
      await _channel.invokeMethod('syncAlarm', {'alarmId': alarmId, 'json': tombstoneJson});
      appLog("🗑️ [WearableSync] Sent tombstone for alarm $alarmId. Reason: $reason");
    } catch (e) {
      appLog("⚠️ [WearableSync] deleteAlarm error: $e");
    }
  }

  static Future<void> drainPendingWearEvents() async {
    try {
      final Map<Object?, Object?>? events = await _channel.invokeMethod('drainPendingEvents');
      if (events == null || events.isEmpty) return;

      for (var entry in events.entries) {
        if (entry.key is! String || entry.value is! String) {
          appLog("⚠️ [WearableSync] Invalid entry in pending events queue, skipping.");
          continue;
        }
        final eventId = entry.key as String;
        final payloadStr = entry.value as String;
        
        try {
          final payload = jsonDecode(payloadStr);
          
          final schemaVersion = payload['schemaVersion'] as int?;
          if (schemaVersion == null || schemaVersion != 1) {
            appLog("⚠️ [WearableSync] Invalid schemaVersion for event $eventId");
            await _channel.invokeMethod('ackPendingEvent', {'eventId': eventId});
            continue;
          }

          final actionTypeStr = payload['actionType'] as String?;
          final alarmId = payload['alarmId'] as int?;
          if (actionTypeStr == null || alarmId == null) {
            appLog("⚠️ [WearableSync] Missing required fields for event $eventId");
            await _channel.invokeMethod('ackPendingEvent', {'eventId': eventId});
            continue;
          }
          
          final sourceStr = payload['source'] as String? ?? 'wear_os';
          final actionSource = sourceStr == 'wear_os' ? AlarmCommandSource.wearOsDataEvent : AlarmCommandSource.wearOsMessage;

          final scheduledAtStr = payload['scheduledAt'] as String?;
          final actionAtStr = payload['actionAt'] as String?;
          DateTime? scheduledAt;
          DateTime? actionAt;
          if (scheduledAtStr != null && scheduledAtStr.isNotEmpty) scheduledAt = DateTime.tryParse(scheduledAtStr);
          if (actionAtStr != null && actionAtStr.isNotEmpty) actionAt = DateTime.tryParse(actionAtStr);

          AlarmCommandType? commandType;
          if (actionTypeStr == 'dismiss') {
            commandType = AlarmCommandType.dismiss;
          } else if (actionTypeStr == 'snooze') {
            commandType = AlarmCommandType.snooze;
          } else if (actionTypeStr == 'ignore') {
            commandType = AlarmCommandType.ignore;
          }

          if (commandType != null) {
            appLog("⌚ [WearableSync] Processing event $eventId ($actionTypeStr) for alarm $alarmId");
            await AlarmCommandExecutor.execute(
              alarmId: alarmId,
              command: commandType,
              source: actionSource,
              eventId: eventId,
              scheduledAt: scheduledAt,
              actionAt: actionAt,
            );
            // Ack and cleanup after success
            await _channel.invokeMethod('ackPendingEvent', {'eventId': eventId});
          } else {
            appLog("⚠️ [WearableSync] Unknown actionType $actionTypeStr for event $eventId");
            await _channel.invokeMethod('ackPendingEvent', {'eventId': eventId});
          }
        } catch (innerE) {
          appLog("⚠️ [WearableSync] Failed to process event $eventId: $innerE");
        }
      }
    } catch (e) {
      appLog("⚠️ [WearableSync] drainPendingWearEvents error: $e");
    }
  }

  static Future<Map<String, dynamic>> getConnectionStatus() async {
    try {
      final status = await _channel.invokeMethod('getConnectionStatus');
      if (status is Map) {
        appLog("📡 [WearOsConnection] connectedNodes count=${status['nodeCount']}");
        return Map<String, dynamic>.from(status);
      }
    } catch (e) {
      appLog("⚠️ [WearableSync] getConnectionStatus error: $e");
    }
    return {"connected": false, "nodeCount": 0, "nodes": []};
  }

  static Future<void> pingCompanion() async {
    try {
      final sentCount = await _channel.invokeMethod('pingWearCompanion');
      appLog("📡 [WearOsConnection] ping sent count=$sentCount");
    } catch (e) {
      appLog("⚠️ [WearableSync] pingCompanion error: $e");
    }
  }

  static Future<String> getCompanionStatus() async {
    if (!await isEnabled()) return "disabled";
    
    final nodeStatus = await getConnectionStatus();
    final connectedNodes = nodeStatus['nodeCount'] as int? ?? 0;
    if (connectedNodes == 0) return "enabled_no_node";
    
    try {
      final companionMap = await _channel.invokeMethod('getCompanionStatus');
      if (companionMap is Map) {
        final lastSeenMs = companionMap['wear_companion_last_seen_ms'] as int? ?? 0;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (lastSeenMs > 0 && (nowMs - lastSeenMs) < 120000) { // 2 minutes
          return "companion_ready";
        }
      }
    } catch (e) {
      appLog("⚠️ [WearableSync] getCompanionStatus error: $e");
    }
    
    return "node_connected_companion_unknown";
  }
}
