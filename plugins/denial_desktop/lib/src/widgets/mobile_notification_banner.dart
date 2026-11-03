part of 'notification_banner.dart';

/// A single mobile heads-up card. The top inset travels with the card, so its
/// starting position is above the screen rather than clipped at the safe area.
class MobileNotificationBannerView extends StatefulWidget {
  const MobileNotificationBannerView({
    required this.notification,
    required this.onHide,
    super.key,
    this.previewMode = NotificationPreviewMode.full,
    this.interactive = true,
    this.onDismiss,
    this.onDefaultAction,
    this.onAction,
  });

  final DesktopNotification? notification;
  final NotificationPreviewMode previewMode;
  final bool interactive;
  final ValueChanged<int> onHide;
  final bool Function(int)? onDismiss;
  final bool Function(int)? onDefaultAction;
  final bool Function(int, String)? onAction;

  @override
  State<MobileNotificationBannerView> createState() =>
      _MobileNotificationBannerViewState();
}

class _MobileNotificationBannerViewState
    extends State<MobileNotificationBannerView> {
  Timer? _timeout;
  bool _ready = false;
  double _verticalDrag = 0;
  double _horizontalDrag = 0;

  @override
  void initState() {
    super.initState();
    _armTimeout();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void didUpdateWidget(covariant MobileNotificationBannerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.notification;
    final next = widget.notification;
    // A quiet update keeps the banner's remaining time.
    if (previous?.id != next?.id ||
        (next != null && next.alert && !identical(previous, next))) {
      _armTimeout();
    }
  }

  void _armTimeout() {
    _timeout?.cancel();
    final notification = widget.notification;
    if (notification == null || notification.historyOnly) return;
    _timeout = Timer(const Duration(seconds: 5), () {
      if (mounted) widget.onHide(notification.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final notification = widget.notification;
    final padding = MediaQuery.viewPaddingOf(context);
    final top = padding.top + ReferenceShellMetrics.statusBarHeight + 8;
    final duration =
        MediaQuery.disableAnimationsOf(context) ||
            widget.previewMode == NotificationPreviewMode.hidden
        ? Duration.zero
        : Motion.mobileNotificationBanner;
    return Align(
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: Curves.fastOutSlowIn,
        switchOutCurve: const FlippedCurve(Curves.fastOutSlowIn),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: [...previous, ?current],
        ),
        // The slide repaints only its own boundary, not the overlays and
        // chrome up to the root.
        transitionBuilder: (child, animation) => RepaintBoundary(
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -1),
              end: Offset.zero,
            ).animate(animation),
            child: AnimatedBuilder(
              animation: animation,
              child: child,
              builder: (context, child) {
                final exiting = animation.status == AnimationStatus.reverse;
                // The banner takes input once it has arrived. A region that
                // followed the slide would republish the native input layout
                // on every frame of it.
                return ShellInputScope(
                  enabled:
                      animation.isCompleted &&
                      ShellInputScope.enabledOf(context),
                  child: IgnorePointer(
                    ignoring: exiting,
                    child: ExcludeSemantics(excluding: exiting, child: child),
                  ),
                );
              },
            ),
          ),
        ),
        child: !_ready || notification == null || notification.historyOnly
            ? const SizedBox.shrink()
            : Padding(
                key: ValueKey(notification.id),
                padding: EdgeInsets.fromLTRB(
                  padding.left + MobileNotificationCard.horizontalMargin,
                  top,
                  padding.right + MobileNotificationCard.horizontalMargin,
                  12,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: _card(notification),
                ),
              ),
      ),
    );
  }

  Widget _card(DesktopNotification notification) {
    final interactive = widget.interactive;
    final card = RepaintBoundary(
      child: Semantics(
        onDismiss: interactive ? () => widget.onHide(notification.id) : null,
        child: GestureDetector(
          onVerticalDragStart: interactive
              ? (_) {
                  _verticalDrag = 0;
                  _timeout?.cancel();
                }
              : null,
          onVerticalDragUpdate: interactive
              ? (event) => _verticalDrag += event.primaryDelta ?? 0
              : null,
          onVerticalDragEnd: interactive
              ? (event) {
                  if (_verticalDrag < -24 ||
                      (event.primaryVelocity ?? 0) < -300) {
                    widget.onHide(notification.id);
                  } else {
                    _armTimeout();
                  }
                }
              : null,
          onVerticalDragCancel: _armTimeout,
          onHorizontalDragStart: interactive
              ? (_) {
                  _horizontalDrag = 0;
                  _timeout?.cancel();
                }
              : null,
          onHorizontalDragUpdate: interactive
              ? (event) => _horizontalDrag += event.primaryDelta ?? 0
              : null,
          onHorizontalDragEnd: interactive
              ? (event) {
                  if (_horizontalDrag.abs() > 64 ||
                      (event.primaryVelocity ?? 0).abs() > 500) {
                    widget.onDismiss?.call(notification.id);
                  }
                  _armTimeout();
                }
              : null,
          onHorizontalDragCancel: _armTimeout,
          child: MobileNotificationCard(
            notification: notification,
            interactive: interactive,
            announce: true,
            previewMode: widget.previewMode,
            onDefaultAction: interactive && widget.onDefaultAction != null
                ? () => widget.onDefaultAction!(notification.id)
                : null,
            onAction: interactive && widget.onAction != null
                ? (key) => widget.onAction!(notification.id, key)
                : null,
          ),
        ),
      ),
    );
    return interactive
        ? ShellInputRegion(
            debugLabel: 'Mobile notification ${notification.id}',
            child: card,
          )
        : IgnorePointer(child: card);
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }
}
