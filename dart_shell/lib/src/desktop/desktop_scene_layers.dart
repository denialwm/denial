part of 'desktop_shell.dart';

class _DesktopLayerShellSurface extends StatelessWidget {
  const _DesktopLayerShellSurface({
    required this.surface,
    required this.displayLayout,
    super.key,
  });

  final DenialWindow surface;
  final DisplayLayout? displayLayout;

  @override
  Widget build(BuildContext context) {
    final geometry = surface.geometry;
    if (geometry == null || surface.surfaceLayers.isEmpty) {
      return const SizedBox.shrink();
    }
    final outputPixelGrid = desktopOutputPixelGridForMonitor(
      displayLayout,
      surface.monitorId,
    );
    return Positioned.fromRect(
      rect: geometry,
      // Flutter paints the client texture, while DesktopInputLayoutPublisher
      // transfers pointer and touch ownership to the native Wayland route.
      // Keeping this widget transparent avoids duplicating that lifecycle in
      // Flutter's gesture arena.
      child: IgnorePointer(
        child: RepaintBoundary(
          child: WindowSurfaceTree(
            window: surface,
            includePopups: true,
            presentationScale: outputPixelGrid?.scale,
            pixelGridOrigin:
                outputPixelGrid?.logicalRect.topLeft ?? Offset.zero,
          ),
        ),
      ),
    );
  }
}

class _DesktopPanelEdgeTrigger extends StatelessWidget {
  const _DesktopPanelEdgeTrigger({required this.onEnter, required this.onExit});

  final VoidCallback onEnter;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: MouseRegion(
        opaque: true,
        onEnter: (_) => onEnter(),
        onExit: (_) => onExit(),
        child: const SizedBox.expand(),
      ),
    );
  }
}

Offset _entryDirectionFor(int horizontal, int vertical) {
  if (horizontal != 0) {
    return Offset(horizontal.toDouble(), 0);
  }
  if (vertical != 0) {
    return Offset(0, vertical.toDouble());
  }
  return Offset.zero;
}

/// Owns overview input while keeping wallpaper-plane controls interactive.
///
/// The full-scene region transfers native pointer ownership to Flutter. The
/// dismissal barrier then handles otherwise-unclaimed taps, while controls
/// painted after it (such as the workspace indicator and system tray) win
/// Flutter hit testing inside their own bounds.
class DesktopOverviewInputLayer extends StatelessWidget {
  const DesktopOverviewInputLayer({
    required this.active,
    required this.onBarrierTap,
    required this.foregroundControls,
    super.key,
  });

  final bool active;
  final ValueChanged<Offset> onBarrierTap;
  final List<Widget> foregroundControls;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: ShellInputRegion(
            debugLabel: 'Desktop overview',
            active: active,
            pointerPolicy: ShellPointerPolicy.fullScene,
            keyboardPolicy: ShellKeyboardPolicy.capture,
            compositorPolicy: ShellCompositorPolicy.exclusive,
            child: const IgnorePointer(child: SizedBox.expand()),
          ),
        ),
        Positioned.fill(
          child: _DesktopOverviewBarrier(active: active, onTap: onBarrierTap),
        ),
        ...foregroundControls,
      ],
    );
  }
}

class _DesktopOverviewBarrier extends StatelessWidget {
  const _DesktopOverviewBarrier({required this.active, required this.onTap});

  final bool active;
  final ValueChanged<Offset> onTap;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => onTap(details.localPosition),
      ),
    );
  }
}

class _DesktopWidgetCanvas extends StatelessWidget {
  const _DesktopWidgetCanvas({required this.widgets, required this.frames});

  final List<HomeGridItem> widgets;
  final Map<String, Rect> frames;

  @override
  Widget build(BuildContext context) {
    if (widgets.isEmpty) {
      return const SizedBox.shrink();
    }

    return BackdropGroup(
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (final item in widgets)
            if (frames[item.id] case final frame?)
              Positioned.fromRect(
                key: ValueKey<String>('desktop-${item.id}'),
                rect: frame,
                child: _DesktopHomeWidget(item: item),
              ),
        ],
      ),
    );
  }
}

class _DesktopHomeWidget extends StatelessWidget {
  const _DesktopHomeWidget({required this.item});

  final HomeGridItem item;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: HomeGridItemCard(
        item: item,
        launchEnabled: false,
        onLaunch: (_, _) {},
      ),
    );
    return RepaintBoundary(
      child: item.type == HomeGridItemType.clock
          ? content
          : ShellBackdropBlur(
              blur: theme.effectiveCardOpacity < 1.0,
              grouped: true,
              borderRadius: context.shellTheme.borderRadius(ShellRadii.tile),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.cardColor(context.shellColors.panelBackground),
                  borderRadius: context.shellTheme.borderRadius(
                    ShellRadii.tile,
                  ),
                  border: Border.all(color: context.shellColors.hairlineSoft),
                ),
                child: content,
              ),
            ),
    );
  }
}

class _DesktopWidgetVerticalTransition extends StatefulWidget {
  const _DesktopWidgetVerticalTransition({
    required this.entering,
    required this.exiting,
    required this.duration,
    required this.child,
  });

  final bool entering;
  final bool exiting;
  final Duration duration;
  final Widget child;

  @override
  State<_DesktopWidgetVerticalTransition> createState() =>
      _DesktopWidgetVerticalTransitionState();
}

class _DesktopWidgetVerticalTransitionState
    extends State<_DesktopWidgetVerticalTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      value: widget.entering ? 0.0 : 1.0,
      vsync: this,
    );
    _progress = _controller.drive(
      CurveTween(curve: Motion.md3EmphasizedDecelerate),
    );
    if (widget.entering) {
      _controller.forward();
    } else if (widget.exiting) {
      _controller.reverse();
    }
  }

  @override
  void didUpdateWidget(covariant _DesktopWidgetVerticalTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (!oldWidget.entering && widget.entering) {
      _controller.forward(from: 0.0);
    } else if (!oldWidget.exiting && widget.exiting) {
      _controller.reverse(from: 1.0);
    } else if (!widget.entering && !widget.exiting) {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) => FractionalTranslation(
        translation: Offset(0, -1.0 + _progress.value),
        child: child,
      ),
    );
  }
}

class _DesktopPopupSurfaceLayers extends StatelessWidget {
  const _DesktopPopupSurfaceLayers({
    super.key,
    required this.window,
    required this.placement,
    required this.frame,
    required this.minimized,
    required this.offscreenMinimized,
    required this.overviewActive,
    required this.overview,
    required this.switching,
    required this.motionDuration,
  });

  final DenialWindow window;
  final DesktopWindowPlacement placement;
  final Rect frame;
  final bool minimized;
  final bool offscreenMinimized;
  final bool overviewActive;
  final bool overview;
  final bool switching;
  final Duration motionDuration;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
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
                : (
                    frameSize: placement.frame.size,
                    dragging: placement.dragging,
                  );
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
        final placement = followsLivePlacement
            ? selectedPlacement
            : this.placement;
        final outputPixelGrid = ref.watch(
          displayLayoutProvider.select(
            (layout) =>
                desktopOutputPixelGridForMonitor(layout, placement.monitorId),
          ),
        );
        final devicePixelRatio =
            outputPixelGrid?.scale ?? MediaQuery.devicePixelRatioOf(context);
        final pixelGridOrigin =
            outputPixelGrid?.logicalRect.topLeft ?? Offset.zero;
        final liveFrame = followsLivePlacement
            ? desktopLivePlacementVisualFrame(
                visualFrame: this.frame,
                placementFrame: this.placement.frame,
                livePlacementFrame: placement.frame,
              )
            : this.frame;
        final transformed = overview || switching || offscreenMinimized;
        final outputClip = desktopOutputClip(
          activelyDragging: placement.dragging,
          outputRect: outputPixelGrid?.logicalRect,
        );
        final frame = desktopPixelAlignedWindowFrame(
          frame: liveFrame,
          contentInset: placement.frameBorder,
          devicePixelRatio: devicePixelRatio,
          pixelGridOrigin: pixelGridOrigin,
          enabled: !transformed,
          alignSize: true,
        );
        if (window.surfaceLayers.isEmpty) {
          return const SizedBox.shrink();
        }

        final drawsServerFrame = transformed
            ? placement.serverSideDecorated
            : placement.drawsLiveServerFrame;
        final contentRect = drawsServerFrame
            ? frame.deflate(DesktopMetrics.frameBorder)
            : frame;
        final retainedContentRect = drawsServerFrame
            ? placement.frame.deflate(DesktopMetrics.frameBorder)
            : placement.frame;
        final duration = placement.dragging ? Duration.zero : motionDuration;
        final resizing = desktopTextureNeedsResizeSmoothing(
          targetSize: contentRect.size,
          sourceSize: window.contentCoordinateRect.size,
        );
        final filterQuality = transformed || resizing
            ? FilterQuality.medium
            : FilterQuality.none;

        return Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: duration,
              curve: minimized
                  ? Motion.md3EmphasizedAccelerate
                  : Motion.md3EmphasizedDecelerate,
              opacity: desktopWindowPresentationOpacity(
                transparencyMode: ShellTheme.of(context).transparencyMode,
                minimized: minimized,
                desktopWidget: false,
                windowOpacity: 1.0,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final layer in window.popupSurfaceLayers)
                    if (layer.textureId > 0)
                      _DesktopAnimatedWindowPosition(
                        key: ValueKey<int>(layer.surfaceId),
                        duration: duration,
                        rect: window.mapSurfaceRect(layer, contentRect),
                        layoutRect: transformed
                            ? window.mapSurfaceRect(layer, retainedContentRect)
                            : null,
                        placementObjectId: placement.objectId,
                        overview: overview,
                        switching: switching,
                        offscreenMinimized: offscreenMinimized,
                        dragging: placement.dragging,
                        layoutPreviewing: placement.layoutPreviewing,
                        pixelAlignmentInset: 0.0,
                        pixelGridScale: devicePixelRatio,
                        pixelGridOrigin: pixelGridOrigin,
                        alignSizeToDevicePixels: true,
                        globalClipRect: outputClip,
                        child: ShellBackdropBlur(
                          blur: !layer.opaque || layer.opacity < 1.0,
                          useWindowAlphaThreshold: true,
                          singleWindowSurface: true,
                          child: SurfaceLayerTexture(
                            layer: layer,
                            filterQuality: filterQuality,
                            presentationScale: devicePixelRatio,
                            pixelGridOrigin: pixelGridOrigin,
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
