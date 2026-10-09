import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/pets.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/default_shell/panel_composition.dart';
import 'desktop_held_layers.dart';
import 'desktop_workspace.dart';

/// While the user drags a desktop pet, asks the selected [ShellPetHolds]
/// which window would hold it, from what the user sees, and names that hold
/// to the compositor. The compositor applies the last one named when the
/// user lets go; meanwhile the window's frame draws the pet on it.
class DesktopPetHoldPublisher extends ConsumerStatefulWidget {
  const DesktopPetHoldPublisher({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<DesktopPetHoldPublisher> createState() =>
      _DesktopPetHoldPublisherState();
}

class _DesktopPetHoldPublisherState
    extends ConsumerState<DesktopPetHoldPublisher> {
  /// The hold last named for each pet being dragged.
  final Map<int, DenialPetHold?> _named = {};
  bool _scheduled = false;

  @override
  Widget build(BuildContext context) {
    final holds = ref.watch(desktopPetHoldsProvider);
    final dragged = ref.watch(
      referenceShellProvider.select(
        (state) => _DraggedPets(state.layerSurfaces),
      ),
    );
    if (holds != null && dragged.pets.isNotEmpty) {
      // The scene a hold depends on, while something is dragged.
      ref.watch(desktopWorkspaceProvider);
      ref.watch(displayLayoutProvider);
      ref.watch(referenceShellProvider.select((state) => state.windows));
      _schedule();
    } else if (_named.isNotEmpty) {
      _named.clear();
    }
    return widget.child;
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    // Built in a frame: name the hold once it is laid out.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _name();
    });
  }

  void _name() {
    final holds = ref.read(desktopPetHoldsProvider);
    final shell = ref.read(referenceShellProvider);
    final pets = _DraggedPets(shell.layerSurfaces).pets;
    _named.removeWhere((id, _) => !pets.any((pet) => pet.objectId == id));
    if (holds == null || pets.isEmpty) return;
    final desktop = ref.read(desktopWorkspaceProvider);
    final screens = [
      for (final output
          in ref.read(displayLayoutProvider)?.outputs ??
              const <DisplayOutput>[])
        output.logicalRect,
    ];
    final bridge = ref.read(denialBridgeProvider);
    for (final pet in pets) {
      final description = pet.pet!;
      final targets = desktop.overviewActive
          ? const <PetHoldTarget>[]
          : desktopPetHoldTargets(
              desktop: desktop,
              windows: shell.windows,
              layerSurfaces: shell.layerSurfaces,
              pet: pet,
            );
      final proposed = holds.holdFor(
        PetDrag(
          pet: pet,
          anchor: pet.geometry!.topLeft + description.anchor,
          targets: targets,
          screens: screens,
        ),
      );
      // Native would refuse anything else; the host does not ask it to.
      final hold =
          proposed != null &&
              description.accepts(proposed.hold) &&
              targets.any(
                (target) =>
                    target.holdsPets && target.window == proposed.windowId,
              )
          ? proposed
          : null;
      final last = _named.containsKey(pet.objectId)
          ? _named[pet.objectId]
          : description.held;
      if (hold == last) continue;
      _named[pet.objectId] = hold;
      bridge.holdPet(pet.objectId, hold);
    }
  }
}

/// The pets the user is dragging, compared by value.
@immutable
class _DraggedPets {
  _DraggedPets(List<DenialWindow> layerSurfaces)
    : pets = [
        for (final surface in layerSurfaces)
          if ((surface.pet?.dragged ?? false) && surface.geometry != null)
            surface,
      ];

  final List<DenialWindow> pets;

  @override
  bool operator ==(Object other) =>
      other is _DraggedPets && listEquals(other.pets, pets);

  @override
  int get hashCode => Object.hashAll(pets);
}

/// What the user sees around [pet], front to back, for [PetDrag.targets]:
/// panels and free pets over the windows, then each window shown on its
/// workspace with the pets it holds above it, its popups, itself and the
/// pets it holds below it. Windows that are fullscreen or maximized cover
/// without holding.
List<PetHoldTarget> desktopPetHoldTargets({
  required DesktopWorkspaceState desktop,
  required List<DenialWindow> windows,
  required List<DenialWindow> layerSurfaces,
  required DenialWindow pet,
}) {
  final targets = <PetHoldTarget>[];
  // Layer surfaces stack back to front.
  for (final surface in layerSurfaces.reversed) {
    final geometry = surface.geometry;
    if (surface.objectId == pet.objectId ||
        surface.isHeld ||
        geometry == null ||
        geometry.isEmpty) {
      continue;
    }
    if (surface.contentKind == DenialWindowContentKind.layerShellTop ||
        surface.contentKind == DenialWindowContentKind.layerShellOverlay) {
      targets.add(PetHoldTarget(rect: geometry));
    }
  }
  final windowsById = {for (final window in windows) window.objectId: window};
  final held = desktopHeldLayersByWindow(
    layerSurfaces.where((surface) => surface.objectId != pet.objectId),
  );
  final placements =
      desktop.placements.values
          .where(
            (placement) =>
                !placement.minimized &&
                desktop.isPlacementOnActiveWorkspace(placement) &&
                windowsById.containsKey(placement.objectId),
          )
          .toList(growable: false)
        ..sort((a, b) => compareDesktopWindowStack(b, a, windowsById));
  for (final placement in placements) {
    final window = windowsById[placement.objectId]!;
    final pets = held[placement.objectId] ?? const <DenialWindow>[];
    Iterable<PetHoldTarget> petTargets({required bool below}) sync* {
      for (final heldPet in pets.reversed) {
        if ((heldPet.pet?.below ?? false) != below) continue;
        final rect = desktopHeldLayerRect(
          layer: heldPet,
          window: window,
          contentRect: placement.contentRect,
          frameBorder: placement.frameBorder,
        );
        if (rect != null && !rect.isEmpty) {
          yield PetHoldTarget(rect: rect);
        }
      }
    }

    targets.addAll(petTargets(below: false));
    for (final popup in window.popupRootsFrontToBack) {
      final rect = window.mapSurfaceRect(popup, placement.contentRect);
      if (!rect.isEmpty) targets.add(PetHoldTarget(rect: rect));
    }
    final holdsPets = !placement.fullscreen && !placement.maximized;
    targets.add(
      PetHoldTarget(
        rect: placement.frame,
        window: holdsPets ? placement.objectId : null,
        frame: holdsPets ? placement.frame : null,
      ),
    );
    targets.addAll(petTargets(below: true));
  }
  return targets;
}
