import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../models/app_launch_request.dart';
import '../models/denial_window.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import 'app_icon.dart';
import 'window_hero.dart';

typedef LaunchTransitionCompleted = void Function(int requestId, int objectId);

/// Immediately grows a black app preview from the centre of the launcher.
///
/// The requested app's icon remains visible while its process is starting.
/// Once the matching compositor window exists, its live texture cross-fades
/// into the exact same moving rect. Completion is reported only after both the
/// zoom and live-surface reveal have finished.
class LaunchTransitionLayer extends StatefulWidget {
  const LaunchTransitionLayer({
    super.key,
    required this.request,
    required this.window,
    required this.onCompleted,
  });

  final AppLaunchRequest? request;
  final DenialWindow? window;
  final LaunchTransitionCompleted onCompleted;

  @override
  State<LaunchTransitionLayer> createState() => _LaunchTransitionLayerState();
}

class _LaunchTransitionLayerState extends State<LaunchTransitionLayer>
    with TickerProviderStateMixin {
  late final AnimationController _zoomController;
  late final AnimationController _revealController;
  int? _activeRequestId;
  int? _completedRequestId;

  @override
  void initState() {
    super.initState();
    _zoomController = AnimationController(vsync: this, duration: Motion.launch)
      ..addStatusListener(_handleAnimationStatus);
    _revealController = AnimationController(
      vsync: this,
      duration: Motion.launchReveal,
    )..addStatusListener(_handleAnimationStatus);
    _startRequest(widget.request, widget.window);
  }

  @override
  void didUpdateWidget(covariant LaunchTransitionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.request?.requestId != oldWidget.request?.requestId) {
      _startRequest(widget.request, widget.window);
      return;
    }
    if (widget.window?.objectId != oldWidget.window?.objectId) {
      _syncWindow(widget.window);
    }
  }

  @override
  void dispose() {
    _revealController.dispose();
    _zoomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    if (request == null) {
      return const SizedBox.expand();
    }

    return Positioned.fill(
      child: IgnorePointer(
        child: Semantics(
          container: true,
          liveRegion: true,
          label: 'Opening ${request.appName}',
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth <= 0.0 || constraints.maxHeight <= 0.0) {
                return const SizedBox.expand();
              }
              return AnimatedBuilder(
                animation: Listenable.merge(<Listenable>[
                  _zoomController,
                  _revealController,
                ]),
                child: ExcludeSemantics(
                  child: AppIconImage(iconPath: request.iconPath),
                ),
                builder: (context, child) {
                  return _buildTransition(
                    context,
                    constraints,
                    widget.window,
                    child!,
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTransition(
    BuildContext context,
    BoxConstraints constraints,
    DenialWindow? window,
    Widget appIcon,
  ) {
    final zoom = Motion.md3EmphasizedDecelerate.transform(
      unit(_zoomController.value),
    );
    final reveal = Motion.standard.transform(unit(_revealController.value));
    final viewRect = Offset.zero & constraints.biggest;
    final startRect = _startRectFor(context, constraints);
    final rect = Rect.lerp(startRect, viewRect, zoom)!;
    final radius = lerpDouble(ShellTheme.of(context).panelRadius, 0.0, zoom)!;
    final iconSize = math
        .min(startRect.width * 0.28, startRect.height * 0.34)
        .clamp(56.0, 112.0)
        .toDouble();

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fromRect(
          rect: rect,
          child: RepaintBoundary(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ShellColors.launchSurface,
                borderRadius: BorderRadius.circular(radius),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (window != null)
                      Opacity(
                        opacity: reveal,
                        child: WindowSurface(
                          window: window,
                          addRepaintBoundary: false,
                        ),
                      ),
                    Opacity(
                      opacity: 1.0 - reveal,
                      child: Center(
                        child: Transform.scale(
                          scale: lerpDouble(1.0, 0.92, reveal)!,
                          child: SizedBox.square(
                            dimension: iconSize,
                            child: appIcon,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _startRequest(AppLaunchRequest? request, DenialWindow? window) {
    _activeRequestId = request?.requestId;
    _completedRequestId = null;
    _zoomController.stop();
    _revealController.stop();
    _zoomController.value = 0.0;
    _revealController.value = 0.0;
    if (request == null) {
      return;
    }

    MotionTelemetry.observe(
      _zoomController,
      _zoomController.forward(),
      'app_launch_zoom',
      target: 1.0,
    );
    if (window != null) {
      _startReveal();
    }
  }

  void _syncWindow(DenialWindow? window) {
    _revealController.stop();
    _revealController.value = 0.0;
    if (window != null && widget.request != null) {
      _startReveal();
    }
  }

  void _startReveal() {
    MotionTelemetry.observe(
      _revealController,
      _revealController.forward(),
      'app_launch_reveal',
      target: 1.0,
    );
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        _zoomController.status != AnimationStatus.completed ||
        _revealController.status != AnimationStatus.completed) {
      return;
    }

    final request = widget.request;
    final window = widget.window;
    if (request == null ||
        window == null ||
        request.requestId != _activeRequestId ||
        _completedRequestId == request.requestId) {
      return;
    }
    _completedRequestId = request.requestId;
    widget.onCompleted(request.requestId, window.objectId);
  }

  Rect _startRectFor(BuildContext context, BoxConstraints constraints) {
    final padding = MediaQuery.paddingOf(context);
    final viewSize = constraints.biggest;
    final availableWidth = math.max(
      0.0,
      viewSize.width - padding.horizontal - 48.0,
    );
    final availableHeight = math.max(
      0.0,
      viewSize.height - padding.vertical - 144.0,
    );
    final landscape = viewSize.width > viewSize.height;
    final viewAspect = viewSize.height <= 0.0
        ? 1.0
        : (viewSize.width / viewSize.height).clamp(0.56, 2.40).toDouble();
    final preferredWidth = landscape
        ? math.min(availableWidth * 0.44, 520.0)
        : math.min(availableWidth * 0.68, 390.0);
    final maxHeight = math.min(availableHeight, viewSize.height * 0.58);

    var width = math.min(preferredWidth, availableWidth);
    var height = width / viewAspect;
    if (height > maxHeight && maxHeight > 0.0) {
      height = maxHeight;
      width = height * viewAspect;
    }

    final left = (viewSize.width - width) / 2.0;
    final top = (viewSize.height - height) / 2.0;
    return Rect.fromLTWH(left, top, width, height);
  }
}
