part of 'desktop_system_bar.dart';

class _WorkspaceIndicator extends ConsumerWidget {
  const _WorkspaceIndicator({
    required this.monitorId,
    required this.horizontal,
    required this.accent,
  });

  final int monitorId;
  final bool horizontal;
  final WallpaperAccent accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktop = ref.watch(desktopWorkspaceProvider);
    final count = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.layout.workspaceCount,
      ),
    );
    final active = desktop.activeWorkspaceFor(monitorId);
    final occupied = desktop.placements.values
        .where(
          (placement) =>
              !placement.minimized && placement.monitorId == monitorId,
        )
        .map((placement) => placement.workspaceId)
        .toSet();
    return RepaintBoundary(
      child: _SystemBarCard(
        accent: accent,
        padding: horizontal
            ? const EdgeInsets.symmetric(horizontal: 4)
            : const EdgeInsets.all(4),
        child: _WorkspaceRail(
          count: count,
          active: active,
          occupied: occupied,
          horizontal: horizontal,
          accent: accent,
          onPressed: (workspace) => ref
              .read(denialBridgeProvider)
              .switchWorkspace(monitorId: monitorId, workspaceId: workspace),
        ),
      ),
    );
  }
}

class _WorkspaceRail extends StatelessWidget {
  const _WorkspaceRail({
    required this.count,
    required this.active,
    required this.occupied,
    required this.horizontal,
    required this.accent,
    required this.onPressed,
  });

  static const double _itemExtent = 20;
  static const double _crossExtent = 18;

  final int count;
  final int active;
  final Set<int> occupied;
  final bool horizontal;
  final WallpaperAccent accent;
  final ValueChanged<int> onPressed;

  @override
  Widget build(BuildContext context) {
    final mainExtent = _itemExtent * count;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      width: horizontal ? mainExtent : _crossExtent,
      height: horizontal ? _crossExtent : mainExtent,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: AnimatedAlign(
              duration: reduceMotion ? Duration.zero : Motion.workspaceSwitch,
              curve: Motion.md3Emphasized,
              alignment: _activeAlignment(active, count, horizontal),
              child: _WorkspaceActiveLens(
                workspace: active,
                horizontal: horizontal,
                reduceMotion: reduceMotion,
              ),
            ),
          ),
          Flex(
            direction: horizontal ? Axis.horizontal : Axis.vertical,
            children: <Widget>[
              for (var workspace = 1; workspace <= count; workspace++)
                _WorkspaceIndicatorButton(
                  workspace: workspace,
                  active: workspace == active,
                  occupied: occupied.contains(workspace),
                  horizontal: horizontal,
                  accent: accent,
                  onPressed: () => onPressed(workspace),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

Alignment _activeAlignment(int active, int count, bool horizontal) {
  final position = count <= 1 ? 0.0 : -1.0 + (2.0 * (active - 1) / (count - 1));
  return horizontal ? Alignment(position, 0) : Alignment(0, position);
}

class _WorkspaceActiveLens extends StatefulWidget {
  const _WorkspaceActiveLens({
    required this.workspace,
    required this.horizontal,
    required this.reduceMotion,
  });

  final int workspace;
  final bool horizontal;
  final bool reduceMotion;

  @override
  State<_WorkspaceActiveLens> createState() => _WorkspaceActiveLensState();
}

class _WorkspaceActiveLensState extends State<_WorkspaceActiveLens>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shape = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  var _generation = 0;

  @override
  void didUpdateWidget(_WorkspaceActiveLens oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion) {
      _generation++;
      _shape.stop();
      _shape.value = 1;
    } else if (widget.workspace != oldWidget.workspace) {
      _generation++;
      unawaited(_animateLiquid(_generation));
    }
  }

  Future<void> _animateLiquid(int generation) async {
    _shape.stop();
    try {
      await _shape
          .animateTo(
            1.34,
            duration: Motion.workspaceIndicatorTakeoff,
            curve: Motion.md3EmphasizedAccelerate,
          )
          .orCancel;
      if (generation != _generation) return;
      await _shape
          .animateTo(
            0.94,
            duration: Motion.workspaceIndicatorTravel,
            curve: Motion.standard,
          )
          .orCancel;
      if (generation != _generation) return;
      await _shape
          .animateTo(
            1,
            duration: Motion.workspaceIndicatorSettle,
            curve: Motion.md3EmphasizedDecelerate,
          )
          .orCancel;
    } on TickerCanceled {
      // A newer workspace target continues from the current deformation.
    }
  }

  @override
  void dispose() {
    _generation++;
    _shape.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shape,
      builder: (context, child) {
        final mainScale = _shape.value;
        final delta = mainScale - 1;
        final crossScale = delta >= 0 ? 1 - (delta * 0.34) : 1 - (delta * 0.72);
        return Transform.scale(
          scaleX: widget.horizontal ? mainScale : crossScale,
          scaleY: widget.horizontal ? crossScale : mainScale,
          child: child,
        );
      },
      child: SizedBox(
        width: widget.horizontal
            ? _WorkspaceRail._itemExtent
            : _WorkspaceRail._crossExtent,
        height: widget.horizontal
            ? _WorkspaceRail._crossExtent
            : _WorkspaceRail._itemExtent,
        child: Center(
          child: SizedBox.square(
            dimension: 17,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ShellMediaColors.darkness.withValues(alpha: 0.36),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceIndicatorButton extends StatelessWidget {
  const _WorkspaceIndicatorButton({
    required this.workspace,
    required this.active,
    required this.occupied,
    required this.horizontal,
    required this.accent,
    required this.onPressed,
  });

  final int workspace;
  final bool active;
  final bool occupied;
  final bool horizontal;
  final WallpaperAccent accent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final l10n = context.l10n;
    final description = occupied ? l10n.workspaceOccupied : l10n.workspaceEmpty;
    final label =
        '${l10n.workspaceLabel(workspace)}, $description'
        '${active ? ', ${l10n.workspaceActive}' : ''}';
    final captionColor = accent.captionColor(theme);
    final textStyle = active
        ? theme.text.systemBarValue.copyWith(
            color: theme.accent,
            fontSize: theme.text.systemBarValue.fontSize! + 1,
          )
        : theme.text.systemBarCaption.copyWith(
            color: occupied ? theme.colors.textSecondary : captionColor,
            fontSize: theme.text.systemBarCaption.fontSize! + 2,
          );
    final itemSize = horizontal
        ? const Size(_WorkspaceRail._itemExtent, _WorkspaceRail._crossExtent)
        : const Size(_WorkspaceRail._crossExtent, _WorkspaceRail._itemExtent);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: active,
        label: label,
        onTap: onPressed,
        child: ExcludeSemantics(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: theme.borderRadius(999),
              mouseCursor: ShellMouseCursors.link,
              splashFactory: NoSplash.splashFactory,
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.focused)) {
                  return theme.accent.withValues(alpha: 0.12);
                }
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.pressed)) {
                  return theme.accent.withValues(alpha: 0.08);
                }
                return Colors.transparent;
              }),
              onTap: onPressed,
              child: SizedBox(
                width: itemSize.width,
                height: itemSize.height,
                child: Center(
                  child: AnimatedDefaultTextStyle(
                    duration: Motion.pill,
                    curve: Motion.standard,
                    style: textStyle,
                    child: Text('$workspace', maxLines: 1),
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
