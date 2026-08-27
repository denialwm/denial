part of 'clipboard_tray_layer.dart';

@immutable
class _ClipboardEntryDragState {
  const _ClipboardEntryDragState({
    required this.entry,
    required this.position,
    required this.size,
    required this.anchor,
  });

  final ClipboardHistoryEntry entry;
  final Offset position;
  final Size size;
  final Offset anchor;

  _ClipboardEntryDragState copyWith({Offset? position}) {
    return _ClipboardEntryDragState(
      entry: entry,
      position: position ?? this.position,
      size: size,
      anchor: anchor,
    );
  }
}

class _DraggedClipboardEntry extends StatelessWidget {
  const _DraggedClipboardEntry({required this.state});

  final _ClipboardEntryDragState state;

  @override
  Widget build(BuildContext context) {
    final origin =
        state.position -
        Offset(
          state.size.width * state.anchor.dx,
          state.size.height * state.anchor.dy,
        );
    return Positioned(
      key: const ValueKey<String>('clipboard-drag-preview'),
      left: origin.dx,
      top: origin.dy,
      width: state.size.width,
      height: state.size.height,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: RepaintBoundary(
            child: _ClipboardEntryItem(
              onDelete: () {},
              pinned: state.entry.pinned,
              onTogglePinned: () {},
              showDelete: false,
              showPin: false,
              child: _ClipboardEntryVisual(entry: state.entry, lifted: true),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewFallback extends StatelessWidget {
  const _PreviewFallback({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: context.shellColors.textTertiary),
          const SizedBox(height: 6),
          Text(
            label,
            style: ShellText.base.copyWith(
              color: context.shellColors.textTertiary,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _ClipboardMessage extends StatelessWidget {
  const _ClipboardMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 330),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: accent.subtle,
                shape: BoxShape.circle,
                border: Border.all(color: accent.outline),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Icon(icon, size: 28, color: accent.primary),
              ),
            ),
            const SizedBox(height: 15),
            Text(
              title,
              textAlign: TextAlign.center,
              style: ShellText.statusClock,
            ),
            const SizedBox(height: 7),
            Text(
              message,
              textAlign: TextAlign.center,
              style: ShellText.base.copyWith(
                color: context.shellColors.textTertiary,
                height: 1.4,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

bool _isVerticalEdge(ClipboardTrayEdge edge) =>
    edge == ClipboardTrayEdge.left || edge == ClipboardTrayEdge.right;

EdgeInsets _clipboardTrayContentPadding(ClipboardTrayEdge edge) {
  if (_isVerticalEdge(edge)) {
    return const EdgeInsets.symmetric(horizontal: 8, vertical: 16);
  }
  return EdgeInsets.fromLTRB(
    16,
    edge == ClipboardTrayEdge.top ? 18 : 16,
    16,
    edge == ClipboardTrayEdge.bottom ? 18 : 16,
  );
}

Offset _hiddenOffset(ClipboardTrayEdge edge, double extent) => switch (edge) {
  ClipboardTrayEdge.left => Offset(-extent, 0),
  ClipboardTrayEdge.right => Offset(extent, 0),
  ClipboardTrayEdge.top => Offset(0, -extent),
  ClipboardTrayEdge.bottom => Offset(0, extent),
};

Rect _trayRect(Rect output, ClipboardTrayEdge edge, double extent) =>
    switch (edge) {
      ClipboardTrayEdge.left => Rect.fromLTWH(
        output.left,
        output.top,
        extent,
        output.height,
      ),
      ClipboardTrayEdge.right => Rect.fromLTWH(
        output.right - extent,
        output.top,
        extent,
        output.height,
      ),
      ClipboardTrayEdge.top => Rect.fromLTWH(
        output.left,
        output.top,
        output.width,
        extent,
      ),
      ClipboardTrayEdge.bottom => Rect.fromLTWH(
        output.left,
        output.bottom - extent,
        output.width,
        extent,
      ),
    };

BorderRadius _panelRadius(ClipboardTrayEdge edge, double radius) =>
    switch (edge) {
      ClipboardTrayEdge.left => BorderRadius.only(
        topRight: Radius.circular(radius),
        bottomRight: Radius.circular(radius),
      ),
      ClipboardTrayEdge.right => BorderRadius.only(
        topLeft: Radius.circular(radius),
        bottomLeft: Radius.circular(radius),
      ),
      ClipboardTrayEdge.top => BorderRadius.only(
        bottomLeft: Radius.circular(radius),
        bottomRight: Radius.circular(radius),
      ),
      ClipboardTrayEdge.bottom => BorderRadius.only(
        topLeft: Radius.circular(radius),
        topRight: Radius.circular(radius),
      ),
    };

Alignment _gradientBegin(ClipboardTrayEdge edge) => switch (edge) {
  ClipboardTrayEdge.left => Alignment.centerRight,
  ClipboardTrayEdge.right => Alignment.centerLeft,
  ClipboardTrayEdge.top => Alignment.bottomCenter,
  ClipboardTrayEdge.bottom => Alignment.topCenter,
};

Alignment _gradientEnd(ClipboardTrayEdge edge) => switch (edge) {
  ClipboardTrayEdge.left => Alignment.centerLeft,
  ClipboardTrayEdge.right => Alignment.centerRight,
  ClipboardTrayEdge.top => Alignment.topCenter,
  ClipboardTrayEdge.bottom => Alignment.bottomCenter,
};
