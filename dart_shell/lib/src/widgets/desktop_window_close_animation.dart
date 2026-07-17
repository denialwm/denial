import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../state/desktop_window_close_effect.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Plays a desktop window's terminal visual without retaining native input.
///
/// [child] contains the compositor-leased final external texture until
/// [onCompleted] reports that this terminal visual has finished.
class DesktopWindowCloseAnimation extends StatefulWidget {
  const DesktopWindowCloseAnimation({
    super.key,
    required this.effect,
    required this.seed,
    required this.onCompleted,
    required this.child,
  });

  final DesktopWindowCloseEffect effect;
  final int seed;
  final VoidCallback onCompleted;
  final Widget child;

  @override
  State<DesktopWindowCloseAnimation> createState() =>
      _DesktopWindowCloseAnimationState();
}

class _DesktopWindowCloseAnimationState
    extends State<DesktopWindowCloseAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late List<_ExplosionParticle> _particles;
  bool _started = false;
  bool _completionReported = false;

  @override
  void initState() {
    super.initState();
    _particles = _buildParticles(widget.seed);
    _controller = AnimationController(
      vsync: this,
      duration: _durationFor(widget.effect),
      animationBehavior: AnimationBehavior.preserve,
    )..addStatusListener(_handleStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.duration = Duration.zero;
    }
    _controller.forward();
  }

  @override
  void didUpdateWidget(covariant DesktopWindowCloseAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.seed != oldWidget.seed) {
      _particles = _buildParticles(widget.seed);
    }
  }

  @override
  void dispose() {
    _controller
      ..removeStatusListener(_handleStatus)
      ..dispose();
    super.dispose();
  }

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _completionReported) {
      return;
    }
    _completionReported = true;
    widget.onCompleted();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _controller,
            child: widget.child,
            builder: (context, child) {
              final progress = _controller.value;
              final transform = _windowTransform(widget.effect, progress);
              return CustomPaint(
                key: ValueKey<String>(
                  'desktop-window-close-${widget.effect.name}',
                ),
                painter: widget.effect == DesktopWindowCloseEffect.explosion
                    ? _ExplosionPainter(
                        progress: progress,
                        particles: _particles,
                      )
                    : null,
                foregroundPainter:
                    widget.effect == DesktopWindowCloseEffect.explosion
                        ? _ExplosionParticlePainter(
                            progress: progress,
                            particles: _particles,
                          )
                        : null,
                child: Opacity(
                  opacity: transform.opacity,
                  child: Transform.rotate(
                    angle: transform.rotation,
                    child: Transform.scale(
                      scale: transform.scale,
                      child: child,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

Duration _durationFor(DesktopWindowCloseEffect effect) {
  return switch (effect) {
    DesktopWindowCloseEffect.explosion => Motion.desktopWindowCloseExplosion,
    DesktopWindowCloseEffect.implode => Motion.desktopWindowCloseImplode,
    DesktopWindowCloseEffect.fade => Motion.desktopWindowCloseFade,
    DesktopWindowCloseEffect.none => Duration.zero,
  };
}

({double opacity, double rotation, double scale}) _windowTransform(
  DesktopWindowCloseEffect effect,
  double progress,
) {
  switch (effect) {
    case DesktopWindowCloseEffect.explosion:
      final vanish = interval(progress, 0.10, 0.38);
      final eased = Motion.md3EmphasizedAccelerate.transform(vanish);
      final punch = math.sin(interval(progress, 0.0, 0.13) * math.pi) * 0.025;
      return (
        opacity: 1.0 - eased,
        rotation: -0.012 * eased,
        scale: 1.0 + punch - 0.18 * eased,
      );
    case DesktopWindowCloseEffect.implode:
      final eased = Curves.easeInBack.transform(progress);
      return (
        opacity: 1.0 - interval(progress, 0.56, 1.0),
        rotation: 0.035 * eased,
        scale: math.max(0.02, 1.0 - 0.98 * eased),
      );
    case DesktopWindowCloseEffect.fade:
      final eased = Motion.md3EmphasizedAccelerate.transform(progress);
      return (
        opacity: 1.0 - eased,
        rotation: 0.0,
        scale: 1.0 - 0.045 * eased,
      );
    case DesktopWindowCloseEffect.none:
      return (opacity: 0.0, rotation: 0.0, scale: 1.0);
  }
}

class _ExplosionPainter extends CustomPainter {
  const _ExplosionPainter({
    required this.progress,
    required this.particles,
  });

  final double progress;
  final List<_ExplosionParticle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final center = size.center(Offset.zero);
    final shortestSide = math.min(size.width, size.height);
    final flash = 1.0 - interval(progress, 0.0, 0.24);
    if (flash > 0.0) {
      final radius = shortestSide * (0.10 + progress * 0.58);
      final glow = Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            ShellColors.textPrimary.withValues(alpha: flash * 0.72),
            ShellColors.performanceWarning.withValues(alpha: flash * 0.48),
            ShellColors.accent.withValues(alpha: flash * 0.20),
            ShellColors.accent.withValues(alpha: 0.0),
          ],
          stops: const <double>[0.0, 0.20, 0.52, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, glow);
    }

    final shockwave = interval(progress, 0.04, 0.58);
    if (shockwave > 0.0 && shockwave < 1.0) {
      final eased = Curves.easeOutCubic.transform(shockwave);
      canvas.drawCircle(
        center,
        shortestSide * (0.09 + eased * 0.64),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.0 * (1.0 - shockwave) + 0.8
          ..color = ShellColors.accent.withValues(
            alpha: 0.65 * (1.0 - shockwave),
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ExplosionPainter oldDelegate) {
    return progress != oldDelegate.progress ||
        particles != oldDelegate.particles;
  }
}

class _ExplosionParticlePainter extends CustomPainter {
  const _ExplosionParticlePainter({
    required this.progress,
    required this.particles,
  });

  final double progress;
  final List<_ExplosionParticle> particles;

  static const List<Color> _palette = <Color>[
    ShellColors.textPrimary,
    ShellColors.accent,
    ShellColors.performanceWarning,
    ShellColors.performanceBad,
    ShellColors.gestureArmed,
    ShellColors.surfaceContainerHighest,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final center = size.center(Offset.zero);
    final travelScale =
        math.min(220.0, math.max(96.0, size.shortestSide * 0.54));

    for (var index = 0; index < particles.length; index += 1) {
      final particle = particles[index];
      final local = interval(progress, particle.delay, 1.0);
      if (local <= 0.0 || local >= 1.0) {
        continue;
      }
      final travel = Curves.easeOutCubic.transform(local);
      final gravity = local * local * travelScale * 0.34;
      final start = Offset(
        particle.x * size.width,
        particle.y * size.height,
      );
      final radial = start - center;
      final radialDistance = radial.distance;
      final direction = radialDistance < 0.001
          ? Offset.fromDirection(particle.angle)
          : radial / radialDistance;
      final jitter = Offset.fromDirection(particle.angle) * 0.34;
      final velocity = direction + jitter;
      final position = start +
          velocity * (travelScale * particle.speed * travel) +
          Offset(0.0, gravity);
      final opacity = math.sin(local * math.pi).clamp(0.0, 1.0);
      final color = _palette[index % _palette.length]
          .withValues(alpha: opacity * particle.opacity);
      final width = particle.size * (1.0 - local * 0.28);
      final height = width * particle.aspect;

      canvas.save();
      canvas.translate(position.dx, position.dy);
      canvas.rotate(particle.rotation + particle.spin * travel);
      final paint = Paint()..color = color;
      if (particle.round) {
        canvas.drawCircle(Offset.zero, width * 0.45, paint);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: width,
              height: height,
            ),
            Radius.circular(width * 0.18),
          ),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ExplosionParticlePainter oldDelegate) {
    return progress != oldDelegate.progress ||
        particles != oldDelegate.particles;
  }
}

class _ExplosionParticle {
  const _ExplosionParticle({
    required this.x,
    required this.y,
    required this.angle,
    required this.speed,
    required this.size,
    required this.aspect,
    required this.delay,
    required this.rotation,
    required this.spin,
    required this.opacity,
    required this.round,
  });

  final double x;
  final double y;
  final double angle;
  final double speed;
  final double size;
  final double aspect;
  final double delay;
  final double rotation;
  final double spin;
  final double opacity;
  final bool round;
}

List<_ExplosionParticle> _buildParticles(int seed) {
  final random = math.Random(seed);
  return List<_ExplosionParticle>.generate(88, (index) {
    final column = index % 11;
    final row = index ~/ 11;
    return _ExplosionParticle(
      x: ((column + 0.25 + random.nextDouble() * 0.5) / 11.0).clamp(0.04, 0.96),
      y: ((row + 0.20 + random.nextDouble() * 0.6) / 8.0).clamp(0.04, 0.96),
      angle: random.nextDouble() * math.pi * 2.0,
      speed: 0.42 + random.nextDouble() * 0.90,
      size: 3.0 + random.nextDouble() * 8.0,
      aspect: 0.45 + random.nextDouble() * 1.7,
      delay: 0.04 + random.nextDouble() * 0.15,
      rotation: random.nextDouble() * math.pi,
      spin: (random.nextDouble() - 0.5) * math.pi * 3.6,
      opacity: 0.72 + random.nextDouble() * 0.28,
      round: index % 5 == 0,
    );
  }, growable: false);
}
