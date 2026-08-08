import 'package:flutter/material.dart'
    show CircularProgressIndicator, Icons, IconData, Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../services/power_profile_service.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';

/// The grid of quick-settings tiles. Purely presentational: every value and
/// callback is supplied by the panel.
class QuickSettingsTiles extends StatelessWidget {
  const QuickSettingsTiles({
    super.key,
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
    required this.keyboardOpening,
    required this.onToggleWifi,
    required this.onOpenWifi,
    required this.onToggleBluetooth,
    required this.onOpenBluetooth,
    required this.onToggleRotation,
    required this.onToggleDnd,
    required this.onCycleProfile,
    required this.onOpenKeyboard,
  });

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
  final bool keyboardOpening;
  final VoidCallback onToggleWifi;
  final VoidCallback onOpenWifi;
  final VoidCallback onToggleBluetooth;
  final VoidCallback onOpenBluetooth;
  final VoidCallback onToggleRotation;
  final VoidCallback onToggleDnd;
  final VoidCallback onCycleProfile;
  final VoidCallback onOpenKeyboard;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final cell = ((constraints.maxWidth - gap * 3) / 4)
            .clamp(58.0, double.infinity)
            .toDouble();
        final wide = cell * 2 + gap;

        return Column(
          children: [
            Row(
              children: [
                SizedBox(
                  width: wide,
                  height: 72,
                  child: QuickTile(
                    icon: _profileIcon(profile),
                    title: l10n.quickSettingsPerformance,
                    subtitle: _profileLabel(profile, l10n),
                    active: profile != PowerProfile.balanced,
                    onTap: onCycleProfile,
                    wide: true,
                  ),
                ),
                const SizedBox(width: gap),
                SizedBox(
                  width: wide,
                  height: 72,
                  child: QuickTile(
                    icon: Icons.notifications_off_rounded,
                    title: l10n.quickSettingsSilent,
                    subtitle: dndReady
                        ? (dnd ? l10n.commonOn : l10n.quickSettingsNormal)
                        : l10n.commonLoading,
                    active: dnd,
                    enabled: dndReady,
                    onTap: onToggleDnd,
                    wide: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: gap),
            Row(
              children: [
                SizedBox(
                  width: wide,
                  height: 72,
                  child: QuickTile(
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
                ),
                const SizedBox(width: gap),
                SizedBox(
                  width: wide,
                  height: 72,
                  child: QuickTile(
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
                ),
              ],
            ),
            const SizedBox(height: gap),
            Row(
              children: [
                SizedBox(
                  width: wide,
                  height: 68,
                  child: QuickTile(
                    icon: Icons.screen_rotation_rounded,
                    title: l10n.quickSettingsRotation,
                    subtitle: rotationLock
                        ? l10n.quickSettingsLocked
                        : l10n.quickSettingsAutomatic,
                    active: !rotationLock,
                    onTap: onToggleRotation,
                    wide: true,
                  ),
                ),
                const SizedBox(width: gap),
                SizedBox(
                  width: wide,
                  height: 68,
                  child: QuickTile(
                    icon: Icons.keyboard_rounded,
                    title: l10n.quickSettingsKeyboard,
                    subtitle: keyboardOpening
                        ? l10n.commonOpening
                        : l10n.quickSettingsOpenOnScreen,
                    active: false,
                    onTap: keyboardOpening ? _noop : onOpenKeyboard,
                    wide: true,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  static void _noop() {}
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
    final accent = ShellTheme.of(context).accent;
    final background = widget.active
        ? ShellColors.primaryContainer
        : ShellColors.tileOff;
    final foreground = widget.active
        ? ShellColors.onPrimaryContainer
        : ShellColors.panelText;
    final secondary = widget.active
        ? ShellColors.onPrimaryContainerSecondary
        : ShellColors.textTertiary;
    final radius = widget.wide ? ShellRadii.tileWide : ShellRadii.tile;

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
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.tile,
            curve: Motion.standard,
            padding: EdgeInsets.symmetric(horizontal: widget.wide ? 18 : 10),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: _focused
                    ? accent
                    : widget.active
                    ? ShellColors.surfaceTint
                    : ShellColors.hairlineSoft,
                width: _focused ? 1.5 : 1,
              ),
            ),
            child: widget.wide
                ? _buildWide(foreground, secondary)
                : _buildSmall(foreground),
          ),
        ),
      ),
    );
  }

  Widget _buildWide(Color foreground, Color secondary) {
    return Row(
      children: [
        _TileIcon(
          icon: widget.icon,
          active: widget.active,
          busy: widget.busy,
          foreground: foreground,
          size: 42,
          iconSize: 24,
        ),
        const SizedBox(width: 12),
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
                  fontSize: 15,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                  decoration: TextDecoration.none,
                ),
              ),
              if (widget.subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  widget.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: secondary,
                    fontSize: 13,
                    height: 1,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (widget.onDetails != null) ...[
          const SizedBox(width: 6),
          _TileDetailsButton(
            label: context.l10n.quickSettingsOpenDetails(widget.title),
            foreground: foreground,
            onPressed: widget.onDetails!,
          ),
        ],
      ],
    );
  }

  Widget _buildSmall(Color foreground) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _TileIcon(
          icon: widget.icon,
          active: widget.active,
          busy: widget.busy,
          foreground: foreground,
          size: 34,
          iconSize: 21,
        ),
        const SizedBox(height: 7),
        Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: foreground,
            fontSize: 12,
            height: 1,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }
}

class _TileIcon extends StatelessWidget {
  const _TileIcon({
    required this.icon,
    required this.active,
    required this.busy,
    required this.foreground,
    required this.size,
    required this.iconSize,
  });

  final IconData icon;
  final bool active;
  final bool busy;
  final Color foreground;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? ShellColors.tileIconActive : ShellColors.tileIcon,
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: busy
            ? Padding(
                padding: EdgeInsets.all(size * 0.27),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: foreground,
                ),
              )
            : Icon(icon, color: foreground, size: iconSize),
      ),
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
                  ? ShellColors.surfaceContainerHighest
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(10),
              border: _focused ? Border.all(color: accent) : null,
            ),
            child: SizedBox.square(
              dimension: 34,
              child: Icon(
                Icons.chevron_right_rounded,
                size: 21,
                color: widget.foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shade footer: an "app active" chip plus two round action buttons.
class ShadeFooter extends StatelessWidget {
  const ShadeFooter({super.key, required this.onOpenPower});

  final VoidCallback onOpenPower;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        Container(
          height: 42,
          padding: const EdgeInsets.only(left: 8, right: 16),
          decoration: BoxDecoration(
            color: ShellColors.chip,
            borderRadius: BorderRadius.circular(ShellRadii.chip),
            border: Border.all(color: ShellColors.hairlineSoft),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _FooterStatusIcon(),
              const SizedBox(width: 10),
              Text(
                l10n.quickSettingsOneAppActive,
                style: const TextStyle(
                  color: ShellColors.panelText,
                  fontSize: 14,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        _RoundButton(
          label: l10n.quickSettingsSettingsUnavailable,
          icon: Icons.settings_rounded,
        ),
        const SizedBox(width: 12),
        _RoundButton(
          label: l10n.desktopOpenPowerControls,
          icon: Icons.power_settings_new_rounded,
          onPressed: onOpenPower,
        ),
      ],
    );
  }
}

class _FooterStatusIcon extends StatelessWidget {
  const _FooterStatusIcon();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.secondaryContainer,
        borderRadius: BorderRadius.circular(13),
      ),
      child: const SizedBox(
        width: 26,
        height: 26,
        child: Icon(
          Icons.info_rounded,
          color: ShellColors.onSecondaryContainer,
          size: 17,
        ),
      ),
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
    final accent = ShellTheme.of(context).accent;
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
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ShellColors.chip,
                borderRadius: BorderRadius.circular(ShellRadii.roundButton),
                border: Border.all(
                  color: _focused ? accent : ShellColors.hairlineSoft,
                ),
              ),
              child: SizedBox(
                width: 42,
                height: 42,
                child: Icon(
                  widget.icon,
                  color: enabled
                      ? ShellColors.onSecondaryContainer
                      : ShellColors.textTertiary,
                  size: 21,
                ),
              ),
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
