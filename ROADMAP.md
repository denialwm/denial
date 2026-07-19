# Denial roadmap

Only unfinished project-level work belongs here. Completed investigations and
migration plans are represented by the current code, tests, and architecture
instead of retained as historical task documents.

## One product install

The native build is one Rust workspace containing `deniald` and the private
Flutter Engine host crate. The remaining runtime artifacts are the patched
`libflutter_engine.so`, the Dart AOT bundle and assets, ICU data, and
`deniald`.

The target is one versioned install unit, not a single self-extracting ELF. The
shell bundle should become a declared build dependency, while Flutter support
and bundle paths should no longer be optional runtime flags.

Completion requires:

- a clean build producing the complete install tree from pinned inputs;
- no valid `deniald` configuration without the Flutter shell;
- atomic install and rollback of executable, engine, AOT, ICU, and assets;
- unchanged rendering, input and platform-channel behavior.

## Rust parity audit

The Hyprland implementation is frozen at `hyprland-last-known-good` only as a
regression reference. Native features claimed by historical documents must be
ported and revalidated instead of being assumed complete. The secure
PAM-backed lock boundary is the most important known gap; its contract remains
in `SECURE_LOCK.md`.

Completion requires:

- explicit parity tests for every native platform channel used by Dart;
- secure lock and authentication ownership restored in Rust;
- suspend/resume, VT switching, hotplug and teardown soak tests;
- regressions converted into Rust tests before the legacy checkout is closed.

## Adaptive mixed displays

The current multi-output runtime already provides one scene, global
coordinates, per-output KMS state, and a selectable system-bar output. The
remaining product step is simultaneous output-specific shell policy:

- touch UI on touch displays and desktop UI on pointer-driven displays;
- per-output chrome, safe areas, scale, transform, and hit layout;
- a window clipped consistently when it spans output viewports;
- hotplug or mode changes without restarting the Flutter engine;
- mouse and keyboard semantics preserved as native pointer/keyboard input;
- a single Flutter engine and scene atlas.

The first acceptance setup is an internal touch panel plus one external desktop
monitor, with a window movable between them while touch remains mapped to the
internal panel.

## General presentation fallback

The Rust compositor currently validates and uses direct shared-atlas scanout.
Layouts or driver constraints incompatible with that path are rejected. A
general correctness fallback should copy only damaged output regions into
per-output scanout buffers without changing Flutter's ownership of the scene.

Open validation includes blur/readback effects, mixed refresh rates, hotplug,
suspend/resume, long interaction runs, incompatible modifiers and explicit
synchronization on every target GPU. A busy output may still render a frame
that is later discarded; eliminating that wasted work requires explicit
output-slot admission, not a recovery timer.
