part of 'desktop_shell.dart';

class _ClosingDesktopWindow {
  const _ClosingDesktopWindow({
    required this.id,
    required this.window,
    required this.frame,
    required this.fullscreen,
    required this.effect,
  });

  final int id;
  final DenialWindow window;
  final Rect frame;
  final bool fullscreen;
  final DesktopWindowCloseEffect effect;
}

class _DesktopClosingWindowFrame extends StatelessWidget {
  const _DesktopClosingWindowFrame({
    required this.closing,
    required this.onCompleted,
  });

  final _ClosingDesktopWindow closing;
  final VoidCallback onCompleted;

  @override
  Widget build(BuildContext context) {
    final drawsServerFrame =
        !closing.fullscreen && closing.window.serverSideDecorated;
    final radius = drawsServerFrame ? ShellTheme.of(context).windowRadius : 0.0;
    return DesktopWindowCloseAnimation(
      effect: closing.effect,
      seed: Object.hash(closing.window.objectId, closing.id),
      onCompleted: onCompleted,
      child: CustomPaint(
        painter: drawsServerFrame
            ? DesktopWindowFramePainter(
                windowId: closing.window.objectId,
                radius: radius,
                shadowColor: context.shellColors.shadow,
                frameColor: context.shellColors.windowFrameSurface,
              )
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(math.max(0.0, radius - 1.0)),
          child: Padding(
            padding: drawsServerFrame
                ? const EdgeInsets.all(DesktopMetrics.frameBorder)
                : EdgeInsets.zero,
            child: SizedBox.expand(
              child: _DesktopWindowContent(
                window: closing.window,
                smooth: false,
                active: false,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopWindowFrame extends ConsumerWidget {
  const _DesktopWindowFrame({
    super.key,
    required this.window,
    required this.placement,
    required this.frame,
    required this.minimized,
    required this.desktopWidget,
    required this.offscreenMinimized,
    required this.desktopWidgetEntering,
    required this.desktopWidgetExiting,
    required this.desktopWidgetTransitionDuration,
    required this.suppressPositionAnimation,
    required this.overviewActive,
    required this.overview,
    required this.switching,
    required this.motionDuration,
    required this.active,
    required this.onOverviewTap,
    required this.onOverviewDragStart,
    required this.onOverviewDragUpdate,
    required this.onOverviewDragEnd,
    required this.onOverviewDragCancel,
  });

  final DenialWindow window;
  final DesktopWindowPlacement placement;
  final Rect frame;
  final bool minimized;
  final bool desktopWidget;
  final bool offscreenMinimized;
  final bool desktopWidgetEntering;
  final bool desktopWidgetExiting;
  final Duration desktopWidgetTransitionDuration;
  final bool suppressPositionAnimation;
  final bool overviewActive;
  final bool overview;
  final bool switching;
  final Duration motionDuration;
  final bool active;
  final VoidCallback onOverviewTap;
  final VoidCallback onOverviewDragStart;
  final ValueChanged<Offset> onOverviewDragUpdate;
  final VoidCallback onOverviewDragEnd;
  final VoidCallback onOverviewDragCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window =
        ref.watch(
          shellControllerProvider.select(
            (state) => state.windowByObjectId(this.window.objectId),
          ),
        ) ??
        this.window;
    final liveGeometry = ref.watch(
      desktopWorkspaceProvider.select((state) {
        final placement = state.placements[this.placement.objectId];
        return placement == null
            ? null
            : (frameSize: placement.frame.size, dragging: placement.dragging);
      }),
    );
    final selectedPlacement = ref.read(
      desktopWorkspaceProvider.select(
        (state) => state.placements[this.placement.objectId],
      ),
    );
    final followsLivePlacement =
        this.placement.dragging &&
        liveGeometry?.dragging == true &&
        selectedPlacement != null;
    final placement = followsLivePlacement ? selectedPlacement : this.placement;
    final liveFrame = followsLivePlacement
        ? desktopLivePlacementVisualFrame(
            visualFrame: this.frame,
            placementFrame: this.placement.frame,
            livePlacementFrame: placement.frame,
          )
        : this.frame;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final transformed =
        overview || switching || desktopWidget || offscreenMinimized;
    final frame = desktopPixelAlignedWindowFrame(
      frame: liveFrame,
      contentInset: placement.frameBorder,
      devicePixelRatio: devicePixelRatio,
      enabled: !transformed,
      alignSize: true,
    );
    DesktopWindowRenderTelemetry.recordWindowBuild(
      windowId: window.objectId,
      textureId: window.textureId,
      label: window.appId.isEmpty
          ? localizedWindowTitle(context, window)
          : window.appId,
    );
    final duration = motionDuration;
    final minimizeEffectDuration = desktopWidgetEntering
        ? Duration.zero
        : duration;
    final fullscreenVisual = placement.fullscreen && !transformed;
    final drawsServerFrame = !fullscreenVisual && placement.serverSideDecorated;
    final theme = ShellTheme.of(context);
    final windowRadius = drawsServerFrame ? theme.windowRadius : 0.0;
    final windowOpacity = active
        ? theme.focusedWindowOpacity
        : theme.unfocusedWindowOpacity;
    final targetContentSize = drawsServerFrame
        ? frame.deflate(DesktopMetrics.frameBorder).size
        : frame.size;
    final resizing = desktopTextureNeedsResizeSmoothing(
      targetSize: targetContentSize,
      sourceSize: window.contentCoordinateRect.size,
    );
    final minimizeDelta = frame.center - placement.frame.center;
    final minimizedOffset = offscreenMinimized
        ? minimizeDelta.dx.abs() > minimizeDelta.dy.abs()
              ? Offset(0.12 * minimizeDelta.dx.sign, 0)
              : Offset(0, 0.12 * minimizeDelta.dy.sign)
        : const Offset(0, 0.16);
    final minimizeCurve = minimized
        ? Motion.md3EmphasizedAccelerate
        : Motion.md3EmphasizedDecelerate;
    return _DesktopAnimatedWindowPosition(
      duration: placement.dragging || suppressPositionAnimation
          ? Duration.zero
          : duration,
      rect: frame,
      layoutRect: transformed ? placement.frame : null,
      placementObjectId: placement.objectId,
      overview: overview,
      switching: switching,
      desktopWidget: desktopWidget,
      offscreenMinimized: offscreenMinimized,
      dragging: placement.dragging,
      layoutPreviewing: placement.layoutPreviewing,
      pixelAlignmentInset: placement.frameBorder,
      alignSizeToDevicePixels: true,
      child: _DesktopWidgetVerticalTransition(
        entering: desktopWidgetEntering,
        exiting: desktopWidgetExiting,
        duration: desktopWidgetTransitionDuration,
        child: DesktopWindowReveal(
          key: ValueKey<String>('desktop-window-content-${window.objectId}'),
          enabled: window.shouldAnimateEntrance,
          child: IgnorePointer(
            ignoring:
                minimized ||
                desktopWidgetEntering ||
                desktopWidgetExiting ||
                (desktopWidget && overviewActive),
            child: AnimatedSlide(
              duration: minimizeEffectDuration,
              curve: minimizeCurve,
              offset: minimized ? minimizedOffset : Offset.zero,
              child: AnimatedScale(
                duration: minimizeEffectDuration,
                curve: minimizeCurve,
                scale: minimized ? 0.84 : 1.0,
                child: AnimatedOpacity(
                  duration: minimizeEffectDuration,
                  curve: minimizeCurve,
                  opacity: minimized
                      ? 0.0
                      : desktopWidget
                      ? 0.86 * windowOpacity
                      : windowOpacity,
                  child: DesktopWindowRepaintBoundary(
                    outset: drawsServerFrame
                        ? DesktopWindowFramePainter.shadowOutset
                        : 0,
                    child: DesktopOverviewPreviewInteraction(
                      overviewActive: overviewActive,
                      overview: overview,
                      desktopWidget: desktopWidget,
                      dragging: placement.dragging,
                      label: desktopWidget
                          ? context.l10n.desktopRestoreWindow(
                              localizedWindowTitle(context, window),
                            )
                          : context.l10n.desktopActivateWindow(
                              localizedWindowTitle(context, window),
                            ),
                      onTap: onOverviewTap,
                      onDragStart: onOverviewDragStart,
                      onDragUpdate: onOverviewDragUpdate,
                      onDragEnd: onOverviewDragEnd,
                      onDragCancel: onOverviewDragCancel,
                      child: Builder(
                        builder: (context) {
                          final client = ClipRRect(
                            borderRadius: BorderRadius.circular(
                              math.max(0.0, windowRadius - 1.0),
                            ),
                            child: Padding(
                              // The native client keeps its real geometry
                              // during overview; only its live texture scales.
                              padding: drawsServerFrame
                                  ? const EdgeInsets.all(
                                      DesktopMetrics.frameBorder,
                                    )
                                  : EdgeInsets.zero,
                              child: SizedBox.expand(
                                child: _DesktopWindowContent(
                                  window: window,
                                  smooth: transformed || resizing,
                                  active: active && !minimized,
                                  localLayoutSize: window.isLocalFlutter
                                      ? placement.contentRect.size
                                      : null,
                                ),
                              ),
                            ),
                          );
                          if (!drawsServerFrame) {
                            return client;
                          }
                          return DesktopWindowFrameLayers(
                            windowId: window.objectId,
                            borderPainter: _DesktopWindowBorderPainter(
                              windowId: window.objectId,
                              color: desktopWindowBorderColor(
                                pinned: window.pinned,
                                active: active,
                                theme: theme,
                                inactiveColor:
                                    context.shellColors.hairlineWindow,
                              ),
                              devicePixelRatio: devicePixelRatio,
                              radius: windowRadius,
                            ),
                            child: client,
                          );
                        },
                      ),
                    ),
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

class _DesktopAnimatedWindowPosition extends ConsumerStatefulWidget {
  const _DesktopAnimatedWindowPosition({
    super.key,
    required this.duration,
    required this.rect,
    this.layoutRect,
    required this.placementObjectId,
    required this.overview,
    required this.switching,
    this.desktopWidget = false,
    this.offscreenMinimized = false,
    required this.dragging,
    required this.layoutPreviewing,
    this.pixelAlignmentInset,
    this.alignSizeToDevicePixels = false,
    required this.child,
  });

  final Duration duration;
  final Rect rect;
  final Rect? layoutRect;
  final int placementObjectId;
  final bool overview;
  final bool switching;
  final bool desktopWidget;
  final bool offscreenMinimized;
  final bool dragging;
  final bool layoutPreviewing;
  final double? pixelAlignmentInset;
  final bool alignSizeToDevicePixels;
  final Widget child;

  @override
  ConsumerState<_DesktopAnimatedWindowPosition> createState() =>
      _DesktopAnimatedWindowPositionState();
}

class _DesktopAnimatedWindowPositionState
    extends ConsumerState<_DesktopAnimatedWindowPosition> {
  late Curve _curve;
  bool _overviewTransitionActive = false;
  bool _layoutPreviewExitActive = false;
  Rect? _dragReleaseAnimationOrigin;

  @override
  void initState() {
    super.initState();
    _curve = widget.overview ? Motion.overviewEnterCurve : Motion.md3Emphasized;
  }

  @override
  void didUpdateWidget(covariant _DesktopAnimatedWindowPosition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dragging && !widget.dragging) {
      final translation = ref
          .read(desktopLiveWindowPlacementsProvider)
          .settleTranslationFor(widget.placementObjectId);
      _dragReleaseAnimationOrigin = translation == null
          ? null
          : oldWidget.rect.shift(translation);
    }
    if (oldWidget.layoutPreviewing && !widget.layoutPreviewing) {
      _layoutPreviewExitActive = true;
    }
    final interruptedOverviewTransition = _overviewTransitionActive;
    if (!oldWidget.overview && widget.overview) {
      _curve = interruptedOverviewTransition
          ? Motion.overviewReversalCurve
          : Motion.overviewEnterCurve;
      _overviewTransitionActive = true;
    } else if (oldWidget.overview && !widget.overview) {
      _curve = interruptedOverviewTransition
          ? Motion.overviewReversalCurve
          : Motion.overviewExitCurve;
      _overviewTransitionActive = true;
    } else if (widget.desktopWidget != oldWidget.desktopWidget ||
        widget.offscreenMinimized != oldWidget.offscreenMinimized ||
        widget.switching ||
        oldWidget.switching) {
      _curve = Motion.md3Emphasized;
      _overviewTransitionActive = false;
    } else if (!_overviewTransitionActive &&
        !widget.overview &&
        widget.rect != oldWidget.rect) {
      _curve = Motion.standard;
    }
  }

  @override
  Widget build(BuildContext context) {
    var rect = widget.rect;
    var layoutRect = widget.layoutRect;
    final pixelAlignmentInset = widget.pixelAlignmentInset;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    if (pixelAlignmentInset != null) {
      rect = desktopPixelAlignedWindowFrame(
        frame: rect,
        contentInset: pixelAlignmentInset,
        devicePixelRatio: devicePixelRatio,
        enabled:
            !widget.overview &&
            !widget.switching &&
            !widget.desktopWidget &&
            !widget.offscreenMinimized,
        alignSize: widget.alignSizeToDevicePixels,
      );
      if (layoutRect != null) {
        layoutRect = desktopPixelAlignedWindowFrame(
          frame: layoutRect,
          contentInset: pixelAlignmentInset,
          devicePixelRatio: devicePixelRatio,
          enabled: true,
        );
      }
    }
    final liveTranslation = ref
        .read(desktopLiveWindowPlacementsProvider)
        .translationFor(widget.placementObjectId);
    final previewMotionActive =
        widget.layoutPreviewing || _layoutPreviewExitActive;
    final positionDuration = widget.dragging
        ? Duration.zero
        : previewMotionActive && widget.duration != Duration.zero
        ? Motion.tile
        : widget.duration;
    return RetainedAnimatedPositioned(
      duration: positionDuration,
      curve: _curve,
      rect: rect,
      animationOrigin: _dragReleaseAnimationOrigin,
      // SUPER+A and SUPER+Tab retain the real window geometry. Their live
      // texture, frame, shadow, and hit-test region move as one composited
      // layer instead of resizing and repainting on every animation tick.
      layoutRect: layoutRect,
      onEnd: () {
        _overviewTransitionActive = false;
        _layoutPreviewExitActive = false;
        _dragReleaseAnimationOrigin = null;
      },
      child: RetainedTranslation(
        translation: liveTranslation,
        enabled: widget.dragging,
        devicePixelRatio: pixelAlignmentInset == null ? null : devicePixelRatio,
        child: widget.child,
      ),
    );
  }
}

class _DesktopSurfaceTexture extends StatefulWidget {
  const _DesktopSurfaceTexture({required this.window, required this.smooth});

  final DenialWindow window;
  final bool smooth;

  @override
  State<_DesktopSurfaceTexture> createState() => _DesktopSurfaceTextureState();
}

class _DesktopWindowContent extends ConsumerWidget {
  const _DesktopWindowContent({
    required this.window,
    required this.smooth,
    required this.active,
    this.localLayoutSize,
  });

  final DenialWindow window;
  final bool smooth;
  final bool active;
  final Size? localLayoutSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShellTheme.of(context);
    final windowOpacity = active
        ? theme.focusedWindowOpacity
        : theme.unfocusedWindowOpacity;
    final content = _buildContent();
    final localApplication = window.isLocalFlutter
        ? ref.watch(localFlutterApplicationRegistryProvider)[window.appId]
        : null;
    final singleWindowSurface =
        !window.isLocalFlutter && window.mainVisibleSurfaceIds.length == 1;
    return ShellBackdropBlur(
      blur: desktopWindowNeedsBackdropTexture(
        window: window,
        shellOpacity: windowOpacity,
        localContentTranslucent: localApplication?.translucent ?? false,
      ),
      useWindowAlphaThreshold: true,
      singleWindowSurface: singleWindowSurface,
      child: content,
    );
  }

  Widget _buildContent() {
    if (window.isLocalFlutter) {
      final host = LocalFlutterWindowHost(
        key: LocalFlutterWindowHostKey(window.objectId),
        window: window,
        active: active,
      );
      final layoutSize = localLayoutSize;
      if (layoutSize == null || layoutSize.isEmpty) {
        return host;
      }
      // Native clients keep their configured buffer size while overview,
      // switching, and minimize animate the compositor texture. Give local
      // Flutter apps the same contract: retain the real window layout and
      // scale the complete app as one surface for shell-only transitions.
      return ClipRect(
        child: FittedBox(
          fit: BoxFit.fill,
          clipBehavior: Clip.hardEdge,
          child: SizedBox.fromSize(size: layoutSize, child: host),
        ),
      );
    }
    return _DesktopSurfaceTexture(window: window, smooth: smooth);
  }
}

class _DesktopSurfaceTextureState extends State<_DesktopSurfaceTexture> {
  Timer? _disableSmoothingTimer;
  late bool _smooth;

  @override
  void initState() {
    super.initState();
    _smooth = widget.smooth;
  }

  @override
  void didUpdateWidget(covariant _DesktopSurfaceTexture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.smooth) {
      _disableSmoothingTimer?.cancel();
      _disableSmoothingTimer = null;
      _smooth = true;
    } else if (oldWidget.smooth && _smooth) {
      _disableSmoothingTimer?.cancel();
      _disableSmoothingTimer = Timer(Motion.overviewClose, () {
        if (mounted) {
          setState(() => _smooth = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _disableSmoothingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filterQuality = _smooth ? FilterQuality.medium : FilterQuality.none;
    return WindowSurfaceTree(
      window: widget.window,
      filterQuality: filterQuality,
    );
  }
}

class _DesktopWindowBorderPainter extends CustomPainter {
  const _DesktopWindowBorderPainter({
    required this.windowId,
    required this.color,
    required this.devicePixelRatio,
    required this.radius,
  });

  final int windowId;
  final Color color;
  final double devicePixelRatio;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    DesktopWindowRenderTelemetry.recordBorderPaint(windowId, size);
    if (size.isEmpty) {
      return;
    }

    final ratio = devicePixelRatio.isFinite && devicePixelRatio > 0.0
        ? devicePixelRatio
        : 1.0;
    final pixel = 1.0 / ratio;
    final inset = pixel / 2.0;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      math.max(0.0, size.width - pixel),
      math.max(0.0, size.height - pixel),
    );
    final resolvedRadius = math.max(0.0, radius - inset);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = pixel
      ..isAntiAlias = false;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(resolvedRadius)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _DesktopWindowBorderPainter oldDelegate) {
    return windowId != oldDelegate.windowId ||
        color != oldDelegate.color ||
        devicePixelRatio != oldDelegate.devicePixelRatio ||
        radius != oldDelegate.radius;
  }
}
