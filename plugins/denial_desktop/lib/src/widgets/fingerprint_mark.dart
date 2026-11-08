import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/tokens.dart';

/// Marks the fingerprint sensor whenever the reader listens for someone: the
/// lock screen, the ambient display or an application that asked for a
/// fingerprint. On an under-display sensor the ring sits on the sensor,
/// otherwise near the bottom edge. Red while the reader is not listening,
/// after a rejected scan or while it re-arms, so the user waits for white.
class FingerprintMark extends ConsumerStatefulWidget {
  const FingerprintMark({super.key});

  @override
  ConsumerState<FingerprintMark> createState() => _FingerprintMarkState();
}

class _FingerprintMarkState extends ConsumerState<FingerprintMark>
    with TickerProviderStateMixin {
  late final AnimationController _present = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  /// 1 white, 0 red: it turns red at once and back to white gently.
  late final AnimationController _ready = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 90),
  );

  late final AnimationController _scanning = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    reverseDuration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    final authentication = ref.read(authenticationProvider);
    _present.value = _shown(authentication) ? 1.0 : 0.0;
    _ready.value = authentication.fingerprintAvailable ? 1.0 : 0.0;
    _scanning.value = authentication.fingerprintScanning ? 1.0 : 0.0;
  }

  static bool _shown(AuthenticationState authentication) =>
      authentication.fingerprintReader && authentication.fingerprintWanted;

  void _animate(AnimationController controller, bool on) {
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.value = on ? 1.0 : 0.0;
    } else if (on) {
      controller.forward();
    } else {
      controller.reverse();
    }
  }

  @override
  void dispose() {
    _present.dispose();
    _ready.dispose();
    _scanning.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthenticationState>(authenticationProvider, (previous, next) {
      if (previous == null || _shown(previous) != _shown(next)) {
        _animate(_present, _shown(next));
      }
      if (previous?.fingerprintAvailable != next.fingerprintAvailable) {
        _animate(_ready, next.fingerprintAvailable);
      }
      if (previous?.fingerprintScanning != next.fingerprintScanning) {
        _animate(_scanning, next.fingerprintScanning);
      }
    });
    final sensor = ref.watch(
      authenticationProvider.select((state) => state.fingerprintSensor),
    );
    return IgnorePointer(
      child: CustomPaint(
        painter: _FingerprintMarkPainter(
          present: _present,
          ready: _ready,
          scanning: _scanning,
          sensor: sensor,
        ),
      ),
    );
  }
}

class _FingerprintMarkPainter extends CustomPainter {
  _FingerprintMarkPainter({
    required this.present,
    required this.ready,
    required this.scanning,
    required this.sensor,
  }) : super(repaint: Listenable.merge([present, ready, scanning]));

  final Animation<double> present;
  final Animation<double> ready;
  final Animation<double> scanning;

  /// Panel fractions in the panel's native orientation.
  final Rect? sensor;

  static const double _radius = 13.0;
  static const double _stroke = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = present.value;
    if (alpha <= 0.0) {
      return;
    }
    final sensor = this.sensor;
    // Sensor fractions follow the panel's native portrait orientation; in
    // landscape the mark falls back to the bottom edge.
    final center = sensor != null && size.height >= size.width
        ? Offset(sensor.center.dx * size.width, sensor.center.dy * size.height)
        : Offset(size.width / 2, size.height * 0.88);
    final ink = Color.lerp(
      ShellTelemetryColors.danger,
      ShellMediaColors.lightForeground,
      ready.value,
    )!;
    canvas.drawCircle(
      center,
      _radius * (1.0 + 0.35 * scanning.value),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = ink.withValues(alpha: 0.92 * alpha),
    );
  }

  @override
  bool shouldRepaint(covariant _FingerprintMarkPainter oldDelegate) =>
      oldDelegate.present != present ||
      oldDelegate.ready != ready ||
      oldDelegate.scanning != scanning ||
      oldDelegate.sensor != sensor;
}
