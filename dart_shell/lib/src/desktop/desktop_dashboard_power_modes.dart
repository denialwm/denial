part of 'desktop_shell.dart';

class DesktopPowerModesSection extends ConsumerWidget {
  const DesktopPowerModesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modes = ref.watch(desktopPowerModesProvider);

    // The system profile is the primary control in this ordered group. Until
    // it is editable, the remaining hardware-specific controls should not
    // surface as a standalone power-modes section.
    if (!modes.systemAvailable) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _DesktopPowerModesCard(modes: modes),
    );
  }
}

class _DesktopPowerModesCard extends ConsumerWidget {
  const _DesktopPowerModesCard({required this.modes});

  final DesktopPowerModesState modes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(desktopPowerModesProvider.notifier);
    final systemEnabled = modes.systemAvailable && !modes.systemChanging;
    final pboEnabled = modes.pboAvailable && !modes.pboChanging;
    final gpuEnabled = modes.gpuAvailable && !modes.gpuChanging;
    final accent = ShellTheme.of(context).accent;
    final l10n = context.l10n;

    return _DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 21, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.desktopPowerModesTitle,
                  style: context.shellTheme.text.cardTitle,
                ),
              ),
              _DashboardIconButton(
                semanticLabel: l10n.desktopRefreshPowerModes,
                icon: Icons.refresh_rounded,
                busy: modes.refreshing,
                enabled:
                    !modes.systemChanging &&
                    !modes.pboChanging &&
                    !modes.gpuChanging,
                onTap: () => unawaited(controller.refresh()),
              ),
            ],
          ),
          const SizedBox(height: 11),
          _PowerModeRow(
            label: l10n.desktopSystemProfile,
            children: [
              _PowerModeOption(
                semanticLabel: l10n.desktopSystemProfilePowerSaver,
                icon: Icons.energy_savings_leaf_rounded,
                selected: modes.systemProfile == PowerProfile.powerSave,
                busy:
                    modes.systemChanging &&
                    modes.systemProfile == PowerProfile.powerSave,
                enabled: systemEnabled,
                onTap: () => unawaited(
                  controller.selectSystemProfile(PowerProfile.powerSave),
                ),
              ),
              _PowerModeOption(
                semanticLabel: l10n.desktopSystemProfileBalanced,
                icon: Icons.balance_rounded,
                selected: modes.systemProfile == PowerProfile.balanced,
                busy:
                    modes.systemChanging &&
                    modes.systemProfile == PowerProfile.balanced,
                enabled: systemEnabled,
                onTap: () => unawaited(
                  controller.selectSystemProfile(PowerProfile.balanced),
                ),
              ),
              _PowerModeOption(
                semanticLabel: l10n.desktopSystemProfilePerformance,
                icon: Icons.rocket_launch_rounded,
                selected: modes.systemProfile == PowerProfile.performance,
                busy:
                    modes.systemChanging &&
                    modes.systemProfile == PowerProfile.performance,
                enabled: systemEnabled,
                onTap: () => unawaited(
                  controller.selectSystemProfile(PowerProfile.performance),
                ),
              ),
            ],
          ),
          if (modes.pboAvailable) ...[
            const SizedBox(height: 8),
            _PowerModeRow(
              label: l10n.desktopPboLabel,
              children: [
                _PowerModeOption(
                  semanticLabel: l10n.desktopPboSilent,
                  icon: Icons.bedtime_rounded,
                  selected: modes.pboProfile == DesktopPboProfile.silent,
                  busy:
                      modes.pboChanging &&
                      modes.pboProfile == DesktopPboProfile.silent,
                  enabled: pboEnabled,
                  secondary: true,
                  onTap: () => unawaited(
                    controller.selectPboProfile(DesktopPboProfile.silent),
                  ),
                ),
                _PowerModeOption(
                  semanticLabel: l10n.desktopPboBalanced,
                  icon: Icons.balance_rounded,
                  selected: modes.pboProfile == DesktopPboProfile.balanced,
                  busy:
                      modes.pboChanging &&
                      modes.pboProfile == DesktopPboProfile.balanced,
                  enabled: pboEnabled,
                  secondary: true,
                  onTap: () => unawaited(
                    controller.selectPboProfile(DesktopPboProfile.balanced),
                  ),
                ),
                _PowerModeOption(
                  semanticLabel: l10n.desktopPboPerformance,
                  icon: Icons.speed_rounded,
                  selected: modes.pboProfile == DesktopPboProfile.performance,
                  busy:
                      modes.pboChanging &&
                      modes.pboProfile == DesktopPboProfile.performance,
                  enabled: pboEnabled,
                  secondary: true,
                  onTap: () => unawaited(
                    controller.selectPboProfile(DesktopPboProfile.performance),
                  ),
                ),
              ],
            ),
          ],
          if (modes.gpuAvailable) ...[
            const SizedBox(height: 8),
            _PowerModeRow(
              label: l10n.desktopGpuLabel,
              children: [
                _PowerModeOption(
                  semanticLabel: l10n.desktopGpuPresetLow,
                  icon: Icons.keyboard_double_arrow_down_rounded,
                  selected:
                      modes.gpuPerformancePreset == LactPerformancePreset.low,
                  busy:
                      modes.gpuChanging &&
                      modes.gpuPerformancePreset == LactPerformancePreset.low,
                  enabled: gpuEnabled,
                  secondary: true,
                  onTap: () => unawaited(
                    controller.selectGpuPerformancePreset(
                      LactPerformancePreset.low,
                    ),
                  ),
                ),
                _PowerModeOption(
                  semanticLabel: l10n.desktopGpuPresetAutomatic,
                  icon: Icons.auto_mode_rounded,
                  selected:
                      modes.gpuPerformancePreset ==
                      LactPerformancePreset.automatic,
                  busy:
                      modes.gpuChanging &&
                      modes.gpuPerformancePreset ==
                          LactPerformancePreset.automatic,
                  enabled: gpuEnabled,
                  secondary: true,
                  onTap: () => unawaited(
                    controller.selectGpuPerformancePreset(
                      LactPerformancePreset.automatic,
                    ),
                  ),
                ),
                _PowerModeOption(
                  semanticLabel: l10n.desktopGpuPresetHigh,
                  icon: Icons.keyboard_double_arrow_up_rounded,
                  selected:
                      modes.gpuPerformancePreset == LactPerformancePreset.high,
                  busy:
                      modes.gpuChanging &&
                      modes.gpuPerformancePreset == LactPerformancePreset.high,
                  enabled: gpuEnabled,
                  secondary: true,
                  onTap: () => unawaited(
                    controller.selectGpuPerformancePreset(
                      LactPerformancePreset.high,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (modes.error != null) ...[
            const SizedBox(height: 9),
            Text(
              l10n.desktopPowerModesUnavailable,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.shellTheme.text.cardTitle.copyWith(
                color: context.shellColors.performanceBad,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PowerModeRow extends StatelessWidget {
  const _PowerModeRow({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.shellTheme.text.cardTitle.copyWith(
              color: context.shellColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: context.shellColors.surfaceContainer,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: context.shellColors.hairlineSoft),
          ),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ],
    );
  }
}

class _PowerModeOption extends StatefulWidget {
  const _PowerModeOption({
    required this.semanticLabel,
    required this.icon,
    required this.selected,
    required this.busy,
    required this.enabled,
    required this.onTap,
    this.secondary = false,
  });

  final String semanticLabel;
  final IconData icon;
  final bool selected;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  final bool secondary;

  @override
  State<_PowerModeOption> createState() => _PowerModeOptionState();
}

class _PowerModeOptionState extends State<_PowerModeOption> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final actionable = widget.enabled && !widget.busy;
    final accent = ShellTheme.of(context).accentPalette;
    final selectedBackground = widget.secondary
        ? accent.mutedContainer
        : accent.container;
    final selectedForeground = widget.secondary
        ? accent.onMutedContainer
        : accent.onContainer;

    return Semantics(
      button: true,
      enabled: widget.enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.busy
            ? ShellMouseCursors.working
            : actionable
            ? ShellMouseCursors.link
            : ShellMouseCursors.normal,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (actionable) {
                widget.onTap();
              }
              return null;
            },
          ),
        },
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: actionable ? widget.onTap : null,
          child: AnimatedContainer(
            duration: Motion.pill,
            curve: Motion.standard,
            width: 36,
            height: 32,
            decoration: BoxDecoration(
              color: widget.selected
                  ? selectedBackground
                  : _hovered
                  ? context.shellColors.surfaceContainerHighest
                  : ShellMediaColors.transparentDark,
              borderRadius: BorderRadius.circular(12),
              border: _focused
                  ? Border.all(color: accent.primary, width: 1.5)
                  : null,
            ),
            child: widget.busy
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent.primary,
                    ),
                  )
                : Icon(
                    widget.icon,
                    size: 18,
                    color: !widget.enabled
                        ? context.shellColors.glyphInactive
                        : widget.selected
                        ? selectedForeground
                        : context.shellColors.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }
}
