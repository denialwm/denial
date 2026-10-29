import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../widgets/liquid/liquid.dart';
import 'color_grade.dart';
import 'color_presets.dart';
import 'color_tuning_controller.dart';
import 'liquid_color_wheel.dart';
import 'liquid_grade_slider.dart';

/// The color tuning editor: a glass panel over the live desktop. It is born
/// as a bead from the bottom edge and stretches into its shape.
class ColorTuningLayer extends ConsumerStatefulWidget {
  const ColorTuningLayer({super.key, required this.displayRect});

  /// Where the panel lives, in scene coordinates.
  final Rect displayRect;

  @override
  ConsumerState<ColorTuningLayer> createState() => _ColorTuningLayerState();
}

class _ColorTuningLayerState extends ConsumerState<ColorTuningLayer>
    with SingleTickerProviderStateMixin {
  late final _PanelMotion _motion = _PanelMotion(this);

  /// The panel's top-left from its default spot, moved by its header.
  Offset _moved = Offset.zero;
  bool _mounted = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<bool>(colorTuningProvider.select((s) => s.visible), (
      _,
      visible,
    ) {
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      if (visible) {
        setState(() => _mounted = true);
        _motion.show(reduceMotion: reduceMotion);
      } else {
        _motion.hide(
          reduceMotion: reduceMotion,
          onGone: () {
            if (mounted) setState(() => _mounted = false);
          },
        );
      }
    });
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = ref.watch(colorTuningProvider.select((s) => s.visible));
    if (!_mounted || widget.displayRect.isEmpty) {
      return const SizedBox.shrink();
    }
    final display = widget.displayRect;
    final layout = _PanelLayout.forWidth(math.min(760, display.width - 32));
    final size = layout.size;
    final home = Offset(
      display.center.dx - size.width / 2,
      display.bottom - size.height - math.min(96, display.height * 0.08),
    );
    final topLeft = _clampInto(display, home + _moved, size);
    return Stack(
      children: [
        Positioned(
          left: topLeft.dx,
          top: topLeft.dy,
          width: size.width,
          height: size.height,
          child: ShellInputRegion(
            debugLabel: 'Color tuning',
            active: visible,
            child: _BeadShape(
              motion: _motion,
              size: size,
              travel: display.bottom - topLeft.dy,
              child: _ColorTuningContents(
                layout: layout,
                onMove: (delta) => setState(() {
                  _moved =
                      _clampInto(display, home + _moved + delta, size) - home;
                }),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static Offset _clampInto(Rect display, Offset topLeft, Size size) => Offset(
    topLeft.dx.clamp(
      display.left + 8,
      math.max(display.left + 8, display.right - size.width - 8),
    ),
    topLeft.dy.clamp(
      display.top + 8,
      math.max(display.top + 8, display.bottom - size.height - 8),
    ),
  );
}

/// Sizes of the panel's parts for one width.
class _PanelLayout {
  const _PanelLayout({
    required this.width,
    required this.columns,
    required this.wheelSide,
    required this.headerRows,
  });

  factory _PanelLayout.forWidth(double width) {
    final compact = width < 560;
    final inner = width - 2 * padding;
    return _PanelLayout(
      width: width,
      columns: compact ? 2 : 3,
      wheelSide: ((inner - 2 * columnGap) / 3).clamp(84.0, 150.0),
      headerRows: compact ? 2 : 1,
    );
  }

  static const double padding = 18;
  static const double columnGap = 18;
  static const double rowGap = 10;
  static const double headerRow = 34;
  static const double sectionGap = 16;
  static const double labelHeight = 18;
  static const double sliderHeight = 22;

  final double width;
  final int columns;
  final double wheelSide;
  final int headerRows;

  double get header => headerRows * headerRow + (headerRows - 1) * 8;
  double get wheelBlock => labelHeight + 4 + wheelSide + 6 + sliderHeight;
  int get sliderRows => (GradeSlider.values.length / columns).ceil();
  double get sliderBlock =>
      sliderRows * (labelHeight + 2 + sliderHeight) + (sliderRows - 1) * rowGap;

  Size get size => Size(
    width,
    2 * padding + header + sectionGap + wheelBlock + sectionGap + sliderBlock,
  );
}

class _PanelMotion extends LiquidMotion {
  _PanelMotion(super.vsync);

  /// 1 is off the bottom edge, 0 home.
  final LiquidSpring slide = LiquidSpring(
    1,
    stiffness: 520,
    dampingRatio: 0.74,
  );

  /// 0 is the bead, 1 the panel.
  final LiquidSpring grow = LiquidSpring(0, stiffness: 230, dampingRatio: 0.6);
  bool _hiding = false;
  VoidCallback? _onGone;

  @override
  List<LiquidSpring> get springs => [slide, grow];

  void show({required bool reduceMotion}) {
    _hiding = false;
    _onGone = null;
    slide
      ..tune(520, 0.74)
      ..target = 0;
    grow
      ..tune(230, 0.6)
      ..target = 1;
    kick(reduceMotion: reduceMotion);
  }

  void hide({required bool reduceMotion, required VoidCallback onGone}) {
    _hiding = true;
    _onGone = onGone;
    // The shape shrinks back into the bead first, then the bead slides away.
    grow
      ..tune(420, 1)
      ..target = 0;
    slide
      ..tune(150, 1)
      ..target = 1;
    kick(reduceMotion: reduceMotion);
  }

  @override
  bool advance(double dt) {
    grow.step(dt);
    // While leaving, the bead waits until the shape has mostly gone.
    if (!_hiding || grow.value < 0.35) slide.step(dt);
    return slide.resting(0.001) && grow.resting(0.001);
  }

  @override
  void rested() {
    if (!_hiding) return;
    final onGone = _onGone;
    _onGone = null;
    onGone?.call();
  }
}

/// Paints the glass in the bead-to-panel shape; the contents keep their
/// resting layout, revealed as the shape grows.
class _BeadShape extends StatelessWidget {
  const _BeadShape({
    required this.motion,
    required this.size,
    required this.travel,
    required this.child,
  });

  final _PanelMotion motion;
  final Size size;
  final double travel;
  final Widget child;

  static const double bead = 56;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final colors = context.shellColors;
    final contents = RepaintBoundary(child: child);
    return AnimatedBuilder(
      animation: motion,
      child: contents,
      builder: (context, contents) {
        final grow = motion.grow.value;
        final width = bead + (size.width - bead) * grow;
        final height = bead + (size.height - bead) * grow;
        final radius =
            bead / 2 + (theme.panelRadius - bead / 2) * grow.clamp(0.0, 1.0);
        final shape = BorderRadius.circular(radius);
        final reveal = liquidSmooth((grow - 0.55) / 0.4);
        // The bead rides along the bottom edge's centre.
        final offset = Offset(
          (size.width - width) / 2,
          (size.height - height) + motion.slide.value * (travel + bead),
        );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: offset.dx,
              top: offset.dy,
              width: math.max(1, width),
              height: math.max(1, height),
              child: ShellBackdropBlur(
                separateChild: true,
                blur: theme.effectivePanelOpacity < 1.0,
                borderRadius: shape,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: theme.panelGradient(
                      colors.panelBackground,
                      colors.panelBackgroundBottom,
                    ),
                    borderRadius: shape,
                    border: Border.all(color: colors.hairline),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: colors.shadow,
                        blurRadius: 24,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: shape,
                    child: OverflowBox(
                      alignment: Alignment.bottomCenter,
                      minWidth: size.width,
                      maxWidth: size.width,
                      minHeight: size.height,
                      maxHeight: size.height,
                      child: reveal <= 0
                          ? const SizedBox.shrink()
                          : Opacity(opacity: reveal, child: contents),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ColorTuningContents extends ConsumerStatefulWidget {
  const _ColorTuningContents({required this.layout, required this.onMove});

  final _PanelLayout layout;
  final ValueChanged<Offset> onMove;

  @override
  ConsumerState<_ColorTuningContents> createState() =>
      _ColorTuningContentsState();
}

class _ColorTuningContentsState extends ConsumerState<_ColorTuningContents> {
  /// What shows in place of the sliders, if anything.
  _Shelf? _shelf;

  void _toggle(_Shelf shelf) =>
      setState(() => _shelf = _shelf == shelf ? null : shelf);

  @override
  Widget build(BuildContext context) {
    final tuning = ref.watch(colorTuningProvider);
    final controller = ref.read(colorTuningProvider.notifier);
    final layout = widget.layout;
    final l10n = context.l10n;
    final theme = ShellTheme.of(context);
    final ink = context.shellColors.panelText;
    final secondary = context.shellColors.textSecondary;

    void setGrade(
      ColorGrade Function(ColorGrade) change, {
      required bool save,
    }) {
      controller.setGrade(
        change(ref.read(colorTuningProvider).grade),
        save: save,
      );
    }

    final focused = tuning.focusedAppId;
    final targetChips = <Widget>[
      _Chip(
        label: l10n.colorTuningDesktop,
        icon: Icons.desktop_windows_outlined,
        selected: tuning.target.isDesktop,
        onTap: () => controller.selectTarget(const ColorTuningTarget.desktop()),
      ),
      _Chip(
        label: focused == null
            ? l10n.colorTuningNoApp
            : colorTuningAppName(focused),
        icon: Icons.web_asset_outlined,
        selected: !tuning.target.isDesktop,
        onTap: focused == null
            ? null
            : () => controller.selectTarget(ColorTuningTarget.app(focused)),
      ),
    ];
    final commands = <Widget>[
      _Chip(
        label: l10n.colorTuningPresets,
        icon: _shelf == _Shelf.presets ? Icons.expand_less : Icons.expand_more,
        selected: _shelf == _Shelf.presets,
        onTap: () => _toggle(_Shelf.presets),
      ),
      _Chip(
        label:
            '${l10n.colorTuningBase}: ${tuning.baseTitle ?? l10n.colorTuningNoBase}',
        icon: _shelf == _Shelf.looks ? Icons.expand_less : Icons.expand_more,
        selected: _shelf == _Shelf.looks,
        onTap: () => _toggle(_Shelf.looks),
      ),
      _HoldChip(
        label: l10n.colorTuningBefore,
        active: tuning.comparing,
        onHold: controller.compare,
      ),
      _Chip(
        label: l10n.colorTuningReset,
        icon: Icons.restart_alt,
        onTap: tuning.grade.isNeutral ? null : controller.reset,
      ),
    ];
    final title = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) => widget.onMove(details.delta),
      child: Row(
        children: [
          Icon(Icons.tune, size: 18, color: theme.accent),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              tuning.failed ? l10n.colorTuningFailed : l10n.colorTuningAction,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.cardTitle.copyWith(
                color: tuning.failed ? context.shellColors.performanceBad : ink,
              ),
            ),
          ),
        ],
      ),
    );
    final close = _IconChip(
      icon: Icons.close,
      label: l10n.colorTuningClose,
      onTap: controller.close,
    );
    final header = layout.headerRows == 1
        ? SizedBox(
            height: _PanelLayout.headerRow,
            child: Row(
              children: [
                Expanded(child: title),
                ...targetChips.expand(
                  (chip) => [chip, const SizedBox(width: 6)],
                ),
                const SizedBox(width: 8),
                ...commands.expand((chip) => [chip, const SizedBox(width: 6)]),
                close,
              ],
            ),
          )
        : Column(
            children: [
              SizedBox(
                height: _PanelLayout.headerRow,
                child: Row(
                  children: [
                    Expanded(child: title),
                    close,
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: _PanelLayout.headerRow,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [...targetChips, ...commands]
                        .expand((chip) => [chip, const SizedBox(width: 6)])
                        .toList(),
                  ),
                ),
              ),
            ],
          );

    final wheels = Row(
      children: [
        for (final (index, wheel) in GradeWheel.values.indexed) ...[
          if (index > 0) const SizedBox(width: _PanelLayout.columnGap),
          Expanded(
            child: _WheelColumn(
              wheel: wheel,
              label: switch (wheel) {
                GradeWheel.lift => l10n.colorTuningShadows,
                GradeWheel.gamma => l10n.colorTuningMidtones,
                GradeWheel.gain => l10n.colorTuningHighlights,
              },
              side: layout.wheelSide,
              position: tuning.grade.wheel(wheel),
              revision: tuning.revision,
              ink: ink,
              secondary: secondary,
              onChanged: (position, {required save}) => setGrade(
                (grade) => grade.withWheel(wheel, position),
                save: save,
              ),
            ),
          ),
        ],
      ],
    );

    final sliders = <Widget>[
      for (final slider in GradeSlider.values)
        _SliderCell(
          label: switch (slider) {
            GradeSlider.exposure => l10n.colorTuningExposure,
            GradeSlider.contrast => l10n.colorTuningContrast,
            GradeSlider.saturation => l10n.colorTuningSaturation,
            GradeSlider.vibrance => l10n.colorTuningVibrance,
            GradeSlider.temperature => l10n.colorTuningWarmth,
            GradeSlider.tint => l10n.colorTuningTint,
          },
          slider: slider,
          value: tuning.grade.slider(slider),
          revision: tuning.revision,
          ink: ink,
          secondary: secondary,
          onChanged: (value, {required save}) =>
              setGrade((grade) => grade.withSlider(slider, value), save: save),
        ),
    ];
    final grid = Column(
      children: [
        for (var row = 0; row < layout.sliderRows; row++) ...[
          if (row > 0) const SizedBox(height: _PanelLayout.rowGap),
          Row(
            children: [
              for (var column = 0; column < layout.columns; column++) ...[
                if (column > 0) const SizedBox(width: _PanelLayout.columnGap),
                Expanded(
                  child: row * layout.columns + column < sliders.length
                      ? sliders[row * layout.columns + column]
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ],
      ],
    );

    final looks = _LooksShelf(
      bases: tuning.bases,
      current: tuning.baseTitle,
      onPick: (base) {
        setState(() => _shelf = null);
        controller.selectBase(base);
      },
    );
    // Presets stay open, so one after another can be tried.
    final presets = _PresetShelf(
      grade: tuning.grade,
      onPick: controller.applyPreset,
    );

    return Padding(
      padding: const EdgeInsets.all(_PanelLayout.padding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: _PanelLayout.sectionGap),
          SizedBox(height: layout.wheelBlock, child: wheels),
          const SizedBox(height: _PanelLayout.sectionGap),
          SizedBox(
            height: layout.sliderBlock,
            child: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              child: KeyedSubtree(
                key: ValueKey(_shelf),
                child: switch (_shelf) {
                  null => grid,
                  _Shelf.looks => looks,
                  _Shelf.presets => presets,
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WheelColumn extends StatelessWidget {
  const _WheelColumn({
    required this.wheel,
    required this.label,
    required this.side,
    required this.position,
    required this.revision,
    required this.ink,
    required this.secondary,
    required this.onChanged,
  });

  final GradeWheel wheel;
  final String label;
  final double side;
  final WheelPosition position;
  final int revision;
  final Color ink;
  final Color secondary;
  final void Function(WheelPosition position, {required bool save}) onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: _PanelLayout.labelHeight,
          child: _Readout(
            label: label,
            value: position.level,
            ink: ink,
            secondary: secondary,
          ),
        ),
        const SizedBox(height: 4),
        SizedBox.square(
          dimension: side,
          child: LiquidColorWheel(
            puck: position.puck,
            revision: revision,
            ink: ink,
            rim: ink.withValues(alpha: 0.22),
            semanticLabel: label,
            onChanged: (puck, {required save}) =>
                onChanged(WheelPosition(puck, position.level), save: save),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: side,
          child: LiquidGradeSlider(
            value: position.level,
            range: 1,
            revision: revision,
            track: <Color>[
              const Color(0xFF101010).withValues(alpha: 0.7),
              const Color(0xFFF2F2F2).withValues(alpha: 0.7),
            ],
            fill: ink.withValues(alpha: 0.42),
            ink: ink,
            semanticLabel: label,
            onChanged: (level, {required save}) =>
                onChanged(WheelPosition(position.puck, level), save: save),
          ),
        ),
      ],
    );
  }
}

class _SliderCell extends StatelessWidget {
  const _SliderCell({
    required this.label,
    required this.slider,
    required this.value,
    required this.revision,
    required this.ink,
    required this.secondary,
    required this.onChanged,
  });

  final String label;
  final GradeSlider slider;
  final double value;
  final int revision;
  final Color ink;
  final Color secondary;
  final void Function(double value, {required bool save}) onChanged;

  /// Each track shows which way its control pushes.
  static List<Color> _track(GradeSlider slider) {
    const alpha = 0.62;
    final colors = switch (slider) {
      GradeSlider.exposure => const <Color>[
        Color(0xFF151515),
        Color(0xFFF4F4F4),
      ],
      GradeSlider.contrast => const <Color>[
        Color(0xFF8A8A8A),
        Color(0xFF5E5E5E),
        Color(0xFF0E0E0E),
        Color(0xFFFFFFFF),
      ],
      GradeSlider.saturation => const <Color>[
        Color(0xFF8C8C8C),
        Color(0xFF8C8C8C),
        Color(0xFFFF5D5D),
        Color(0xFFFFC53D),
        Color(0xFF3DD6A0),
        Color(0xFF4C9BFF),
      ],
      GradeSlider.vibrance => const <Color>[
        Color(0xFF9A9A9A),
        Color(0xFFB59F95),
        Color(0xFFFF8A6B),
        Color(0xFF6BE0C8),
      ],
      GradeSlider.temperature => const <Color>[
        Color(0xFF5CA8FF),
        Color(0xFFE6E6E6),
        Color(0xFFFFA04A),
      ],
      GradeSlider.tint => const <Color>[
        Color(0xFF52D17C),
        Color(0xFFE6E6E6),
        Color(0xFFE25BD6),
      ],
    };
    return <Color>[for (final color in colors) color.withValues(alpha: alpha)];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _PanelLayout.labelHeight,
          child: _Readout(
            label: label,
            value: value,
            ink: ink,
            secondary: secondary,
          ),
        ),
        const SizedBox(height: 2),
        LiquidGradeSlider(
          value: value,
          range: slider.range,
          revision: revision,
          track: _track(slider),
          fill: ink.withValues(alpha: 0.38),
          ink: ink,
          semanticLabel: label,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({
    required this.label,
    required this.value,
    required this.ink,
    required this.secondary,
  });

  final String label;
  final double value;
  final Color ink;
  final Color secondary;

  @override
  Widget build(BuildContext context) {
    final style = ShellText.cardTitle.copyWith(fontSize: 12);
    final shown = value.abs() < 0.005
        ? '0'
        : '${value > 0 ? '+' : '−'}${value.abs().toStringAsFixed(2)}';
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(color: secondary),
          ),
        ),
        Text(
          shown,
          style: style.copyWith(
            color: value.abs() < 0.005 ? secondary : ink,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _LooksShelf extends StatelessWidget {
  const _LooksShelf({
    required this.bases,
    required this.current,
    required this.onPick,
  });

  final List<ColorBase> bases;
  final String? current;
  final ValueChanged<ColorBase?> onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final directory = colorBaseDirectory();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Chip(
                label: l10n.colorTuningNoBase,
                selected: current == null,
                onTap: () => onPick(null),
              ),
              for (final base in bases)
                _Chip(
                  label: base.title,
                  selected: current == base.title,
                  onTap: () => onPick(base),
                ),
            ],
          ),
          if (directory != null) ...[
            const SizedBox(height: 10),
            Text(
              directory,
              style: ShellText.cardTitle.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: context.shellColors.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    this.icon,
    this.selected = false,
    this.enabled,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool selected;

  /// Whether it shows as usable; by default, whether it has [onTap].
  final bool? enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final colors = context.shellColors;
    final enabled = this.enabled ?? onTap != null;
    final foreground = selected
        ? theme.accent
        : enabled
        ? colors.panelText
        : colors.textTertiary;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: selected
                ? theme.accent.withValues(alpha: 0.18)
                : colors.panelText.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: selected
                  ? theme.accent.withValues(alpha: 0.55)
                  : colors.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: foreground),
                const SizedBox(width: 6),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShellText.cardTitle.copyWith(
                    fontSize: 12,
                    color: foreground,
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

/// Shows the target without its grade while pressed.
class _HoldChip extends StatelessWidget {
  const _HoldChip({
    required this.label,
    required this.active,
    required this.onHold,
  });

  final String label;
  final bool active;
  final ValueChanged<bool> onHold;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => onHold(true),
      onPointerUp: (_) => onHold(false),
      onPointerCancel: (_) => onHold(false),
      child: _Chip(
        label: label,
        icon: Icons.compare,
        selected: active,
        enabled: true,
        onTap: null,
      ),
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: colors.panelText.withValues(alpha: 0.06),
            shape: BoxShape.circle,
            border: Border.all(color: colors.hairline),
          ),
          child: Icon(icon, size: 16, color: colors.panelText),
        ),
      ),
    );
  }
}

enum _Shelf { looks, presets }

/// The built-in looks, each a strip of colors through its grade.
class _PresetShelf extends StatelessWidget {
  const _PresetShelf({required this.grade, required this.onPick});

  final ColorGrade grade;
  final ValueChanged<ColorPreset> onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SingleChildScrollView(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final preset in ColorPreset.values)
            _PresetTile(
              label: preset.label(l10n),
              grade: preset.grade,
              selected: grade.matches(preset.grade),
              onTap: () => onPick(preset),
            ),
        ],
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.label,
    required this.grade,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final ColorGrade grade;
  final bool selected;
  final VoidCallback onTap;

  /// Shadow, foliage, skin, sky and highlight: a scene in five colors.
  static const List<Color> _scene = <Color>[
    Color(0xFF1E2430),
    Color(0xFF4F7A3A),
    Color(0xFFD9A07E),
    Color(0xFF6FA8DC),
    Color(0xFFF4EFE6),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final colors = context.shellColors;
    final foreground = selected ? theme.accent : colors.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 72,
          child: Column(
            children: [
              Container(
                height: 30,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  gradient: LinearGradient(
                    colors: [for (final color in _scene) grade.preview(color)],
                  ),
                  border: Border.all(
                    color: selected ? theme.accent : colors.hairline,
                    width: selected ? 2 : 1,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShellText.cardTitle.copyWith(
                  fontSize: 11,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
