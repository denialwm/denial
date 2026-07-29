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

Without `DENIA_RENDER_AUDIT`, Denial creates no report timers or damage-summary
strings.

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

`source=output_scheduler` is emitted approximately once per second:

- `ready_published` counts Flutter atlas generations made available to KMS.
- `ready_with_fence` and `fence_signals` describe native-fence readiness.
- `real_submissions` counts actual KMS framebuffer submissions.
- `ready_superseded` counts completed generations replaced before submission.
- `ready_to_submit_max_us` records the largest publication-to-submission delay
  in the interval.

## Autonomous external-texture damage

An external texture update schedules a frame with
`Engine::ScheduleFrame(false)`: Dart does not construct a new layer tree and
the rasterizer calls `DrawLastLayerTrees()`. At the pinned upstream revision,
that path moved the cached task out of the view record before frame-damage
calculation looked up the previous tree. The lookup was consequently null and
Flutter treated every autonomous texture frame as a first frame, damaging the
entire view.

The locked Flutter fork commit
[`ef8d243f38b`](https://github.com/denialwm/flutter/commit/ef8d243f38b)
marks these reused tasks and compares the in-flight tree against itself. This is intentional:
`TextureLayer::Diff` always marks the texture bounds dirty, while retained
static siblings preserve their paint regions. Thus a 200 fps client can update
at 200 fps without turning every update into a full-atlas repaint.

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
