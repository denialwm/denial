import 'dart:math' as math;

import 'package:flutter/material.dart'
    show CircularProgressIndicator, Icons, IconData, Tooltip;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/effects.dart';

import '../liquid/liquid.dart';
import '../liquid/water_reveal.dart';
import 'shade_reference_geometry.dart';

abstract final class QuickSettingsGridMetrics {
  static const double row = 76;
  static const double capsule = 62;
  static const double gutter = 14;
  static const double minimumWidth = capsule * 4 + gutter * 3;
  static const double height = row * 3;
}

/// The grid of quick-settings tiles. Purely presentational: every value and
/// callback is supplied by the panel.
class QuickSettingsTiles extends StatelessWidget {
  const QuickSettingsTiles({
    super.key,
    this.mobileDataTile,
    this.brightnessControl,
    this.volumeControl,
    this.expansionProgress,
    this.footerTiles = const [],
    required this.wifi,
    required this.wifiSubtitle,
    required this.wifiEnabled,
    required this.wifiBusy,
    required this.bluetooth,
    required this.bluetoothSubtitle,
    required this.bluetoothEnabled,
    required this.bluetoothBusy,
    required this.dnd,
    required this.dndReady,
    required this.profile,
    required this.onToggleWifi,
    required this.onOpenWifi,
    required this.onToggleBluetooth,
    required this.onOpenBluetooth,
    required this.onToggleDnd,
    required this.onCycleProfile,
  });

  final Widget? mobileDataTile;
  final Widget? brightnessControl;
  final Widget? volumeControl;
  final Animation<double>? expansionProgress;

  /// A row below the grid, aligned with its columns: a square tile takes
  /// one column and a wide one two, four columns at most.
  final List<QuickTile> footerTiles;
  final bool wifi;
  final String wifiSubtitle;
  final bool wifiEnabled;
  final bool wifiBusy;
  final bool bluetooth;
  final String bluetoothSubtitle;
  final bool bluetoothEnabled;
  final bool bluetoothBusy;
  final bool dnd;
  final bool dndReady;
  final String profile;
  final VoidCallback onToggleWifi;
  final VoidCallback onOpenWifi;
  final VoidCallback onToggleBluetooth;
  final VoidCallback onOpenBluetooth;
  final VoidCallback onToggleDnd;
  final VoidCallback onCycleProfile;

  @override
  Widget build(BuildContext context) {
    assert(
      footerTiles.fold(0, (columns, tile) => columns + (tile.wide ? 2 : 1)) <=
          4,
      'the footer row has four columns',
    );
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Water runs down the grid with the shade: each row starts filling
        // a little after the one above, and within a row left to right.
        // Closing, the lowest rows drain first, all of it before the
        // shade's blur fades.
        Widget reveal(int index, Widget child, {required (int, int) cell}) {
          final progress = expansionProgress;
          if (progress == null) return child;
          final (row, column) = cell;
          return WaterReveal(
            progress: progress,
            start: 0.33 + 0.05 * row + 0.01 * column,
            child: child,
          );
        }

        final width = constraints.maxWidth;
        final scale = (width / QuickSettingsGridMetrics.minimumWidth)
            .clamp(0.0, 1.0)
            .toDouble();
        final gutter = QuickSettingsGridMetrics.gutter * scale;
        final capsule = QuickSettingsGridMetrics.capsule * scale;
        final row = QuickSettingsGridMetrics.row * scale;
        final column = (width - gutter * 3) / 4;
        final pitch = column + gutter;
        final wide = column * 2 + gutter;
        final tall = capsule * 2 + gutter;
        final footerTop = row * 3 + gutter;
        final footerHeight = footerTiles.any((tile) => !tile.wide)
            ? row
            : capsule;
        final footerColumns = <int>[];
        var footerColumn = 0;
        for (final tile in footerTiles) {
          footerColumns.add(footerColumn);
          footerColumn += tile.wide ? 2 : 1;
        }
        return SizedBox(
          height: footerTiles.isEmpty
              ? QuickSettingsGridMetrics.height * scale
              : footerTop + footerHeight,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                width: wide,
                height: capsule,
                child: reveal(
                  0,
                  QuickTile(
                    icon: Icons.wifi_rounded,
                    title: l10n.commonWifi,
                    subtitle: wifiSubtitle,
                    active: wifi,
                    enabled: wifiEnabled,
                    busy: wifiBusy,
                    onTap: onToggleWifi,
                    onDetails: onOpenWifi,
                    wide: true,
                  ),
                  cell: (0, 0),
                ),
              ),
              Positioned(
                left: pitch * 2,
                top: 0,
                width: wide,
                height: capsule,
                child: reveal(
                  1,
                  QuickTile(
                    icon: Icons.bluetooth_rounded,
                    title: l10n.commonBluetooth,
                    subtitle: bluetoothSubtitle,
                    active: bluetooth,
                    enabled: bluetoothEnabled,
                    busy: bluetoothBusy,
                    onTap: onToggleBluetooth,
                    onDetails: onOpenBluetooth,
                    wide: true,
                  ),
                  cell: (0, 2),
                ),
              ),
              Positioned(
                left: 0,
                top: row,
                width: column,
                height: tall,
                child: reveal(
                  2,
                  brightnessControl ?? const SizedBox.expand(),
                  cell: (1, 0),
                ),
              ),
              Positioned(
                left: pitch,
                top: row,
                width: column,
                height: tall,
                child: reveal(
                  3,
                  volumeControl ?? const SizedBox.expand(),
                  cell: (1, 1),
                ),
              ),
              if (mobileDataTile != null)
                Positioned(
                  left: pitch * 2,
                  top: row,
                  width: wide,
                  height: capsule,
                  child: reveal(4, mobileDataTile!, cell: (1, 2)),
                ),
              Positioned(
                left: pitch * 2,
                top: row * 2,
                width: column,
                height: row,
                child: reveal(
                  5,
                  QuickTile(
                    icon: _profileIcon(profile),
                    title: _profileLabel(profile, l10n),
                    active: profile != PowerProfile.balanced,
                    onTap: onCycleProfile,
                  ),
                  cell: (2, 2),
                ),
              ),
              Positioned(
                left: pitch * 3,
                top: row * 2,
                width: column,
                height: row,
                child: reveal(
                  6,
                  QuickTile(
                    icon: Icons.notifications_off_rounded,
                    title: l10n.quickSettingsSilent,
                    subtitle: dndReady
                        ? (dnd ? l10n.commonOn : l10n.quickSettingsNormal)
                        : l10n.commonLoading,
                    active: dnd,
                    enabled: dndReady,
                    onTap: onToggleDnd,
                  ),
                  cell: (2, 3),
                ),
              ),
              for (final (index, tile) in footerTiles.indexed)
                Positioned(
                  left: pitch * footerColumns[index],
                  top: footerTop,
                  width: tile.wide ? wide : column,
                  height: tile.wide ? capsule : row,
                  child: reveal(
                    7 + index,
                    tile,
                    cell: (3, footerColumns[index]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A single quick-settings tile. Animates its surface between the off and
/// active (accent) states.
class QuickTile extends StatefulWidget {
  const QuickTile({
    super.key,
    required this.icon,
    required this.title,
    required this.active,
    required this.onTap,
    this.subtitle,
    this.wide = false,
    this.enabled = true,
    this.busy = false,
    this.onDetails,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool active;
  final VoidCallback onTap;
  final bool wide;
  final bool enabled;
  final bool busy;
  final VoidCallback? onDetails;

  @override
  State<QuickTile> createState() => _QuickTileState();
}

class _QuickTileState extends State<QuickTile>
    with SingleTickerProviderStateMixin {
  bool _focused = false;
  late final _TilePour _pour = _TilePour(this, widget.active);

  /// Where the last tap landed across the tile, 0 to 1; the liquid pours
  /// in or drains out there. A state that changes much later, or from
  /// elsewhere, pours from the middle.
  double _tapAt = 0.5;
  DateTime _tappedAt = DateTime(0);

  ValueListenable<double>? _reveal;
  double _revealAmount = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pour.reduced = MediaQuery.disableAnimationsOf(context);
    final reveal = LiquidRevealScope.maybeOf(context);
    if (reveal != _reveal) {
      _reveal?.removeListener(_revealChanged);
      _reveal = reveal?..addListener(_revealChanged);
      _revealAmount = reveal?.value ?? 1;
    }
  }

  /// While the shade carries the tile, a lit tile's liquid rides below the
  /// brim and sloshes with the motion; at rest it is simply full.
  void _revealChanged() {
    final amount = _reveal!.value;
    _pour.stir(amount, amount - _revealAmount, fromEmpty: _revealAmount <= 0);
    _revealAmount = amount;
  }

  @override
  void didUpdateWidget(covariant QuickTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    final recent =
        DateTime.now().difference(_tappedAt) < const Duration(seconds: 3);
    _pour.turn(widget.active, at: recent ? _tapAt : 0.5);
    _tappedAt = DateTime(0);
  }

  @override
  void dispose() {
    _reveal?.removeListener(_revealChanged);
    _pour.dispose();
    super.dispose();
  }

  void _noteTap(TapUpDetails details) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    _tapAt = (details.localPosition.dx / width).clamp(0.05, 0.95).toDouble();
    _tappedAt = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final off = _TileInk(
      foreground: context.shellColors.panelText,
      secondary: context.shellColors.textTertiary,
    );
    final on = _TileInk(
      foreground: accent.onPrimary,
      secondary: accent.onPrimary.withValues(alpha: 0.78),
    );
    final radius = theme.scaledRadius(20);

    return Semantics(
      button: true,
      explicitChildNodes: widget.onDetails != null,
      enabled: widget.enabled,
      toggled: widget.active,
      label: widget.subtitle == null
          ? widget.title
          : context.l10n.commonTitleAndSubtitle(widget.title, widget.subtitle!),
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (widget.enabled) {
                widget.onTap();
              }
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: widget.enabled ? _noteTap : null,
          onTap: widget.enabled ? widget.onTap : null,
          child: widget.wide
              ? _buildWide(off, on, radius)
              : _buildSmall(off, on, radius),
        ),
      ),
    );
  }

  Widget _buildWide(_TileInk off, _TileInk on, double radius) {
    final visualScale = ShadeReferenceGeometry.inverseScaleOf(context);
    return _animatedSurface(
      radius: radius,
      content: (ink) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 42,
              child: Center(
                child: widget.busy
                    ? SizedBox.square(
                        dimension: 20 * visualScale,
                        child: CircularProgressIndicator(
                          strokeWidth: 2 * visualScale,
                          color: ink.foreground,
                        ),
                      )
                    : Icon(
                        widget.icon,
                        color: ink.foreground,
                        size: 24 * visualScale,
                      ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ink.foreground,
                      fontSize: 14,
                      height: 1.08,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  if (widget.subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      widget.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ink.secondary,
                        fontSize: 10.5,
                        height: 1,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (widget.onDetails != null)
              _TileDetailsButton(
                label: context.l10n.quickSettingsOpenDetails(widget.title),
                foreground: ink.foreground,
                onPressed: widget.onDetails!,
              ),
          ],
        ),
      ),
      off: off,
      on: on,
    );
  }

  Widget _buildSmall(_TileInk off, _TileInk on, double radius) {
    final visualScale = ShadeReferenceGeometry.inverseScaleOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fill the column so the tile's edges line up with the capsules and
        // sliders around it. A row shorter than the reference scales down.
        final fit = constraints.hasBoundedHeight
            ? math.min(
                1.0,
                constraints.maxHeight / QuickSettingsGridMetrics.row,
              )
            : 1.0;
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth / fit
            : QuickSettingsGridMetrics.capsule;
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            height: QuickSettingsGridMetrics.row,
            child: _buildSmallContent(off, on, radius, visualScale),
          ),
        );
      },
    );
  }

  Widget _buildSmallContent(
    _TileInk off,
    _TileInk on,
    double radius,
    double visualScale,
  ) {
    return Column(
      children: [
        SizedBox(
          height: QuickSettingsGridMetrics.capsule,
          width: double.infinity,
          child: _animatedSurface(
            radius: radius,
            off: off,
            on: on,
            content: (ink) => Center(
              child: widget.busy
                  ? SizedBox.square(
                      dimension: 22 * visualScale,
                      child: CircularProgressIndicator(
                        strokeWidth: 2 * visualScale,
                        color: ink.foreground,
                      ),
                    )
                  : Icon(
                      widget.icon,
                      color: ink.foreground,
                      size: 30 * visualScale,
                    ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: context.shellColors.panelText,
            fontSize: 10,
            height: 1,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }

  /// The tile's surface: off glass, with the accent poured in as liquid
  /// when it turns on and drained out when it turns off. The contents are
  /// drawn in the off ink above the liquid and in the on ink beneath it.
  Widget _animatedSurface({
    required double radius,
    required _TileInk off,
    required _TileInk on,
    required Widget Function(_TileInk ink) content,
  }) {
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final glass = theme.transparencyMode == ShellTransparencyMode.glass;
    final colors = _TileSurfaceColors(
      off: theme.cardColor(context.shellColors.tileOff),
      on: accent.primary,
      offBorder: _focused
          ? accent.primary
          : glass
          ? null
          : context.shellColors.hairlineSoft,
      onBorder: _focused || !glass ? accent.primary : null,
      borderWidth: _focused ? 1.5 : 1,
    );
    // The liquid moves in the clippers and the painter; the tree is rebuilt
    // only when the tile turns full, empty or in between.
    return ValueListenableBuilder<_PourPhase>(
      valueListenable: _pour.phase,
      builder: (context, phase, _) {
        final dry = phase.dry;
        final wet = phase.wet;
        Widget layer(_TileInk ink, bool liquid, bool shown) => Visibility(
          visible: shown,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          // Only the layer of the state the tile is turning to takes input;
          // a hidden layer's spinner does not tick.
          child: TickerMode(
            enabled: shown,
            child: IgnorePointer(
              ignoring: liquid != widget.active,
              child: ExcludeSemantics(
                excluding: liquid != widget.active,
                child: ClipPath(
                  clipper: _PourClipper(_pour, liquid: liquid),
                  clipBehavior: dry && wet ? Clip.antiAlias : Clip.none,
                  child: content(ink),
                ),
              ),
            ),
          ),
        );
        // Only an off tile frosts its backdrop, as before the liquid: a lit
        // tile sloshing below its brim does not pay for a blur.
        return ShellBackdropBlur(
          blur: !widget.active && glass && theme.effectivePanelOpacity < 1,
          separateChild: true,
          borderRadius: BorderRadius.circular(radius),
          // The painter rounds the tile itself.
          clipUnfiltered: false,
          child: CustomPaint(
            painter: _TileSurfacePainter(_pour, colors, radius),
            child: Stack(
              fit: StackFit.expand,
              children: [layer(off, false, dry), layer(on, true, wet)],
            ),
          ),
        );
      },
    );
  }
}

@immutable
class _TileInk {
  const _TileInk({required this.foreground, required this.secondary});

  final Color foreground;
  final Color secondary;
}

@immutable
class _TileSurfaceColors {
  const _TileSurfaceColors({
    required this.off,
    required this.on,
    required this.offBorder,
    required this.onBorder,
    required this.borderWidth,
  });

  final Color off;
  final Color on;
  final Color? offBorder;
  final Color? onBorder;
  final double borderWidth;

  @override
  bool operator ==(Object other) =>
      other is _TileSurfaceColors &&
      other.off == off &&
      other.on == on &&
      other.offBorder == offBorder &&
      other.onBorder == onBorder &&
      other.borderWidth == borderWidth;

  @override
  int get hashCode => Object.hash(off, on, offBorder, onBorder, borderWidth);
}

/// The accent liquid in a tile: its level rises to full when the tile
/// turns on and falls to empty when it turns off, its surface bulging
/// where the tap landed and ringing as it settles.
class _TilePour extends ChangeNotifier {
  _TilePour(TickerProvider vsync, bool active)
    : _level = LiquidSpring(active ? 1 : 0, stiffness: 200, dampingRatio: 0.8) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final LiquidSpring _level;

  /// Rings longer than the recipe's surface, so the slosh lasts.
  final LiquidSpring _surface = LiquidSpring(
    0,
    stiffness: 300,
    dampingRatio: 0.11,
  );

  /// How far below the brim a lit tile's liquid rides while the shade
  /// moves it, as a fraction of its height.
  final LiquidSpring _slack = LiquidSpring(
    0,
    stiffness: 100,
    dampingRatio: 0.42,
  );

  /// The fastest the surface is ever kicked, in pixels per second, and the
  /// fastest the liquid rises back to the brim, in heights per second.
  static const double _calmSwing = 90;
  static const double _calmRise = 1.5;

  bool _arriving = false;
  double _time = 0;
  double _height = 62;
  double centre = 0.5;
  bool reduced = false;

  /// Whether the tile shows any dry glass and any liquid.
  late final ValueNotifier<_PourPhase> phase = ValueNotifier(_phaseNow());

  /// The surface of the current frame, kept for the clippers and the
  /// painter that all ask for it.
  List<Offset>? _points;
  Size _pointsSize = Size.zero;

  double get level =>
      (_level.value - math.max(0.0, _slack.value)).clamp(0.0, 1.0).toDouble();

  _PourPhase _phaseNow() {
    final level = this.level;
    return _PourPhase(dry: level < 1, wet: level > 0 || surface.abs() > 0.5);
  }

  /// The liquid moved: drops the kept surface and tells the clippers, the
  /// painter and, when it changed, the tile.
  void _moved() {
    _points = null;
    final now = _phaseNow();
    if (now != phase.value) phase.value = now;
    notifyListeners();
  }

  double get surface => _surface.value;
  double get time => _time;

  void turn(bool active, {required double at}) {
    centre = at;
    _level.target = active ? 1 : 0;
    if (reduced) {
      _level.settle();
      _surface.set(0);
      _moved();
      return;
    }
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  /// The shade moved the tile: [amount] is how far it is revealed and
  /// [change] the step it just took.
  void stir(double amount, double change, {required bool fromEmpty}) {
    if (_level.target < 1) return;
    if (amount <= 0 || amount >= 1) {
      _arriving = false;
      _slack.target = 0;
    } else {
      // Arriving, the liquid comes in half full and stays there until the
      // tile is in, then rises to the brim.
      if (fromEmpty) {
        _arriving = true;
        _slack.value = 0.5;
      }
      _slack.target = _arriving ? 0.5 : 0.22;
      // Each step tugs the surface, but never past a gentle swing: a quick
      // swipe that opens the shade in a few frames sloshes no harder than
      // a slow one.
      _surface.velocity = (_surface.velocity + change * 900)
          .clamp(-_calmSwing, _calmSwing)
          .toDouble();
    }
    if (reduced) {
      _slack.settle();
      _surface.set(0);
      _moved();
      return;
    }
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  /// The liquid below its surface, or with [liquid] false the dry glass
  /// above it.
  Path region(Size size, {required bool liquid}) {
    _height = size.height;
    final points = _surfaceLine(size);
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    final edge = liquid ? size.height : 0.0;
    return path
      ..lineTo(size.width, edge)
      ..lineTo(0, edge)
      ..close();
  }

  /// The liquid's surface, left to right. Waves are sized in pixels, so a
  /// wide tile sloshes like a wide container: a taller swell where the tap
  /// landed, a tilt, and waves running across it.
  List<Offset> _surfaceLine(Size size) {
    final kept = _points;
    if (kept != null && size == _pointsSize) return kept;
    final width = size.width;
    final y = size.height * (1 - level);
    // A full or empty tile has no surface to show.
    final calm = math.min(1.0, math.min(level, 1 - level) * 6);
    final scale = (width / 76).clamp(1.0, 2.0);
    final bulge = surface * calm * scale;
    final tilt = bulge.abs() * 0.4 * math.sin(_time * 22);
    final wave = bulge.abs() * 0.3;
    final spread = (width * 0.22).clamp(14.0, 26.0);
    const steps = 20;
    final points = <Offset>[];
    for (var i = 0; i <= steps; i += 1) {
      final t = i / steps;
      final x = width * t;
      final distance = (x - centre * width) / spread;
      final top =
          y -
          bulge * math.exp(-distance * distance / 2) +
          tilt * (1 - 2 * t) +
          wave * math.sin(x / 9 - _time * 9);
      points.add(Offset(x, top));
    }
    _pointsSize = size;
    return _points = points;
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 1 / 120
        : ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 1 / 30);
    _last = elapsed;
    _time += dt;
    _level.step(dt);
    _slack.step(dt);
    _slack.velocity = _slack.velocity.clamp(-_calmRise, _calmRise).toDouble();
    // A small tile sloshes less than a tall bar.
    _surface.target = LiquidTuning.surfaceTarget(
      (_level.velocity - _slack.velocity) * _height * 0.6,
    );
    _surface.step(dt);
    _moved();
    if (_level.resting(0.0005) &&
        _slack.resting(0.0005) &&
        _surface.resting(0.05)) {
      _level.settle();
      _slack.settle();
      _surface.settle();
      _ticker.stop();
      _moved();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    phase.dispose();
    super.dispose();
  }
}

@immutable
class _PourPhase {
  const _PourPhase({required this.dry, required this.wet});

  final bool dry;
  final bool wet;

  @override
  bool operator ==(Object other) =>
      other is _PourPhase && other.dry == dry && other.wet == wet;

  @override
  int get hashCode => Object.hash(dry, wet);
}

class _PourClipper extends CustomClipper<Path> {
  _PourClipper(this.pour, {required this.liquid}) : super(reclip: pour);

  final _TilePour pour;
  final bool liquid;

  @override
  Path getClip(Size size) => pour.region(size, liquid: liquid);

  @override
  bool shouldReclip(_PourClipper oldClipper) =>
      oldClipper.pour != pour || oldClipper.liquid != liquid;
}

class _TileSurfacePainter extends CustomPainter {
  _TileSurfacePainter(this.pour, this.colors, this.radius)
    : super(repaint: pour);

  final _TilePour pour;
  final _TileSurfaceColors colors;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final shape = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(math.min(radius, size.shortestSide / 2)),
    );
    final level = pour.level;
    if (level < 1) canvas.drawRRect(shape, Paint()..color = colors.off);
    if (level > 0 || pour.surface.abs() > 0.5) {
      canvas.save();
      canvas.clipRRect(shape);
      canvas.drawPath(
        pour.region(size, liquid: true),
        Paint()..color = colors.on,
      );
      canvas.restore();
    }
    final border = Color.lerp(
      colors.offBorder ?? colors.off.withValues(alpha: 0),
      colors.onBorder ?? colors.on.withValues(alpha: 0),
      level,
    )!;
    if (border.a > 0) {
      canvas.drawRRect(
        shape.deflate(colors.borderWidth / 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = colors.borderWidth
          ..color = border,
      );
    }
  }

  @override
  bool shouldRepaint(_TileSurfacePainter oldDelegate) =>
      oldDelegate.pour != pour ||
      oldDelegate.colors != colors ||
      oldDelegate.radius != radius;
}

class _TileDetailsButton extends StatefulWidget {
  const _TileDetailsButton({
    required this.label,
    required this.foreground,
    required this.onPressed,
  });

  final String label;
  final Color foreground;
  final VoidCallback onPressed;

  @override
  State<_TileDetailsButton> createState() => _TileDetailsButtonState();
}

class _TileDetailsButtonState extends State<_TileDetailsButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _focused
                  ? context.shellTheme.cardColor(
                      context.shellColors.surfaceContainerHighest,
                    )
                  : const Color(0x00000000),
              borderRadius: context.shellTheme.borderRadius(10),
              border: _focused ? Border.all(color: accent) : null,
            ),
            child: SizedBox.square(
              dimension: 24,
              child: Icon(
                Icons.chevron_right_rounded,
                size: 17 * ShadeReferenceGeometry.inverseScaleOf(context),
                color: widget.foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact shade actions. Application-count prose belongs in the overview,
/// not in quick settings.
class ShadeActions extends StatelessWidget {
  const ShadeActions({super.key, required this.onOpenPower});

  final VoidCallback onOpenPower;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _RoundButton(
          label: context.l10n.quickSettingsSettingsUnavailable,
          icon: Icons.edit_rounded,
        ),
        const SizedBox(width: 12),
        _RoundButton(
          label: context.l10n.quickSettingsSettingsUnavailable,
          icon: Icons.settings_rounded,
        ),
        const SizedBox(width: 12),
        _RoundButton(
          label: context.l10n.desktopOpenPowerControls,
          icon: Icons.more_horiz_rounded,
          onPressed: onOpenPower,
        ),
      ],
    );
  }
}

class _RoundButton extends StatefulWidget {
  const _RoundButton({required this.label, required this.icon, this.onPressed});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final theme = ShellTheme.of(context);
    final accent = theme.accent;
    final radius = theme.borderRadius(16);
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardColor(context.shellColors.chip),
        borderRadius: radius,
        border: _focused
            ? Border.all(color: accent)
            : theme.transparencyMode == ShellTransparencyMode.glass
            ? null
            : Border.all(color: context.shellColors.hairlineSoft),
      ),
      child: SizedBox(
        width: 32,
        height: 32,
        child: Icon(
          widget.icon,
          color: context.shellColors.panelText,
          size: 18 * ShadeReferenceGeometry.inverseScaleOf(context),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        child: FocusableActionDetector(
          enabled: enabled,
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onShowFocusHighlight: (focused) => setState(() => _focused = focused),
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: ShellBackdropBlur(
              blur:
                  theme.transparencyMode == ShellTransparencyMode.glass &&
                  theme.effectivePanelOpacity < 1,
              separateChild: true,
              borderRadius: radius,
              clipUnfiltered: false,
              child: surface,
            ),
          ),
        ),
      ),
    );
  }
}

IconData _profileIcon(String profile) => switch (profile) {
  PowerProfile.powerSave => Icons.energy_savings_leaf_rounded,
  PowerProfile.performance => Icons.speed_rounded,
  _ => Icons.balance_rounded,
};

String _profileLabel(String profile, AppLocalizations l10n) =>
    switch (profile) {
      PowerProfile.powerSave => l10n.quickSettingsBatterySaver,
      PowerProfile.performance => l10n.quickSettingsHighPerformance,
      _ => l10n.quickSettingsBalanced,
    };
