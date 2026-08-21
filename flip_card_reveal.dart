import 'dart:math' as math;
import 'package:flutter/material.dart';

class FlipCardReveal extends StatefulWidget {
  final Widget
      frontWidget; // Mặt trước của thẻ (AnimatedRarityCard hoặc thẻ thường)
  final Widget backWidget; // Mặt sau của thẻ (Lưng bài úp)
  final bool isHighRank; // Có phải rank A, SR, SR++ không?
  final int
      delayMillis; // Thời gian chờ để tạo hiệu ứng gợn sóng (khi bấm Lật Tất Cả)
  final bool triggerReveal; // Lệnh kích hoạt lật từ nút "Lật Tất Cả"
  final VoidCallback?
      onRevealCompleted; // Callback báo về màn hình cha khi lật xong hoàn toàn

  const FlipCardReveal({
    super.key,
    required this.frontWidget,
    required this.backWidget,
    required this.isHighRank,
    this.delayMillis = 0,
    required this.triggerReveal,
    this.onRevealCompleted,
  });

  @override
  State<FlipCardReveal> createState() => _FlipCardRevealState();
}

class _FlipCardRevealState extends State<FlipCardReveal>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  bool _isRevealed = false;
  bool _showBurst = false;

  @override
  void initState() {
    super.initState();
    // Thẻ xịn lật chậm hơn (2200ms) để tạo độ "nặng" và hype, thẻ thường lật nhanh (1200ms)
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.isHighRank ? 2200 : 1200),
    );

    // 1 vòng = 2*pi. Xoay 3.5 vòng = 7 * pi (để mặt cuối cùng dừng lại là mặt trước)
    _animation = Tween<double>(begin: 0, end: 7 * math.pi).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
      ),
    );

    // Lắng nghe quá trình lật để kích hoạt chớp sáng cho thẻ Xịn
    _controller.addListener(() {
      // Khi lật qua mốc 90 độ (pi/2) -> bắt đầu chớp sáng
      if (widget.isHighRank && _controller.value >= 0.5 && !_showBurst) {
        if (!mounted) return;
        setState(() => _showBurst = true);

        // Tắt chớp sáng sau 600ms để lộ ra thẻ
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) setState(() => _showBurst = false);
        });
      }
    });

    // Lắng nghe trạng thái hoàn thành animation (Tránh rò rỉ bộ nhớ & kiểm tra mount an toàn)
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (mounted) {
          widget.onRevealCompleted?.call();
        }
      }
    });
  }

  // Lắng nghe lệnh "Lật Tất Cả" từ bên ngoài truyền vào
  @override
  void didUpdateWidget(FlipCardReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.triggerReveal && !oldWidget.triggerReveal && !_isRevealed) {
      _startRevealSequence();
    }
  }

  void _startRevealSequence() async {
    if (_isRevealed) return;
    _isRevealed = true;

    // Chờ theo thứ tự truyền vào để tạo dải sóng lật bài
    await Future.delayed(Duration(milliseconds: widget.delayMillis));
    // ĐẶC QUYỀN THẺ XỊN: Khựng lại 500ms tạo sự hồi hộp trước khi lật
    if (widget.isHighRank && mounted) {
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (mounted) _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose(); // Tự động hủy cả StatusListener đi kèm
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _startRevealSequence,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          final angle = _animation.value;
          final double normalizedAngle = angle % (2 * math.pi);
          final isFrontVisible = normalizedAngle > (math.pi / 2) &&
              normalizedAngle < (3 * math.pi / 2);

          return Stack(
            fit: StackFit.expand,
            children: [
              // LỚP 1: THẺ BÀI XOAY 3D
              Transform(
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001) // Hack tỷ lệ phối cảnh 3D
                  ..rotateY(angle),
                alignment: Alignment.center,
                child: isFrontVisible
                    ? Transform(
                        // Lật ngược lại mặt trước 180 độ để chữ/ảnh không bị soi gương
                        transform: Matrix4.identity()..rotateY(math.pi),
                        alignment: Alignment.center,
                        child: widget.frontWidget,
                      )
                    : widget.backWidget,
              ),

              // LỚP 2: HIỆU ỨNG CHỚP SÁNG VÀNG HOÀNG KIM (Chỉ thẻ xịn)
              if (isFrontVisible && widget.isHighRank)
                IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _showBurst ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.amber.withValues(alpha: 0.8),
                            blurRadius: 40,
                            spreadRadius: 10,
                          )
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
