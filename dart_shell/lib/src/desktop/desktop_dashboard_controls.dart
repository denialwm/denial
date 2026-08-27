part of 'desktop_shell.dart';

class _DashboardIconButton extends StatefulWidget {
  const _DashboardIconButton({
    required this.semanticLabel,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.busy = false,
    this.enabled = true,
  });

  final String semanticLabel;
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final bool busy;
  final bool enabled;

  @override
  State<_DashboardIconButton> createState() => _DashboardIconButtonState();
}

class _DashboardIconButtonState extends State<_DashboardIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: widget.busy
            ? ShellMouseCursors.working
            : widget.enabled
            ? ShellMouseCursors.link
            : ShellMouseCursors.normal,
        onEnter: widget.enabled ? (_) => setState(() => _hovered = true) : null,
        onExit: widget.enabled ? (_) => setState(() => _hovered = false) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled && !widget.busy ? widget.onTap : null,
          child: AnimatedContainer(
            duration: Motion.pill,
            curve: Motion.standard,
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: widget.active
                  ? accent.container
                  : _hovered
                  ? context.shellColors.surfaceContainerHighest
                  : context.shellColors.surfaceContainerHigh,
              borderRadius: context.shellTheme.borderRadius(12),
            ),
            child: widget.busy
                ? Padding(
                    padding: const EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent.primary,
                    ),
                  )
                : Icon(
                    widget.icon,
                    size: 18,
                    color: widget.enabled
                        ? widget.active
                              ? accent.onContainer
                              : context.shellColors.textPrimary
                        : context.shellColors.glyphInactive,
                  ),
          ),
        ),
      ),
    );
  }
}

class _DashboardValueButton extends StatefulWidget {
  const _DashboardValueButton({
    required this.semanticLabel,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String semanticLabel;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_DashboardValueButton> createState() => _DashboardValueButtonState();
}

class _DashboardValueButtonState extends State<_DashboardValueButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Motion.pill,
            curve: Motion.standard,
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: _hovered || _focused
                  ? context.shellColors.surfaceContainerHighest
                  : context.shellColors.surfaceContainerHigh,
              borderRadius: context.shellTheme.borderRadius(12),
              border: Border.all(
                color: _focused
                    ? accent.primary
                    : context.shellColors.hairlineSoft,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: context.shellTheme.text.cardTitle.copyWith(
                    color: context.shellColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 7),
                Icon(widget.icon, size: 16, color: accent.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
