import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../utils/logger.dart';
import 'mail_service.dart';
import 'profile_sync_service.dart';

/// Chịu trách nhiệm xử lý các tác vụ đồng bộ tồn đọng (offline):
/// - Đơn hàng IAP bị kẹt trong hàng đợi
/// - Nhật ký báo thức offline chưa được đẩy lên server
class OfflineSyncService {
  static final _supabase = Supabase.instance.client;

  /// Entry point chính — gọi theo thứ tự: IAP → Alarm logs → Profile sync
  static Future<void> syncAll() async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    final prefs = await SharedPreferences.getInstance();

    try {
      await _syncPendingPurchases(user.id, prefs);
    } catch (e) {
      appLog("⚠️ [OfflineSyncService] Lỗi đồng bộ mua hàng: $e");
    }

    try {
      await _syncAlarmLogs(prefs);
    } catch (e) {
      appLog("⚠️ [OfflineSyncService] Lỗi đồng bộ nhật ký báo thức: $e");
    }

    try {
      await ProfileSyncService.fetchAndUpdate();
    } catch (e) {
      appLog("⚠️ [OfflineSyncService] Lỗi đồng bộ profile: $e");
    }
  }

  // =================================================================
  // 1. XỬ LÝ ĐƠN HÀNG IAP BỊ KẸT (Hàng đợi Cứu hộ)
  // =================================================================
  static Future<void> _syncPendingPurchases(
      String userId, SharedPreferences prefs) async {
    List<String> pendingPurchases =
        prefs.getStringList('pending_purchase_mails') ?? [];
    if (pendingPurchases.isEmpty) return;

    appLog(
        "🔄 [OfflineSyncService] Đang xử lý ${pendingPurchases.length} đơn hàng mua vật phẩm bị kẹt...");
    List<String> failedPurchases = [];
    bool hasNewMail = false;

    for (String log in pendingPurchases) {
      try {
        // Tách chuỗi dữ liệu (userId|itemName|attachmentType|attachmentAmount)
        final parts = log.split('|');
        if (parts.length == 4 && parts[0] == userId) {
          await _supabase.from('user_mails').insert({
            'user_id': userId,
            'title_key': 'mailbox.purchase_title',
            'content_key': parts[1],
            'attachment_type': parts[2],
            'attachment_amount': int.tryParse(parts[3]) ?? 0,
          });
          hasNewMail = true;
        }
      } catch (e) {
        appLog("⚠️ [OfflineSyncService] Lỗi gửi bù đơn hàng ($log): $e");
        // Nếu vẫn lỗi mạng, đưa đơn hàng này vào danh sách failed để lần sau thử tiếp
        failedPurchases.add(log);
      }
    }

    // Cập nhật lại hàng đợi: Xóa các đơn thành công, chỉ giữ lại đơn thất bại
    await prefs.setStringList('pending_purchase_mails', failedPurchases);

    // Kéo lại hòm thư để người chơi thấy quà (fire-and-forget)
    if (hasNewMail && Hive.isBoxOpen('mailBox')) {
      MailService.syncMailsFromServer();
    }
  }

  // =================================================================
  // 2. ĐẨY NHẬT KÝ BÁO THỨC OFFLINE LÊN SERVER
  // =================================================================
  static Future<void> _syncAlarmLogs(SharedPreferences prefs) async {
    List<String> pendingLogs = prefs.getStringList('pending_reward_logs') ?? [];
    if (pendingLogs.isEmpty) return;

    appLog(
        "🔄 [OfflineSyncService] Đang đẩy ${pendingLogs.length} logs tắt báo thức lên Server...");
    final response = await _supabase.rpc(
      'sync_offline_alarms',
      params: {'log_timestamps': pendingLogs},
    );
    appLog(
        "✅ [OfflineSyncService] Server duyệt xong báo thức offline! Vé thực tế cộng: $response");
    await prefs.setStringList('pending_reward_logs', []);
  }
}
