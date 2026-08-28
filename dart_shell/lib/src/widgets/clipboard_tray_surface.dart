part of 'clipboard_tray_layer.dart';

class _ClipboardTraySurface extends ConsumerWidget {
  const _ClipboardTraySurface({
    required this.edge,
    required this.onClose,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.draggedEntryId,
    required this.onEntryDragStart,
    required this.onEntryDragUpdate,
    required this.onEntryDragEnd,
  });

  final ClipboardTrayEdge edge;
  final VoidCallback onClose;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final int? draggedEntryId;
  final _ClipboardEntryDragStart onEntryDragStart;
  final _ClipboardEntryDragUpdate onEntryDragUpdate;
  final _ClipboardEntryDragEnd onEntryDragEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shellTheme = ShellTheme.of(context);
    final accent = shellTheme.accentPalette;
    final radius = _panelRadius(edge, shellTheme.panelRadius);
    final history = ref.watch(clipboardHistoryProvider);
    final controller = ref.read(clipboardHistoryProvider.notifier);
    final horizontal = !_isVerticalEdge(edge);

    return RepaintBoundary(
      child: ShellBackdropBlur(
        blur: shellTheme.effectivePanelOpacity < 1.0,
        borderRadius: radius,
        child: Material(
          color: ShellMediaColors.transparentDark,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border(
                left: edge == ClipboardTrayEdge.right
                    ? BorderSide(color: accent.outline)
                    : BorderSide.none,
                right: edge == ClipboardTrayEdge.left
                    ? BorderSide(color: accent.outline)
                    : BorderSide.none,
                top: edge == ClipboardTrayEdge.bottom
                    ? BorderSide(color: accent.outline)
                    : BorderSide.none,
                bottom: edge == ClipboardTrayEdge.top
                    ? BorderSide(color: accent.outline)
                    : BorderSide.none,
              ),
              gradient: LinearGradient(
                begin: _gradientBegin(edge),
                end: _gradientEnd(edge),
                colors: [
                  shellTheme.panelColor(
                    Color.alphaBlend(
                      accent.primary.withValues(alpha: 0.14),
                      context.shellColors.surfaceContainerLow,
                    ),
                  ),
                  shellTheme.panelColor(
                    context.shellColors.panelBackgroundBottom,
                  ),
                ],
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: _clipboardTrayContentPadding(edge),
                    child: _ClipboardHistoryBody(
                      horizontal: horizontal,
                      state: history,
                      draggedEntryId: draggedEntryId,
                      onActivate: (entry) async {
                        if (await controller.activate(entry.id)) {
                          onClose();
                        }
                      },
                      onDelete: (entry) => controller.delete(entry.id),
                      onSetPinned: (entry, pinned) =>
                          controller.setPinned(entry.id, pinned: pinned),
                      onClearAll: controller.clear,
                      onEntryDragStart: onEntryDragStart,
                      onEntryDragUpdate: onEntryDragUpdate,
                      onEntryDragEnd: onEntryDragEnd,
                      onRetry: controller.refresh,
                    ),
                  ),
                ),
                _ClipboardTrayDragRegion(
                  edge: edge,
                  onDragStart: onDragStart,
                  onDragUpdate: onDragUpdate,
                  onDragEnd: onDragEnd,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ClipboardTrayDragRegion extends StatelessWidget {
  const _ClipboardTrayDragRegion({
    required this.edge,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final ClipboardTrayEdge edge;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final verticalTray = _isVerticalEdge(edge);
    final region = Semantics(
      label: context.l10n.clipboardDragToClose,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: verticalTray ? onDragStart : null,
        onHorizontalDragUpdate: verticalTray ? onDragUpdate : null,
        onHorizontalDragEnd: verticalTray ? onDragEnd : null,
        onVerticalDragStart: verticalTray ? null : onDragStart,
        onVerticalDragUpdate: verticalTray ? null : onDragUpdate,
        onVerticalDragEnd: verticalTray ? null : onDragEnd,
        child: const SizedBox.expand(),
      ),
    );
    return switch (edge) {
      ClipboardTrayEdge.left => Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 8,
        child: region,
      ),
      ClipboardTrayEdge.right => Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: 8,
        child: region,
      ),
      ClipboardTrayEdge.top => Positioned(
        left: 0,
        top: 0,
        right: 0,
        height: 18,
        child: region,
      ),
      ClipboardTrayEdge.bottom => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: 18,
        child: region,
      ),
    };
  }
}

class _ClipboardHistoryBody extends StatelessWidget {
  const _ClipboardHistoryBody({
    required this.horizontal,
    required this.state,
    required this.draggedEntryId,
    required this.onActivate,
    required this.onDelete,
    required this.onSetPinned,
    required this.onClearAll,
    required this.onEntryDragStart,
    required this.onEntryDragUpdate,
    required this.onEntryDragEnd,
    required this.onRetry,
  });

  final bool horizontal;
  final ClipboardHistoryViewState state;
  final int? draggedEntryId;
  final ValueChanged<ClipboardHistoryEntry> onActivate;
  final ValueChanged<ClipboardHistoryEntry> onDelete;
  final void Function(ClipboardHistoryEntry entry, bool pinned) onSetPinned;
  final VoidCallback onClearAll;
  final _ClipboardEntryDragStart onEntryDragStart;
  final _ClipboardEntryDragUpdate onEntryDragUpdate;
  final _ClipboardEntryDragEnd onEntryDragEnd;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (state.snapshot?.locked ?? false) {
      return _ClipboardMessage(
        icon: Icons.lock_outline_rounded,
        title: l10n.clipboardHistoryLockedTitle,
        message: l10n.clipboardHistoryLockedDescription,
      );
    }
    if (state.entries.isEmpty && state.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (state.entries.isEmpty && state.error != null) {
      return _ClipboardMessage(
        icon: Icons.sync_problem_rounded,
        title: l10n.clipboardUnavailableTitle,
        message: l10n.clipboardUnavailableDescription,
        actionLabel: l10n.commonRetry,
        onAction: onRetry,
      );
    }
    if (state.entries.isEmpty) {
      return _ClipboardMessage(
        icon: state.query.isEmpty
            ? Icons.content_paste_off_rounded
            : Icons.search_off_rounded,
        title: state.query.isEmpty
            ? l10n.clipboardEmptyTitle
            : l10n.clipboardNoSearchResultsTitle,
        message: state.query.isEmpty
            ? l10n.clipboardEmptyDescription
            : l10n.clipboardNoSearchResultsDescription,
      );
    }

    final pinnedEntries = <ClipboardHistoryEntry>[];
    final unpinnedEntries = <ClipboardHistoryEntry>[];
    for (final entry in state.entries) {
      (entry.pinned ? pinnedEntries : unpinnedEntries).add(entry);
    }
    final pinnedCount = pinnedEntries.length;
    final entryCount = pinnedCount + unpinnedEntries.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: _ClipboardClearAllButton(
            enabled: unpinnedEntries.isNotEmpty && !state.clearing,
            clearing: state.clearing,
            onPressed: onClearAll,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Stack(
            children: [
              ListView.separated(
                scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
                physics: draggedEntryId == null
                    ? null
                    : const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 6),
                itemCount: entryCount,
                separatorBuilder: (_, _) => SizedBox(
                  width: horizontal ? 12 : 0,
                  height: horizontal ? 0 : 12,
                ),
                itemBuilder: (context, index) {
                  final entry = index < pinnedCount
                      ? pinnedEntries[index]
                      : unpinnedEntries[index - pinnedCount];
                  return Align(
                    alignment: horizontal
                        ? Alignment.centerLeft
                        : Alignment.topCenter,
                    child: _ClipboardHistoryCard(
                      entry: entry,
                      busy: state.busyItemIds.contains(entry.id),
                      dragging: draggedEntryId == entry.id,
                      onActivate: () => onActivate(entry),
                      onDelete: () => onDelete(entry),
                      onTogglePinned: () => onSetPinned(entry, !entry.pinned),
                      onEntryDragStart: onEntryDragStart,
                      onEntryDragUpdate: onEntryDragUpdate,
                      onEntryDragEnd: onEntryDragEnd,
                    ),
                  );
                },
              ),
              if (state.loading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ClipboardClearAllButton extends StatelessWidget {
  const _ClipboardClearAllButton({
    required this.enabled,
    required this.clearing,
    required this.onPressed,
  });

  final bool enabled;
  final bool clearing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = context.l10n.clipboardClearAll;
    return Tooltip(
      message: label,
      child: TextButton.icon(
        key: const ValueKey<String>('clipboard-clear-all'),
        onPressed: enabled ? onPressed : null,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          foregroundColor: context.shellColors.textSecondary,
          disabledForegroundColor: context.shellColors.glyphInactive,
          backgroundColor: context.shellColors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: context.shellTheme.borderRadius(12),
            side: BorderSide(color: context.shellColors.hairlineSoft),
          ),
        ),
        icon: clearing
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.clear_all_rounded, size: 18),
        label: Text(label),
      ),
    );
  }
}
