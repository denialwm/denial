part of 'lock_screen_layer.dart';

class _LockBackdrop extends ConsumerWidget {
  const _LockBackdrop({this.output});

  final DisplayOutput? output;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(
      shellSettingsProvider.select((value) => value.lockScreen),
    );
    final output = this.output;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _LockFillPainter(color: context.shellColors.background),
          ),
          if (settings.useSystemWallpaper)
            ClipRect(
              child: ImageFiltered(
                key: ValueKey<String>(
                  output == null
                      ? 'lock-wallpaper-blur'
                      : 'lock-wallpaper-blur-${output.monitorId}',
                ),
                imageFilter: ImageFilter.blur(
                  sigmaX: settings.blurRadius,
                  sigmaY: settings.blurRadius,
                  // The lock wallpaper fills the output. Clamping keeps the
                  // blur kernel from sampling transparent pixels beyond that
                  // boundary and exposing a bright halo around the display.
                  tileMode: TileMode.clamp,
                ),
                child: output == null
                    ? const ShellWallpaper()
                    : ShellOutputWallpaper(output: output),
              ),
            ),
          CustomPaint(
            painter: _LockFillPainter(
              color: ShellMediaColors.darkness.withValues(
                alpha: settings.dimAmount,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Uses round-rect geometry with an imperceptible radius so the backdrop obeys
/// lock-stage transforms without entering Impeller's UberSDF rect path.
class _LockFillPainter extends CustomPainter {
  const _LockFillPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(0.01)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _LockFillPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _LockStatusIcons extends StatelessWidget {
  const _LockStatusIcons({
    required this.power,
    required this.cpu,
    required this.gpus,
    required this.desktop,
  });

  final ShellPowerStatus power;
  final LoadSeries cpu;
  final List<GpuLoad> gpus;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;
    if (desktop) {
      return Positioned(
        top: math.max(24.0, topPadding + 18.0),
        right: 34,
        child: _DesktopLockStatusBar(cpu: cpu, gpus: gpus),
      );
    }
    return Positioned(
      top: math.max(22.0, topPadding + 18.0),
      right: 28,
      child: Opacity(
        opacity: 0.92,
        child: StatusIconCluster(battery: power.batteryStatus),
      ),
    );
  }
}

class _DesktopLockStatusBar extends StatelessWidget {
  const _DesktopLockStatusBar({required this.cpu, required this.gpus});

  final LoadSeries cpu;
  final List<GpuLoad> gpus;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.lockPerformanceStatusLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.shellTheme.panelColor(
            context.shellColors.panelBackground,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.shellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DesktopPerformanceMetric(
                icon: Icons.memory_rounded,
                label: l10n.lockCpuLabel,
                series: cpu,
              ),
              for (final gpu in gpus) ...[
                const SizedBox(width: 8),
                _DesktopPerformanceMetric(
                  icon: Icons.developer_board_rounded,
                  label: gpu.label,
                  series: gpu.series,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopPerformanceMetric extends StatelessWidget {
  const _DesktopPerformanceMetric({
    required this.icon,
    required this.label,
    required this.series,
  });

  final IconData icon;
  final String label;
  final LoadSeries series;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final usage = series.current;
    final value = usage == null
        ? l10n.lockMetricUnavailable
        : l10n.settingsPercent((usage * 100).round());
    final temperature = series.temperatureC;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellColors.surfaceContainerHigh.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: context.shellColors.textTertiary),
            const SizedBox(width: 7),
            Text(
              l10n.lockPerformanceMetric(label, value),
              style: ShellText.cardTitle.copyWith(fontSize: 11),
            ),
            if (temperature != null) ...[
              const SizedBox(width: 7),
              Text(
                l10n.lockTemperature(temperature.round()),
                style: ShellText.base.copyWith(
                  color: context.shellColors.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LockClockBlock extends StatelessWidget {
  const _LockClockBlock({
    required this.clock,
    required this.desktop,
    required this.scale,
    required this.showSystemStatus,
  });

  final HomeClockInfo clock;
  final bool desktop;
  final double scale;
  final bool showSystemStatus;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final top = desktop
        ? math.max(72.0, size.height * 0.22)
        : math.max(48.0, size.height * 0.25 - 96.0);
    final horizontalInset = desktop ? math.max(48.0, size.width * 0.065) : 0.0;
    final height = desktop
        ? math.min(280.0, size.height * 0.36)
        : math.min(250.0, size.height * 0.34);

    return Positioned(
      left: horizontalInset,
      right: desktop ? size.width * 0.48 : 0,
      top: top,
      height: height,
      child: Transform.scale(
        alignment: Alignment.center,
        scale: scale,
        child: Padding(
          padding: desktop
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 24),
          child: RepaintBoundary(
            child: HomeClockWidget(clock: clock, showStatus: showSystemStatus),
          ),
        ),
      ),
    );
  }
}

class _LockSwipePill extends StatelessWidget {
  const _LockSwipePill({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;

    return Positioned(
      left: 0,
      right: 0,
      bottom:
          math.max(34.0, MediaQuery.sizeOf(context).height * 0.034) +
          bottomPadding,
      child: Center(
        child: Opacity(
          opacity: 0.76 + progress * 0.2,
          child: Transform.translate(
            offset: Offset(0.0, -8.0 * progress),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.shellColors.gesturePill,
                borderRadius: BorderRadius.circular(3),
              ),
              child: const SizedBox(width: 132, height: 5),
            ),
          ),
        ),
      ),
    );
  }
}
