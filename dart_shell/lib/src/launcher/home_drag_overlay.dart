part of 'home_surface.dart';

/// Pointer updates move the retained tile without rebuilding or laying it out.
class _HomeDragOverlay extends ConsumerStatefulWidget {
  const _HomeDragOverlay({required this.owner});

  final _HomeSurfaceState owner;

  @override
  ConsumerState<_HomeDragOverlay> createState() => _HomeDragOverlayState();
}

class _HomeDragOverlayState extends ConsumerState<_HomeDragOverlay> {
  final _translation = ValueNotifier(Offset.zero);

  @override
  void dispose() {
    _translation.dispose();
    super.dispose();
  }

  void _updateTranslation(HomeDragSession? session) {
    if (session == null) return;
    final offset = widget.owner._dragOverlayOffset(session);
    if (offset != null) _translation.value = offset;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(homeDragSessionProvider, (_, next) => _updateTranslation(next));
    final tile = ref.watch(
      homeDragSessionProvider.select(
        (session) => session == null
            ? null
            : (item: session.item, size: session.feedbackSize),
      ),
    );
    if (tile == null) return const SizedBox.shrink();
    _updateTranslation(ref.read(homeDragSessionProvider));
    return Positioned(
      left: 0,
      top: 0,
      width: tile.size.width,
      height: tile.size.height,
      child: IgnorePointer(
        child: RetainedTranslation(
          translation: _translation,
          child: RepaintBoundary(
            child: HomeGridItemCard(
              item: tile.item,
              onLaunch: widget.owner._launchApp,
            ),
          ),
        ),
      ),
    );
  }
}
