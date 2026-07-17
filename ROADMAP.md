# Denial roadmap

Only unfinished project-level work belongs here. Completed investigations and
migration plans are represented by the current code, tests, and architecture
instead of retained as historical task documents.

## One product install

The native build is now one graph: the retained Flutter embedder sources are an
internal object target linked directly into `deniald`, with no project-owned
embedder library. The remaining runtime artifacts are the upstream
`libflutter_engine.so`, the Dart AOT bundle and assets, and `deniald`.

The target is one versioned install unit, not a single self-extracting ELF. The
shell bundle should become a declared build dependency, while Flutter support
and bundle paths should no longer be optional runtime flags.

Completion requires:

- a clean build producing the complete install tree from pinned inputs;
- no valid `deniald` configuration without the Flutter shell;
- atomic install and rollback of executable, engine, AOT, ICU, and assets;
- unchanged rendering, input, reload, and platform-channel behavior.

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

## Presentation simplification

The correctness fallback copies damaged scene regions into output swapchain
buffers. Direct atlas scanout is used only where buffer layout and KMS
constraints permit it. Future simplification must be driven by measurements,
not by removing Aquamarine or weakening the fallback.

Open validation includes blur/readback effects, mixed refresh rates, hotplug,
suspend/resume, long interaction runs, and explicit synchronization on every
target GPU. A busy output may still render a frame that is later discarded;
eliminating that wasted work requires explicit output-slot admission, not a
recovery timer.
