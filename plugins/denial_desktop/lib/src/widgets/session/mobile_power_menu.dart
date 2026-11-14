import 'dart:async';

import 'package:flutter/material.dart' show CircularProgressIndicator, Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/popups.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/system_services.dart'
    show hapticsServiceProvider;
import 'package:denial_flutter_sdk/tokens.dart';

/// The phone's power menu: lock, restart and power off as round buttons on
/// one glass island. Restart and power off ask for a second tap on the same
/// button, which lights up and says so.
void showMobilePowerMenu(WidgetRef ref) {
  final controller = ref.read(sessionPowerProvider.notifier);
  // A confirmation left from a menu closed while it asked starts over.
  controller.cancelConfirmation();
  unawaited(controller.refresh());
  ref
      .read(shellPopupControllerProvider.notifier)
      .show(
        keyName: 'mobile-power-menu',
        debugLabel: 'Mobile power menu',
        pointerPolicy: ShellPointerPolicy.fullScene,
        keyboardPolicy: ShellKeyboardPolicy.capture,
        dismissPolicy: ShellDismissPolicy.outsideTapAndEscape,
        builder: (_, handle) => _MobilePowerMenu(onClose: handle.close),
      );
}

class _MobilePowerMenu extends ConsumerWidget {
  const _MobilePowerMenu({required this.onClose});

  final VoidCallback onClose;

  static const List<SessionPowerAction> _actions = [
    SessionPowerAction.lock,
    SessionPowerAction.reboot,
    SessionPowerAction.powerOff,
  ];

  static const double _radius = 40;

  void _press(WidgetRef ref, SessionPowerAction action) {
    final state = ref.read(sessionPowerProvider);
    final controller = ref.read(sessionPowerProvider.notifier);
    if (state.busy) return;
    ref.read(hapticsServiceProvider).pulse();
    if (state.confirmationAction == action) {
      unawaited(controller.confirm());
      return;
    }
    controller.cancelConfirmation();
    unawaited(controller.request(action));
    if (!action.requiresConfirmation) onClose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionPowerProvider);
    final theme = ShellTheme.of(context);
    final l10n = context.l10n;
    final armed = state.confirmationAction;
    final note = switch (armed) {
      SessionPowerAction.reboot => l10n.mobilePowerTapToRestart,
      SessionPowerAction.powerOff => l10n.mobilePowerTapToPowerOff,
      _ when state.error != null => l10n.powerSessionRequestError,
      _ when state.initialized && !state.snapshot.serviceAvailable =>
        l10n.powerSessionUnavailable,
      _ => null,
    };
    final radius = BorderRadius.circular(_radius);
    return SafeArea(
      minimum: const EdgeInsets.all(16),
      child: Center(
        // Taps on the island stay on it; the scrim around it closes.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: l10n.mobilePowerMenuSemantics,
            child: ShellBackdropBlur(
              separateChild: true,
              blur: theme.effectivePanelOpacity < 1.0,
              borderRadius: radius,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.panelColor(context.shellColors.panelBackground),
                  borderRadius: radius,
                  border: Border.all(color: context.shellColors.hairline),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 30, 28, 26),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (index, action) in _actions.indexed) ...[
                            if (index > 0) const SizedBox(width: 22),
                            _MobilePowerButton(
                              action: action,
                              enabled:
                                  !state.busy &&
                                  state.availabilityFor(action).enabled,
                              armed: armed == action,
                              busy: state.busyAction == action,
                              onPressed: () => _press(ref, action),
                            ),
                          ],
                        ],
                      ),
                      AnimatedSize(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : Motion.cardSettle,
                        curve: Motion.md3EmphasizedDecelerate,
                        child: note == null
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.only(top: 20),
                                child: Text(
                                  note,
                                  textAlign: TextAlign.center,
                                  style: ShellText.base.copyWith(
                                    color: armed == null
                                        ? context.shellColors.textSecondary
                                        : context.shellColors.panelText,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobilePowerButton extends StatefulWidget {
  const _MobilePowerButton({
    required this.action,
    required this.enabled,
    required this.armed,
    required this.busy,
    required this.onPressed,
  });

  final SessionPowerAction action;
  final bool enabled;

  /// Tapped once: the next tap does it.
  final bool armed;
  final bool busy;
  final VoidCallback onPressed;

  @override
  State<_MobilePowerButton> createState() => _MobilePowerButtonState();
}

class _MobilePowerButtonState extends State<_MobilePowerButton> {
  static const double _size = 76;

  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (pressed != _pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final accent = ShellTheme.of(context).accentPalette;
    final l10n = context.l10n;
    final powerOff = widget.action == SessionPowerAction.powerOff;
    // Power off is red; an armed button fills with its colour.
    final (Color fill, Color foreground) = !widget.enabled
        ? (colors.tileOff, colors.textTertiary)
        : widget.armed
        ? powerOff
              ? (colors.performanceBad, const Color(0xFFFFFFFF))
              : (accent.primary, accent.onPrimary)
        : powerOff
        ? (colors.performanceBad.withValues(alpha: 0.18), colors.performanceBad)
        : (accent.container, accent.onContainer);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.tile;
    final label = switch (widget.action) {
      SessionPowerAction.lock => l10n.powerActionLock,
      SessionPowerAction.reboot => l10n.powerActionRestart,
      _ => l10n.powerActionPowerOff,
    };
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: widget.enabled ? widget.onPressed : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: _pressed
                  ? 0.92
                  : widget.armed
                  ? 1.08
                  : 1.0,
              duration: duration,
              curve: Motion.md3EmphasizedDecelerate,
              child: AnimatedContainer(
                duration: duration,
                width: _size,
                height: _size,
                decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                child: widget.busy
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: foreground,
                        ),
                      )
                    : Icon(_icon(widget.action), size: 32, color: foreground),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style: ShellText.cardTitle.copyWith(
                color: widget.enabled ? colors.panelText : colors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _icon(SessionPowerAction action) => switch (action) {
    SessionPowerAction.lock => Icons.lock_rounded,
    SessionPowerAction.reboot => Icons.restart_alt_rounded,
    _ => Icons.power_settings_new_rounded,
  };
}
