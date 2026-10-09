import 'dart:async';
import 'dart:math' as math;

import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/diagnostics.dart';
import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/clipboard_tray.dart';
import '../widgets/desktop_visibility_transition.dart';
import '../widgets/desktop_window_close_animation.dart';
import '../widgets/desktop_window_emphasis_transition.dart';
import '../widgets/desktop_window_reveal.dart';
import 'desktop_held_pets.dart';
import 'desktop_overview_preview_interaction.dart';
import 'desktop_pixel_alignment.dart';
import 'desktop_texture_resize.dart';
import 'desktop_widget_transition.dart';
import 'desktop_window_coordinator.dart';
import 'desktop_window_frame_painter.dart';
import 'desktop_workspace.dart';
import 'retained_animated_positioned.dart';
import 'window_backdrop_blur_policy.dart';

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

class ClosingDesktopWindow {
  const ClosingDesktopWindow({
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

class DesktopClosingWindowFrame extends StatelessWidget {
  const DesktopClosingWindowFrame({
    super.key,
    required this.closing,
    required this.onCompleted,
  });

  final ClosingDesktopWindow closing;
  final VoidCallback onCompleted;

  @override
  Widget build(BuildContext context) {
    final drawsServerFrame =
        !closing.fullscreen && closing.window.serverSideDecorated;
    final radius = drawsServerFrame ? ShellTheme.of(context).windowRadius : 0.0;
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
            DesktopVisibilityFade(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: DesktopWindowShadowPainter(
                    windowId: closing.window.objectId,
                    radius: radius,
                    shadowColor: context.shellColors.shadow,
                  ),
                ),
              ),
            ),
          _DesktopWindowContent(
            window: closing.window,
            smooth: false,
            active: false,
            borderRadius: BorderRadius.circular(radius),
            frameWidth: drawsServerFrame ? DesktopMetrics.frameBorder : 0,
            frameColor: frameColor,
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

class DesktopWindowFrame extends ConsumerWidget {
  const DesktopWindowFrame({
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
    this.overviewDeparting = false,
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
    this.heldPets = const <DenialWindow>[],
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

  /// Leaving a workspace overview for a workspace that is not shown. The
  /// window keeps its scaled overview presentation while it moves off screen.
  final bool overviewDeparting;
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

  /// The pets the window holds (denial-pet-v1), back to front. They are drawn
  /// with the window, inside every transform that moves it.
  final List<DenialWindow> heldPets;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window =
        ref.watch(
          referenceShellProvider.select(
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
        overview ||
        overviewDeparting ||
        switching ||
        desktopWidget ||
        offscreenMinimized;
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
    return DesktopAnimatedWindowPosition(
      separateSurfaceOpacity: true,
      duration: placement.dragging || suppressPositionAnimation
          ? Duration.zero
          : duration,
      rect: frame,
      layoutRect: transformed ? placement.frame : null,
      placementObjectId: placement.objectId,
      overview: overview,
      overviewDeparting: overviewDeparting,
      switching: switching,
      desktopWidget: desktopWidget,
      offscreenMinimized: offscreenMinimized,
      dragging: placement.dragging,
      resizing: placement.resizing,
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
        child: DesktopWidgetVerticalTransition(
          entering: desktopWidgetEntering,
          exiting: desktopWidgetExiting,
          duration: desktopWidgetTransitionDuration,
          child: TrackedDesktopWindowReveal(
            key: ValueKey<String>('desktop-window-content-${window.objectId}'),
            registry: windowRevealRegistry,
            objectId: window.objectId,
            enabled: window.shouldAnimateEntrance,
            suppressInitialAnimation: desktopWindowSuppressesInitialReveal(
              overview: overview || overviewDeparting,
              switching: switching,
              minimized: placement.minimized,
              hasWorkspaceTransition:
                  workspaceTransition != null && !placement.minimized,
            ),
            child: IgnorePointer(
              ignoring:
                  minimized ||
                  overviewDeparting ||
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
                  child: DesktopHeldPets(
                    window: window,
                    pets: heldPets,
                    frameBorder: placement.frameBorder,
                    frameRadius: windowRadius,
                    drawsServerFrame: drawsServerFrame,
                    opacity: desktopWindowPresentationOpacity(
                      transparencyMode: theme.transparencyMode,
                      minimized: minimized,
                      desktopWidget: desktopWidget,
                      windowOpacity: 1.0,
                    ),
                    duration: minimizeEffectDuration,
                    curve: minimizeCurve,
                    filterQuality: transformed || resizing
                        ? FilterQuality.medium
                        : FilterQuality.none,
                    presentationScale: devicePixelRatio,
                    pixelGridOrigin: pixelGridOrigin,
                    child: AnimatedDesktopPresentationOpacity(
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
                              final client = _DesktopWindowContent(
                                window: window,
                                allowDirectLayers:
                                    !transformed && !resizing && !minimized,
                                smooth: transformed || resizing,
                                active: active && !minimized,
                                borderRadius: BorderRadius.circular(
                                  windowRadius,
                                ),
                                frameWidth: drawsServerFrame
                                    ? DesktopMetrics.frameBorder
                                    : 0,
                                frameColor: Color.alphaBlend(
                                  desktopWindowBorderColor(
                                    pinned: window.pinned,
                                    active: active,
                                    theme: theme,
                                    inactiveColor:
                                        context.shellColors.hairlineWindow,
                                  ),
                                  context.shellColors.windowFrameSurface,
                                ),
                                localLayoutSize: window.isLocalFlutter
                                    ? placement.contentRect.size
                                    : null,
                                presentationScale: devicePixelRatio,
                                pixelGridOrigin: pixelGridOrigin,
                              );
                              if (!drawsServerFrame) {
                                return client;
                              }
                              return DesktopWindowFrameLayers(
                                drawFrame: false,
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
      ),
    );
  }
}

class DesktopWorkspaceWindowTransition extends StatefulWidget {
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
  State<DesktopWorkspaceWindowTransition> createState() =>
      _DesktopWorkspaceWindowTransitionState();
}

class _DesktopWorkspaceWindowTransitionState
    extends State<DesktopWorkspaceWindowTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Offset _begin = Offset.zero;
  Offset _end = Offset.zero;
  Offset _distance = Offset.zero;
  bool _participates = false;

  Offset get _offset {
    if (!_participates) return Offset.zero;
    // Never leave interpolation residue in the settled window transform.
    if (_controller.isCompleted) return _end;
    return Offset.lerp(
      _begin,
      _end,
      Motion.workspaceSwitchCurve.transform(_controller.value),
    )!;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, value: 1);
    _updateTransition();
  }

  @override
  void didUpdateWidget(covariant DesktopWorkspaceWindowTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateTransition(oldWidget);
  }

  void _updateTransition([DesktopWorkspaceWindowTransition? oldWidget]) {
    final current = _offset;
    final wasParticipating = _participates;
    final placement = widget.placement;
    // Older departures retain their original serial and ticker timeline while
    // the latest incoming/outgoing pair can retarget from its current position.
    final transition = widget.transition?.forWorkspace(placement.workspaceId);
    final oldTransition = oldWidget?.transition?.forWorkspace(
      oldWidget.placement.workspaceId,
    );
    final resolvedOutput = widget.outputRect;
    final vertical =
        widget.orientation == WorkspaceSwitchingOrientation.vertical;
    final outputExtent = vertical
        ? resolvedOutput?.height
        : resolvedOutput?.width;
    final fallbackExtent = vertical
        ? placement.frame.height
        : placement.frame.width;
    final travel = outputExtent?.isFinite == true
        ? outputExtent!
        : fallbackExtent;
    _participates =
        !placement.minimized &&
        transition != null &&
        (placement.workspaceId == transition.fromWorkspace ||
            placement.workspaceId == transition.toWorkspace);
    if (!_participates) {
      _controller.stop();
      _begin = _end = _distance = Offset.zero;
      _controller.value = 1;
      return;
    }
    final entering = placement.workspaceId == transition!.toWorkspace;
    final direction = transition.direction.toDouble();
    final distance = vertical
        ? Offset(0, direction * travel)
        : Offset(direction * travel, 0);
    final end = entering ? Offset.zero : -distance;
    final changed =
        !wasParticipating ||
        oldTransition?.serial != transition.serial ||
        oldTransition?.monitorId != transition.monitorId ||
        _distance != distance ||
        _end != end;
    _distance = distance;
    _end = end;
    _controller.duration = widget.duration;
    if (widget.duration == Duration.zero) {
      _controller.stop();
      _begin = _end;
      _controller.value = 1;
    } else if (changed) {
      // Retarget from the currently presented position on rapid switches,
      // preserving the window subtree and its authoritative placement.
      _begin = wasParticipating
          ? current
          : entering
          ? distance
          : Offset.zero;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resolvedOutput = widget.outputRect;
    return ClipPath(
      clipper: _participates && resolvedOutput != null
          ? _WorkspaceOutputClipper(
              resolvedOutput.shift(-widget.placement.frame.topLeft),
            )
          : null,
      clipBehavior: _participates ? Clip.hardEdge : Clip.none,
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) =>
            Transform.translate(offset: _offset, child: child),
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

class DesktopAnimatedWindowPosition extends ConsumerStatefulWidget {
  const DesktopAnimatedWindowPosition({
    super.key,
    required this.duration,
    required this.rect,
    this.layoutRect,
    required this.placementObjectId,
    required this.overview,
    this.overviewDeparting = false,
    required this.switching,
    this.desktopWidget = false,
    this.offscreenMinimized = false,
    required this.dragging,
    required this.resizing,
    required this.layoutPreviewing,
    this.pixelAlignmentInset,
    this.pixelGridScale,
    this.pixelGridOrigin = Offset.zero,
    this.alignSizeToDevicePixels = false,
    this.globalClipRect,
    this.separateSurfaceOpacity = false,
    required this.child,
  });

  final Duration duration;
  final Rect rect;
  final Rect? layoutRect;
  final int placementObjectId;
  final bool overview;
  final bool overviewDeparting;
  final bool switching;
  final bool desktopWidget;
  final bool offscreenMinimized;
  final bool dragging;
  final bool resizing;
  final bool layoutPreviewing;
  final double? pixelAlignmentInset;
  final double? pixelGridScale;
  final Offset pixelGridOrigin;
  final bool alignSizeToDevicePixels;
  final Rect? globalClipRect;
  final bool separateSurfaceOpacity;
  final Widget child;

  @override
  ConsumerState<DesktopAnimatedWindowPosition> createState() =>
      _DesktopAnimatedWindowPositionState();
}

class _DesktopAnimatedWindowPositionState
    extends ConsumerState<DesktopAnimatedWindowPosition> {
  late Curve _curve;
  late final ValueNotifier<bool> _overviewTransitionCompleted;
  bool _overviewTransitionActive = false;
  bool _layoutPreviewExitActive = false;
  bool _resizeJustEnded = false;
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
  void didUpdateWidget(covariant DesktopAnimatedWindowPosition oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resizeJustEnded = oldWidget.resizing && !widget.resizing;
    final layoutPreviewGeometryChanged =
        widget.rect != oldWidget.rect &&
        (widget.layoutPreviewing || oldWidget.layoutPreviewing);
    if (oldWidget.dragging && !widget.dragging) {
      final translation = ref
          .read(desktopLiveWindowPlacementsProvider)
          .settleTranslation(widget.placementObjectId);
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
    if (widget.overviewDeparting && !oldWidget.overviewDeparting) {
      _curve = Motion.overviewExitCurve;
      _overviewTransitionActive = false;
      _overviewTransitionCompleted.value = false;
    } else if (!oldWidget.overview && widget.overview) {
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
            !widget.overviewDeparting &&
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
    // Also commit the release rectangle immediately if the final pointer
    // sample and transaction end arrive in the same Flutter frame.
    final positionDuration =
        widget.dragging || widget.resizing || _resizeJustEnded
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
      child: DesktopVisibilityTransition(
        separateSurfaceOpacity: widget.separateSurfaceOpacity,
        child: DesktopWindowEmphasisTransition(
          windowId: widget.placementObjectId,
          separateSurfaceOpacity: widget.separateSurfaceOpacity,
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
        ),
      ),
    );
  }
}

class _DesktopSurfaceTexture extends StatefulWidget {
  const _DesktopSurfaceTexture({
    required this.window,
    required this.allowDirectLayers,
    required this.smooth,
    required this.presentationScale,
    required this.pixelGridOrigin,
    required this.radius,
    required this.frameWidth,
    required this.frameColor,
    required this.backdrop,
  });

  final DenialWindow window;
  final bool allowDirectLayers;
  final bool smooth;
  final double presentationScale;
  final Offset pixelGridOrigin;

  final double radius;
  final double frameWidth;
  final Color frameColor;
  final ImageFilterConfig? backdrop;

  @override
  State<_DesktopSurfaceTexture> createState() => _DesktopSurfaceTextureState();
}

class _DesktopWindowContent extends ConsumerWidget {
  const _DesktopWindowContent({
    required this.window,
    this.allowDirectLayers = false,
    required this.smooth,
    required this.active,
    required this.borderRadius,
    this.frameWidth = 0,
    this.frameColor = const Color(0x00000000),
    this.localLayoutSize,
    this.presentationScale,
    this.pixelGridOrigin = Offset.zero,
  });

  final DenialWindow window;
  final bool allowDirectLayers;
  final bool smooth;
  final bool active;
  final BorderRadius borderRadius;
  final double frameWidth;
  final Color frameColor;
  final Size? localLayoutSize;
  final double? presentationScale;
  final Offset pixelGridOrigin;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      DesktopVisibilityFade(child: _buildSurface(context, ref));

  Widget _buildSurface(BuildContext context, WidgetRef ref) {
    final theme = ShellTheme.of(context);
    final windowOpacity = active
        ? theme.focusedWindowOpacity
        : theme.unfocusedWindowOpacity;
    final localApplication = window.isLocalFlutter
        ? ref.watch(localFlutterApplicationRegistryProvider)[window.appId]
        : null;
    final wantsBackdrop = desktopWindowNeedsBackdropTexture(
      window: window,
      shellOpacity: windowOpacity,
      localContentTranslucent: localApplication?.translucent ?? false,
    );
    final available =
        wantsBackdrop &&
        theme.backdropBlurEnabled &&
        (theme.transparencyMode == ShellTransparencyMode.glass ||
            theme.backdropBlurSigma > 0) &&
        theme.backdropBlurOpacityThreshold < 1;
    final backdrop = available
        ? theme.backdropFilterConfigAt(
            1,
            borderRadius: BorderRadius.circular(
              math.max(0, borderRadius.topLeft.x - frameWidth),
            ),
            useWindowAlphaThreshold: true,
            singleWindowSurface:
                false, // The primitive selects its input plan explicitly.
          )
        : null;
    if (window.isLocalFlutter) {
      return WindowPlane.child(
        radius: borderRadius.topLeft.x,
        frameWidth: frameWidth,
        frameColor: frameColor,
        backdrop: backdrop,
        child: _buildContent(context),
      );
    }
    return _DesktopSurfaceTexture(
      window: window,
      allowDirectLayers: allowDirectLayers,
      smooth: smooth,
      presentationScale:
          presentationScale ?? MediaQuery.devicePixelRatioOf(context),
      pixelGridOrigin: pixelGridOrigin,
      radius: borderRadius.topLeft.x,
      frameWidth: frameWidth,
      frameColor: frameColor,
      backdrop: backdrop,
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
    throw StateError('Only local Flutter content uses the child window input');
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
    final texture = singleWindowPlaneTexture(widget.window);
    if (texture != null) {
      return WindowPlane.texture(
        texture: texture,
        radius: widget.radius,
        frameWidth: widget.frameWidth,
        frameColor: widget.frameColor,
        backdrop: widget.backdrop,
        filterQuality: filterQuality,
        presentationScale: widget.presentationScale,
        pixelGridOrigin: widget.pixelGridOrigin,
      );
    }
    final layers = widget.window.paintedMainSurfaceLayers;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final content = (Offset.zero & size).deflate(
          widget.frameWidth.clamp(0.0, size.shortestSide / 2),
        );
        if (widget.allowDirectLayers &&
            !_smooth &&
            canDrawWindowLayersDirectly(
              window: widget.window,
              layers: layers,
              content: content,
              radius: widget.radius,
              frameWidth: widget.frameWidth,
              presentationScale: widget.presentationScale,
              hasBackdrop: widget.backdrop != null,
            )) {
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              WindowPlane.texture(
                texture: windowPlaneTextureForLayer(
                  widget.window,
                  layers.first,
                ),
                radius: widget.radius,
                frameWidth: widget.frameWidth,
                frameColor: widget.frameColor,
                filterQuality: filterQuality,
                presentationScale: widget.presentationScale,
                pixelGridOrigin: widget.pixelGridOrigin,
              ),
              for (final layer in layers.skip(1))
                Positioned.fromRect(
                  key: ValueKey(layer.surfaceId),
                  rect: widget.window.mapSurfaceRect(layer, content),
                  child: SurfaceLayerTexture(
                    layer: layer,
                    filterQuality: filterQuality,
                    presentationScale: widget.presentationScale,
                    pixelGridOrigin: widget.pixelGridOrigin,
                  ),
                ),
            ],
          );
        }
        return WindowPlane.child(
          radius: widget.radius,
          frameWidth: widget.frameWidth,
          frameColor: widget.frameColor,
          backdrop: widget.backdrop,
          child: WindowSurfaceTree(
            window: widget.window,
            filterQuality: filterQuality,
            presentationScale: widget.presentationScale,
            pixelGridOrigin: widget.pixelGridOrigin,
          ),
        );
      },
    );
  }
}
