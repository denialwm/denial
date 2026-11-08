import 'dart:math' as math;

import 'package:flutter/material.dart'
    show CircularProgressIndicator, Icons, IconData, Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/effects.dart';

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
    this.airplaneTile,
    this.orientationLockTile,
    this.clipboardTile,
    this.desktopViewTile,
    this.autoBrightnessTile,
    this.darkModeTile,
    this.flashlightTile,
    this.brightnessControl,
    this.volumeControl,
    this.footerTiles = const [],
    this.expansionProgress,
    this.designLayout = false,
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
  final Widget? airplaneTile;
  final Widget? orientationLockTile;
  final Widget? clipboardTile;
  final Widget? desktopViewTile;
  final Widget? autoBrightnessTile;
  final Widget? darkModeTile;
  final Widget? flashlightTile;
  final Widget? brightnessControl;
  final Widget? volumeControl;

  /// A row below the grid, aligned with its columns: a square tile takes
  /// one column and a wide one two, four columns at most.
  final List<QuickTile> footerTiles;

  final Animation<double>? expansionProgress;

  /// Wide, landscape split layout: three columns of short tiles with their
  /// contents stacked, followed by the sliders as full-width cards. The
  /// phone pager keeps the four-column capsule grid.
  final bool designLayout;
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
    if (designLayout) return _buildDesignLayout(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Water runs down the grid with the shade, row by row. Closing,
        // the lowest rows drain first, before the shade's blur fades.
        Widget reveal(Widget child, {required (int, int) cell}) {
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
                  child: reveal(mobileDataTile!, cell: (1, 2)),
                ),
              Positioned(
                left: pitch * 2,
                top: row * 2,
                width: column,
                height: row,
                child: reveal(
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
                  child: reveal(tile, cell: (3, footerColumns[index])),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDesignLayout(BuildContext context) {
    final l10n = context.l10n;
    const tileHeight = 44.0;
    const gutter = 6.0;
    final entries = <(Widget, int)>[
      (
        QuickTile(
          icon: Icons.wifi_rounded,
          title: l10n.commonWifi,
          subtitle: wifiSubtitle,
          active: wifi,
          enabled: wifiEnabled,
          busy: wifiBusy,
          stacked: true,
          onTap: onToggleWifi,
          onDetails: onOpenWifi,
        ),
        1,
      ),
      (
        QuickTile(
          icon: Icons.bluetooth_rounded,
          title: l10n.commonBluetooth,
          subtitle: bluetoothSubtitle,
          active: bluetooth,
          enabled: bluetoothEnabled,
          busy: bluetoothBusy,
          stacked: true,
          onTap: onToggleBluetooth,
          onDetails: onOpenBluetooth,
        ),
        1,
      ),
      if (mobileDataTile != null) (mobileDataTile!, 1),
      if (airplaneTile != null) (airplaneTile!, 1),
      (
        QuickTile(
          icon: Icons.notifications_off_rounded,
          title: l10n.quickSettingsSilent,
          subtitle: dndReady
              ? (dnd ? l10n.commonOn : l10n.quickSettingsNormal)
              : l10n.commonLoading,
          active: dnd,
          enabled: dndReady,
          stacked: true,
          onTap: onToggleDnd,
        ),
        1,
      ),
      if (orientationLockTile != null) (orientationLockTile!, 1),
      (
        QuickTile(
          icon: _profileIcon(profile),
          title: _profileLabel(profile, l10n),
          active: profile != PowerProfile.balanced,
          stacked: true,
          onTap: onCycleProfile,
        ),
        1,
      ),
      if (clipboardTile != null) (clipboardTile!, 1),
      if (desktopViewTile != null) (desktopViewTile!, 1),
      if (autoBrightnessTile != null) (autoBrightnessTile!, 1),
      if (darkModeTile != null) (darkModeTile!, 1),
      if (flashlightTile != null) (flashlightTile!, 1),
    ];

    // Water runs down the redesign row by row, sliders included, so every
    // card fades in and out with the shade.
    Widget revealRow(int row, Widget child, {int column = 0}) {
      final progress = expansionProgress;
      if (progress == null) return child;
      return WaterReveal(
        progress: progress,
        start: 0.33 + 0.05 * row + 0.01 * column,
        child: child,
      );
    }

    final revealed = <(Widget, int)>[
      for (final (index, entry) in entries.indexed)
        (revealRow(index ~/ 4, entry.$1, column: index % 4), entry.$2),
    ];

    // Pack the tiles into rows of three columns; a two-column tile only
    // fits where the row still has room for it.
    final rows = <List<(Widget, int)>>[];
    var row = <(Widget, int)>[];
    var used = 0;
    for (final entry in revealed) {
      final span = entry.$2.clamp(1, 4);
      if (used + span > 4) {
        rows.add(row);
        row = [];
        used = 0;
      }
      row.add((entry.$1, span));
      used += span;
    }
    if (row.isNotEmpty) rows.add(row);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, rowTiles) in rows.indexed) ...[
          if (index > 0) const SizedBox(height: gutter),
          _buildDesignRow(rowTiles, tileHeight: tileHeight, gutter: gutter),
        ],
        if (brightnessControl != null) ...[
          const SizedBox(height: gutter),
          revealRow(3, brightnessControl!),
        ],
        if (volumeControl != null) ...[
          const SizedBox(height: gutter),
          revealRow(4, volumeControl!),
        ],
      ],
    );
  }

  Widget _buildDesignRow(
    List<(Widget, int)> tiles, {
    required double tileHeight,
    required double gutter,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 4;
        final columnWidth =
            (constraints.maxWidth - gutter * (columns - 1)) / columns;
        final children = <Widget>[];
        var used = 0;
        for (final (index, entry) in tiles.indexed) {
          final (tile, span) = entry;
          if (index > 0) children.add(SizedBox(width: gutter));
          children.add(
            SizedBox(
              width: columnWidth * span + gutter * (span - 1),
              height: tileHeight,
              child: tile,
            ),
          );
          used += span;
        }
        while (used < columns) {
          if (used > 0) children.add(SizedBox(width: gutter));
          children.add(SizedBox(width: columnWidth));
          used += 1;
        }
        return Row(children: children);
      },
    );
  }
}

/// A single quick-settings tile. Shows the off glass or the accent surface.
class QuickTile extends StatefulWidget {
  const QuickTile({
    super.key,
    required this.icon,
    required this.title,
    required this.active,
    required this.onTap,
    this.subtitle,
    this.wide = false,
    this.stacked = false,
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

  /// Stacked contents for the wide split layout: icon on top, label at the
  /// bottom edge, like the redesigned quick settings.
  final bool stacked;

  final bool enabled;
  final bool busy;
  final VoidCallback? onDetails;

  @override
  State<QuickTile> createState() => _QuickTileState();
}

class _QuickTileState extends State<QuickTile> {
  bool _focused = false;

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
          onTap: widget.enabled ? widget.onTap : null,
          child: widget.stacked
              ? _buildStacked(off, on, theme.scaledRadius(10))
              : widget.wide
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

  Widget _buildStacked(_TileInk off, _TileInk on, double radius) {
    final visualScale = ShadeReferenceGeometry.inverseScaleOf(context);
    return _animatedSurface(
      radius: radius,
      off: off,
      on: on,
      content: (ink) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 7, 6, 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox.square(
                  dimension: 30 * visualScale,
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
                            size: 30 * visualScale,
                          ),
                  ),
                ),
                const Spacer(),
                if (widget.onDetails != null)
                  _TileDetailsButton(
                    label: context.l10n.quickSettingsOpenDetails(widget.title),
                    foreground: ink.foreground,
                    dimension: 14,
                    onPressed: widget.onDetails!,
                  ),
              ],
            ),
            const Spacer(),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ink.foreground,
                fontSize: 18,
                height: 1.05,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
                decoration: TextDecoration.none,
              ),
            ),
            if (widget.subtitle != null) ...[
              SizedBox(height: 2 * visualScale),
              Text(
                widget.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ink.secondary,
                  fontSize: 14,
                  height: 1.05,
                  letterSpacing: 0,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ],
        ),
      ),
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

  /// The tile's surface: plain glass or the accent, with no liquid motion.
  Widget _animatedSurface({
    required double radius,
    required _TileInk off,
    required _TileInk on,
    required Widget Function(_TileInk ink) content,
  }) {
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final glass = theme.transparencyMode == ShellTransparencyMode.glass;
    final ink = widget.active ? on : off;
    final border = _focused
        ? accent.primary
        : glass
        ? null
        : widget.active
        ? accent.primary
        : context.shellColors.hairlineSoft;
    return ShellBackdropBlur(
      blur: !widget.active && glass && theme.effectivePanelOpacity < 1,
      separateChild: true,
      borderRadius: BorderRadius.circular(radius),
      clipUnfiltered: false,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: widget.active
              ? accent.primary
              : theme.cardColor(context.shellColors.tileOff),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: border ?? const Color(0x00000000),
            width: _focused ? 1.5 : 1,
          ),
        ),
        child: content(ink),
      ),
    );
  }
}

@immutable
class _TileInk {
  const _TileInk({required this.foreground, required this.secondary});

  final Color foreground;
  final Color secondary;
}

class _TileDetailsButton extends StatefulWidget {
  const _TileDetailsButton({
    required this.label,
    required this.foreground,
    required this.onPressed,
    this.dimension = 24,
  });

  final String label;
  final Color foreground;
  final VoidCallback onPressed;
  final double dimension;

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
              dimension: widget.dimension,
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
  const ShadeActions({
    super.key,
    required this.onOpenSettings,
    required this.onScreenshot,
    required this.onOpenPower,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback onScreenshot;
  final VoidCallback onOpenPower;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _RoundButton(
          label: context.l10n.quickSettingsScreenshot,
          icon: Icons.photo_camera_rounded,
          onPressed: onScreenshot,
        ),
        const SizedBox(width: 6),
        _RoundButton(
          label: context.l10n.settingsApplicationSemanticsLabel,
          icon: Icons.settings_rounded,
          onPressed: onOpenSettings,
        ),
        const SizedBox(width: 6),
        _RoundButton(
          label: context.l10n.desktopOpenPowerControls,
          icon: Icons.power_settings_new_rounded,
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
    final radius = theme.borderRadius(7);
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
        width: 22,
        height: 22,
        child: Icon(
          widget.icon,
          color: context.shellColors.panelText,
          size: 26 * ShadeReferenceGeometry.inverseScaleOf(context),
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
