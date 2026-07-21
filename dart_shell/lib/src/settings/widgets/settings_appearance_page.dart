import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../localization/denial_localizations.dart';
import '../../models/display_layout.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';
import '../color_format.dart';
import 'system_bar_placement_card.dart';

const settingsFocusedBorderColorTriggerKey =
    ValueKey<String>('settings-focused-border-color-trigger');

class SettingsAppearancePage extends StatelessWidget {
  const SettingsAppearancePage({
    super.key,
    required this.focusedBorderColor,
    required this.onOpenColorPicker,
    required this.displayLayout,
    required this.onSystemBarChanged,
  });

  final Color focusedBorderColor;
  final VoidCallback onOpenColorPicker;
  final DisplayLayout? displayLayout;
  final SystemBarPlacementChanged onSystemBarChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 26, 28, 32),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionEyebrow(),
              const SizedBox(height: 18),
              Text(
                l10n.settingsAppearanceTitle,
                style: const TextStyle(
                  color: ShellColors.textPrimary,
                  fontSize: 25,
                  height: 1.12,
                  fontWeight: FontWeight.w800,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.settingsAppearanceDescription,
                style: ShellText.base.copyWith(
                  color: ShellColors.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 24),
              SystemBarPlacementCard(
                layout: displayLayout,
                onChanged: onSystemBarChanged,
              ),
              const SizedBox(height: 16),
              _FocusedBorderColorCard(
                color: focusedBorderColor,
                onPressed: onOpenColorPicker,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionEyebrow extends StatelessWidget {
  const _SectionEyebrow();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        const Icon(
          Icons.palette_outlined,
          size: 16,
          color: ShellColors.accent,
        ),
        const SizedBox(width: 8),
        Text(
          l10n.settingsAppearanceSection,
          style: ShellText.cardTitle.copyWith(
            color: ShellColors.accent,
            fontSize: 11,
            letterSpacing: 1.4,
          ),
        ),
        const Spacer(),
        const _LiveBadge(),
      ],
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      label: l10n.settingsLiveChangesSemanticsLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShellColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShellRadii.chip),
          border: Border.all(color: ShellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: ShellColors.gestureArmed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                l10n.settingsLiveBadge,
                style: ShellText.cardTitle.copyWith(
                  color: ShellColors.textSecondary,
                  fontSize: 9,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FocusedBorderColorCard extends StatelessWidget {
  const _FocusedBorderColorCard({
    required this.color,
    required this.onPressed,
  });

  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        final description = Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.settingsFocusedBorderTitle,
                style: ShellText.statusClock,
              ),
              const SizedBox(height: 7),
              Text(
                l10n.settingsFocusedBorderDescription,
                style: ShellText.base.copyWith(
                  color: ShellColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        );
        return DecoratedBox(
          decoration: BoxDecoration(
            color: ShellColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(ShellRadii.tile),
            border: Border.all(color: ShellColors.hairline),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _ActiveWindowPreview(color: color),
                          const SizedBox(width: 16),
                          description,
                        ],
                      ),
                      const SizedBox(height: 18),
                      _ColorTrigger(color: color, onPressed: onPressed),
                    ],
                  )
                : Row(
                    children: [
                      _ActiveWindowPreview(color: color),
                      const SizedBox(width: 20),
                      description,
                      const SizedBox(width: 20),
                      _ColorTrigger(color: color, onPressed: onPressed),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _ActiveWindowPreview extends StatelessWidget {
  const _ActiveWindowPreview({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: context.l10n.settingsFocusedBorderPreviewSemanticsLabel,
      child: AnimatedContainer(
        duration: Motion.tile,
        curve: Motion.standard,
        width: 104,
        height: 70,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: ShellColors.windowFrameSurface,
          borderRadius: BorderRadius.circular(ShellRadii.window + 2),
          border: Border.all(color: color, width: 2),
          boxShadow: [
            BoxShadow(
              color: color.withAlpha(48),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ShellColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(ShellRadii.window - 1),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  _PreviewDot(color: ShellColors.performanceBad),
                  SizedBox(width: 4),
                  _PreviewDot(color: ShellColors.performanceWarning),
                  SizedBox(width: 4),
                  _PreviewDot(color: ShellColors.gestureArmed),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewDot extends StatelessWidget {
  const _PreviewDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: const SizedBox.square(dimension: 5),
    );
  }
}

class _ColorTrigger extends StatefulWidget {
  const _ColorTrigger({required this.color, required this.onPressed});

  final Color color;
  final VoidCallback onPressed;

  @override
  State<_ColorTrigger> createState() => _ColorTriggerState();
}

class _ColorTriggerState extends State<_ColorTrigger> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final hex = formatOpaqueColorHex(widget.color);
    final highlighted = _hovered || _focused;
    return Semantics(
      button: true,
      label: context.l10n.settingsFocusedBorderChangeSemanticsLabel,
      value: hex,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
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
          key: settingsFocusedBorderColorTriggerKey,
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            height: 48,
            padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
            decoration: BoxDecoration(
              color: highlighted
                  ? ShellColors.surfaceContainerHighest
                  : ShellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShellRadii.chip),
              border: Border.all(
                color: _focused ? ShellColors.accent : ShellColors.hairline,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: Motion.tile,
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                    border: Border.all(color: ShellColors.panelHighlight),
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  hex,
                  style: ShellText.cardTitle.copyWith(
                    color: ShellColors.textSecondary,
                    fontFamily: ShellText.systemBarFontFamily,
                  ),
                ),
                const SizedBox(width: 7),
                const Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: ShellColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
