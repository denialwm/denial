import 'dart:math' as math;

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/tokens.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/input_deck.dart';
import 'input_deck_keyboard.dart';
import 'input_deck_surface.dart';
import 'input_deck_touchpad.dart';
import '../../state/phone_desk.dart';

class InputDeckLayer extends ConsumerWidget {
  const InputDeckLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(inputDeckProvider);
    final layout = ref.watch(deskDisplayLayoutProvider);
    DisplayOutput? source;
    for (final output in layout?.outputs ?? const <DisplayOutput>[]) {
      if (output.name == state.activeOutput) source = output;
    }
    if (source == null) return const SizedBox.shrink();
    final rect = source.logicalRect;
    return Stack(
      children: [
        Positioned.fill(
          child: ClipPath(
            clipper: _OutputClipper(rect),
            child: const ShellWallpaper(),
          ),
        ),
        Positioned.fromRect(
          rect: rect,
          child: _InputDeckPanel(key: ValueKey(state.activeOutput)),
        ),
      ],
    );
  }
}

class _OutputClipper extends CustomClipper<Path> {
  const _OutputClipper(this.rect);
  final Rect rect;
  @override
  Path getClip(Size size) => Path()..addRect(rect);
  @override
  bool shouldReclip(_OutputClipper oldClipper) => rect != oldClipper.rect;
}

/// Laptop arrangement: a slim status strip, the keyboard, and the touchpad
/// directly below it. Every element sits on the shell's panel glass.
class _InputDeckPanel extends ConsumerStatefulWidget {
  const _InputDeckPanel({super.key});
  @override
  ConsumerState<_InputDeckPanel> createState() => _InputDeckPanelState();
}

class _InputDeckPanelState extends ConsumerState<_InputDeckPanel> {
  static const _headerHeight = 40.0;
  static const _headerGap = 14.0;
  static const _touchpadGap = 18.0;

  late DenialBridge _bridge;

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(denialBridgeProvider);
  }

  @override
  void dispose() {
    _bridge.releaseInputDeck();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(
      shellSettingsProvider.select((settings) => settings.inputDeck),
    );
    return TextFieldTapRegion(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerCancel: (event) {
          if (event.kind == PointerDeviceKind.touch) {
            _bridge.acknowledgeInputDeckContactCancelled(event.device);
          }
        },
        child: MediaQuery.removePadding(
          context: context,
          removeLeft: true,
          removeRight: true,
          removeTop: true,
          removeBottom: true,
          child: BackdropGroup(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final available = math.max(
                    0.0,
                    constraints.maxHeight -
                        _headerHeight -
                        _headerGap -
                        _touchpadGap,
                  );
                  final keyboardHeight = available * settings.keyboardHeight;
                  final width = math.min(
                    constraints.maxWidth,
                    InputDeckKeyboard.maximumWidth(keyboardHeight),
                  );
                  return Column(
                    children: [
                      SizedBox(
                        width: width,
                        height: _headerHeight,
                        child: _DeckHeader(
                          cpu: settings.showCpu,
                          gpu: settings.showGpu,
                          onStop: ref.read(inputDeckProvider.notifier).stop,
                        ),
                      ),
                      const SizedBox(height: _headerGap),
                      SizedBox(
                        width: width,
                        height: keyboardHeight,
                        child: InputDeckKeyboard(bridge: _bridge),
                      ),
                      const SizedBox(height: _touchpadGap),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            width: width * settings.touchpadWidth,
                            child: FractionallySizedBox(
                              heightFactor: settings.touchpadHeight,
                              child: InputDeckTouchpad(
                                bridge: _bridge,
                                settings: settings,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeckHeader extends StatelessWidget {
  const _DeckHeader({
    required this.cpu,
    required this.gpu,
    required this.onStop,
  });
  final bool cpu;
  final bool gpu;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: cpu || gpu
            ? UnconstrainedBox(
                alignment: Alignment.centerLeft,
                constrainedAxis: Axis.vertical,
                clipBehavior: Clip.hardEdge,
                child: _PerformanceCharts(cpu: cpu, gpu: gpu),
              )
            : const SizedBox.shrink(),
      ),
      const SizedBox(width: 12),
      _UseAsDisplayButton(onPressed: onStop),
    ],
  );
}

class _UseAsDisplayButton extends StatefulWidget {
  const _UseAsDisplayButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  State<_UseAsDisplayButton> createState() => _UseAsDisplayButtonState();
}

class _UseAsDisplayButtonState extends State<_UseAsDisplayButton> {
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final label = context.l10n.inputDeckUseAsDisplay;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: InputDeckGlass(
            radius: ShellRadii.chip,
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : Motion.tile,
              curve: Motion.standard,
              color: _pressed
                  ? theme.accentPalette.container.withValues(alpha: 0.7)
                  : theme.accentPalette.container.withValues(alpha: 0),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.desktop_windows_rounded,
                    size: 17,
                    color: theme.accent,
                  ),
                  const SizedBox(width: 9),
                  Text(
                    label,
                    maxLines: 1,
                    style: theme.text.base.copyWith(
                      color: colors.panelText,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PerformanceCharts extends ConsumerWidget {
  const _PerformanceCharts({required this.cpu, required this.gpu});
  final bool cpu;
  final bool gpu;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final charts = [
      if (cpu) _Chart(label: 'CPU', series: ref.watch(cpuUsageProvider)),
      if (gpu)
        for (final device in ref.watch(gpuUsageProvider))
          _Chart(label: device.label, series: device.series),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, chart) in charts.indexed) ...[
          if (index > 0) const SizedBox(width: 10),
          chart,
        ],
      ],
    );
  }
}

class _Chart extends StatelessWidget {
  const _Chart({required this.label, required this.series});
  final String label;
  final LoadSeries series;
  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final reading = series.current == null
        ? '—'
        : '${(series.current! * 100).round()}%';
    return Semantics(
      label: '$label $reading',
      excludeSemantics: true,
      child: InputDeckGlass(
        radius: ShellRadii.chip,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.text.base.copyWith(
                  color: colors.textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  height: 1,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 76,
                height: 20,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _LoadPainter(series.history, theme.accent),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 40,
                child: Text(
                  reading,
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  style: theme.text.systemBarValue.copyWith(
                    color: colors.panelText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sparkline with a soft fill fading toward the baseline.
class _LoadPainter extends CustomPainter {
  const _LoadPainter(this.history, this.color);
  final List<double> history;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (history.length < 2) return;
    final line = Path();
    for (var i = 0; i < history.length; i++) {
      final x = i * size.width / (history.length - 1);
      final y = (1 - history[i].clamp(0, 1)) * (size.height - 2) + 1;
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
    }
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.32), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_LoadPainter oldDelegate) =>
      history != oldDelegate.history || color != oldDelegate.color;
}
