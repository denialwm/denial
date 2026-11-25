import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../state/phone_triggers.dart';

/// Places where the shoulder triggers touch in the app in front. The app
/// stays visible under a light veil; the L and R marks are dragged to the
/// spots, held to clear, and saved per app id for deniald, which presses a
/// finger there while a trigger is held.
class PhoneTriggerPointsLayer extends ConsumerStatefulWidget {
  const PhoneTriggerPointsLayer({super.key});

  @override
  ConsumerState<PhoneTriggerPointsLayer> createState() =>
      _PhoneTriggerPointsLayerState();
}

class _PhoneTriggerPointsLayerState
    extends ConsumerState<PhoneTriggerPointsLayer> {
  static const double _markSize = 64;

  /// Where an unplaced mark waits, dimmed, until it is dragged.
  static const List<Offset> _waiting = <Offset>[
    Offset(0.2, 0.5),
    Offset(0.8, 0.5),
  ];

  String? _appId;
  List<Offset?> _points = <Offset?>[null, null];

  void _load(String? appId) {
    final points = appId == null
        ? const ShellTriggerPoints()
        : ref.read(shellSettingsProvider).phoneTriggers.pointsFor(appId);
    setState(() {
      _appId = appId;
      _points = <Offset?>[points.left, points.right];
    });
  }

  void _close() => ref.read(triggerPointsEditorProvider.notifier).close();

  void _save() {
    final appId = _appId;
    if (appId != null) {
      ref
          .read(shellSettingsProvider.notifier)
          .setPhoneTriggerPoints(
            appId,
            ShellTriggerPoints(left: _points[0], right: _points[1]),
          );
    }
    _close();
  }

  void _drag(int side, Offset position, Size size) {
    setState(() {
      _points[side] = Offset(
        (position.dx / size.width).clamp(0.0, 1.0),
        (position.dy / size.height).clamp(0.0, 1.0),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(
      triggerPointsEditorProvider,
      (_, appId) => _load(appId),
    );
    ref.listen<bool>(
      referenceShellProvider.select((state) => state.lockLayerVisible),
      (_, locked) {
        if (locked) _close();
      },
    );
    if (_appId == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    return ShellInputRegion(
      debugLabel: 'trigger points editor',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.exclusive,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _close,
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              final padding = MediaQuery.viewPaddingOf(context);
              return Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: ShellMediaColors.darkness.withValues(alpha: 0.35),
                  ),
                  Positioned(
                    left: 24,
                    right: 24,
                    top: padding.top + 24,
                    child: Text(
                      l10n.triggerPointsHint,
                      textAlign: TextAlign.center,
                      style: ShellText.base.copyWith(
                        color: ShellMediaColors.lightForeground,
                        fontSize: 15,
                        height: 1.35,
                      ),
                    ),
                  ),
                  for (final side in const <int>[0, 1])
                    _mark(context, side, size),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: padding.bottom + 24,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _TriggerEditorButton(
                          icon: Icons.close_rounded,
                          label: l10n.commonCancel,
                          onPressed: _close,
                        ),
                        const SizedBox(width: 12),
                        _TriggerEditorButton(
                          icon: Icons.delete_outline_rounded,
                          label: l10n.triggerPointsReset,
                          onPressed: () =>
                              setState(() => _points = <Offset?>[null, null]),
                        ),
                        const SizedBox(width: 12),
                        _TriggerEditorButton(
                          icon: Icons.check_rounded,
                          label: l10n.lockEditorDone,
                          primary: true,
                          onPressed: _save,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _mark(BuildContext context, int side, Size size) {
    final point = _points[side];
    final at = point ?? _waiting[side];
    final accent = ShellTheme.of(context).accentPalette;
    final placed = point != null;
    return Positioned(
      left: at.dx * size.width - _markSize / 2,
      top: at.dy * size.height - _markSize / 2,
      width: _markSize,
      height: _markSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          _drag(side, box.globalToLocal(details.globalPosition), size);
        },
        onLongPress: () => setState(() => _points[side] = null),
        child: Opacity(
          opacity: placed ? 1 : 0.5,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.container.withValues(alpha: 0.7),
              border: Border.all(color: accent.primary, width: 2),
            ),
            child: Center(
              child: Text(
                side == 0 ? 'L' : 'R',
                style: ShellText.cardTitle.copyWith(
                  color: accent.onContainer,
                  fontSize: 22,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TriggerEditorButton extends StatelessWidget {
  const _TriggerEditorButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final foreground = primary
        ? accent.onContainer
        : context.shellColors.textPrimary;
    return Semantics(
      excludeSemantics: true,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: primary
                ? accent.container
                : context.shellColors.surfaceContainerHigh,
            borderRadius: context.shellTheme.borderRadius(ShellRadii.chip),
            border: Border.all(
              color: primary ? accent.primary : context.shellColors.hairline,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: foreground),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: ShellText.base.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
