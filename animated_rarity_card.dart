import 'package:flutter/material.dart';

class AnimatedRarityCard extends StatefulWidget {
  final String rank;
  final Widget child;
  final bool isOwned;
  final String borderImageUrl;

  const AnimatedRarityCard({
    super.key,
    required this.rank,
    required this.child,
    required this.isOwned,
    required this.borderImageUrl,
  });

  @override
  State<AnimatedRarityCard> createState() => _AnimatedRarityCardState();
}

class _AnimatedRarityCardState extends State<AnimatedRarityCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4700),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isOwned) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: const Color(0xFF2C2C3E),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              Opacity(
                  opacity: 0.35,
                  child: Image.asset(widget.borderImageUrl, fit: BoxFit.fill)),
            ],
          ),
        ),
      );
    }

    if (widget.rank == 'SR++' || widget.rank == 'SR') {
      const ColorFilter luminanceToAlpha = ColorFilter.matrix(<double>[
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0.33,
        0.33,
        0.33,
        0,
        0,
      ]);

      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: const Color(0xFF2C2C3E),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                widget.child,
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) {
                        final slideOffset = _controller.value * 2.0 - 0.5;

                        return ShaderMask(
                          blendMode: BlendMode.srcIn,
                          shaderCallback: (bounds) {
                            return LinearGradient(
                              begin: Alignment(
                                  slideOffset - 1.2, slideOffset - 1.2),
                              end: Alignment(
                                  slideOffset + 1.2, slideOffset + 1.2),
                              colors: const [
                                Colors.transparent,
                                Color(0x8880DEEA),
                                Color(0x88F48FB1),
                                Color(0xCCFFFFFF),
                                Color(0x88FFF59D),
                                Color(0x8880DEEA),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.2, 0.4, 0.5, 0.6, 0.8, 1.0],
                            ).createShader(bounds);
                          },
                          child: ColorFiltered(
                            colorFilter: luminanceToAlpha,
                            child: Image.asset(
                              'assets/images/effects/shattered_mask.webp',
                              fit: BoxFit.cover,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Image.asset(widget.borderImageUrl, fit: BoxFit.fill),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF2C2C3E),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            Image.asset(widget.borderImageUrl, fit: BoxFit.fill),
          ],
        ),
      ),
    );
  }
}
