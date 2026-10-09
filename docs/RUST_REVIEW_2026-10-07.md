# Rust review — 2026-10-07

Multi-agent review of the Rust side (`compositor/`, ~122k lines). 149 findings
from 15 reviewers; 109 adversarial verifications completed before the run was
stopped. Items marked *(unverified)* were not independently checked.

Context: DP-4 2560x1440 @ 240 Hz, DP-5 2560x1440 @ 165 Hz rotated 90° + VRR,
amdgpu. deniald ~1.05 GiB VRAM. Live sample with Dart nearly idle (UI thread
~56 wakes/s): raster ~880 wakes/s, volition-kms ~700/s, main thread ~2250/s.

Overall code quality: ~7/10. Strong local engineering (comments, SAFETY notes,
Volition, explicit buffer-ownership state machine); weak at the architecture
level (god loop/objects, string errors, untested presentation path).

## CPU: frames that should not exist

Partial repaint already works and the engine skips the GPU pass on empty
buffer damage. The cost is the fixed per-frame overhead (diff/preroll, fence,
glFlush, atomic commit, flip) paid by frames that change nothing.

1. **Hidden-texture re-dirty loop (confirmed by hand).** A texture with an
   unsampled `current` and a `queued` buffer cannot advance
   (`flutter_runtime/renderer/texture.rs:602`), is reported as deferred
   (`flutter_runtime/renderer/handler.rs:649`) and re-staged as changed
   (`flutter_runtime/output_runtime.rs:431`), so its output renders every tick
   forever. Hidden windows keep `expects_sample = true` since bff2a93
   (taskbar previews). Fix: don't re-stage textures blocked only on sampling;
   re-stage when `mark_external_texture_sampled` unblocks them.
2. **Frame callbacks ignore visibility.** `frame_tick`
   (`wayland_frontend/scene_input.rs:305`) uses geometric membership only;
   other-workspace and minimized windows get 240 Hz callbacks. Gate them on
   `window_is_on_active_workspace` / `window_is_minimized`.
3. **Unchanged outputs are rendered and flipped.** Every Dart frame calls
   `mark_all_dirty()` (`frame_scheduler.rs:329`); nothing short-circuits empty
   damage, and the output scheduler drops the damage (`damage: _`). Up to 165
   empty passes/s on DP-5 (or 240 on DP-4) and VRR pinned at max. Rust step:
   in `present()` skip fence/publish/flip when frame and buffer damage are
   empty, still `complete_render`; never skip wake/lock, screenshot, or first
   post-modeset frames. Engine step: diff before `AcquireFrame` and report the
   skip through the render-completion callback.
4. **Software cursor.** Each pointer move = Dart frame (240/s) + DP-4 raster +
   DP-5 empty pass (via 3). Estimated 5–20% of a core while the mouse moves.
   Hardware cursor plane needs: multi-plane Volition commits (`PlaneCommit`
   has one object), cursor updates folded into each output's vblank commit
   (EBUSY), pre-rotated image for DP-5 (rotation is in the Flutter projection,
   plane rotation is `ROTATE_0`), screencopy cursor handling, software fallback.
5. **Single Dart clock = fastest output** *(unverified)*. DP-5 animations are
   built at 240/s and sampled on DP-4's phase (judder). Use per-output clocks
   or clock from the damaged output.
6. **Idle timelines tick at 240 + 165 Hz** plus fixed 30 Hz / 10 Hz service
   polls. Park timelines with no callbacks and no damage.
7. **Client damage discarded** (`wayland_frontend/surface_pipeline.rs`, damage
   cleared without reading). Whole windows repaint for small updates. Use
   Smithay's `damage_since` per published generation.
8. **SHM path:** full memset + copy + swizzle on the main thread, then a new
   full-size texture per commit. Use one persistent texture per surface and
   damaged-region `glTexSubImage2D`.
9. **Experiment:** `mesa_glthread=false` (a `gl0` thread exists; Impeller's
   synchronous GL calls may make glthread pure overhead). Unmeasured.
10. Smaller: ~5 main-loop wakes per output frame; per-sample pointer
    forwarding to Flutter; per-sample full arrange during tile resize and
    X11 move/resize; Mesa driver threads at nice 0 under the RR raster thread
    *(unverified)*; VRR DP-5 paced on the fixed 165 Hz grid *(unverified)*.

## VRAM

Rust-owned floor ≈ 115 MiB (3 XR24 scanouts + 1 depth/stencil per output);
rendering directly into scanouts avoids a ~127 MiB MSAA root per output.
Growth comes from caches:

- **dmabuf cache pins destroyed client buffers** (8 per surface,
  `flutter_runtime.rs:136`); `buffer_destroyed` never evicts. Evict there or
  key by `WeakDmabuf`.
- **SHM cache keeps up to 32 dead full-size textures**
  (`flutter_runtime.rs:137`). On insert, drop older revisions of the same
  texture id.
- Screencopy pools retained after capture, up to 56 MiB/output *(unverified)*.
- Share one depth/stencil across outputs (~17 MiB) *(unverified)*; free pools
  of DPMS-off outputs (~58 MiB each) *(unverified)*.
- Engine: saveLayers ~36 B/px; `--resource-cache-max-bytes-threshold` is a
  no-op under Impeller (no engine VRAM cap).

## Stability

1. **X11 title/WM_CLASS > 4096 bytes aborts the session**
   (`wayland_frontend/managed_window.rs:306` copies unbounded, wire validation
   fails). Clamp on a char boundary at the source.
2. **Rolled-back hotplug still ends the session** (`return Err` at
   `flutter_event_loop.rs:1645`). Mirror the output-control rollback path.
3. **Security: Flutter runtime restarted while locked starts unlocked.**
   `DENIAL_START_LOCKED` is set once (`deniald.rs:407`). Pass the live lock
   state per engine as an entrypoint argument.
4. **fd soft limit 1024; EMFILE ends the session.** Raise to the hard limit at
   startup, restore in child `pre_exec`.
5. **Uncommitted render-completion work:** completion-tagged authorizations
   never expire (`flutter_runtime/output_pipeline.rs:250`), so one lost
   completion freezes an output and stalls reconfiguration; a no-scene
   completion sends `FrameReady` and can mark a plugin bundle healthy
   (`flutter_runtime/renderer/handler.rs:580`). Add a watchdog and a separate
   "real frame published" signal before committing.
6. Xwayland is never respawned (`wayland_frontend/xwayland.rs:1329`).
7. Flutter runtime errors abort the session although in-place runtime
   replacement exists.
8. GPU reset ends the session (known issue). Robust contexts only together
   with detection + recovery, otherwise Mesa freezes instead of exiting.
9. Blocking on the compositor thread: XIM discovery (X11 connect, no timeout)
   per app launch (`x11_input_method.rs:30`); settings and placement-store
   fsyncs; legacy blocking gamma SETPROPERTY; sequential blocking modesets.
10. Clipboard history captures password-manager copies (ignores
    `x-kde-passwordManagerHint`, `clipboard.rs:401`).
11. Smaller: PulseAudio restart not detected until the next command; DDC/CI
    redetect per request; D-Bus reconnect churn every 2 s for missing optional
    services; VT return / KMS recovery restarts the engine even when topology
    is unchanged; any EINVAL or long EBUSY triggers a full all-output KMS
    reset *(unverified)*.

## Code quality

- `run_flutter_event_loop` ~600 lines, ~30 phases; `RuntimeState` ~70 fields,
  `WaylandFrontend` ~147 fields; ~330 `expect("missing Wayland frontend")`.
- String errors (`Box<dyn Error>`) give the frame path only "handle locally"
  or "abort the session"; introduce a recoverable/fatal error class.
- 1,346 `cfg(feature = "flutter")` gates for a non-Flutter build CI only
  `cargo check`s.
- No tests for Volition, output frame state, ready-fence slots,
  `kms_pipeline`, renderer handler, or the hand-written engine-extension ABI.
- CI runs neither clippy nor rustfmt; `deny(clippy::undocumented_unsafe_blocks)`
  is not enforced.
- PAM and libpulse run in-process via hand-declared FFI.

## Suggested order

1. Hidden-texture loop, X11 title clamp, hotplug rollback, completion watchdog.
2. Empty-damage skip (Rust step), cache evictions (dmabuf, SHM).
3. Visibility-gated frame callbacks, idle timeline parking, client damage.
4. Hardware cursor plane; per-output Dart clock; direct scanout.

Refuted: toplevel screencopy waiting on the GPU on the main thread.
