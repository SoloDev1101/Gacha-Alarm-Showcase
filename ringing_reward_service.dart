import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:uuid/uuid.dart';

import '../models/user_profile.dart';

import '../services/evolution_service.dart';
import '../services/lore_service.dart';
import '../utils/logger.dart';
import '../utils/affinity_helper.dart';

class RingingRewardService {
  static Future<bool> grantRewardsAndAffinity(BuildContext context,
      {String? ringingPartnerId}) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      // BUG3 FIX: Dùng UTC để tránh lệch ngày theo múi giờ thiết bị
      String todayStr = DateTime.now().toUtc().toIso8601String().split('T')[0];
      String lastLocalAffinityDate =
          prefs.getString('last_affinity_date') ?? '';

      // 1. LOGIC ĐIỂM THÂN MẬT
      if (lastLocalAffinityDate != todayStr) {
        // BUG1 FIX: KHÔNG ghi last_affinity_date ở đây — chỉ ghi sau khi cloud phản hồi
        // để tránh mất lượt khi mất mạng giữa chừng.
        final profileBox = Hive.box<UserProfile>('userProfileBox');

        if (profileBox.isNotEmpty) {
          final profile = profileBox.getAt(0)!;

          // Ưu tiên partner đang reo báo thức (nếu user set partner riêng cho alarm này)
          // Nếu không có, fallback về current partner ngoài màn hình chính.
          String currentPartnerId =
              ringingPartnerId ?? prefs.getString('current_partner_id') ?? '';

          if (currentPartnerId.isEmpty) {
            appLog(
                "⚠️ [RewardService] Chưa set partner, bỏ qua cộng điểm affinity.");
          } else if (!profile.unlockedCharacters.contains(currentPartnerId)) {
            appLog(
                "⚠️ [RewardService] Partner '$currentPartnerId' chưa unlock, bỏ qua cộng điểm.");
          } else {
            int currentAffinity = profile.affinityScores[currentPartnerId] ?? 0;
            if (currentAffinity < AffinityHelper.daysToLv3) {
              try {
                final supabase = Supabase.instance.client;
                final userId = supabase.auth.currentUser?.id;

                if (userId != null) {
                  final bool isApproved = await supabase.rpc(
                    'request_daily_affinity',
                    params: {
                      'p_user_id': userId,
                      'p_char_id': currentPartnerId
                    },
                  );
                  if (isApproved) {
                    appLog(
                        "✅ [RewardService] Cloud đã DUYỆT! Cộng điểm affinity.");
                    // BUG1 FIX: Ghi date SAU khi cloud xác nhận thành công
                    await prefs.setString('last_affinity_date', todayStr);
                    final newAffinity = currentAffinity + 1;
                    profile.affinityScores[currentPartnerId] = newAffinity;
                    await profile.save();
                    await LoreService.checkAndUpgradePhase(
                        currentPartnerId, newAffinity);
                  } else {
                    appLog(
                        "⚠️ [RewardService] Cloud TỪ CHỐI: Gian lận/Đã nhận.");
                    // BUG1 FIX: Cloud từ chối → cũng ghi date để tránh gọi RPC lặp lại vô ích
                    await prefs.setString('last_affinity_date', todayStr);
                  }
                }
              } catch (e) {
                // BUG1 FIX: Lỗi mạng → KHÔNG ghi date → lần dismiss tiếp theo sẽ thử lại
                appLog(
                    "❌ [RewardService] Lỗi khi gửi yêu cầu xin phép Cloud: $e");
              }
            }
          }
        }
      }

      // 2. LOGIC VÉ GACHA & MIGRATION LOG
      if (context.mounted) {
        await EvolutionService.checkAndTriggerEvolution(context);
      }
      final profileBox = Hive.box<UserProfile>('userProfileBox');

      if (profileBox.isNotEmpty) {
        final profile = profileBox.getAt(0)!;
        String lastDate = prefs.getString('last_ticket_date') ?? '';
        int ticketsToday = prefs.getInt('tickets_today') ?? 0;

        if (lastDate != todayStr) {
          ticketsToday = 0;
          await prefs.setString('last_ticket_date', todayStr);
        }

        int ticketsToAdd = 0;
        if (ticketsToday < 6) {
          ticketsToAdd = (ticketsToday + 2 <= 6) ? 2 : (6 - ticketsToday);
          profile.gachaTickets += ticketsToAdd;
          await profile.save();
          ticketsToday += ticketsToAdd;
          await prefs.setInt('tickets_today', ticketsToday);

          // LOGIC MỚI: Lưu log dạng JSON + UUID
          List<String> pendingLogs =
              prefs.getStringList('pending_reward_logs') ?? [];
          final newLogEntry = jsonEncode({
            'id': const Uuid().v4(),
            'timestamp': DateTime.now().toUtc().toIso8601String(),
          });
          pendingLogs.add(newLogEntry);
          await prefs.setStringList('pending_reward_logs', pendingLogs);
        }

        // Bắn thông báo
        final FlutterLocalNotificationsPlugin np =
            FlutterLocalNotificationsPlugin();
        await np.cancel(1);

        String channelName = 'ringing.reward_channel_name'.tr();
        String notifTitle = 'ringing.reward_title'.tr();
        String notifBody = ticketsToAdd > 0
            ? 'ringing.reward_body_success'
                .tr(namedArgs: {'tickets': ticketsToAdd.toString()})
            : 'ringing.reward_body_limit'.tr();

        AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
          'reward_channel',
          channelName,
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        );
        await np.show(1001, notifTitle, notifBody,
            NotificationDetails(android: androidDetails));
      }
      return true;
    } catch (e) {
      appLog("⚠️ Lỗi khi xử lý phần thưởng: $e");
      return false;
    }
  }

  static Future<void> drainPendingWearableRewards(BuildContext context) async {
    if (!context.mounted) return;
    if (!Hive.isBoxOpen('userProfileBox')) {
      appLog('[RewardService] Skip wearable reward drain: Hive not ready.');
      return;
    }
    try {
      Supabase.instance.client;
    } catch (_) {
      appLog('[RewardService] Skip wearable reward drain: Supabase not ready.');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final queueStr = prefs.getString('pending_wearable_rewards') ?? '[]';
    final List<dynamic> queue = _decodeQueue(queueStr);
    
    if (queue.isEmpty) return;
    appLog("🎁 [RewardService] Draining ${queue.length} pending wearable rewards...");
    
    final processedStr = prefs.getString('wearable_processed_reward_ids') ?? '[]';
    final List<dynamic> processedIds = _decodeQueue(processedStr);
    
    List<dynamic> remainingQueue = [];
    
    for (var entry in queue) {
      String id = entry['id'];
      String? partnerId = entry['partnerId'];
      
      if (processedIds.contains(id)) {
        appLog("ℹ️ [RewardService] Skipping duplicate pending reward $id");
        continue;
      }
      
      try {
        bool success = await grantRewardsAndAffinity(context, ringingPartnerId: partnerId);
        
        if (success) {
          processedIds.add(id);
          if (processedIds.length > 100) processedIds.removeAt(0);
        } else {
          appLog("⚠️ [RewardService] Soft fail processing reward $id");
          remainingQueue.add(entry);
        }
      } catch (e) {
        appLog("⚠️ [RewardService] Error processing pending reward $id: $e");
        remainingQueue.add(entry); // keep if failed
      }
    }
    
    await prefs.setString('wearable_processed_reward_ids', jsonEncode(processedIds));
    await prefs.setString('pending_wearable_rewards', jsonEncode(remainingQueue));
  }

  static List<dynamic> _decodeQueue(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : <dynamic>[];
    } catch (_) {
      return <dynamic>[];
    }
  }
}
