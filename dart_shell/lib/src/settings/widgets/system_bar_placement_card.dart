import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../localization/denial_localizations.dart';
import '../../models/display_layout.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';

const settingsSystemBarPlacementCardKey =
    ValueKey<String>('settings-system-bar-placement-card');

typedef SystemBarPlacementChanged = void Function(
  SystemBarSide side,
  List<int> monitorIds,
);

class SystemBarPlacementCard extends StatelessWidget {
  const SystemBarPlacementCard({
    super.key,
    required this.layout,
    required this.onChanged,
  });

  final DisplayLayout? layout;
  final SystemBarPlacementChanged onChanged;

  void _setSide(SystemBarSide side) {
    final current = layout;
    if (current == null) {
      return;
    }
    onChanged(side, current.effectiveSystemBarMonitorIds);
  }

  void _toggleOutput(int monitorId) {
    final current = layout;
    if (current == null) {
      return;
    }
    final selected = current.effectiveSystemBarMonitorIds.toSet();
    if (selected.contains(monitorId)) {
      if (selected.length == 1) {
        return;
      }
      selected.remove(monitorId);
    } else {
      selected.add(monitorId);
    }
    final ordered = current.outputs
        .where((output) => selected.contains(output.monitorId))
        .map((output) => output.monitorId)
        .toList(growable: false);
    onChanged(current.systemBarSide, ordered);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current = layout;
    final selected = current?.effectiveSystemBarMonitorIds.toSet() ?? <int>{};
    return DecoratedBox(
      key: settingsSystemBarPlacementCardKey,
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(ShellRadii.tile),
        border: Border.all(color: ShellColors.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _CardHeader(),
            const SizedBox(height: 22),
            _SettingLabel(label: l10n.settingsSystemBarEdgeLabel),
            const SizedBox(height: 10),
            _EdgeSelector(
              selected: current?.systemBarSide ?? SystemBarSide.hidden,
              enabled: current != null,
              onSelected: _setSide,
            ),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _SettingLabel(label: l10n.settingsSystemBarDisplaysLabel),
                const Spacer(),
                if (current != null)
                  Text(
                    l10n.settingsSystemBarDisplaysSelected(selected.length),
                    style: ShellText.cardTitle.copyWith(
                      color: ShellColors.textTertiary,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              l10n.settingsSystemBarCloneHint,
              style: ShellText.base.copyWith(
                color: ShellColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            if (current == null || current.outputs.isEmpty)
              _UnavailableMessage(label: l10n.settingsSystemBarUnavailable)
            else
              _DisplaySelector(
                layout: current,
                selectedMonitorIds: selected,
                onToggle: _toggleOutput,
              ),
          ],
        ),
      ),
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            color: ShellColors.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: SizedBox.square(
            dimension: 42,
            child: ExcludeSemantics(
              child: Icon(
                Icons.view_day_rounded,
                size: 21,
                color: ShellColors.onPrimaryContainer,
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.settingsSystemBarTitle, style: ShellText.statusClock),
              const SizedBox(height: 7),
              Text(
                l10n.settingsSystemBarDescription,
                style: ShellText.base.copyWith(
                  color: ShellColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingLabel extends StatelessWidget {
  const _SettingLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: ShellText.cardTitle.copyWith(
        color: ShellColors.textTertiary,
        fontSize: 10,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _EdgeSelector extends StatelessWidget {
  const _EdgeSelector({
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final SystemBarSide selected;
  final bool enabled;
  final ValueChanged<SystemBarSide> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final choices = <({SystemBarSide side, IconData icon, String label})>[
      (
        side: SystemBarSide.top,
        icon: Icons.vertical_align_top_rounded,
        label: l10n.settingsSystemBarEdgeTop,
      ),
      (
        side: SystemBarSide.bottom,
        icon: Icons.vertical_align_bottom_rounded,
        label: l10n.settingsSystemBarEdgeBottom,
      ),
      (
        side: SystemBarSide.left,
        icon: Icons.align_horizontal_left_rounded,
        label: l10n.settingsSystemBarEdgeLeft,
      ),
      (
        side: SystemBarSide.right,
        icon: Icons.align_horizontal_right_rounded,
        label: l10n.settingsSystemBarEdgeRight,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 430 ? 2 : 4;
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final choice in choices)
              SizedBox(
                width: width,
                child: _EdgeChoice(
                  side: choice.side,
                  icon: choice.icon,
                  label: choice.label,
                  selected: choice.side == selected,
                  enabled: enabled,
                  onPressed: () => onSelected(choice.side),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EdgeChoice extends StatefulWidget {
  const _EdgeChoice({
    required this.side,
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onPressed,
  });

  final SystemBarSide side;
  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_EdgeChoice> createState() => _EdgeChoiceState();
}

class _EdgeChoiceState extends State<_EdgeChoice> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.enabled && (_hovered || _focused);
    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: widget.enabled,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor:
            widget.enabled ? ShellMouseCursors.link : SystemMouseCursors.basic,
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
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: widget.selected
                  ? ShellColors.primaryContainer
                  : highlighted
                      ? ShellColors.surfaceContainerHighest
                      : ShellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShellRadii.chip),
              border: Border.all(
                color: _focused || widget.selected
                    ? ShellColors.accent
                    : ShellColors.hairline,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.icon,
                  size: 17,
                  color: widget.selected
                      ? ShellColors.onPrimaryContainer
                      : ShellColors.textSecondary,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.cardTitle.copyWith(
                      color: widget.selected
                          ? ShellColors.onPrimaryContainer
                          : ShellColors.textSecondary,
                    ),
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

class _DisplaySelector extends StatelessWidget {
  const _DisplaySelector({
    required this.layout,
    required this.selectedMonitorIds,
    required this.onToggle,
  });

  final DisplayLayout layout;
  final Set<int> selectedMonitorIds;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 520 ? 1 : 2;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final output in layout.outputs)
              SizedBox(
                key: ValueKey<String>(
                  'settings-system-bar-display-${output.monitorId}',
                ),
                width: width,
                child: _DisplayChoice(
                  output: output,
                  side: layout.systemBarSide,
                  selected: selectedMonitorIds.contains(output.monitorId),
                  isMain: output.monitorId == layout.tickerMonitorId,
                  canDeselect: selectedMonitorIds.length > 1,
                  onPressed: () => onToggle(output.monitorId),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DisplayChoice extends StatefulWidget {
  const _DisplayChoice({
    required this.output,
    required this.side,
    required this.selected,
    required this.isMain,
    required this.canDeselect,
    required this.onPressed,
  });

  final DisplayOutput output;
  final SystemBarSide side;
  final bool selected;
  final bool isMain;
  final bool canDeselect;
  final VoidCallback onPressed;

  @override
  State<_DisplayChoice> createState() => _DisplayChoiceState();
}

class _DisplayChoiceState extends State<_DisplayChoice> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = !widget.selected || widget.canDeselect;
    final scale = widget.output.scale.toStringAsFixed(
      widget.output.scale == widget.output.scale.roundToDouble() ? 0 : 2,
    );
    final details = l10n.settingsSystemBarDisplayDetails(
      widget.output.pixelSize.width.round(),
      widget.output.pixelSize.height.round(),
      scale,
    );
    final semanticsValue = widget.selected
        ? l10n.settingsSystemBarDisplaySelectedSemantics(widget.output.name)
        : l10n.settingsSystemBarDisplayNotSelectedSemantics(widget.output.name);
    final highlighted = enabled && (_hovered || _focused);
    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: enabled,
      label: widget.output.name,
      value: semanticsValue,
      hint: widget.selected && !widget.canDeselect
          ? l10n.settingsSystemBarLastDisplayHint
          : null,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor:
            enabled ? ShellMouseCursors.link : SystemMouseCursors.basic,
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
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: widget.selected
                  ? ShellColors.primaryContainer.withAlpha(110)
                  : highlighted
                      ? ShellColors.surfaceContainerHighest
                      : ShellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShellRadii.chip),
              border: Border.all(
                color: _focused || widget.selected
                    ? ShellColors.accent
                    : ShellColors.hairline,
              ),
            ),
            child: Row(
              children: [
                _MonitorPreview(
                  side: widget.side,
                  selected: widget.selected,
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.output.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ShellText.cardTitle.copyWith(
                                color: ShellColors.textPrimary,
                              ),
                            ),
                          ),
                          if (widget.isMain) ...[
                            const SizedBox(width: 6),
                            _MainBadge(
                                label: l10n.settingsSystemBarMainDisplay),
                          ],
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        details,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.base.copyWith(
                          color: ShellColors.textTertiary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  widget.selected
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 19,
                  color: widget.selected
                      ? ShellColors.accent
                      : ShellColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MonitorPreview extends StatelessWidget {
  const _MonitorPreview({required this.side, required this.selected});

  final SystemBarSide side;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? ShellColors.accent : ShellColors.textTertiary,
        borderRadius: BorderRadius.circular(2),
      ),
    );
    return AnimatedContainer(
      duration: Motion.tile,
      width: 68,
      height: 43,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: ShellColors.windowFrameSurface,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: selected ? ShellColors.accent : ShellColors.hairline,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: ShellColors.accent.withAlpha(70),
                  blurRadius: 12,
                  spreadRadius: -2,
                ),
              ]
            : null,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ShellColors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          switch (side) {
            SystemBarSide.top => Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 4,
                child: bar,
              ),
            SystemBarSide.bottom => Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 4,
                child: bar,
              ),
            SystemBarSide.left => Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                width: 4,
                child: bar,
              ),
            SystemBarSide.right => Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: 4,
                child: bar,
              ),
            SystemBarSide.hidden => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }
}

class _MainBadge extends StatelessWidget {
  const _MainBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(ShellRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          label,
          style: ShellText.cardTitle.copyWith(
            color: ShellColors.textTertiary,
            fontSize: 7,
            letterSpacing: 0.7,
          ),
        ),
      ),
    );
  }
}

class _UnavailableMessage extends StatelessWidget {
  const _UnavailableMessage({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShellRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          label,
          style: ShellText.base.copyWith(color: ShellColors.textSecondary),
        ),
      ),
    );
  }
}
