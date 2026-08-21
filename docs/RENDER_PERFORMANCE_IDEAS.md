# Render performance ideas

This note records three related optimization opportunities found while
profiling Denial at 240 Hz. They are proposals, not accepted implementation
plans. Damage correctness and retained framebuffer contents must remain
unchanged unless a dedicated test proves otherwise.

## Profile summary

The profile compared an idle 240 Hz Denial session with rapid movement of an
opaque Wayland window. It sampled the optimized release engine at Flutter
commit `d7e37c4844556c40eb88c0066ca653f76715d1f8`.

Normalized userspace cycles increased by approximately 2.2 times during the
move. Flutter's UI and raster threads accounted for about 79% of that increase:

| Work | Share while moving | Share of additional cycles |
| --- | ---: | ---: |
| Flutter UI thread | 31.8% | 42.8% |
| Flutter raster thread | 44.7% | 35.9% |
| Rust `deniald` main thread | 11.3% | 9.7% |
| GL and driver threads | 11.1% | 10.6% |

Notable movement-sensitive functions included:

- `flutter::ContainerLayer::DiffChildren`, about 3.8 times its idle rate;
- `impeller::RenderPassGLES::OnEncodeCommands`, about 3.6 times;
- damage-region construction and tree balancing, about 6 times;
- Dart young-generation allocation, about 3.3 times.

`deniald::flutter_scene_sync::collect_flutter_output_damage` represented only
about 0.12% of cycles while moving. The primary opportunity is therefore the
Flutter UI/raster path rather than Rust scene-damage collection.

## 1. A retained live-position path for windows and the cursor

### Current behavior

Native window placement updates are coalesced to one update per Flutter frame,
but each visible update still copies the workspace placement map, publishes a
new workspace state, evaluates Riverpod selectors, and rebuilds the widgets
that produce the moving transform.

The software cursor is more direct: every new position calls `setState` on
`ShellCursorHost`. This rebuilds the root cursor overlay and produces another
Flutter frame even when the cursor artwork, shape, visibility, and output
scale are unchanged.

At 240 Hz these otherwise small allocations and state transitions are repeated
up to 240 times per second. A high-rate input device can deliver even more
samples before Flutter coalesces the resulting frame request.

### Proposed design

Separate semantic, committed state from high-rate visual position:

- Keep authoritative window placement in `DesktopWorkspaceState`. It remains
  responsible for persistence, monitor/workspace membership, stacking,
  fullscreen/maximize state, and the final geometry.
- Add a small per-window live-position controller containing only the newest
  drag rectangle or translation.
- During a native grab, overwrite the controller's pending value and publish
  at most once per display frame. Commit the final rectangle to workspace
  state when the grab ends.
- Let a retained render object listen to that controller and update only its
  compositing transform. The window content remains the same child and does
  not participate in widget build or layout for every coordinate.
- Make the main surface and its popup layers consume the same controller so
  they remain aligned.

Use the same principle for the software cursor:

- Cursor shape, artwork, visibility, animation frame, and scale remain normal
  Flutter state.
- Cursor motion updates a latest-position controller rather than calling
  `setState` on `ShellCursorHost`.
- A retained render object applies the cursor translation. Crossing an output
  with a different scale is a semantic change and may still rebuild the cursor
  artwork.

This reduces Dart allocation, provider notification, widget traversal, and
layout work. It does not remove the raster frame: a software-composited window
or cursor still changes the Flutter layer tree and framebuffer damage.

### Correctness requirements

- Preserve pointer hit testing and the exact grab position.
- Commit the final window geometry even if a grab is cancelled or interrupted.
- Keep popup surfaces synchronized with their parent window.
- Preserve cursor hotspot, output scaling, visibility, animated artwork, drag
  icons, and transitions between Flutter-routed and client-routed input.
- Do not reduce input sampling precision; only replace intermediate visual
  values that cannot be displayed before the next frame.

## 2. Replace allocation-heavy paint-region tree maps

Flutter currently defines per-layer damage metadata as:

```cpp
using PaintRegionMap = std::map<uint64_t, PaintRegion>;
```

Every diffed layer inserts a paint region keyed by its unique layer ID. A
`std::map` allocates a node for each entry, performs pointer-heavy tree lookup
and balancing, and destroys the nodes individually when the old `LayerTree`
is released. Tree balancing and map destruction were visible in the movement
profile.

No current consumer appears to depend on key ordering. A narrow first version
can therefore use a hash map, reserve approximately the previous frame's entry
count, and avoid default construction during assignment:

```cpp
using PaintRegionMap = std::unordered_map<uint64_t, PaintRegion>;

current_regions.reserve(previous_regions.size());
current_regions.insert_or_assign(layer->unique_id(), region);
```

A suitable existing flat hash container may be evaluated separately, but the
minimal standard-library change is easier to validate and back out.

This optimization must not change which regions are recorded or how damage is
computed. It only changes metadata storage. It is expected to produce a
low-single-digit overall improvement, although it should help any workload
that repeatedly constructs layer-tree damage metadata.

If idea 3 eliminates metadata reconstruction for large retained subtrees, it
will also eliminate many map operations. The map change remains useful for
branches that genuinely require diffing.

## 3. Reuse complete diff metadata for clean retained texture subtrees

### Existing dirty-texture knowledge

Denial already tells the engine which external textures changed. The rasterizer
drains `pending_texture_ids_` into every framework frame. An engaged empty set
means that no external texture changed; a missing set retains conservative
upstream behavior.

`TextureLayer::Diff` consults this set. When a texture ID is clean, it reuses
the old paint region and does not add the texture bounds to damage. Therefore,
cursor movement does not currently mark every Wayland window's pixels dirty.

### Remaining unnecessary work

Flutter still cannot skip a retained subtree that contains a `TextureLayer`.
Every new `LayerTree` owns new per-frame diff metadata, including:

- layer ID to paint-region entries;
- texture ID to screen-region entries;
- readback regions;
- backdrop-filter dependency metadata.

The parent `PaintRegion` records only that its subtree contains a texture. It
does not contain enough information to reproduce all descendant metadata.
Flutter consequently walks down to each clean `TextureLayer`, republishes its
paint region, and rebuilds the maps and lists. Cursor motion and unrelated
shell animation pay this cost even when every window subtree is retained and
every external texture is clean.

### Proposed design

Represent the complete diff metadata for a retained subtree as a reusable
block or reference. The block needs the descendant paint-region associations,
texture paint regions, readback regions, and backdrop dependencies required by
future frames.

During diffing:

1. Confirm that the layer and its ancestor transform/clip state are retained.
2. Determine whether the dirty-texture set intersects the texture IDs recorded
   for that subtree.
3. If there is no intersection and no other invalidating state, attach or copy
   the previous metadata block and skip every descendant.
4. If a texture is dirty, descend only into branches that contain a relevant
   texture ID while retaining unrelated branches.

This is not damage elision. A dirty texture must still add its current region
to damage, a changed transform must still damage the old and new regions, and
readback/backdrop dependencies must still expand damage exactly as before.
The optimization only avoids reconstructing metadata already known to be
identical.

This should benefit more than cursor movement:

- unrelated shell animations can retain all clean application windows;
- changing one Wayland texture can skip other window subtrees;
- moving one window can skip stationary windows;
- HUD, notification, clock, and overlay frames can avoid repeatedly walking
  the complete textured desktop.

### Correctness requirements

Tests must cover at least:

- an empty dirty-texture set;
- one dirty texture among several retained textures;
- the same texture ID painted in multiple locations;
- insertion and removal of textured layers;
- transform, clip, opacity, and output-projection changes;
- readback and backdrop-filter dependencies;
- autonomous reused-layer-tree frames and ordinary Dart-generated frames;
- multiple Denial render outputs;
- exact equality of frame and buffer damage before and after the optimization.

## Suggested order and measurement

1. Add repeatable idle, cursor-motion, and opaque-window-move measurements.
2. Implement idea 2 first as the smallest semantics-preserving engine change.
3. Implement idea 1 and measure UI-thread and allocation reductions.
4. Implement idea 3 behind focused unit tests, then measure raster-thread
   traversal and damage-metadata reductions.

For experimental engine builds, use only the isolated fast path:

```sh
tools/denial-pc engine-test-build
tools/denial-pc engine-test-check
tools/denial-pc engine-test-arm
```

Do not overwrite the normal bundle or run the full release metadata refresh
until the isolated engine has passed damage, cursor, window-movement, and
high-refresh-rate testing.
