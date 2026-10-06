part of 'desktop_shell.dart';

/// Keeps native glass in one compositing mode across minimized presentations.
///
/// Blur and transparency-off retain their existing fade. Glass windows are
/// already moved offscreen or arranged on the desktop, so changing the whole
/// subtree opacity only forces the backdrop filter through a different render
/// plan while the window transitions back into overview.
double desktopWindowPresentationOpacity({
  required ShellTransparencyMode transparencyMode,
  required bool minimized,
  required bool desktopWidget,
  required double windowOpacity,
}) {
  if (transparencyMode == ShellTransparencyMode.glass) {
    return windowOpacity;
  }
  if (minimized) {
    return 0.0;
  }
  return desktopWidget ? 0.86 * windowOpacity : windowOpacity;
}

/// Existing windows mounted for desktop navigation are never application
/// entrances. Their overview, switcher, minimize, or workspace motion owns
/// the transition instead.
bool desktopWindowSuppressesInitialReveal({
  required bool overview,
  required bool switching,
  required bool minimized,
  required bool hasWorkspaceTransition,
}) => overview || switching || minimized || hasWorkspaceTransition;

class _ClosingDesktopWindow {
  const _ClosingDesktopWindow({
    required this.id,
    required this.window,
    required this.frame,
    required this.fullscreen,
    required this.effect,
    required this.outputClip,
  });

  final int id;
  final DenialWindow window;
  final Rect frame;
  final bool fullscreen;
  final DesktopWindowCloseEffect effect;
  final Rect? outputClip;
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
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final frameColor = context.shellColors.windowFrameSurface;
    Widget result = DesktopWindowCloseAnimation(
      effect: closing.effect,
      seed: Object.hash(closing.window.objectId, closing.id),
      onCompleted: onCompleted,
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          if (drawsServerFrame)
            IgnorePointer(
              child: CustomPaint(
                painter: DesktopWindowShadowPainter(
                  windowId: closing.window.objectId,
                  radius: radius,
                  shadowColor: context.shellColors.shadow,
                ),
              ),
            ),
          ClipRRect(
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
                  borderRadius: BorderRadius.circular(
                    math.max(0.0, radius - DesktopMetrics.frameBorder),
                  ),
                ),
              ),
            ),
          ),
          if (drawsServerFrame)
            IgnorePointer(
              child: CustomPaint(
                painter: DesktopWindowFramePainter(
                  windowId: closing.window.objectId,
                  devicePixelRatio: devicePixelRatio,
                  radius: radius,
                  frameColor: frameColor,
                ),
              ),
            ),
        ],
      ),
    );
    if (closing.outputClip case final outputClip?) {
      result = ClipPath(
        clipper: _WorkspaceOutputClipper(
          outputClip.shift(-closing.frame.topLeft),
        ),
        clipBehavior: Clip.hardEdge,
        child: result,
      );
    }
    return result;
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
    required this.selected,
    required this.windowRevealRegistry,
    required this.onOverviewTap,
    required this.onOverviewClose,
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
  final bool selected;
  final DesktopWindowRevealMountRegistry windowRevealRegistry;
  final VoidCallback onOverviewTap;
  final VoidCallback onOverviewClose;
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
    final workspaceTransition = ref.watch(
      desktopWorkspaceProvider.select(
        (state) => state.workspaceTransitions[this.placement.monitorId],
      ),
    );
    final workspaceSwitchingOrientation = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.layout.workspaceSwitchingOrientation,
      ),
    );
    final followsLivePlacement =
        this.placement.dragging &&
        liveGeometry?.dragging == true &&
        selectedPlacement != null;
    final placement = followsLivePlacement ? selectedPlacement : this.placement;
    final outputPixelGrid = ref.watch(
      displayLayoutProvider.select(
        (layout) =>
            desktopOutputPixelGridForMonitor(layout, placement.monitorId),
      ),
    );
    final liveFrame = followsLivePlacement
        ? desktopLivePlacementVisualFrame(
            visualFrame: this.frame,
            placementFrame: this.placement.frame,
            livePlacementFrame: placement.frame,
          )
        : this.frame;
    final devicePixelRatio =
        outputPixelGrid?.scale ?? MediaQuery.devicePixelRatioOf(context);
    final pixelGridOrigin = outputPixelGrid?.logicalRect.topLeft ?? Offset.zero;
    final outputRect = outputPixelGrid?.logicalRect;
    final transformed =
        overview || switching || desktopWidget || offscreenMinimized;
    final outputClip = desktopOutputClip(
      activelyDragging: placement.dragging,
      outputRect: outputRect,
    );
    final frame = desktopPixelAlignedWindowFrame(
      frame: liveFrame,
      contentInset: placement.frameBorder,
      devicePixelRatio: devicePixelRatio,
      pixelGridOrigin: pixelGridOrigin,
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
    final drawsServerFrame = transformed
        ? placement.serverSideDecorated
        : placement.drawsLiveServerFrame;
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
      pixelGridScale: devicePixelRatio,
      pixelGridOrigin: pixelGridOrigin,
      alignSizeToDevicePixels: true,
      globalClipRect: outputClip,
      child: DesktopWorkspaceWindowTransition(
        placement: placement,
        transition: workspaceTransition,
        orientation: workspaceSwitchingOrientation,
        outputRect: outputRect,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : Motion.workspaceSwitch,
        child: _DesktopWidgetVerticalTransition(
          entering: desktopWidgetEntering,
          exiting: desktopWidgetExiting,
          duration: desktopWidgetTransitionDuration,
          child: TrackedDesktopWindowReveal(
            key: ValueKey<String>('desktop-window-content-${window.objectId}'),
            registry: windowRevealRegistry,
            objectId: window.objectId,
            enabled: window.shouldAnimateEntrance,
            suppressInitialAnimation: desktopWindowSuppressesInitialReveal(
              overview: overview,
              switching: switching,
              minimized: placement.minimized,
              hasWorkspaceTransition:
                  workspaceTransition != null && !placement.minimized,
            ),
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
                    opacity: desktopWindowPresentationOpacity(
                      transparencyMode: theme.transparencyMode,
                      minimized: minimized,
                      desktopWidget: desktopWidget,
                      windowOpacity: windowOpacity,
                    ),
                    child: DesktopWindowRepaintBoundary(
                      outset: drawsServerFrame
                          ? DesktopWindowShadowPainter.shadowOutset
                          : 0,
                      child: DesktopOverviewPreviewInteraction(
                        overviewActive: overviewActive,
                        overview: overview,
                        desktopWidget: desktopWidget,
                        dragging: placement.dragging,
                        selected: selected,
                        label: desktopWidget
                            ? context.l10n.desktopRestoreWindow(
                                localizedWindowTitle(context, window),
                              )
                            : context.l10n.desktopActivateWindow(
                                localizedWindowTitle(context, window),
                              ),
                        onTap: onOverviewTap,
                        onClose: onOverviewClose,
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
                                    borderRadius: BorderRadius.circular(
                                      math.max(
                                        0.0,
                                        windowRadius -
                                            DesktopMetrics.frameBorder,
                                      ),
                                    ),
                                    localLayoutSize: window.isLocalFlutter
                                        ? placement.contentRect.size
                                        : null,
                                    presentationScale: devicePixelRatio,
                                    pixelGridOrigin: pixelGridOrigin,
                                  ),
                                ),
                              ),
                            );
                            if (!drawsServerFrame) {
                              return client;
                            }
                            return DesktopWindowFrameLayers(
                              windowId: window.objectId,
                              devicePixelRatio: devicePixelRatio,
                              radius: windowRadius,
                              frameColor:
                                  context.shellColors.windowFrameSurface,
                              borderColor: desktopWindowBorderColor(
                                pinned: window.pinned,
                                active: active,
                                theme: theme,
                                inactiveColor:
                                    context.shellColors.hairlineWindow,
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
      ),
    );
  }
}

class DesktopWorkspaceWindowTransition extends StatelessWidget {
  const DesktopWorkspaceWindowTransition({
    super.key,
    required this.placement,
    required this.transition,
    required this.orientation,
    required this.outputRect,
    required this.duration,
    required this.child,
  });

  final DesktopWindowPlacement placement;
  final DesktopWorkspaceTransition? transition;
  final WorkspaceSwitchingOrientation orientation;
  final Rect? outputRect;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final transition = this.transition;
    final resolvedOutput = outputRect;
    final vertical = orientation == WorkspaceSwitchingOrientation.vertical;
    final outputExtent = vertical
        ? resolvedOutput?.height
        : resolvedOutput?.width;
    final fallbackExtent = vertical
        ? placement.frame.height
        : placement.frame.width;
    final travel = outputExtent?.isFinite == true
        ? outputExtent!
        : fallbackExtent;
    final participates =
        !placement.minimized &&
        transition != null &&
        (placement.workspaceId == transition.fromWorkspace ||
            placement.workspaceId == transition.toWorkspace);
    final entering =
        participates && placement.workspaceId == transition.toWorkspace;
    final outgoing =
        participates && placement.workspaceId == transition.fromWorkspace;
    final direction = participates ? transition.direction.toDouble() : 0.0;
    return ClipPath(
      clipper: participates && resolvedOutput != null
          ? _WorkspaceOutputClipper(
              resolvedOutput.shift(-placement.frame.topLeft),
            )
          : null,
      clipBehavior: participates ? Clip.hardEdge : Clip.none,
      child: TweenAnimationBuilder<Offset>(
        tween: Tween<Offset>(
          begin: entering
              ? vertical
                    ? Offset(0, direction * travel)
                    : Offset(direction * travel, 0)
              : Offset.zero,
          end: outgoing
              ? vertical
                    ? Offset(0, -direction * travel)
                    : Offset(-direction * travel, 0)
              : Offset.zero,
        ),
        duration: participates ? duration : Duration.zero,
        curve: Motion.md3Emphasized,
        child: child,
        builder: (context, offset, child) =>
            Transform.translate(offset: offset, child: child),
      ),
    );
  }
}

class _WorkspaceOutputClipper extends CustomClipper<Path> {
  const _WorkspaceOutputClipper(this.outputRect);

  final Rect outputRect;

  @override
  Path getClip(Size size) => Path()..addRect(outputRect);

  @override
  bool shouldReclip(covariant _WorkspaceOutputClipper oldClipper) =>
      oldClipper.outputRect != outputRect;
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
    this.pixelGridScale,
    this.pixelGridOrigin = Offset.zero,
    this.alignSizeToDevicePixels = false,
    this.globalClipRect,
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
  final double? pixelGridScale;
  final Offset pixelGridOrigin;
  final bool alignSizeToDevicePixels;
  final Rect? globalClipRect;
  final Widget child;

  @override
  ConsumerState<_DesktopAnimatedWindowPosition> createState() =>
      _DesktopAnimatedWindowPositionState();
}

class _DesktopAnimatedWindowPositionState
    extends ConsumerState<_DesktopAnimatedWindowPosition> {
  late Curve _curve;
  late final ValueNotifier<bool> _overviewTransitionCompleted;
  bool _overviewTransitionActive = false;
  bool _layoutPreviewExitActive = false;
  Rect? _dragReleaseAnimationOrigin;

  @override
  void initState() {
    super.initState();
    _curve = widget.overview ? Motion.overviewEnterCurve : Motion.md3Emphasized;
    _overviewTransitionCompleted = ValueNotifier<bool>(widget.overview);
  }

  @override
  void dispose() {
    _overviewTransitionCompleted.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DesktopAnimatedWindowPosition oldWidget) {
    super.didUpdateWidget(oldWidget);
    final layoutPreviewGeometryChanged =
        widget.rect != oldWidget.rect &&
        (widget.layoutPreviewing || oldWidget.layoutPreviewing);
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
    final overviewGeometryWillAnimate =
        widget.duration != Duration.zero && widget.rect != oldWidget.rect;
    if (!oldWidget.overview && widget.overview) {
      _curve = interruptedOverviewTransition
          ? Motion.overviewReversalCurve
          : Motion.overviewEnterCurve;
      _overviewTransitionActive = overviewGeometryWillAnimate;
      _overviewTransitionCompleted.value = !_overviewTransitionActive;
    } else if (oldWidget.overview && !widget.overview) {
      _curve = interruptedOverviewTransition
          ? Motion.overviewReversalCurve
          : Motion.overviewExitCurve;
      _overviewTransitionActive = overviewGeometryWillAnimate;
      _overviewTransitionCompleted.value = false;
    } else if (widget.desktopWidget != oldWidget.desktopWidget ||
        widget.offscreenMinimized != oldWidget.offscreenMinimized ||
        widget.switching ||
        oldWidget.switching) {
      _curve = Motion.md3Emphasized;
      _overviewTransitionActive = false;
      _overviewTransitionCompleted.value = false;
    } else if (layoutPreviewGeometryChanged) {
      // Native layout previews include only siblings whose planned rectangle
      // changed, so the dragged tile and unaffected tiles never bounce.
      _curve = Motion.layoutTileReflowCurve;
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
    final devicePixelRatio =
        widget.pixelGridScale ?? MediaQuery.devicePixelRatioOf(context);
    if (pixelAlignmentInset != null) {
      rect = desktopPixelAlignedWindowFrame(
        frame: rect,
        contentInset: pixelAlignmentInset,
        devicePixelRatio: devicePixelRatio,
        pixelGridOrigin: widget.pixelGridOrigin,
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
          pixelGridOrigin: widget.pixelGridOrigin,
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
        ? Motion.layoutTileReflow
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
        final completedOverviewEntrance =
            _overviewTransitionActive && widget.overview;
        _overviewTransitionActive = false;
        _layoutPreviewExitActive = false;
        _dragReleaseAnimationOrigin = null;
        if (completedOverviewEntrance) {
          _overviewTransitionCompleted.value = true;
        }
      },
      globalClipRect: widget.globalClipRect,
      child: DesktopOverviewTransitionStatus(
        completed: _overviewTransitionCompleted,
        child: RetainedTranslation(
          translation: liveTranslation,
          enabled: widget.dragging,
          devicePixelRatio: pixelAlignmentInset == null
              ? null
              : devicePixelRatio,
          child: widget.child,
        ),
      ),
    );
  }
}

class _DesktopSurfaceTexture extends StatefulWidget {
  const _DesktopSurfaceTexture({
    required this.window,
    required this.smooth,
    required this.presentationScale,
    required this.pixelGridOrigin,
  });

  final DenialWindow window;
  final bool smooth;
  final double presentationScale;
  final Offset pixelGridOrigin;

  @override
  State<_DesktopSurfaceTexture> createState() => _DesktopSurfaceTextureState();
}

class _DesktopWindowContent extends ConsumerWidget {
  const _DesktopWindowContent({
    required this.window,
    required this.smooth,
    required this.active,
    required this.borderRadius,
    this.localLayoutSize,
    this.presentationScale,
    this.pixelGridOrigin = Offset.zero,
  });

  final DenialWindow window;
  final bool smooth;
  final bool active;
  final BorderRadius borderRadius;
  final Size? localLayoutSize;
  final double? presentationScale;
  final Offset pixelGridOrigin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShellTheme.of(context);
    final windowOpacity = active
        ? theme.focusedWindowOpacity
        : theme.unfocusedWindowOpacity;
    final content = _buildContent(context);
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
      borderRadius: borderRadius,
      child: content,
    );
  }

  Widget _buildContent(BuildContext context) {
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
    return _DesktopSurfaceTexture(
      window: window,
      smooth: smooth,
      presentationScale:
          presentationScale ?? MediaQuery.devicePixelRatioOf(context),
      pixelGridOrigin: pixelGridOrigin,
    );
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
      presentationScale: widget.presentationScale,
      pixelGridOrigin: widget.pixelGridOrigin,
    );
  }
}
