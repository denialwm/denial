part of 'desktop_shell.dart';

class _AppVolumeManagerSurface extends ConsumerWidget {
  const _AppVolumeManagerSurface({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.watch(appAudioProvider);
    final controller = ref.read(appAudioProvider.notifier);
    return MainOutputCenteredSurface(
      builder: (context, constraints) {
        final panelWidth = math.min(560.0, constraints.maxWidth);
        final panelHeight = math.min(520.0, constraints.maxHeight);
        return SizedBox(
          width: panelWidth,
          height: panelHeight,
          child: _AppVolumeManagerPanel(
            state: audio,
            onRefresh: controller.refresh,
            onDismiss: onDismiss,
            onChanged: controller.setVolume,
            onChangeEnd: controller.commitVolume,
          ),
        );
      },
    );
  }
}

class _AppVolumeManagerPanel extends StatelessWidget {
  const _AppVolumeManagerPanel({
    required this.state,
    required this.onRefresh,
    required this.onDismiss,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final AppAudioState state;
  final VoidCallback onRefresh;
  final VoidCallback onDismiss;
  final void Function(int streamId, double value) onChanged;
  final void Function(int streamId, double value) onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final l10n = context.l10n;
    return FocusTraversalGroup(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.panelColor(context.shellColors.panelBackground),
          borderRadius: BorderRadius.circular(theme.panelRadius),
          border: Border.all(color: context.shellColors.hairline),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(theme.panelRadius),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 18, 16),
                child: Row(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: accent.container,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox(
                        width: 42,
                        height: 42,
                        child: Icon(
                          Icons.graphic_eq_rounded,
                          size: 23,
                          color: accent.onContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.desktopApplicationVolumeTitle,
                            style: context.shellTheme.text.statusClock.copyWith(
                              fontSize: 20,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            l10n.desktopApplicationVolumeDescription,
                            style: context.shellTheme.text.cardTitle.copyWith(
                              color: context.shellColors.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _DashboardIconButton(
                      semanticLabel: l10n.desktopRefreshApplicationAudio,
                      icon: Icons.refresh_rounded,
                      busy: state.loading,
                      onTap: onRefresh,
                    ),
                    const SizedBox(width: 8),
                    _DashboardIconButton(
                      semanticLabel: l10n.desktopCloseApplicationAudio,
                      icon: Icons.close_rounded,
                      onTap: onDismiss,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: context.shellColors.hairlineSoft),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = context.l10n;
    if (state.loading && state.streams.isEmpty) {
      return Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: ShellTheme.of(context).accent,
          ),
        ),
      );
    }
    if (state.error != null && state.streams.isEmpty) {
      return _AppVolumeManagerMessage(
        icon: Icons.cloud_off_rounded,
        message: l10n.desktopApplicationAudioUnavailable,
        actionLabel: l10n.commonRetry,
        onAction: onRefresh,
      );
    }
    if (state.streams.isEmpty) {
      return _AppVolumeManagerMessage(
        icon: Icons.music_off_rounded,
        message: l10n.desktopNoApplicationAudio,
      );
    }

    return Scrollbar(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
        itemCount: state.streams.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final stream = state.streams[index];
          return _AppVolumeRow(
            key: ValueKey<int>(stream.id),
            stream: stream,
            onChanged: (value) => onChanged(stream.id, value),
            onChangeEnd: (value) => onChangeEnd(stream.id, value),
          );
        },
      ),
    );
  }
}

class _AppVolumeManagerMessage extends StatelessWidget {
  const _AppVolumeManagerMessage({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: context.shellColors.textTertiary),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.shellTheme.text.cardTitle.copyWith(
                color: context.shellColors.textSecondary,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              _DashboardValueButton(
                semanticLabel: actionLabel!,
                label: actionLabel!,
                icon: Icons.refresh_rounded,
                onTap: onAction!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AppVolumeRow extends StatefulWidget {
  const _AppVolumeRow({
    super.key,
    required this.stream,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final AppAudioStream stream;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  State<_AppVolumeRow> createState() => _AppVolumeRowState();
}

class _AppVolumeRowState extends State<_AppVolumeRow> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'app-volume-slider');
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _adjust(double delta) {
    widget.onChangeEnd(
      (widget.stream.level + delta).clamp(0.0, 1.0).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final percent = (widget.stream.level * 100).round();
    final accent = ShellTheme.of(context).accent;
    final l10n = context.l10n;
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _adjust(-0.05);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _adjust(0.05);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        slider: true,
        label: l10n.desktopVolumeForApplication(widget.stream.name),
        value: l10n.settingsPercent(percent),
        increasedValue: l10n.settingsPercent(math.min(100, percent + 5)),
        decreasedValue: l10n.settingsPercent(math.max(0, percent - 5)),
        onIncrease: () => _adjust(0.05),
        onDecrease: () => _adjust(-0.05),
        child: Listener(
          onPointerDown: (_) => _focusNode.requestFocus(),
          child: AnimatedContainer(
            duration: Motion.pill,
            curve: Motion.standard,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            decoration: BoxDecoration(
              color: _focused
                  ? context.shellColors.surfaceContainerHigh
                  : context.shellColors.surfaceContainerLow,
              borderRadius: context.shellTheme.borderRadius(18),
              border: Border.all(
                color: _focused ? accent : context.shellColors.hairlineSoft,
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.shellColors.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox(
                        width: 34,
                        height: 34,
                        child: Icon(
                          widget.stream.muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          size: 19,
                          color: widget.stream.muted
                              ? context.shellColors.textTertiary
                              : accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        widget.stream.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.shellTheme.text.cardTitle.copyWith(
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      context.l10n.percentCompact(percent),
                      style: context.shellTheme.text.cardTitle.copyWith(
                        color: context.shellColors.textSecondary,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                RangeBar(
                  icon: widget.stream.muted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  value: widget.stream.level,
                  activeColor: accent,
                  inactiveColor: context.shellColors.volumeTrack,
                  onChanged: widget.onChanged,
                  onChangeEnd: widget.onChangeEnd,
                  height: 40,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
