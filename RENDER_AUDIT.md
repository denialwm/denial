# Window rendering audit

Denial can expose the three different kinds of work that are often collapsed
into a single GPU-utilization number:

1. Dart records or re-records a window decoration.
2. Flutter rasterizes a retained DisplayList or reuses its raster-cache image.
3. The embedder repairs part of the shared display atlas and samples client
   textures for that frame.

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
strings and the engine does not collect cache counters.

## The three report sources

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

`source=engine event=raster_cache` is emitted every 120 raster frames:

- `dl_forced_observations` counts DisplayLists marked `isComplex`; the static
  window frame is one of them.
- `dl_forced_unique_ids` reveals whether those DisplayLists retain identity.
  For a stable window it should remain close to the number of decorated
  windows, not grow with the frame count.
- `forced_picture_creations` counts new cached images. It may be non-zero in
  the warm-up interval, then should fall to zero while geometry is stable.
- `forced_draw_hits` and `forced_draw_misses` prove whether rasterization is
  actually reused. After warm-up, hits should dominate and misses should be
  zero or limited to genuine changes.
- `evictions`, `picture_images`, and `picture_bytes` reveal memory pressure or
  cache churn.

The engine's normal release timeline cache counters are compiled out, which is
why the small environment-gated engine delta in
`patches/flutter-engine/0007-add-release-render-cache-audit.patch` exists.
Patch 0009 routes those opt-in records to standard error because informational
FML logs are suppressed in the release engine used by Denial.

## Autonomous external-texture damage

An external texture update schedules a frame with
`Engine::ScheduleFrame(false)`: Dart does not construct a new layer tree and
the rasterizer calls `DrawLastLayerTrees()`. At the pinned upstream revision,
that path moved the cached task out of the view record before frame-damage
calculation looked up the previous tree. The lookup was consequently null and
Flutter treated every autonomous texture frame as a first frame, damaging the
entire view.

`0008-preserve-partial-damage-for-reused-layer-trees.patch` marks these reused
tasks and compares the in-flight tree against itself. This is intentional:
`TextureLayer::Diff` always marks the texture bounds dirty, while retained
static siblings preserve their paint regions. Thus a 200 fps client can update
at 200 fps without turning every update into a full-atlas repaint.

## Expected 200 fps window result

After a short warm-up with one stable decorated window whose client updates at
200 fps:

- Dart may build window widgets, but `shadow_paints` should stay at zero in
  subsequent one-second intervals.
- `frame_damage_avg_pct` should roughly follow the changed window region, not
  approach 100% of the shared atlas unless the window really covers it.
- `dl_forced_unique_ids` should be stable across reports.
- `forced_picture_creations` should stop, while `forced_draw_hits` should
  continue when the frame intersects the damaged region.

If shadow paints remain zero but forced cache misses continue, retention works
and raster caching does not. If shadow paints increase with the client frame
rate, the decoration itself is being re-recorded. If both are healthy but
frame damage is full-atlas, the remaining fault is damage propagation rather
than shadow caching.

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
admission, allocation, and eviction, and the audit above verifies the actual
outcome rather than assuming the hints worked.
