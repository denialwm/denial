# Denial architecture

Denial is a Flutter-native Wayland compositor. Hyprland supplies the mature
Wayland, input, window-management, and DRM foundation; Flutter owns the shell
scene that combines client surfaces with native UI.

This document describes the current system. Historical experiments and
completed implementation plans are intentionally not retained here.

## Runtime shape

```text
deniald
  Hyprland core
    Wayland protocols, clients, focus, layout, grabs, input
    Aquamarine session, output swapchains, KMS commits

  Denial native runtime
    surface registry and buffer lifetime
    Flutter engine host and external textures
    frame scheduling and per-output presentation
    native audio, brightness, notifications, haptics

  Flutter engine
    Dart shell
    one logical desktop scene
    imported Wayland surfaces as external textures
```

The Flutter engine and Dart isolate run inside `deniald`; the shell is not a
Wayland client or a second compositor. Denial compiles its retained Flutter
embedder sources directly into `deniald`; only the upstream Flutter engine and
the AOT shell bundle remain external runtime artifacts. Packaging those
artifacts as one versioned install unit is tracked in [ROADMAP.md](ROADMAP.md).

## Ownership

Native C++ owns everything whose correctness depends on protocol or resource
lifetime:

- Wayland resources, windows, surfaces, popups, and subsurfaces;
- dma-buf attributes, EGL images, fences, release, and presentation feedback;
- physical input, grabs, pointer constraints, focus, and client dispatch;
- output modes, swapchains, page flips, and KMS commits;
- privileged or latency-sensitive services.

Dart owns visual and interaction policy:

- mobile and desktop shell layouts;
- launcher, overview, taskbar, shade, lock screen, and notifications;
- animation, gesture interpretation, and shell hit regions;
- high-level requests such as focus, close, configure, launch, and controls.

Dart receives stable numeric identities and immutable metadata. It never owns a
Wayland resource, dma-buf file descriptor, EGL image, fence, or KMS buffer.

## Client surfaces

On a client commit, the native surface registry records the newest admissible
buffer generation and preserves its lifetime. The runtime imports that buffer
as an EGL image and exposes a stable Flutter external-texture ID. Window
snapshots describe the complete visible surface tree, including popup and
subsurface geometry, ordering, transforms, scale, and texture source rectangles.

Flutter samples a latched generation while rasterizing. Native code releases
or retires a generation only after the scene transaction that sampled it has
completed the required GPU and presentation ownership transitions. Intermediate
commits may be coalesced, but generations and client-facing feedback remain
monotonic.

Each surface has bounded pending state and at most one armed Flutter texture
notification. EGLImage bindings are keyed by stable buffer identity, retired on
the raster thread, and capped so producer rate cannot create unbounded work or
memory. A sampled buffer stays alive through GPU consumption; an unsampled
superseded buffer can be released immediately.

## Scene and outputs

Flutter renders one logical scene covering the union of enabled outputs.
Each output keeps independent KMS ownership, damage, fences, and page-flip
state.

When layout, formats, modifiers, and scanout constraints allow it, Denial uses
a shared atlas and gives each KMS plane the source rectangle for its output.
The small Aquamarine patch in `patches/aquamarine/` implements that source
selection. Otherwise Denial copies only damaged scene regions into normal
per-output swapchain buffers. The fallback is part of correctness, not a
temporary debug path.

An output completion submits an already prepared frame, or repeats the current
scanout if no frame is ready, before granting work for a later frame. Rendering
never starts for the buffer being submitted by the same callback.

Each output buffer moves through `FREE`, `PREPARING`, `READY`, `SUBMITTED`, and
`SCANNING`; repeating the current scanout is the only transition that skips
rendering. Flutter vsync batons remain queued until a physical output pulse can
return them. Scene damage is intersected with each output viewport and damage
history is invalidated on size, mode, scale, or transform changes.

Monitor resolution, scale, position, and the native window layout remain normal
compositor configuration. Pointer and touch coordinates are translated into the
global Flutter scene. One output owns the system bar, selected with
`--system-bar-monitor`/`--system-bar-side` or the startup variables
`DENIAL_SYSTEM_BAR_MONITOR`/`DENIAL_SYSTEM_BAR_SIDE`. Output topology changes
restart only the embedded Flutter engine after outstanding GPU work drains;
Wayland clients and the native compositor stay alive.

## Input

Physical events enter through Hyprland. Dart publishes one immutable input
layout containing shell regions, client regions, ordering, visibility, and
keyboard/exclusive-shell flags. Native swaps that snapshot atomically.

- shell hits become Flutter pointer events;
- client hits are transformed and delivered through the Wayland seat;
- grabs, session lock, drag-and-drop, and pointer constraints take precedence;
- window move and resize remain native compositor operations;
- keyboard text from the built-in OSK returns through the native bridge.

Geometry reported to Dart uses the global logical scene. A window crossing an
output boundary remains one native window and one surface tree.

## Platform bridge

Structured compositor traffic uses the checked-in FlatBuffers schema in
`protocol/denial.fbs`. Small high-frequency or service commands use bounded
little-endian packets. Native verifies and owns any message that outlives the
engine callback. No custom Denial channel uses JSON.

The current channel and packet inventory is
[protocol/CHANNEL_INVENTORY.md](protocol/CHANNEL_INVENTORY.md), and the ordered
window wire format is [protocol/WIRE_FORMAT.md](protocol/WIRE_FORMAT.md).

Audio and brightness use persistent native controllers. Haptics uses a
persistent datagram socket. Notifications are owned by the native D-Bus server.
Application launches and one-shot shell actions cross the native command
bridge; embedded Dart never starts a process.

## Startup configuration

Dart snapshots `Platform.environment` once, at the start of `main()`, and
provides the immutable snapshot through Riverpod. Widgets, render paths,
providers, and services do not read the process environment later.

Native command-line and environment configuration is resolved while
`deniald` starts, before the compositor event loop. GPU-selection variables
used to bootstrap the compositor are removed before applications can be
launched. Native environment access goes through one owned snapshot captured at
process entry; later reads never rescan the mutable process environment.

## Source and build boundaries

Project-owned integration code lives in `Hyprland/`, `dart_shell/`, and
`protocol/`. The retained Flutter embedder is an internal object target under
`Hyprland/deniald/flutter/`, so it has no independent project, build directory,
or shared library. Large upstream toolchains and Aquamarine source do not live
in the repository. `tools/denial-pc bootstrap` checks out their exact revisions
in the user cache and applies only the patches kept under `patches/`.

The PC workflow is documented in [BUILDING.md](BUILDING.md). Hyprland's import
history and update policy are in [HYPRLAND_HISTORY.md](HYPRLAND_HISTORY.md).

## Invariants

1. Flutter is part of the compositor, not an overlay client.
2. One Dart scene owns shell composition across all managed outputs.
3. Native code owns unsafe handles and exact buffer lifetime.
4. A client generation is reported presented only after its containing scene.
5. Output submission never waits for work started by that same output callback.
6. Input routing consumes one immutable layout snapshot.
7. Hot controls never spawn a CLI from embedded Dart.
8. Runtime paths never depend on another source checkout.
