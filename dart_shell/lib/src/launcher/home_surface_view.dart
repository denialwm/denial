part of 'home_surface.dart';

/// Home lifecycle and input boundary; paging and drag feedback stay separate.
class _HomeSurfaceView extends StatelessWidget {
  const _HomeSurfaceView({
    required this.owner,
    required this.active,
    required this.interactive,
    required this.contents,
  });

  final _HomeSurfaceState owner;
  final bool active;
  final bool interactive;
  final _HomePageContents contents;

  @override
  Widget build(BuildContext context) {
    final content = Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          padding: _HomeSurfaceState._contentPadding,
          child: _HomePager(owner: owner, contents: contents),
        ),
        _HomeDragOverlay(owner: owner),
      ],
    );
    final opacity = owner.widget.contentOpacity;
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
                if (opacity == null)
                  content
                else
                  FadeTransition(opacity: opacity, child: content),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
