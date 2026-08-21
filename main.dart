import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/character.dart';
import 'screens/gacha_screen.dart';
import 'screens/ringing_screen.dart';
import 'screens/root_boot_screen.dart';
import 'services/alarm_service.dart';
import 'services/database_service.dart';
import 'services/notification_service.dart';
import 'services/purchase_service.dart';
import 'utils/logger.dart';
import 'utils/navigator_key.dart';
import 'services/isolate_manager_service.dart';
import 'services/navigation_service.dart';
import 'services/auth_service.dart';
import 'services/app_migration_service.dart';
import 'services/alarm_sync_service.dart';
import 'services/alarm_snapshot_service.dart';
import 'services/ringing_reward_service.dart';
import 'services/wearable_sync_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  // Khởi tạo kênh giao tiếp Isolate bất tử
  IsolateManagerService().initialize();

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  bool isRinging = prefs.getBool('isRinging') ?? false;

  // Xử lý báo thức bị "kẹt" (Stale Alarm)
  if (isRinging) {
    final int lastTrigger = prefs.getInt('last_trigger_time') ?? 0;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final bool isStale =
        (nowMs - lastTrigger) > 5 * 60 * 1000; // 300 giây (5 phút)

    if (isStale) {
      appLog("🔄 [Main] Phát hiện stale alarm. Tự động phục hồi...");
      await prefs.setBool('isRinging', false);
      await prefs.remove('ringing_alarm_id');
      await prefs.setBool('force_sync_alarms_next_boot', true);
      isRinging = false; // Tiếp tục luồng boot bình thường
    }
  }

  await DatabaseService.init(isFastBoot: isRinging);

  if (isRinging) {
    await _bootRingingLuong(prefs);
  } else {
    await _bootNormalLuong(prefs);
  }
}

// =========================================================================
// LUỒNG 1: BOOT REO CHUÔNG (Giữ nguyên tối đa logic ưu tiên RingingScreen)
// =========================================================================
Future<void> _bootRingingLuong(SharedPreferences prefs) async {
  appLog("⚡ [Ultra-Fast Boot] Đang reo chuông. Nạp giao diện ưu tiên...");

  // Ghi timestamp "engine sẵn sàng"
  await prefs.setInt('engine_ready_ts', DateTime.now().millisecondsSinceEpoch);

  String initialDialogue = "";
  GachaCharacter? initialPartner;

  // === PHASE 1: Chuẩn bị dữ liệu (có thể fail, có fallback) ===
  try {
    await EasyLocalization.ensureInitialized();
  } catch (e) {
    appLog("⚠️ [BootRinging] Lỗi EasyLocalization: $e");
  }

  // KHÔNG AWAIT: Tránh block luồng UI
  AlarmService.initialize().catchError((e) {
    appLog(
        "⚠️ [BootRinging] AlarmService.init thất bại (không nghiêm trọng): $e");
  });

  try {
    await Supabase.initialize(
      url: dotenv.env['SUPABASE_URL']!,
      anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
    );
  } catch (e) {
    appLog("⚠️ Lỗi init Supabase: $e");
  }

  // 1. Đọc dữ liệu đã chốt từ Snapshot
  final rawSnapshot = prefs.getString('alarm_snapshot');
  if (rawSnapshot != null) {
    try {
      final snapshot = jsonDecode(rawSnapshot) as Map<String, dynamic>;
      initialDialogue = snapshot['fallback_body']?.toString() ?? "";

      final int? ringingAlarmId = prefs.getInt('ringing_alarm_id');
      if (ringingAlarmId != null) {
        int snoozeCount = prefs.getInt('snooze_count_$ringingAlarmId') ?? 0;
        String eventType = AlarmSnapshotService.eventTypeForSnoozeCount(snoozeCount);
        String? d3Dialogue = AlarmSnapshotService.findRingingDialogue(snapshot, ringingAlarmId, eventType);
        if (d3Dialogue != null) {
          initialDialogue = d3Dialogue;
        }
      }

      final String? snapshotPartnerId = snapshot['partner_id']?.toString();
      if (snapshotPartnerId != null && snapshotPartnerId.isNotEmpty) {
        initialPartner =
            Hive.box<GachaCharacter>('characterBox').get(snapshotPartnerId);
        if (initialPartner == null) {
          appLog(
              "⚠️ [BootRinging] Snapshot có partner_id='$snapshotPartnerId' nhưng characterBox không có, fallback sau.");
        }
      }
    } catch (e) {
      appLog("⚠️ [BootRinging] Lỗi parse snapshot: $e");
    }
  }

  // 2. Nếu snapshot không có / lỗi -> fallback về SharedPreferences
  if (initialPartner == null) {
    final fallbackPartnerId = prefs.getString('current_partner_id') ?? '';
    if (fallbackPartnerId.isNotEmpty) {
      initialPartner =
          Hive.box<GachaCharacter>('characterBox').get(fallbackPartnerId);
    }
  }

  // 3. Fallback cuối cùng
  if (initialDialogue.isEmpty) {
    initialDialogue = prefs.getString('ringing_d3_message') ?? "";
  }

  // KHÔNG AWAIT
  NotificationService.initialize(prefs).catchError((e) {
    appLog(
        "⚠️ [BootRinging] NotificationService.init thất bại (không nghiêm trọng): $e");
  });

  // [FIX CRITICAL BUG] Auto pre-schedule next alarm
  try {
    final int? ringingAlarmId = prefs.getInt('ringing_alarm_id');
    if (ringingAlarmId != null) {
      Future.microtask(() async {
        await AlarmSyncService.autoPreScheduleNextCycle(ringingAlarmId);
      });
    }
  } catch (e) {
    appLog("⚠️ Lỗi pre-schedule: $e");
  }

  // === PHASE 2: LUÔN CHẠY DÙ PHASE 1 CÓ LỖI ===
  runApp(
    EasyLocalization(
      supportedLocales: const [
        Locale('en'),
        Locale('vi'),
        Locale('ja'),
        Locale('ko'),
        Locale('zh'),
        Locale('fr'),
        Locale('de'),
        Locale('es')
      ],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      useOnlyLangCode: true,
      child: GachaAlarmApp(
        isLoggedIn: true,
        isFirstTime: false,
        hasProfile: true,
        isRingingAtLaunch: true,
        initialDialogue: initialDialogue,
        initialPartner: initialPartner,
      ),
    ),
  );
}

// =========================================================================
// LUỒNG 2: BOOT BÌNH THƯỜNG (Lazy Boot - Trả UI ngay lập tức)
// =========================================================================
Future<void> _bootNormalLuong(SharedPreferences prefs) async {
  appLog(
      "🏠 [Normal Boot] Người dùng mở app. Nạp nhanh khung giao diện đệm...");

  AlarmService.initialize().catchError((e) {
    appLog("⚠️ [NormalBoot] AlarmService.init thất bại: $e");
  });

  try {
    await EasyLocalization.ensureInitialized();
  } catch (e) {
    appLog("⚠️ Lỗi EasyLocalization (Normal Boot): $e");
  }

  Future.microtask(() => PurchaseService.init());
  final bool isFirstTime = prefs.getBool('isFirstTime') ?? true;

  // Luôn đảm bảo runApp được gọi để tránh đen màn hình
  runApp(
    EasyLocalization(
      supportedLocales: const [
        Locale('en'),
        Locale('vi'),
        Locale('ja'),
        Locale('ko'),
        Locale('zh'),
        Locale('fr'),
        Locale('de'),
        Locale('es')
      ],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      useOnlyLangCode: true,
      useFallbackTranslations: true,
      child: GachaAlarmApp(
        isLoggedIn: false,
        isFirstTime: isFirstTime,
        hasProfile: false,
        isRingingAtLaunch: false,
      ),
    ),
  );
}

class GachaAlarmApp extends StatefulWidget {
  final bool isLoggedIn;
  final bool isFirstTime;
  final bool hasProfile;
  final bool isRingingAtLaunch;
  final String? initialDialogue;
  final GachaCharacter? initialPartner;

  const GachaAlarmApp({
    super.key,
    required this.isLoggedIn,
    required this.isFirstTime,
    required this.hasProfile,
    required this.isRingingAtLaunch,
    this.initialDialogue,
    this.initialPartner,
  });

  @override
  State<GachaAlarmApp> createState() => _GachaAlarmAppState();
}

class _GachaAlarmAppState extends State<GachaAlarmApp>
    with WidgetsBindingObserver {
  bool _openedFromNoti = false;
  bool _isRinging = false;
  StreamSubscription? _notiSubscription;
  RealtimeChannel? _kickChannel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isRinging = widget.isRingingAtLaunch;
    _checkNotiFlag();

    // 1. Lắng nghe các sự kiện tương tác thông báo mới khi app đang chạy
    _notiSubscription = NotificationService.onEvent.listen((event) {
      if (event.startsWith('ALARM_COMMAND_')) {
        if (mounted) {
          setState(() {
            _isRinging = false;
          });
        }
        return;
      }
      NavigationService.handleNotificationEvent(event);
    });

    // 2. BỔ SUNG CHIẾN LƯỢC: Xử lý sự kiện tồn đọng từ Cold Start an toàn
    final cachedEvent = NotificationService.consumeCachedEvent();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (cachedEvent != null) {
        NavigationService.handleNotificationEvent(cachedEvent);
      }
      // DRAIN pending rewards on cold start when UI is ready
      RingingRewardService.drainPendingWearableRewards(context);
      WearableSyncService.drainPendingWearEvents();
    });

    _setupSessionKickRadar();
  }

  Future<void> _setupSessionKickRadar() async {
    if (!widget.isLoggedIn) return;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final prefs = await SharedPreferences.getInstance();
    final localDeviceId = prefs.getString('local_device_id');
    if (localDeviceId == null) return;

    _kickChannel = Supabase.instance.client
        .channel('device_kick_${user.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'user_profiles',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'id', value: user.id),
          callback: (payload) {
            final newDeviceId = payload.newRecord['current_device_id'];
            if (newDeviceId != null && newDeviceId != localDeviceId) {
              appLog(
                  "🚨 [RealtimeRadar] Thiết bị khác đã đăng nhập! ID mới: $newDeviceId. Thực thi Kick-out.");
              AuthService.forceLogoutAndKick();
            }
          },
        );

    _kickChannel?.subscribe();
  }

  Future<void> _checkNotiFlag() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final bool currentRinging = prefs.getBool('isRinging') ?? false;
    final bool fromNoti = prefs.getBool('opened_from_reward_noti') ?? false;

    if (fromNoti) {
      await prefs.setBool('opened_from_reward_noti', false);
    }

    try {
      if (!currentRinging && fromNoti) {
        await DatabaseService.openAllBoxes();
      }
    } catch (e) {
      appLog("⚠️ [GachaAlarmApp] Lỗi mở hộp đệm trong checkNotiFlag: $e");
    }

    if (!mounted) return;
    setState(() {
      _isRinging = currentRinging;
      _openedFromNoti = fromNoti;
    });
  }

  @override
  void dispose() {
    // Ngắt kết nối bộ thu khi app bị hủy để chống rò rỉ bộ nhớ
    _notiSubscription?.cancel();
    _kickChannel?.unsubscribe();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkNotiFlag();
      RingingRewardService.drainPendingWearableRewards(context);
      WearableSyncService.drainPendingWearEvents();
    }
  }

  Widget getStartScreen() {
    if (_isRinging) {
      return RingingScreen(
        initialDialogue: widget.initialDialogue ?? "",
        initialPartner: widget.initialPartner,
        onExit: () {
          if (!mounted) return;
          setState(() {
            _isRinging = false;
          });
        },
      );
    }

    if (_openedFromNoti) return const GachaScreen();

    return RootBootScreen(isFirstTime: widget.isFirstTime);
  }

  List<String> _getDynamicFallback(Locale locale) {
    if (locale.languageCode == 'ja') return ['DotGothic16'];
    if (locale.languageCode == 'ko') return ['DungGeunMo'];
    if (locale.languageCode == 'zh') {
      final osLocale = WidgetsBinding.instance.platformDispatcher.locale;
      if (osLocale.countryCode == 'TW' ||
          osLocale.countryCode == 'HK' ||
          osLocale.countryCode == 'MO') {
        return ['Cubic_11'];
      }
      return ['Zpix'];
    }
    return ['DotGothic16', 'DungGeunMo', 'Cubic_11', 'Zpix'];
  }

  @override
  Widget build(BuildContext context) {
    final currentFallback = _getDynamicFallback(context.locale);
    return MaterialApp(
      navigatorKey: navigatorKey,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      title: 'Gacha Alarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.amber,
        scaffoldBackgroundColor: const Color(0xFF1E1E2C),
        textTheme: ThemeData.dark()
            .textTheme
            .apply(
              fontFamily: 'MyPixelFont',
            )
            .copyWith(
              bodyMedium: TextStyle(
                fontFamily: 'MyPixelFont',
                fontFamilyFallback: currentFallback,
              ),
            ),
      ),
      home: getStartScreen(),
    );
  }
}
