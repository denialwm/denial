import 'dart:async';

import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/pets.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/default_shell/panel_composition.dart';
import 'desktop_held_layers.dart';
import 'desktop_workspace.dart';

/// Draws the pets [window] holds (denial-pet-v1) around [child], the window,
/// inside its frame's transforms, so they follow every move of the window the
/// user sees: live drags, settling, layout reflow, workspace slides,
/// minimize, the overview and the switcher. Pets stacking below go under the
/// window, the others over it. What the pets above cast on the window, through
/// the selected [ShellPetShadows], goes just under them all, clipped to the
/// window's visible frame.
///
/// Each held pet reports how fast it moves on screen; see [DesktopPetCarry].
///
/// The window keeps its place in the tree whatever pets come and go, so a pet
/// landing never rebuilds the window's content.
class DesktopHeldPets extends StatelessWidget {
  const DesktopHeldPets({
    super.key,
    required this.window,
    required this.pets,
    required this.frameBorder,
    this.frameRadius = 0.0,
    required this.drawsServerFrame,
    required this.opacity,
    required this.duration,
    required this.curve,
    required this.filterQuality,
    required this.presentationScale,
    required this.pixelGridOrigin,
    required this.child,
  });

  final DenialWindow window;

  /// The pets the window holds, back to front, as the scene last saw them.
  /// Each is selected again from the shell state, so its current geometry
  /// and textures are drawn.
  final List<DenialWindow> pets;

  /// The width of the frame the hold points lie on, around the window's
  /// presentation rectangle.
  final double frameBorder;

  /// The radius of the visible frame's corners, which clip what pets cast.
  final double frameRadius;

  /// Whether the window is drawn inside a frame of [DesktopMetrics]'s width,
  /// so its presentation rectangle is the frame deflated by it.
  final bool drawsServerFrame;

  /// The pets fade with their window when it is minimized, but not with its
  /// own translucency.
  final double opacity;
  final Duration duration;
  final Curve curve;
  final FilterQuality filterQuality;
  final double presentationScale;
  final Offset pixelGridOrigin;
  final Widget child;

  static const _belowKey = ValueKey<String>('desktop-held-pets-below');
  static const _windowKey = ValueKey<String>('desktop-held-pets-window');
  static const _aboveKey = ValueKey<String>('desktop-held-pets-above');

  @override
  Widget build(BuildContext context) {
    Widget layer(Key key, {required bool below}) {
      final ids = [
        for (final pet in pets)
          if ((pet.pet?.below ?? false) == below) pet.objectId,
      ];
      return Positioned.fill(
        key: key,
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: opacity,
            duration: duration,
            curve: curve,
            child: _DesktopHeldPetLayer(
              window: window,
              petIds: ids,
              below: below,
              frameBorder: frameBorder,
              frameRadius: frameRadius,
              drawsServerFrame: drawsServerFrame,
              filterQuality: filterQuality,
              presentationScale: presentationScale,
              pixelGridOrigin: pixelGridOrigin,
            ),
          ),
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        if (pets.any((pet) => pet.pet?.below ?? false))
          layer(_belowKey, below: true),
        KeyedSubtree(key: _windowKey, child: child),
        if (pets.any((pet) => !(pet.pet?.below ?? false)))
          layer(_aboveKey, below: false),
      ],
    );
  }
}

/// The pets on one side of a window, laid out over the window's frame.
class _DesktopHeldPetLayer extends ConsumerWidget {
  const _DesktopHeldPetLayer({
    required this.window,
    required this.petIds,
    required this.below,
    required this.frameBorder,
    required this.frameRadius,
    required this.drawsServerFrame,
    required this.filterQuality,
    required this.presentationScale,
    required this.pixelGridOrigin,
  });

  final DenialWindow window;
  final List<int> petIds;
  final bool below;
  final double frameBorder;
  final double frameRadius;
  final bool drawsServerFrame;
  final FilterQuality filterQuality;
  final double presentationScale;
  final Offset pixelGridOrigin;

  static DenialWindow? _layerByObjectId(
    List<DenialWindow> layerSurfaces,
    int objectId,
  ) {
    for (final surface in layerSurfaces) {
      if (surface.objectId == objectId) return surface;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window =
        ref.watch(
          referenceShellProvider.select(
            (state) => state.windowByObjectId(this.window.objectId),
          ),
        ) ??
        this.window;
    final pets = <DenialWindow>[
      for (final id in petIds)
        if (ref.watch(
              referenceShellProvider.select(
                (state) => _layerByObjectId(state.layerSurfaces, id),
              ),
            )
            case final pet?
            when pet.heldBy?.windowId == window.objectId &&
                (pet.pet?.below ?? false) == below)
          pet,
    ];
    if (pets.isEmpty) {
      return const SizedBox.shrink();
    }
    // Pets below the window cast nothing the user could see.
    final shadows = below ? null : ref.watch(desktopPetShadowsProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The frame as the window is laid out, in its own unscaled units;
        // every transform above maps it to the screen with the window.
        final frame = Offset.zero & constraints.biggest;
        final contentRect = drawsServerFrame
            ? frame.deflate(DesktopMetrics.frameBorder)
            : frame;
        final placed = [
          for (final pet in pets)
            if (desktopHeldLayerRect(
                  layer: pet,
                  window: window,
                  contentRect: contentRect,
                  frameBorder: frameBorder,
                )
                case final rect?)
              (pet: pet, rect: _alignToPixels(rect)),
        ];
        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (shadows != null) ?_shadows(shadows, placed, contentRect),
            for (final (:pet, :rect) in placed)
              Positioned.fromRect(
                key: ValueKey<int>(pet.objectId),
                rect: rect,
                child: DesktopPetCarry(
                  petId: pet.objectId,
                  // The user moves a pet they drag, not its window.
                  enabled: !(pet.pet?.dragged ?? false),
                  anchor: _scaledAnchor(pet, rect),
                  child: RepaintBoundary(
                    child: WindowSurfaceTree(
                      window: pet,
                      includePopups: true,
                      filterQuality: filterQuality,
                      presentationScale: presentationScale,
                      pixelGridOrigin: pixelGridOrigin,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// What the [placed] pets cast on the window, under them all and clipped to
  /// its visible frame; null when they cast nothing.
  Widget? _shadows(
    ShellPetShadows shadows,
    List<({DenialWindow pet, Rect rect})> placed,
    Rect contentRect,
  ) {
    final visible = desktopHeldFrameRect(
      window: window,
      contentRect: contentRect,
      frameBorder: frameBorder,
    );
    if (visible == null) return null;
    final cast = <Widget>[
      for (final (:pet, :rect) in placed)
        if (pet.heldBy?.hold case final hold?)
          if (shadows.shadowFor(
                PetShadow(
                  pet: pet,
                  hold: hold,
                  size: rect.size,
                  anchor: _scaledAnchor(pet, rect),
                  surface: WindowSurfaceTree(
                    window: pet,
                    filterQuality: FilterQuality.low,
                    presentationScale: presentationScale,
                    pixelGridOrigin: pixelGridOrigin,
                  ),
                ),
              )
              case final shadow?)
            Positioned.fromRect(
              key: ValueKey<int>(pet.objectId),
              rect: rect.shift(-visible.topLeft),
              child: shadow,
            ),
    ];
    if (cast.isEmpty) return null;
    return Positioned.fromRect(
      key: const ValueKey<String>('desktop-held-pet-shadows'),
      rect: visible,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(frameRadius),
        child: Stack(clipBehavior: Clip.none, children: cast),
      ),
    );
  }

  /// Where the pet holds on, in its drawn rectangle [rect].
  static Offset _scaledAnchor(DenialWindow pet, Rect rect) {
    final geometry = pet.geometry;
    final anchor = pet.pet?.anchor ?? Offset.zero;
    if (geometry == null || geometry.width <= 0 || geometry.height <= 0) {
      return anchor;
    }
    return Offset(
      anchor.dx * rect.width / geometry.width,
      anchor.dy * rect.height / geometry.height,
    );
  }

  /// The window's frame lies on device pixels when it is not transformed; a
  /// pet's anchor may not, so its texture would be sampled between them.
  Rect _alignToPixels(Rect rect) {
    final scale = presentationScale;
    if (scale <= 0) return rect;
    double snap(double value) => (value * scale).roundToDouble() / scale;
    return Rect.fromLTWH(
      snap(rect.left),
      snap(rect.top),
      snap(rect.width),
      snap(rect.height),
    );
  }
}

/// Reports how fast a held pet moves on screen to the compositor, which
/// forwards it to the pet (`carried`): what the user sees, every animation
/// of its window included.
///
/// The point the pet holds on by is read after each frame the shell draws
/// anyway; tracking never asks for a frame. The velocity is measured over at
/// least [sample], and a pet that stops moving is told so after [still]
/// without a frame that moves it.
class DesktopPetCarry extends ConsumerStatefulWidget {
  const DesktopPetCarry({
    super.key,
    required this.petId,
    this.enabled = true,
    required this.anchor,
    required this.child,
  });

  final int petId;

  /// Whether the pet is carried. A pet the user drags is not.
  final bool enabled;

  /// The point the pet holds on by, in this widget's coordinates.
  final Offset anchor;
  final Widget child;

  static const sample = Duration(milliseconds: 16);
  static const still = Duration(milliseconds: 48);

  /// Velocities closer than this to the last one sent, in logical px/s, are
  /// not sent again.
  static const tolerance = 1.0;

  @override
  ConsumerState<DesktopPetCarry> createState() => _DesktopPetCarryState();
}

class _DesktopPetCarryState extends ConsumerState<DesktopPetCarry> {
  late final void Function(int petId, Offset velocity) _carry;
  bool _scheduled = false;
  Offset? _from;
  Duration? _fromTime;
  Offset _sent = Offset.zero;
  Timer? _stop;

  @override
  void initState() {
    super.initState();
    // Kept for dispose, when the provider may no longer be read.
    _carry = ref.read(denialBridgeProvider).carryPet;
    _schedule();
  }

  @override
  void didUpdateWidget(covariant DesktopPetCarry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.petId != widget.petId || !widget.enabled) {
      _stop?.cancel();
      _send(Offset.zero, petId: oldWidget.petId);
      _from = null;
      _fromTime = null;
    }
  }

  @override
  void dispose() {
    _stop?.cancel();
    // Its window went from view, or let it go: it is no longer carried.
    _send(Offset.zero);
    super.dispose();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    // A post-frame callback runs after the next frame drawn for any reason
    // and never schedules one itself.
    SchedulerBinding.instance.addPostFrameCallback(_sampleFrame);
  }

  void _sampleFrame(Duration time) {
    _scheduled = false;
    if (!mounted) return;
    _schedule();
    if (!widget.enabled) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final point = box.localToGlobal(widget.anchor);
    if (!point.isFinite) return;
    final from = _from;
    final fromTime = _fromTime;
    if (from == null || fromTime == null) {
      _from = point;
      _fromTime = time;
      return;
    }
    final elapsed = time - fromTime;
    if (elapsed < DesktopPetCarry.sample) return;
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _from = point;
    _fromTime = time;
    final velocity = (point - from) / seconds;
    _send(velocity);
    _stop?.cancel();
    if (velocity != Offset.zero) {
      // No frame may come once it stops: the last one moved it.
      _stop = Timer(DesktopPetCarry.still, () {
        _fromTime = null;
        _send(Offset.zero);
      });
    }
  }

  void _send(Offset velocity, {int? petId}) {
    if ((velocity - _sent).distance < DesktopPetCarry.tolerance &&
        (velocity == Offset.zero) == (_sent == Offset.zero)) {
      return;
    }
    _sent = velocity;
    _carry(petId ?? widget.petId, velocity);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
