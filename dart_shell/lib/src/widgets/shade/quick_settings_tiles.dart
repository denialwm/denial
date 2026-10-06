import 'package:flutter/material.dart'
    show CircularProgressIndicator, Icons, IconData, Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../services/power_profile_service.dart';
import '../../theme/glass_configuration.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../shell_backdrop_blur.dart';
import 'shade_expansion_motion.dart';
import 'shade_reference_geometry.dart';

abstract final class QuickSettingsGridMetrics {
  static const double row = 76;
  static const double capsule = 62;
  static const double gutter = 14;
  static const double minimumWidth = capsule * 4 + gutter * 3;
  static const double height = row * 4;
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
    required this.wifi,
    required this.wifiSubtitle,
    required this.wifiEnabled,
    required this.wifiBusy,
    required this.bluetooth,
    required this.bluetoothSubtitle,
    required this.bluetoothEnabled,
    required this.bluetoothBusy,
    required this.rotationLock,
    required this.dnd,
    required this.dndReady,
    required this.profile,
    required this.onToggleWifi,
    required this.onOpenWifi,
    required this.onToggleBluetooth,
    required this.onOpenBluetooth,
    required this.onToggleRotation,
    required this.onToggleDnd,
    required this.onCycleProfile,
  });

  final Widget? mobileDataTile;
  final Widget? brightnessControl;
  final Widget? volumeControl;
  final Animation<double>? expansionProgress;
  final bool wifi;
  final String wifiSubtitle;
  final bool wifiEnabled;
  final bool wifiBusy;
  final bool bluetooth;
  final String bluetoothSubtitle;
  final bool bluetoothEnabled;
  final bool bluetoothBusy;
  final bool rotationLock;
  final bool dnd;
  final bool dndReady;
  final String profile;
  final VoidCallback onToggleWifi;
  final VoidCallback onOpenWifi;
  final VoidCallback onToggleBluetooth;
  final VoidCallback onOpenBluetooth;
  final VoidCallback onToggleRotation;
  final VoidCallback onToggleDnd;
  final VoidCallback onCycleProfile;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget reveal(
          int index,
          Widget child, {
          required double collapseTranslation,
        }) {
          final progress = expansionProgress;
          if (progress == null) return child;
          return ColorOsShadeElementReveal(
            progress: progress,
            threshold: ColorOsShadeMotion.contentElementThreshold,
            delay: ColorOsShadeMotion.nodeStagger * index,
            fade: false,
            collapseTranslation: collapseTranslation,
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
        // The ColorOS collapse chain adds a larger negative-Y offset to each
        // successive row. Include the node's bottom edge because Denial keeps
        // live glass fully opaque instead of hiding it with a save-layer fade.
        final firstRowExit = capsule + 28;
        final secondRowExit = row + tall + 28;
        final thirdRowExit = row * 3 + 28;
        final fourthRowExit = row * 4 + 28;
        return SizedBox(
          height: QuickSettingsGridMetrics.height * scale,
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
                  collapseTranslation: firstRowExit,
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
                  collapseTranslation: firstRowExit,
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
                  collapseTranslation: secondRowExit,
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
                  collapseTranslation: secondRowExit,
                ),
              ),
              if (mobileDataTile != null)
                Positioned(
                  left: pitch * 2,
                  top: row,
                  width: wide,
                  height: capsule,
                  child: reveal(
                    4,
                    mobileDataTile!,
                    collapseTranslation: secondRowExit,
                  ),
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
                  collapseTranslation: thirdRowExit,
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
                  collapseTranslation: thirdRowExit,
                ),
              ),
              Positioned(
                left: 0,
                top: row * 3,
                width: column,
                height: row,
                child: reveal(
                  7,
                  QuickTile(
                    icon: rotationLock
                        ? Icons.screen_lock_rotation_rounded
                        : Icons.screen_rotation_rounded,
                    title: l10n.quickSettingsRotation,
                    subtitle: rotationLock
                        ? l10n.quickSettingsLocked
                        : l10n.quickSettingsAutomatic,
                    active: !rotationLock,
                    onTap: onToggleRotation,
                  ),
                  collapseTranslation: fourthRowExit,
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

class _QuickTileState extends State<QuickTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final background = widget.active
        ? accent.primary
        : theme.cardColor(context.shellColors.tileOff);
    final foreground = widget.active
        ? accent.onPrimary
        : context.shellColors.panelText;
    final secondary = widget.active
        ? accent.onPrimary.withValues(alpha: 0.78)
        : context.shellColors.textTertiary;
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
          child: widget.wide
              ? _buildWide(background, foreground, secondary, radius)
              : _buildSmall(background, foreground, radius),
        ),
      ),
    );
  }

  Widget _buildWide(
    Color background,
    Color foreground,
    Color secondary,
    double radius,
  ) {
    final visualScale = ShadeReferenceGeometry.inverseScaleOf(context);
    return _animatedSurface(
      background: background,
      radius: radius,
      child: Padding(
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
                          color: foreground,
                        ),
                      )
                    : Icon(
                        widget.icon,
                        color: foreground,
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
                      color: foreground,
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
                        color: secondary,
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
                foreground: foreground,
                onPressed: widget.onDetails!,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmall(Color background, Color foreground, double radius) {
    final visualScale = ShadeReferenceGeometry.inverseScaleOf(context);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: QuickSettingsGridMetrics.capsule,
        height: QuickSettingsGridMetrics.row,
        child: Column(
          children: [
            SizedBox.square(
              dimension: QuickSettingsGridMetrics.capsule,
              child: _animatedSurface(
                background: background,
                radius: radius,
                child: Center(
                  child: widget.busy
                      ? SizedBox.square(
                          dimension: 22 * visualScale,
                          child: CircularProgressIndicator(
                            strokeWidth: 2 * visualScale,
                            color: foreground,
                          ),
                        )
                      : Icon(
                          widget.icon,
                          color: foreground,
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
        ),
      ),
    );
  }

  Widget _animatedSurface({
    required Color background,
    required double radius,
    required Widget child,
  }) {
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final borderRadius = BorderRadius.circular(radius);
    final surface = AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Motion.tile,
      curve: Motion.standard,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        border: _focused
            ? Border.all(color: accent.primary, width: 1.5)
            : theme.transparencyMode == ShellTransparencyMode.glass
            ? null
            : Border.all(
                color: widget.active
                    ? accent.primary
                    : context.shellColors.hairlineSoft,
              ),
      ),
      child: child,
    );
    return ShellBackdropBlur(
      blur:
          !widget.active &&
          theme.transparencyMode == ShellTransparencyMode.glass &&
          theme.effectivePanelOpacity < 1,
      separateChild: true,
      borderRadius: borderRadius,
      child: surface,
    );
  }
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
