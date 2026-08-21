Yes. I think the right architecture for Denial is:

## One logical scene, per-output rasterization

```text
One Dart widget/element/render tree
              │
              ▼
One global Flutter LayerTree
              │
      ┌───────┴────────┐
      ▼                ▼
Output A projection  Output B projection
scale 2.0           scale 1.0
      │                │
native-size buffer   native-size buffer
      │                │
1:1 scanout          1:1 scanout
```

This is different from Flutter’s conventional multi-view model. The additional Flutter views are render targets only; they do not receive their own `View` widgets or `DesktopShell` trees.

Denial can retain:

- One `ProviderScope`
- One `DesktopShell`
- One set of animations and overlays
- One focus tree
- One input coordinate space
- One global desktop layout
- One window-close lifecycle

Only the immutable engine layer tree is rasterized multiple times.

### Where it fits

Currently [topology.rs](/home/logix/denial/compositor/src/topology.rs:349) chooses the maximum scale, and [flutter_runtime.rs](/home/logix/denial/compositor/src/bin/deniald/flutter_runtime.rs:5026) exposes one global view at that DPR. KMS then scales atlas regions.

Instead, the existing `AtlasPlan` can become a projection plan. For an output whose current atlas source is `(x, y, w, h)` and physical target is `(W, H)`:

```text
outputX = (sceneX - x) × W / w
outputY = (sceneY - y) × H / h
```

The engine wraps the shared scene root in that transform and a target-sized clip, then submits it as a `LayerTreeTask` for that output view.

Text is consequently replayed directly onto the output’s physical pixel grid. There is no intermediate high-scale bitmap being reduced by KMS.

## Why engine fan-out is preferable

Flutter’s native layer trees already use shared ownership internally. Producing an output task only needs a small output-specific transform parent around the shared scene root. It does not copy widgets, render objects, pictures, or the underlying window state.

I would keep view 0 as the virtual global desktop:

- Global atlas dimensions and maximum/reference DPR
- The only Dart `RenderView`
- The only input and semantics view
- Never directly scanned out

Every physical output becomes an additional render-only engine view with:

- Physical dimensions
- Actual DPR
- Stable output/view ID
- Its own backing buffers and damage history

The Denial engine’s frame bookkeeping would translate one `render(view0, scene)` call into tasks for every active output.

This also avoids difficult pointer behavior when dragging across outputs: all input can continue going to view 0 in global coordinates.

## Native rendering consequence

The current direct OpenGL callbacks are not view-aware: `FlutterFrameInfo` and `FlutterPresentInfo` contain no `view_id`. Flutter’s standard compositor interface does.

Therefore, the clean initial implementation would use:

- `FlutterCompositor.create_backing_store_callback`
- `FlutterCompositor.present_view_callback`
- A render backing store per output view
- A 1:1 copy into Denial’s independently owned scanout buffer

That extra copy is conceptually simple and prevents Flutter’s backing-store cache from colliding with KMS ownership. It could later become zero-copy through a Denial-specific view-aware buffer acquisition extension.

## Things that still require care

- External Wayland textures will be sampled once per visible output. Buffer leases must survive every raster pass, not be released after the first presentation.
- Damage and buffer history become per output rather than per atlas.
- Raster caching must distinguish the different output transforms/scales.
- The global `MediaQuery` can remain at maximum DPR for high-resolution asset decoding. Code doing explicit pixel snapping should instead use the owning `DisplayOutput.scale`.
- Backdrop filters crossing an output boundary can develop a seam. Rendering a small guard band around each output would solve that.
- Desktop-wide screenshots should become an occasional extra full-desktop render target, rather than requiring a continuously allocated maximum-scale atlas.
- The source-only view 0 means the engine’s normal “all registered views rendered” bookkeeping needs a Denial fan-out mode.

The performance shape is also attractive: Dart build/layout/paint still happens once, while GPU raster work becomes approximately the sum of the physical output pixel counts. That can be substantially smaller than rendering the entire desktop bounding box at its maximum scale.

This feels much more aligned with Denial than duplicating `DesktopShell`: Flutter continues to own one coherent desktop scene, while the engine gives that scene multiple physical manifestations. No files were changed.
