# Direct scanout and hardware plane composition

## Status

This is the implementation design. Direct scanout is not implemented yet.

## Decision

Denial will implement direct presentation as per-output hardware plane
composition, not as exclusive fullscreen mode switching.

On a promoted fullscreen output:

```text
primary plane: client DMA-BUF, changing at the game's rate
overlay plane: transparent Flutter shell, changing only on shell damage
cursor plane:  hardware cursor
```

Other outputs continue scanning their crops of the Flutter atlas at their own
rates. A 240 Hz game therefore does not make Flutter render at 240 Hz when the
only Flutter activity is a 60 Hz video on another output. Denial still brokers
the game's fences, mailbox, page flips, buffer releases, and presentation
feedback; it bypasses Flutter and GPU composition, not the compositor.

## Hard invariants

- Promotion never changes the connector, CRTC, mode, link, color, HDR, or VRR
  state. Direct commits and their `TEST_ONLY` probes must omit
  `ALLOW_MODESET`. A candidate requiring a modeset is rejected.
- Entry, client-buffer replacement, UI-plane replacement, and exit are atomic
  page flips. No blank or stale intermediate framebuffer may become visible.
- Every scanned or submitted client buffer retains its
  `RendererBufferGuard` until the page flip replacing it completes.
- Direct presentation is independent per output. Failure or UI activity on
  one output must not disturb another.
- Composition is always the correctness fallback. Unsupported planes,
  formats, effects, capture requirements, or synchronization return the
  output to the atlas without changing its mode.

## Existing foundation and required changes

- `output_scheduler.rs` already has independent per-CRTC mailboxes and submits
  only primary-plane `FB_ID`, `SRC_*`, and optional `IN_FENCE_FD` properties
  without `ALLOW_MODESET`. Generalize its atlas-only `OutputFrame` into a
  retained plane/frame lease that can own either an atlas slot or an imported
  client framebuffer.
- `kms_state.rs` allocates a shared `Xrgb8888` atlas and selects modifiers
  common to every primary plane. Transparent shell composition needs either:
  an ARGB atlas with opaque and alpha KMS framebuffer views of each buffer, or
  a separate transparent overlay swapchain. Prefer a separate per-output
  overlay pool if intersecting primary, overlay, and renderer modifiers would
  force poor formats or layouts.
- Denial currently clears inherited non-primary planes and then owns only the
  primary selected by `DrmSurface`. Add plane discovery and allocation for
  compatible overlay and cursor planes, including possible CRTCs, formats,
  modifiers, `zpos`, pixel-blend mode, alpha, crop, and scaling limits. Validate
  every new plane arrangement with `TEST_ONLY`.
- `frame_scheduler::render_source` currently chooses the fastest powered
  output. It must instead choose the fastest output with Flutter work. Direct
  outputs keep their physical/client clocks but do not authorize Flutter
  frames when their shell plane has no damage.
- `wayland_frontend::window_expects_sample` currently treats every visible
  window as a Flutter texture consumer. Promoted surfaces must route new
  DMA-BUF revisions to the KMS mailbox and stop dirtying or blocking Flutter.
  The existing sampled-buffer guard/fence machinery remains the model for
  safe buffer retirement.
- Linux DMA-BUF feedback currently describes renderer formats. Add a scanout
  tranche so clients naturally allocate formats and modifiers accepted by the
  display planes.
- Screencopy currently captures the atlas. While planes are active, capture
  must compose the client and shell buffers into the capture target, use DRM
  writeback when available, or temporarily use a prepared composed frame.

## Output plane scene

The scheduler should submit one atomic scene per CRTC:

```rust
struct OutputPlaneScene {
    primary: PlaneLease,              // atlas or client framebuffer
    shell_overlay: Option<PlaneLease>,
    cursor: Option<PlaneLease>,
}
```

There is still only one pending atomic timeline per CRTC. Game-only commits
replace the primary lease while retaining the current shell lease. A new
Flutter overlay is combined with the newest game buffer in the next commit.
Under VRR, UI frames should piggyback on game commits; if the game stalls, a
UI deadline may initiate a commit itself.

Disable the shell plane when it contains no visible pixels. When UI occupies
only a small area, crop the plane to its visible bounding rectangle; an
unchanged fullscreen transparent plane would consume display bandwidth even
though Flutter did no work. Pointer movement must use the cursor plane rather
than damage a fullscreen shell buffer.

## Promotion authority and eligibility

Flutter owns the final visual scene, so fullscreen protocol state alone is
not proof that its pixels are unnecessary. Flutter must publish an
epoch-bound output composition certificate containing the output, sole client
surface, source and destination rectangles, opacity, and absence of shell
effects requiring the client texture. Native code revalidates the certificate
against the current surface buffer and KMS capabilities.

`SUPER+F` shell fullscreen and client-requested true fullscreen are both
candidates after their transition has settled. The initial implementation
requires:

- one opaque DMA-BUF surface covering the output;
- no unresolved popup or subsurface requiring another client plane;
- representable crop, transform, and scaling;
- an importable scanout format/modifier;
- no effect that samples the game, such as backdrop blur, distortion,
  overview thumbnails, or masks.

Ordinary alpha-blended notifications and indicators can remain hardware
overlays. Effects which must read game pixels require a composed frame or a
captured snapshot.

## Seamless state transitions

```text
Composed -> Armed -> Promoted -> Fallback armed -> Composed
```

For entry, retain the atlas on screen while importing the client DMA-BUF and
running `TEST_ONLY`. Prefer first presenting an atlas frame made from the same
client revision, then promote that revision on the following vblank.

While promoted, client commits form a latest-ready mailbox. Flutter does not
sample them unless it is preparing fallback composition.

For exit or an incompatible overlay, keep scanning the last client buffer
while Flutter renders it with the new shell state into an atlas target. After
the render fence signals, atomically replace the client primary and shell
overlay with the prepared atlas. If the client unmaps, retain its last buffer
as the departure texture until this handoff completes.

## Hardware and semantic limits

- Plane count, fixed `zpos`, alpha support, scaling resources, and bandwidth
  vary by driver and output. Cache successful arrangements but keep
  `TEST_ONLY` as the authority.
- HDR games mixed with an SDR Flutter plane require compatible per-plane color
  handling; otherwise fall back to composition while preserving the current
  output mode.
- General non-fullscreen promotion is possible for topmost opaque windows:
  keep the atlas below, place client contents on an overlay, and let Flutter
  draw decorations. Overlap, rounded corners, moving/resizing synchronization,
  and limited planes make this a later plane-allocation feature, not the first
  fullscreen milestone.
- If a visually eligible buffer cannot scan out because of its modifier,
  device, or scaling, an optional GPU blit into a native scanout pool is a
  smooth fallback. It is not zero-copy but still avoids full Flutter scene
  composition.

## Implementation order

1. Add observe-only eligibility and reason reporting; do not program planes.
2. Add client framebuffer leases and seamless primary-plane promotion for an
   exact-size opaque fullscreen surface with hidden cursor and no shell UI.
3. Add the transparent Flutter overlay target, plane allocator, hardware
   cursor, and damage-driven Flutter clock selection.
4. Add prepared fallback frames, capture support, scanout DMA-BUF feedback,
   scaling, and VRR scheduling.
5. Extend the allocator to safe non-fullscreen window promotion.
