import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'desktop_workspace.dart';
import 'desktop_workspace_overview_layout.dart';

/// Workspace cards behind the windows of a managed-layout overview.
///
/// Windows stay in the desktop scene and move between their real frames and
/// these cards. The deck follows the same camera: opening zooms out of the
/// active workspace, and closing zooms into whichever workspace is active by
/// then, so cards and windows travel as one plane. The deck is retained until
/// that closing zoom completes.
class DesktopWorkspaceOverviewDeck extends StatefulWidget {
  const DesktopWorkspaceOverviewDeck({
    super.key,
    required this.desktop,
    required this.onSelectWorkspace,
  });

  final DesktopWorkspaceState desktop;
  final void Function(int monitorId, int workspaceId) onSelectWorkspace;

  @override
  State<DesktopWorkspaceOverviewDeck> createState() =>
      _DesktopWorkspaceOverviewDeckState();
}

class _DesktopWorkspaceOverviewDeckState
    extends State<DesktopWorkspaceOverviewDeck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;
  late final Animation<double> _zoom = _DeckZoom(_progress);
  DesktopOverviewState? _presented;
  int _cameraWorkspace = 1;
  bool _synchronized = false;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this)
      ..addStatusListener(_handleStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_synchronized) {
      _synchronized = true;
      _synchronize();
    }
  }

  @override
  void didUpdateWidget(covariant DesktopWorkspaceOverviewDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    _synchronize();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _synchronize() {
    final overview = widget.desktop.overview;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final closing =
        _progress.status == AnimationStatus.reverse ||
        _progress.status == AnimationStatus.dismissed;
    if (overview?.workspaces != null) {
      if (_presented == null || closing) {
        // The camera starts on the workspace the user is looking at.
        _cameraWorkspace = widget.desktop.activeWorkspaceFor(
          overview!.monitorId,
        );
        _progress.animateTo(
          1.0,
          duration: reduceMotion ? Duration.zero : Motion.overviewOpen,
          curve: _presented == null
              ? Motion.overviewEnterCurve
              : Motion.overviewReversalCurve,
        );
      }
      _presented = overview;
      return;
    }
    final presented = _presented;
    if (presented == null || closing) {
      return;
    }
    if (reduceMotion) {
      _progress.value = 0.0;
      _presented = null;
      return;
    }
    // Windows of the active workspace return to their real frames, so the
    // cards must zoom into that workspace too, even if it changed while open.
    _cameraWorkspace = widget.desktop.activeWorkspaceFor(presented.monitorId);
    _progress.animateBack(
      0.0,
      duration: Motion.overviewClose,
      curve: Motion.overviewExitCurve,
    );
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        widget.desktop.overview?.workspaces == null &&
        mounted) {
      setState(() => _presented = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final overview = _presented;
    final workspaces = overview?.workspaces;
    if (overview == null || workspaces == null) {
      return const SizedBox.shrink();
    }
    final interactive = widget.desktop.overview?.workspaces != null;
    final activeWorkspace = widget.desktop.activeWorkspaceFor(
      overview.monitorId,
    );
    final origin = overview.backgroundBounds.topLeft;
    final scrim = context.shellColors.overviewScrim;
    // The zoom only moves and fades the deck. Its render objects read it in
    // layout and paint, so a frame of the zoom rebuilds no widgets, and the
    // boundary keeps it from repainting the scene behind the deck.
    Rect place(Rect rect) => Rect.lerp(
      workspaces.cameraRect(rect, _cameraWorkspace),
      rect,
      _zoom.value,
    )!.shift(-origin);
    return RepaintBoundary(
      child: IgnorePointer(
        ignoring: !interactive,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Cards of neighbouring workspaces start beside the screen.
            // Keep them on this output while they travel.
            Positioned.fromRect(
              rect: overview.backgroundBounds,
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: [
                    IgnorePointer(
                      child: _FadedDecoratedBox(
                        opacity: _zoom,
                        decoration: BoxDecoration(
                          color: scrim.withValues(alpha: scrim.a * 0.5),
                        ),
                      ),
                    ),
                    // A planned drop can widen a scrolling strip and so
                    // rescale every card. Cards reflow with the windows on
                    // them instead of jumping under their tiles.
                    for (final card in workspaces.cards)
                      _ArrangedRect(
                        key: ValueKey<String>(
                          'workspace-overview-card-${card.workspaceId}',
                        ),
                        frames: _CardFrames(card.rect, card.viewportRect),
                        builder: (context, frames) => _buildCard(
                          context,
                          card: card,
                          frames: frames,
                          place: place,
                          active: card.workspaceId == activeWorkspace,
                          labelled: workspaces.cards.length > 1,
                          monitorId: overview.monitorId,
                        ),
                      ),
                    if (!workspaces.shelf.isEmpty)
                      _ArrangedRect(
                        key: const ValueKey<String>('workspace-overview-shelf'),
                        frames: _CardFrames(workspaces.shelf, workspaces.shelf),
                        builder: (context, frames) => _Placed(
                          motion: _zoom,
                          clipBehavior: Clip.hardEdge,
                          rect: () => frames.rect
                              .shift(-origin)
                              .translate(0.0, (1.0 - _zoom.value) * 48.0),
                          child: IgnorePointer(
                            child: _FadedDecoratedBox(
                              opacity: _zoom,
                              decoration: BoxDecoration(
                                color: context.shellColors.surfaceContainer
                                    .withValues(alpha: 0.42),
                                borderRadius: BorderRadius.circular(
                                  context.shellTheme.panelRadius,
                                ),
                                border: Border.all(
                                  color: context.shellColors.hairline,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    _DropSlot(
                      rect: interactive ? workspaces.dropSlot : null,
                      zoom: _zoom,
                      place: place,
                      radius: workspaces.cards.isEmpty
                          ? 0.0
                          : context.shellTheme.windowRadius *
                                workspaces.cards.first.scale,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required DesktopWorkspaceOverviewCard card,
    required _CardFrames frames,
    required Rect Function(Rect rect) place,
    required bool active,
    required bool labelled,
    required int monitorId,
  }) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final accent = theme.accent;
    final radius =
        theme.windowRadius * card.scale +
        DesktopWorkspaceOverviewLayout.cardInset;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        if (labelled)
          _Placed(
            motion: _zoom,
            rect: () {
              final rect = place(frames.rect);
              return Rect.fromLTWH(
                rect.left,
                rect.top - DesktopWorkspaceOverviewLayout.labelExtent,
                rect.width,
                DesktopWorkspaceOverviewLayout.labelExtent,
              );
            },
            child: IgnorePointer(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 4),
                  // A faded text color would rebuild the paragraph on every
                  // frame of the zoom; the fade only updates its layer. The
                  // engine applies it to a one-glyph label's paint, without
                  // an offscreen layer.
                  child: _WidthStableLabel(
                    child: FadeTransition(
                      opacity: _zoom,
                      child: Text(
                        '${card.workspaceId}',
                        style: theme.text.systemBarCaption.copyWith(
                          color: active ? accent : colors.textSecondary,
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.w500,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        _Placed(
          motion: _zoom,
          rect: () => place(frames.rect),
          child: _WorkspaceOverviewCardSurface(
            workspaceId: card.workspaceId,
            active: active,
            opacity: _zoom,
            radius: radius,
            viewportRect: card.extendsBeyondViewport
                ? () =>
                      place(frames.viewport).shift(-place(frames.rect).topLeft)
                : null,
            viewportRadius: theme.windowRadius * card.scale,
            semanticLabel: context.l10n.settingsShortcutActionSwitchWorkspace(
              card.workspaceId,
            ),
            onTap: () => widget.onSelectWorkspace(monitorId, card.workspaceId),
          ),
        ),
      ],
    );
  }
}

/// The overview zoom, clamped to the camera's range.
class _DeckZoom extends Animation<double>
    with AnimationWithParentMixin<double> {
  _DeckZoom(this.parent);

  @override
  final Animation<double> parent;

  @override
  double get value => parent.value.clamp(0.0, 1.0).toDouble();
}

/// Lays out its child at [rect], read again on every tick of [motion].
///
/// It fills its parent like a non-positioned [Stack] child and places the
/// child as [Positioned.fromRect] would, clipping an overflowing child as a
/// [Stack] with [clipBehavior] does.
class _Placed extends SingleChildRenderObjectWidget {
  const _Placed({
    required this.motion,
    required this.rect,
    this.clipBehavior = Clip.none,
    required super.child,
  });

  final Listenable motion;
  final Rect Function() rect;
  final Clip clipBehavior;

  @override
  _RenderPlaced createRenderObject(BuildContext context) =>
      _RenderPlaced(motion, rect, clipBehavior);

  @override
  void updateRenderObject(BuildContext context, _RenderPlaced renderObject) {
    renderObject
      ..motion = motion
      ..rect = rect
      ..clipBehavior = clipBehavior;
  }
}

class _RenderPlaced extends RenderShiftedBox {
  _RenderPlaced(this._motion, this._rect, this._clipBehavior) : super(null);

  Listenable _motion;
  set motion(Listenable value) {
    if (identical(value, _motion)) {
      return;
    }
    if (attached) {
      _motion.removeListener(markNeedsLayout);
      value.addListener(markNeedsLayout);
    }
    _motion = value;
    markNeedsLayout();
  }

  Rect Function() _rect;
  set rect(Rect Function() value) {
    _rect = value;
    markNeedsLayout();
  }

  Clip _clipBehavior;
  set clipBehavior(Clip value) {
    if (value == _clipBehavior) {
      return;
    }
    _clipBehavior = value;
    markNeedsPaint();
  }

  bool _overflows = false;
  final LayerHandle<ClipRectLayer> _clipLayer = LayerHandle<ClipRectLayer>();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _motion.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _motion.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    super.dispose();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      _overflows = false;
      return;
    }
    final rect = _rect();
    child.layout(
      const BoxConstraints().tighten(width: rect.width, height: rect.height),
    );
    (child.parentData! as BoxParentData).offset = rect.topLeft;
    _overflows =
        rect.left < 0.0 ||
        rect.left + child.size.width > size.width ||
        rect.top < 0.0 ||
        rect.top + child.size.height > size.height;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_clipBehavior != Clip.none && _overflows) {
      _clipLayer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        super.paint,
        clipBehavior: _clipBehavior,
        oldLayer: _clipLayer.layer,
      );
    } else {
      _clipLayer.layer = null;
      super.paint(context, offset);
    }
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      _clipBehavior != Clip.none && _overflows ? Offset.zero & size : null;
}

/// Lays a label out without a width bound when it fits the offered width.
///
/// The zoom changes the width offered to a card's label on every frame. A
/// single line that fits has the same size and glyph positions either way,
/// so the label keeps its layout and its painted layer. A label that does
/// not fit is laid out at the offered constraints.
class _WidthStableLabel extends SingleChildRenderObjectWidget {
  const _WidthStableLabel({required super.child});

  @override
  _RenderWidthStableLabel createRenderObject(BuildContext context) =>
      _RenderWidthStableLabel();
}

class _RenderWidthStableLabel extends RenderProxyBox {
  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(
      BoxConstraints(
        minHeight: constraints.minHeight,
        maxHeight: constraints.maxHeight,
      ),
      parentUsesSize: true,
    );
    if (!constraints.isSatisfiedBy(child.size)) {
      child.layout(constraints, parentUsesSize: true);
    }
    size = constraints.constrain(child.size);
  }
}

/// A [DecoratedBox] whose colors fade with [opacity] without a rebuild.
class _FadedDecoratedBox extends SingleChildRenderObjectWidget {
  const _FadedDecoratedBox({
    required this.decoration,
    required this.opacity,
    super.child,
  });

  final BoxDecoration decoration;
  final Animation<double> opacity;

  @override
  _RenderFadedDecoratedBox createRenderObject(BuildContext context) =>
      _RenderFadedDecoratedBox(
        decoration,
        opacity,
        createLocalImageConfiguration(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFadedDecoratedBox renderObject,
  ) {
    renderObject
      ..base = decoration
      ..opacity = opacity
      ..configuration = createLocalImageConfiguration(context);
  }
}

class _RenderFadedDecoratedBox extends RenderDecoratedBox {
  _RenderFadedDecoratedBox(
    this._base,
    this._opacity,
    ImageConfiguration configuration,
  ) : super(
        decoration: _fadedDecoration(_base, _opacity.value),
        configuration: configuration,
      );

  BoxDecoration _base;
  set base(BoxDecoration value) {
    if (value == _base) {
      return;
    }
    _base = value;
    _fade();
  }

  Animation<double> _opacity;
  set opacity(Animation<double> value) {
    if (identical(value, _opacity)) {
      return;
    }
    if (attached) {
      _opacity.removeListener(_fade);
      value.addListener(_fade);
    }
    _opacity = value;
    _fade();
  }

  void _fade() => decoration = _fadedDecoration(_base, _opacity.value);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _opacity.addListener(_fade);
    _fade();
  }

  @override
  void detach() {
    _opacity.removeListener(_fade);
    super.detach();
  }
}

/// A card's rectangle and its visible work area, which reflow together.
@immutable
class _CardFrames {
  const _CardFrames(this.rect, this.viewport);

  final Rect rect;
  final Rect viewport;

  static _CardFrames lerp(_CardFrames begin, _CardFrames end, double t) =>
      _CardFrames(
        Rect.lerp(begin.rect, end.rect, t)!,
        Rect.lerp(begin.viewport, end.viewport, t)!,
      );

  @override
  bool operator ==(Object other) =>
      other is _CardFrames && other.rect == rect && other.viewport == viewport;

  @override
  int get hashCode => Object.hash(rect, viewport);
}

class _CardFramesTween extends Tween<_CardFrames> {
  _CardFramesTween({super.begin, super.end});

  @override
  _CardFrames lerp(double t) => _CardFrames.lerp(begin!, end!, t);
}

/// Eases arrangement changes while the overview stays open, with the same
/// timing as the window previews that sit on the cards.
class _ArrangedRect extends StatelessWidget {
  const _ArrangedRect({super.key, required this.frames, required this.builder});

  final _CardFrames frames;
  final Widget Function(BuildContext context, _CardFrames frames) builder;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<_CardFrames>(
      tween: _CardFramesTween(begin: frames, end: frames),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Motion.overviewOpen,
      curve: Motion.overviewEnterCurve,
      builder: (context, frames, _) => builder(context, frames),
    );
  }
}

/// Marks where a dragged window will land, as planned by the compositor's
/// layout. It glides between planned tiles and fades when no tile is
/// targeted; a slot appearing anew starts where it is planned.
class _DropSlot extends StatefulWidget {
  const _DropSlot({
    required this.rect,
    required this.zoom,
    required this.place,
    required this.radius,
  });

  final Rect? rect;
  final Animation<double> zoom;
  final Rect Function(Rect rect) place;
  final double radius;

  @override
  State<_DropSlot> createState() => _DropSlotState();
}

class _DropSlotState extends State<_DropSlot> {
  Rect? _lastRect;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant _DropSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rect == null && widget.rect != null) {
      _generation += 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rect = widget.rect ?? _lastRect;
    _lastRect = rect;
    if (rect == null) {
      return const SizedBox.shrink();
    }
    final accent = context.shellTheme.accent;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return _ArrangedRect(
      key: ValueKey<int>(_generation),
      frames: _CardFrames(rect, rect),
      builder: (context, frames) => _Placed(
        motion: widget.zoom,
        clipBehavior: Clip.hardEdge,
        rect: () => widget.place(frames.rect),
        child: IgnorePointer(
          // Starts transparent so a new slot fades in where it lands.
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(
              begin: 0.0,
              end: widget.rect == null ? 0.0 : 1.0,
            ),
            duration: reduceMotion ? Duration.zero : Motion.tile,
            curve: Motion.standard,
            builder: (context, opacity, _) => DecoratedBox(
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.16 * opacity),
                borderRadius: BorderRadius.circular(widget.radius),
                border: Border.all(
                  color: accent.withValues(alpha: 0.72 * opacity),
                  width: 2.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceOverviewCardSurface extends StatefulWidget {
  const _WorkspaceOverviewCardSurface({
    required this.workspaceId,
    required this.active,
    required this.opacity,
    required this.radius,
    required this.viewportRect,
    required this.viewportRadius,
    required this.semanticLabel,
    required this.onTap,
  });

  final int workspaceId;
  final bool active;

  /// The overview fade, applied to the card's paint. An [Opacity] here would
  /// isolate the card in an offscreen layer that the zoom resizes every frame.
  final Animation<double> opacity;
  final double radius;

  /// The visible work area inside a scrolling strip, relative to the card,
  /// read during layout.
  final Rect Function()? viewportRect;
  final double viewportRadius;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  State<_WorkspaceOverviewCardSurface> createState() =>
      _WorkspaceOverviewCardSurfaceState();
}

class _WorkspaceOverviewCardSurfaceState
    extends State<_WorkspaceOverviewCardSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final viewportRect = widget.viewportRect;
    final opacity = widget.opacity;
    final decoration = BoxDecoration(
      color: colors.surfaceContainer.withValues(alpha: _hovered ? 0.56 : 0.38),
      borderRadius: BorderRadius.circular(widget.radius),
      border: Border.all(
        color: widget.active ? theme.accent : colors.hairline,
        width: widget.active ? 2.0 : 1.0,
      ),
    );
    return Semantics(
      button: true,
      selected: widget.active,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          // Hover and selection ease as before; the fade is applied after
          // that tween so it follows the zoom without lagging behind it.
          child: TweenAnimationBuilder<Decoration>(
            tween: DecorationTween(begin: decoration, end: decoration),
            duration: Motion.tile,
            curve: Motion.standard,
            builder: (context, value, child) => _FadedDecoratedBox(
              decoration: value as BoxDecoration,
              opacity: opacity,
              child: child,
            ),
            child: viewportRect == null
                ? null
                : _Placed(
                    motion: opacity,
                    clipBehavior: Clip.hardEdge,
                    rect: viewportRect,
                    child: _FadedDecoratedBox(
                      opacity: opacity,
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHigh.withValues(
                          alpha: 0.32,
                        ),
                        borderRadius: BorderRadius.circular(
                          widget.viewportRadius,
                        ),
                        border: Border.all(color: colors.hairlineSoft),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// Overview cards are resized by the zoom on every frame. Fading their paint
// directly keeps them out of per-frame offscreen layers, which the engine
// would otherwise allocate anew at each size.
Color _faded(Color color, double opacity) =>
    color.withValues(alpha: color.a * opacity);

BoxDecoration _fadedDecoration(BoxDecoration decoration, double opacity) {
  final border = decoration.border;
  return decoration.copyWith(
    color: decoration.color == null ? null : _faded(decoration.color!, opacity),
    border: border is Border && border.isUniform
        ? Border.fromBorderSide(
            border.top.copyWith(color: _faded(border.top.color, opacity)),
          )
        : border,
  );
}
