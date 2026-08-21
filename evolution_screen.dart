import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:easy_localization/easy_localization.dart';
import 'dart:math' as math;

import '../models/character.dart';
import '../data/character_database.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_profile.dart';
import '../services/sync_service.dart';
import '../services/evolution_service.dart';
import '../services/alarm_snapshot_service.dart';
import '../utils/logger.dart';

class EvolutionScreen extends StatefulWidget {
  final String sourceId;
  final String targetId;
  final bool autoStart;

  const EvolutionScreen(
      {super.key, required this.sourceId, required this.targetId, this.autoStart = false});

  @override
  State<EvolutionScreen> createState() => _EvolutionScreenState();
}

class _EvolutionScreenState extends State<EvolutionScreen>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late AnimationController _pulseController;

  bool _isEvolving = false;
  bool _isEvolved = false;
  late bool _autoStartActive;

  @override
  void initState() {
    super.initState();
    _autoStartActive = widget.autoStart;
    // Tăng tổng thời gian lên 6.5 giây để chiêm ngưỡng trọn vẹn từng khoảnh khắc
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 6500));

    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.autoStart && mounted && !_isEvolving && !_isEvolved) {
        _handleEvolutionClick();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _pulseController.dispose();
    super.dispose();
  }


  Future<void> _handleEvolutionClick() async {
    if (_isEvolving) return;
    if (_isEvolved) {
      Navigator.popUntil(context, (route) => route.isFirst);
      return;
    }

    // 1. Kiểm tra điều kiện ngặt nghèo TRƯỚC khi gọi Hive.box
    if (!EvolutionService.validateEvolutionPreconditions(widget.sourceId, widget.targetId)) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('gacha_service.evolution_invalid_or_expired'.tr())));
      if (_autoStartActive) setState(() => _autoStartActive = false);
      return;
    }

    // 2. Khai báo 1 lần duy nhất trên cùng
    final characterBox = Hive.box<GachaCharacter>('characterBox');
    final profile = Hive.box<UserProfile>('userProfileBox').getAt(0);
    final sourceChar = characterBox.get(widget.sourceId);

    final targetData = CharacterDatabase.allCharacters
        .firstWhere((c) => c['id'] == widget.targetId, orElse: () => <String, dynamic>{});

    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;

    // 3. Chặn ngay nếu mất Session hoặc lỗi dữ liệu (Do bấm Noti trễ/sai)
    if (userId == null || profile == null || targetData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('gacha_service.sync_error'.tr())));
      if (_autoStartActive) setState(() => _autoStartActive = false);
      return;
    }

    if (sourceChar != null) {
      setState(() {
        _isEvolving = true;
      });

      final animationFuture = _controller.forward(); // Bắt đầu animation và lưu Future lại để chờ sau RPC

      // =========================================================
      // 🛡️ BƯỚC ROLLBACK 1: CHỤP LẠI BẢN SNAPSHOT TRƯỚC KHI SỬA
      // =========================================================
      final backupSourceChar = GachaCharacter(
        id: sourceChar.id,
        name: sourceChar.name,
        rank: sourceChar.rank,
        baseCp: sourceChar.baseCp,
        personalityTags: List.from(sourceChar.personalityTags),
        isAnimated: sourceChar.isAnimated,
        borderImageUrl: sourceChar.borderImageUrl,
        ringtoneFile: sourceChar.ringtoneFile,
        isUnlocked: sourceChar.isUnlocked,
        shardCount: sourceChar.shardCount,
      );

      final currentTarget = characterBox.get(widget.targetId);
      GachaCharacter? backupTargetChar;
      if (currentTarget != null) {
        backupTargetChar = GachaCharacter(
          id: currentTarget.id,
          name: currentTarget.name,
          rank: currentTarget.rank,
          baseCp: currentTarget.baseCp,
          personalityTags: List.from(currentTarget.personalityTags),
          isAnimated: currentTarget.isAnimated,
          borderImageUrl: currentTarget.borderImageUrl,
          ringtoneFile: currentTarget.ringtoneFile,
          isUnlocked: currentTarget.isUnlocked,
          shardCount: currentTarget.shardCount,
        );
      }

      final backupAffinity = Map<String, int>.from(profile.affinityScores);
      final backupUnlocked = List<String>.from(profile.unlockedCharacters);
      final backupCharacterShards = Map<String, int>.from(profile.characterShards);

      final prefs = await SharedPreferences.getInstance();
      final backupPartnerId = prefs.getString('current_partner_id');
      bool partnerChanged = false;

      try {
        // =========================================================
        // 1. XỬ LÝ LOGIC LOCAL: TIẾN HÓA MỚI HOẶC CỘNG DỒN 10%
        // =========================================================
        int newTargetCp = 0;
        int newTargetShard = 1;

        if (currentTarget != null) {
          // KỊCH BẢN A: ĐÃ SỞ HỮU THẺ TIẾN HÓA -> CỘNG 10% BONUS CP
          int bonusCp = (targetData['baseCp'] * 0.1).round();
          currentTarget.baseCp += bonusCp;
          currentTarget.shardCount += 1;
          await currentTarget.save();

          newTargetCp = currentTarget.baseCp;
          newTargetShard = currentTarget.shardCount;
        } else {
          // KỊCH BẢN B: CHƯA SỞ HỮU -> TẠO THẺ MỚI
          final newChar = GachaCharacter(
            id: targetData['id'],
            name: targetData['name'],
            rank: targetData['rank'],
            baseCp: targetData['baseCp'],
            personalityTags: List<String>.from(targetData['personalityTags']),
            isAnimated: targetData['isAnimated'],
            borderImageUrl: targetData['borderImageUrl'],
            ringtoneFile: targetData['ringtoneFile'],
            isUnlocked: true,
            shardCount: 1,
          );
          await characterBox.put(newChar.id, newChar);

          newTargetCp = newChar.baseCp;
          newTargetShard = newChar.shardCount;
        }

        // =========================================================
        // 2. XÓA LOCAL: HIẾN TẾ THẺ GỐC VÀ CẬP NHẬT PROFILE
        // =========================================================
        await characterBox.delete(widget.sourceId);

        // Cập nhật Profile Local
        profile.affinityScores.remove(widget.sourceId);
        if (currentTarget == null) {
          profile.affinityScores[widget.targetId] = 0;
        }

        profile.unlockedCharacters.remove(widget.sourceId);
        if (!profile.unlockedCharacters.contains(widget.targetId)) {
          profile.unlockedCharacters.add(widget.targetId);
        }

        profile.characterShards.remove(widget.sourceId);
        profile.characterShards[widget.targetId] = newTargetShard;

        await profile.save();

        // =========================================================
        // 3. CẬP NHẬT CURRENT PARTNER (NẾU CÓ) Ở SHAREDPREFERENCES
        // =========================================================
        if (backupPartnerId == widget.sourceId) {
          await prefs.setString('current_partner_id', widget.targetId);
          partnerChanged = true;
          appLog("♻️ Đã cập nhật Đối tác hiện tại từ ${widget.sourceId} sang ${widget.targetId}");
        }

        // =========================================================
        // 4. GIAO TIẾP VỚI ĐÁM MÂY QUA RPC ĐẢM BẢO ATOMICITY
        // =========================================================
        await supabase.rpc('process_evolution_transaction', params: {
          'p_source_char_id': widget.sourceId,
          'p_target_char_id': widget.targetId,
          'p_target_shard_count': newTargetShard,
          'p_target_current_cp': newTargetCp,
        });

        try {
          // 5. XÓA TRẠNG THÁI REJECT/IGNORE VÀ UPDATE SNAPSHOT SAU KHI RPC ĐÃ COMMIT
          await EvolutionService.clearRejectStatus(widget.sourceId, widget.targetId);
          if (partnerChanged) {
            await AlarmSnapshotService.updateSnapshot();
          }
        } catch (cleanupError) {
          appLog("⚠️ Tiến hóa thành công nhưng lỗi lúc dọn dẹp/cập nhật snapshot: $cleanupError");
        }
      } catch (e) {
        appLog("❌ Lỗi Tiến hóa (Cloud thất bại): $e");
        _controller.stop();
        _controller.reset();

        // =========================================================
        // 🛡️ BƯỚC ROLLBACK 2: PHỤC HỒI SNAPSHOT & ĐỒNG BỘ LẠI
        // =========================================================
        appLog("⚠️ Đang tiến hành Rollback khôi phục dữ liệu Local...");

        // Khôi phục thẻ gốc
        await characterBox.put(backupSourceChar.id, backupSourceChar);

        // Khôi phục thẻ đích về trạng thái cũ (hoặc xóa đi nếu trước đó chưa có)
        if (backupTargetChar != null) {
          await characterBox.put(backupTargetChar.id, backupTargetChar);
        } else {
          await characterBox.delete(widget.targetId);
        }

        // Khôi phục Profile
        profile.affinityScores = backupAffinity;
        profile.unlockedCharacters = backupUnlocked;
        profile.characterShards = backupCharacterShards;
        await profile.save();

        // Khôi phục Partner nếu đã lỡ đổi
        if (partnerChanged) {
          if (backupPartnerId != null) {
            await prefs.setString('current_partner_id', backupPartnerId);
          } else {
            await prefs.remove('current_partner_id');
          }
          await AlarmSnapshotService.updateSnapshot();
        }

        // Kích hoạt đồng bộ ngầm để đối chiếu lại với Server cho chắc chắn
        SyncService.syncCharactersAndCP().catchError((_) {});

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('gacha_service.sync_error'.tr())));
        }
        if (!mounted) return;
        setState(() {
          _isEvolving = false;
          _autoStartActive = false;
        });
        return;
      }

      try {
        await animationFuture;
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _isEvolving = false;
        _isEvolved = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Kích thước khu vực chòm sao được phóng to để bao trùm không gian
    final double constellationWidth = MediaQuery.of(context).size.width * 0.9;
    const double constellationHeight = 500.0;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F16),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('gacha_service.evolution_title'.tr(),
            style: const TextStyle(color: Colors.amber)),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  final double t = _controller.value;

                  // 1. THẺ GỐC MỜ DẦN (0.0 -> 0.1)
                  double sourceOpacity = 1.0;
                  if (t > 0.0 && t <= 0.1) {
                    sourceOpacity = 1.0 - (t / 0.1);
                  } else if (t > 0.1) {
                    sourceOpacity = 0.0;
                  }

                  // 2. VẼ CHÒM SAO RẤT CHẬM RÃI VÀ MA MỊ (0.1 -> 0.65)
                  double drawProgress = 0.0;
                  if (t > 0.1 && t <= 0.65) {
                    drawProgress = (t - 0.1) / 0.55;
                  } else if (t > 0.65) {
                    drawProgress = 1.0;
                  }

                  // 3. VẾT CHÉM LÓA SÁNG KHUNG HÌNH (0.65 -> 0.7)
                  double slashProgress = 0.0;
                  if (t > 0.65 && t <= 0.7) {
                    slashProgress = (t - 0.65) / 0.05; // Xẹt qua trong chớp mắt
                  } else if (t > 0.7) {
                    slashProgress = 1.0;
                  }

                  // 4. CHÒM SAO VỠ ĐÔI VÀ TAN BIẾN (0.7 -> 0.85)
                  double splitProgress = 0.0;
                  double splitOpacity = 1.0;
                  if (t > 0.7 && t <= 0.85) {
                    splitProgress = (t - 0.7) / 0.15;
                    splitOpacity = 1.0 - splitProgress;
                  } else if (t > 0.85) {
                    splitProgress = 1.0;
                    splitOpacity = 0.0;
                  }

                  // 5. THẺ MỚI GIÁNG LÂM TỪ VẾT NỨT KHÔNG GIAN (0.75 -> 1.0)
                  double targetOpacity = 0.0;
                  double targetScale = 0.8;
                  if (t > 0.75) {
                    double revealT = (t - 0.75) / 0.25;
                    targetOpacity = revealT.clamp(0.0, 1.0);
                    targetScale = Tween<double>(begin: 1.5, end: 1.0)
                        .transform(Curves.elasticOut.transform(revealT));
                  }

                  // Widget chứa chòm sao tĩnh (để phục vụ việc cắt đôi)
                  Widget constellationCanvas = RepaintBoundary(
                    child: SizedBox(
                      width: constellationWidth,
                      height: constellationHeight,
                      child: CustomPaint(
                        painter: ConstellationPainter(progress: drawProgress),
                      ),
                    ),
                  );

                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      // LỚP 1: THẺ GỐC TỪ TỪ CHÌM VÀO BÓNG TỐI
                      if (sourceOpacity > 0)
                        Opacity(
                          opacity: sourceOpacity,
                          child: _buildEnhancedCard(widget.sourceId,
                              isGlowing: false),
                        ),

                      // LỚP 2.1: NỬA TRÊN CỦA CHÒM SAO BỊ CHÉM ĐỨT (BAY LÊN TRÊN BÊN TRÁI)
                      if (drawProgress > 0 && splitOpacity > 0)
                        Opacity(
                          opacity: splitOpacity,
                          child: Transform.translate(
                            offset: Offset(
                                -50 * splitProgress, -50 * splitProgress),
                            child: ClipPath(
                              clipper: TopLeftClipper(),
                              child: constellationCanvas,
                            ),
                          ),
                        ),

                      // LỚP 2.2: NỬA DƯỚI CỦA CHÒM SAO BỊ CHÉM ĐỨT (BAY XUỐNG DƯỚI BÊN PHẢI)
                      if (drawProgress > 0 && splitOpacity > 0)
                        Opacity(
                          opacity: splitOpacity,
                          child: Transform.translate(
                            offset:
                                Offset(50 * splitProgress, 50 * splitProgress),
                            child: ClipPath(
                              clipper: BottomRightClipper(),
                              child: constellationCanvas,
                            ),
                          ),
                        ),

                      // LỚP 3: HIỆU ỨNG TIA CHỚP/VẾT CHÉM (THE SLASH)
                      if (slashProgress > 0 && splitProgress < 0.8)
                        Transform.rotate(
                          // Góc chém chéo từ góc trên bên phải xuống góc dưới bên trái
                          angle: math.atan2(
                              -constellationHeight, constellationWidth),
                          child: Opacity(
                            opacity:
                                1.0 - splitProgress, // Mờ dần khi vết cắt mở ra
                            child: Container(
                              width: 1000 * slashProgress, // Kéo dài cực nhanh
                              height: 6, // Độ mỏng của lưỡi kiếm
                              decoration: BoxDecoration(
                                color: Colors.white,
                                boxShadow: [
                                  BoxShadow(
                                      color:
                                          Colors.amberAccent.withOpacity(0.8),
                                      blurRadius: 20,
                                      spreadRadius: 8),
                                  BoxShadow(
                                      color: Colors.white,
                                      blurRadius: 10,
                                      spreadRadius: 3),
                                ],
                              ),
                            ),
                          ),
                        ),

                      // LỚP 4: THẺ NHÂN VẬT MỚI TỪ BÊN TRONG VẾT CHÉM PHÓNG RA
                      if (targetOpacity > 0)
                        Opacity(
                          opacity: targetOpacity,
                          child: Transform.scale(
                            scale: targetScale,
                            child: ScaleTransition(
                              scale:
                                  Tween<double>(begin: 1.0, end: 1.04).animate(
                                CurvedAnimation(
                                    parent: _pulseController,
                                    curve: Curves.easeInOut),
                              ),
                              child: _buildEnhancedCard(widget.targetId,
                                  isGlowing: true),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 80),
              if (!_autoStartActive || _isEvolved)
                ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isEvolving ? Colors.grey : Colors.amber,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 50, vertical: 18),
                  elevation: 8,
                ),
                onPressed: _isEvolving ? null : _handleEvolutionClick,
                child: Text(
                    _isEvolved
                        ? 'gacha_service.evolution_confirm'.tr()
                        : 'gacha_service.evolution_accept'.tr(),
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.black)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEnhancedCard(String characterId, {required bool isGlowing}) {
    return Stack(
      alignment: Alignment.center,
      children: [
        if (isGlowing)
          Container(
            width: 280,
            height: 380,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: Colors.amber[300]!.withOpacity(0.9),
                  blurRadius: 40,
                  spreadRadius: 15,
                  blurStyle: BlurStyle.outer,
                ),
              ],
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Container(
            width: 240 + 6,
            height: 340 + 6,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.amber[100]!,
                  Colors.amber[400]!,
                  Colors.amber[700]!,
                  Colors.amber[400]!,
                  Colors.amber[100]!,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: const [0.0, 0.2, 0.5, 0.8, 1.0],
              ),
            ),
          ),
        ),
        Container(
          width: 240,
          height: 340,
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2C),
            borderRadius: BorderRadius.circular(24),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Image.asset(
              'assets/images/characters/base/${characterId}_skin01.png',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
          ),
        ),
      ],
    );
  }
}

// =========================================================================
// CUSTOM CLIPPERS: DAO CẮT CHÒM SAO
// =========================================================================
class TopLeftClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.lineTo(size.width, 0); // Vẽ dọc theo cạnh trên
    path.lineTo(0, size.height); // Chém chéo xuống góc dưới trái
    path.close(); // Trở về gốc tạo thành tam giác trên
    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}

class BottomRightClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.moveTo(size.width, 0); // Bắt đầu ở góc trên phải
    path.lineTo(size.width, size.height); // Kéo xuống dưới cùng bên phải
    path.lineTo(0, size.height); // Kéo qua trái cùng bên dưới
    path.close(); // Trở về vị trí bắt đầu tạo thành tam giác dưới
    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}

// =========================================================================
// CUSTOM PAINTER: HIỆU ỨNG CHÒM SAO ĐÃ ĐƯỢC PHÓNG TO
// =========================================================================
class ConstellationPainter extends CustomPainter {
  final double progress;
  ConstellationPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.amberAccent.withOpacity(0.6)
      ..strokeWidth = 2.0 // Làm nét vẽ đậm hơn một chút
      ..style = PaintingStyle.stroke;

    final starPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final glowPaint = Paint()
      ..color = Colors.amber.withOpacity(0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0);

    final random = math.Random(42);
    final List<Offset> points = [];
    for (int i = 0; i < 40; i++) {
      // Phân bổ 40 điểm neo phủ khắp vùng vẽ rộng lớn
      double dx = 10 + random.nextDouble() * (size.width - 20);
      double dy = 10 + random.nextDouble() * (size.height - 20);
      points.add(Offset(dx, dy));
    }

    final int totalLines = points.length - 1;
    final double linesToDraw = progress * totalLines;
    final int currentLineIndex = linesToDraw.floor();

    for (int i = 0; i <= currentLineIndex; i++) {
      if (i >= totalLines) break;

      final p1 = points[i];
      final p2 = points[i + 1];

      if (i == currentLineIndex) {
        final segmentProgress = linesToDraw - currentLineIndex;
        final currentP2 = Offset(
          p1.dx + (p2.dx - p1.dx) * segmentProgress,
          p1.dy + (p2.dy - p1.dy) * segmentProgress,
        );
        canvas.drawLine(p1, currentP2, linePaint);
      } else {
        canvas.drawLine(p1, p2, linePaint);

        if (i % 4 == 0 && i + 3 < points.length) {
          canvas.drawLine(p1, points[i + 3],
              linePaint..color = Colors.amber.withOpacity(0.2));
        }
      }
    }

    for (int i = 0; i <= currentLineIndex + 1; i++) {
      if (i >= points.length) break;

      canvas.drawCircle(points[i], 5.0, glowPaint);
      canvas.drawCircle(points[i], 2.0, starPaint);
    }
  }

  @override
  bool shouldRepaint(covariant ConstellationPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
