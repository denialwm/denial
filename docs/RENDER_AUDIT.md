# Window rendering diagnostics

Denial can expose four compositor-visible stages that are often collapsed into
a single GPU-utilization number:

1. A Wayland client commits surface state or new content.
2. Dart records or re-records a window decoration.
3. The embedder repairs part of the shared display atlas and samples client
   textures for that frame.
4. The output scheduler publishes the completed atlas generation to KMS.

Engine-internal raster-cache telemetry is not part of the current release
engine. Inspecting Flutter's rasterization and cache decisions therefore
requires external profiling or an explicitly instrumented development engine.

The audit is compiled into release builds but is opt-in. Start a development
session with:

```sh
DENIA_RENDER_AUDIT=1 tools/denial-pc session
```

To keep only the audit records in an interactive terminal:

```sh
DENIA_RENDER_AUDIT=1 tools/denial-pc session 2>&1 \
  | rg --line-buffered 'render_audit'
```

Without `DENIA_RENDER_AUDIT`, Denial creates no report timers, timing sample
vectors, Flutter timing callback, or damage-summary strings. Audit mode retains
every timing sample for one second and sorts those samples for percentiles. It
is intentionally capable of adding overhead and should not be used as the
production configuration being benchmarked.

## Report sources

`source=wayland_commit` is emitted approximately once per second for each
active surface:

- `commits` counts all commits.
- `visual_updates` counts commits that change visible sampling.
- `damage_commits` and `callback_commits` separate content damage from frame
  pacing.
- `buffer_attach_commits`, `buffer_remove_commits`, and
  `first_buffer_commits` describe buffer lifetime.
- `sampling_change_commits` counts changes that require a new imported sample.

`source=dart event=dart_window_work` is emitted once per second without
scheduling a Flutter frame. Counts are grouped by Wayland object ID:

- `builds` counts widget builds. A build does not imply a paint.
- `apps` maps each object ID to its sanitized Wayland app ID (or title when
  the client did not supply one).
- `textures` maps that same object ID to the external Flutter texture ID.
- `shadow_paints` counts recordings of the static shadow/frame DisplayList.
- `border_paints` counts recordings of the focus/pinned-state border.
- `sizes` records the logical size last supplied to either painter.

`source=dart event=dart_frame_timing` reports the engine's completed
`FrameTiming` samples:

- `build_*`, `raster_*`, and `raster_queue_*` separate UI-thread work,
  raster-thread work, and the delay from build completion to raster start.
- `engine_work_*` is build plus raster work. `total_span_*` instead covers the
  complete Flutter interval from vsync start through raster finish.
- `vsync_overhead_*` measures dispatch delay before Dart begins building.
- `vsync_gap_*` describes cadence between frames requested from Flutter. A long
  gap can also mean that the scene was idle, so correlate it with native page
  flips before treating it as a dropped displayed frame.
- Every timing family includes `avg`, `p50`, `p95`, `p99`, and `max` in
  microseconds. The three `*_over_budget` counters use the Flutter view's
  reported refresh-rate budget.

`source=embedder` is emitted approximately once per second:

- `frame_damage_*` describes pixels Flutter says changed in the current
  logical frame. This is the number to use when asking whether a foreground
  window invalidated the entire atlas.
- `buffer_damage_*` also includes historical damage needed to repair the
  particular recycled atlas buffer. It can be larger than frame damage and
  is not proof that Dart or Flutter repainted the whole scene.
- `sampled_textures_*` counts external client buffers retained for the
  submitted frame.
- `sampled_texture_counts` counts samples by Flutter texture ID; correlate it
  with the Dart `textures` map to identify the Wayland application.
- `last_frame_damage` and `last_buffer_damage` show the normalized rectangles
  as `left,top-right,bottom`.
- `context_make_current_*`, `backing_store_*`, `existing_damage_*`,
  `external_texture_*`, `present_callback_*`, and `raster_idle_callback_*`
  time the native embedder callbacks. In particular, an expensive SHM upload
  or first DMA-BUF import appears in `external_texture_*`.
- `raster_to_output_ready_*` measures from the raster transaction's context
  acquisition to a completed output handoff. `raster_transaction_*` ends when
  Flutter's raster-idle sentinel runs. These timing families report `avg`,
  `p95`, `p99`, and `max` in microseconds.
- `gpu_flutter_render_*`, `gpu_scanout_blit_*`, and `gpu_frame_*` use
  non-blocking `GL_EXT_disjoint_timer_query` timestamp markers to separate
  each output's Flutter/Skia rendering from Denial's final render-target to
  scanout copy. These are GPU-clock execution times, not CPU callback duration
  or exported-fence wait. `gpu_render_samples=0` means the driver lacks the
  extension (reported as `gpu_timestamps=false` when audit starts) or results
  have not arrived yet.
  `gpu_timer_disjoint` discards samples invalidated by a GPU clock reset;
  `gpu_timer_abandoned` counts render targets that never reached presentation.

`source=output_scheduler` is emitted approximately once per second:

- `ready_published` counts Flutter atlas generations made available to KMS.
- `ready_with_fence` and `fence_signals` describe native-fence readiness.
- `real_submissions` counts actual KMS framebuffer submissions.
- `volition_scheduled_submissions` counts frames handed to Volition for KMS
  scheduling.
- `stale_ready_drops` counts off-screen successors whose intended edge had
  already completed. Dropping one breaks a persistent one-refresh-late chain;
  screenshot-tagged generations are never discarded by this recovery path.
- `ready_to_submit_max_us` records the largest publication-to-submission delay
  in the interval.
- Each existing scheduler latency now also reports `p95` and `p99` tails.
  `target_to_presentation_*` is physical lateness relative to the intended
  vblank, while `presentation_interval_*` is the observed page-flip cadence.
- `deadline_to_ready_*`, `deadline_to_fence_*`, `deadline_to_submit_*`, and
  `deadline_to_presentation_*` expose the end-to-end path from the output
  timeline's render deadline. They include `avg`, `p50`, `p95`, `p99`, and
  `max`, making it possible to locate work that averages out in the older
  one-second counters.
- `missed_vblanks` remains the authoritative displayed-frame miss count when
  DRM supplies sequence numbers; Dart frame gaps describe engine demand, not
  guaranteed scanout.
- `per_output_timing` keeps mixed-refresh results separate. For each output it
  reports physical presentation-interval p50/p95/p99/max, deadline-to-display
  p99, target lateness p99, and the exact missed-vblank count.

## Autonomous external-texture damage

An external texture update schedules a frame with
`Engine::ScheduleFrame(false)`: Dart does not construct a new layer tree and
the rasterizer calls `DrawLastLayerTrees()`.

The earlier fork commit
[`ef8d243f38b`](https://github.com/denialwm/flutter/commit/ef8d243f38b)
made reused tasks compare the in-flight tree against itself. A later branch
temporarily coupled every reused tree to a full raster repaint even though its
reported frame damage stayed precise.

Flutter fork commit `c3ee9167475bb06d20abb689dc37f2c462909ba1`
removes that coupling. `TextureLayer::Diff` limits autonomous damage to the
texture IDs that requested the frame. Flutter keeps actual `frame_damage`
separate from the selected rotating FBO's historical repair region and unions
them only for `buffer_damage`. Unknown target contents, first frames and
unsupported partial paths still repaint fully.

Follow-up commit `fc290f44fbcf39f272f270fd93c5517aed6cccd0` plans the
physical repaint for the selected backend. Skia software and Impeller retain
an exact complex region (subject to Impeller's existing area economics).
Ganesh uses a conservative rectangular bound so it stays on the hardware
scissor path; if that rectangle covers the target, it omits the root clip and
repaints the target. This avoids turning a union of rectangles into a path that
Ganesh must analyze and apply to every draw. Reported `buffer_damage` is
widened to the pixels that the selected plan can actually modify, while
logical `frame_damage` remains exact.

The compositor preserves the same region topology while accumulating rotating
buffer history. Its normalizer coalesces rectangles only when their union is
itself exactly rectangular; merely touching pieces of an L-shaped region must
not become their bounding box. Storage is capped at 32 rectangles, after which
only the pair with the least added bounding-box area is compacted. This keeps
the callback bounded and conservative without turning a cross-output gap into
damage.

Thus a 200 fps client can update at 200 fps without turning every update into
a full-atlas repaint or leaving stale pixels when an older atlas buffer rotates
back into use.

## Expected 200 fps window result

After a short warm-up with one stable decorated window whose client updates at
200 fps:

- Dart may build window widgets, but `shadow_paints` should stay at zero in
  subsequent one-second intervals.
- Wayland `visual_updates` should follow genuine client changes rather than
  bookkeeping-only commits.
- `frame_damage_avg_pct` should roughly follow the changed window region, not
  approach 100% of the shared atlas unless the window really covers it.

If shadow paints increase with the client frame rate, the decoration itself is
being re-recorded. If shadow paints remain zero but frame damage is full-atlas,
the remaining fault is damage propagation rather than decoration recording.

## Cache candidate in the Dart scene

`DesktopWindowFrameLayers` separates each decorated window into three
siblings:

1. a static shadow/frame `CustomPaint` in its own `RepaintBoundary`, marked
   `isComplex: true` and `willChange: false`;
2. the live Wayland external texture;
3. the cheap stateful border.

This matters because Flutter refuses to raster-cache a layer subtree that
contains an external `TextureLayer`. Isolating the static picture gives it a
stable cache key without caching the live client pixels or forcing a
window-sized cache image for the inexpensive border. Flutter still owns
admission, allocation, and eviction. These diagnostics verify recording
stability and damage propagation, but do not report raster-cache admission,
hits, or eviction; inspect those with external profiling or an explicitly
instrumented development engine.
