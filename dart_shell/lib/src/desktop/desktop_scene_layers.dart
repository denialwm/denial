part of 'desktop_shell.dart';

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
        onLaunch: (_) {},
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

class _DesktopPopupSurfaceLayers extends StatelessWidget {
  const _DesktopPopupSurfaceLayers({
    super.key,
    required this.window,
    required this.placement,
    required this.frame,
    required this.minimized,
    required this.overviewActive,
    required this.overview,
    required this.switching,
    required this.motionDuration,
  });

  final DenialWindow window;
  final DesktopWindowPlacement placement;
  final Rect frame;
  final bool minimized;
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
        final liveFrame = followsLivePlacement
            ? desktopLivePlacementVisualFrame(
                visualFrame: this.frame,
                placementFrame: this.placement.frame,
                livePlacementFrame: placement.frame,
              )
            : this.frame;
        final transformed = overview || switching;
        final frame = desktopPixelAlignedWindowFrame(
          frame: liveFrame,
          contentInset: placement.frameBorder,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          enabled: !transformed,
          alignSize: true,
        );
        if (window.surfaceLayers.isEmpty) {
          return const SizedBox.shrink();
        }

        final fullscreenVisual = placement.fullscreen && !transformed;
        final drawsServerFrame =
            !fullscreenVisual && placement.serverSideDecorated;
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
              curve: Motion.md3EmphasizedAccelerate,
              opacity: minimized ? 0.0 : 1.0,
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
                        dragging: placement.dragging,
                        pixelAlignmentInset: 0.0,
                        alignSizeToDevicePixels: true,
                        child: ShellBackdropBlur(
                          blur: !layer.opaque || layer.opacity < 1.0,
                          useWindowAlphaThreshold: true,
                          singleWindowSurface: true,
                          child: SurfaceLayerTexture(
                            layer: layer,
                            filterQuality: filterQuality,
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
