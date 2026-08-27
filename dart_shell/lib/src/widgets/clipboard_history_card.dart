part of 'clipboard_tray_layer.dart';

class _ClipboardHistoryCard extends StatefulWidget {
  const _ClipboardHistoryCard({
    required this.entry,
    required this.busy,
    required this.dragging,
    required this.onActivate,
    required this.onDelete,
    required this.onTogglePinned,
    required this.onEntryDragStart,
    required this.onEntryDragUpdate,
    required this.onEntryDragEnd,
  });

  final ClipboardHistoryEntry entry;
  final bool busy;
  final bool dragging;
  final VoidCallback onActivate;
  final VoidCallback onDelete;
  final VoidCallback onTogglePinned;
  final _ClipboardEntryDragStart onEntryDragStart;
  final _ClipboardEntryDragUpdate onEntryDragUpdate;
  final _ClipboardEntryDragEnd onEntryDragEnd;

  @override
  State<_ClipboardHistoryCard> createState() => _ClipboardHistoryCardState();
}

class _ClipboardHistoryCardState extends State<_ClipboardHistoryCard> {
  static const _dragThreshold = 5.0;

  final GlobalKey _itemKey = GlobalKey();
  bool _hovered = false;
  bool _focused = false;
  int? _trackedPointer;
  Offset? _pointerDownPosition;
  Rect? _sourceRect;
  bool _dragStarted = false;

  void _setHovered(bool hovered) {
    if (_hovered != hovered) {
      setState(() => _hovered = hovered);
    }
  }

  void _setFocused(bool focused) {
    if (_focused != focused) {
      setState(() => _focused = focused);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (widget.busy ||
        widget.dragging ||
        _trackedPointer != null ||
        event.buttons & kPrimaryMouseButton == 0) {
      return;
    }
    final renderBox = _itemKey.currentContext?.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.hasSize) {
      return;
    }
    _trackedPointer = event.pointer;
    _pointerDownPosition = event.position;
    _sourceRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _trackedPointer) {
      return;
    }
    if (!_dragStarted) {
      final down = _pointerDownPosition;
      final sourceRect = _sourceRect;
      if (down == null ||
          sourceRect == null ||
          (event.position - down).distance < _dragThreshold) {
        return;
      }
      _dragStarted = true;
      widget.onEntryDragStart(widget.entry, event.position, sourceRect);
      return;
    }
    widget.onEntryDragUpdate(event.position);
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _trackedPointer) {
      return;
    }
    final dragStarted = _dragStarted;
    final activate =
        !dragStarted && (_sourceRect?.contains(event.position) ?? false);
    _resetPointerTracking();
    if (dragStarted) {
      widget.onEntryDragEnd();
    } else if (activate) {
      widget.onActivate();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _trackedPointer || _dragStarted) {
      return;
    }
    _resetPointerTracking();
  }

  void _resetPointerTracking() {
    _trackedPointer = null;
    _pointerDownPosition = null;
    _sourceRect = null;
    _dragStarted = false;
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final fileMime = clipboardFileMimeType(entry);
    final imageMime = clipboardImageMimeType(entry);
    final typeLabel = fileMime != null
        ? context.l10n.clipboardTypeFiles
        : imageMime != null
        ? context.l10n.clipboardTypeImage
        : context.l10n.clipboardTypeText;
    final highlighted = _hovered || _focused;

    return SizedBox(
      key: _itemKey,
      child: _ClipboardEntryItem(
        visible: !widget.dragging,
        onDelete: widget.busy ? null : widget.onDelete,
        pinned: entry.pinned,
        onTogglePinned: widget.busy ? null : widget.onTogglePinned,
        child: Semantics(
          key: ValueKey<String>('clipboard-history-card-${entry.id}'),
          button: true,
          label: context.l10n.clipboardItemSemantics(typeLabel, entry.preview),
          hint: context.l10n.clipboardItemHint,
          child: FocusableActionDetector(
            enabled: !widget.busy,
            mouseCursor: widget.dragging
                ? SystemMouseCursors.basic
                : widget.busy
                ? SystemMouseCursors.forbidden
                : SystemMouseCursors.grab,
            onShowHoverHighlight: _setHovered,
            onShowFocusHighlight: _setFocused,
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onActivate();
                  return null;
                },
              ),
            },
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerCancel,
              child: _ClipboardEntryVisual(
                entry: entry,
                highlighted: highlighted && !widget.dragging,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClipboardEntryItem extends StatelessWidget {
  const _ClipboardEntryItem({
    required this.child,
    required this.onDelete,
    required this.pinned,
    required this.onTogglePinned,
    this.visible = true,
    this.showDelete = true,
    this.showPin = true,
  });

  final Widget child;
  final VoidCallback? onDelete;
  final bool pinned;
  final VoidCallback? onTogglePinned;
  final bool visible;
  final bool showDelete;
  final bool showPin;

  @override
  Widget build(BuildContext context) {
    Widget maintainLayout(Widget child) => Visibility(
      visible: visible,
      maintainState: true,
      maintainAnimation: true,
      maintainSize: true,
      child: child,
    );

    return Stack(
      children: [
        Padding(padding: const EdgeInsets.all(8), child: maintainLayout(child)),
        if (showDelete)
          Positioned(
            left: 0,
            top: 0,
            child: maintainLayout(_ClipboardDeleteButton(onPressed: onDelete)),
          ),
        if (showPin)
          Positioned(
            right: 0,
            top: 0,
            child: maintainLayout(
              _ClipboardPinButton(pinned: pinned, onPressed: onTogglePinned),
            ),
          ),
      ],
    );
  }
}

class _ClipboardPinButton extends StatelessWidget {
  const _ClipboardPinButton({required this.pinned, required this.onPressed});

  final bool pinned;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final tooltip = pinned
        ? context.l10n.clipboardUnpin
        : context.l10n.clipboardPin;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: pinned,
        label: pinned
            ? context.l10n.clipboardUnpinItem
            : context.l10n.clipboardPinItem,
        child: SizedBox.square(
          key: ValueKey<String>('clipboard-pin-${pinned ? 'on' : 'off'}'),
          dimension: 20,
          child: Material(
            color: Color.alphaBlend(
              accent.primary.withValues(alpha: pinned ? 0.34 : 0.18),
              context.shellColors.surfaceContainerHigh,
            ).withValues(alpha: 0.94),
            shape: CircleBorder(
              side: BorderSide(
                color: accent.primary.withValues(alpha: pinned ? 0.7 : 0.38),
              ),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: Icon(
                pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 13,
                color: onPressed == null
                    ? context.shellColors.textTertiary
                    : pinned
                    ? accent.primary
                    : context.shellColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClipboardDeleteButton extends StatelessWidget {
  const _ClipboardDeleteButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    return Tooltip(
      message: context.l10n.clipboardDelete,
      child: Semantics(
        button: true,
        label: context.l10n.clipboardDeleteItem,
        child: SizedBox.square(
          dimension: 16,
          child: Material(
            color: Color.alphaBlend(
              accent.primary.withValues(alpha: 0.18),
              context.shellColors.surfaceContainerHigh,
            ).withValues(alpha: 0.9),
            shape: CircleBorder(
              side: BorderSide(color: accent.primary.withValues(alpha: 0.38)),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: Icon(
                Icons.close_rounded,
                size: 12,
                color: onPressed == null
                    ? context.shellColors.textTertiary
                    : context.shellColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
