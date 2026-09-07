part of 'home_surface.dart';

/// Home lifecycle and input boundary; paging and drag feedback stay separate.
class _HomeSurfaceView extends StatelessWidget {
  const _HomeSurfaceView({
    required this.owner,
    required this.active,
    required this.interactive,
    required this.gridAsync,
  });

  final _HomeSurfaceState owner;
  final bool active;
  final bool interactive;
  final AsyncValue<HomeGridState> gridAsync;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !active,
      child: TickerMode(
        enabled: active,
        child: IgnorePointer(
          ignoring: !interactive,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: owner._handlePointerDown,
            onPointerMove: owner._handlePointerMove,
            onPointerUp: owner._handlePointerUp,
            onPointerCancel: owner._handlePointerUp,
            child: Stack(
              key: owner._homeStackKey,
              fit: StackFit.expand,
              children: [
                const CustomPaint(painter: HomeBackdropPainter()),
                Padding(
                  padding: _HomeSurfaceState._contentPadding,
                  child: _HomePager(owner: owner, gridAsync: gridAsync),
                ),
                _HomeDragOverlay(owner: owner),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
