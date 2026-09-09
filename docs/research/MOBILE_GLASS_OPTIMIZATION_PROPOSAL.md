# Mobile shade glass: proposed optimization work

Status: proposals only, 2026-09-09. The user requested a review before any
glass optimization is implemented. The separate notification presentation fix
does not change the material settings or engine.

## What the current code already does

- `quick_settings_panel.dart` groups the panel and notification backdrops.
  `ShellBackdropBlur` paints foreground content separately for these surfaces.
- `ShadeBackdropScene` already shares one screen-coordinate filter for ordinary
  blur. Glass retains each surface's rounded geometry and optical effect.
- `NotificationShadeList` moves retained rows at paint time, culls offscreen
  rows, and removes covered areas using rounded silhouettes. It already skips
  rows whose resulting visible path is empty.
- The sliders deliberately have independent filters: they sample the painted
  glass panel. This preserves the user's requested glass-over-glass effect.
- The installed Flutter fork has backdrop snapshot caching, damage tracking,
  render-target reuse, and a direct-compositing path where its checks allow it.
  Adding a BackdropGroup or RepaintBoundary is therefore not a new solution.

The inspected fork's `flow/layers/backdrop_filter_layer.cc` invalidates a
cached result when its input/target bounds, transform, filter, or underlying
damage change. Sliding the panel and cards, fading the home icons, and changing
the dimming overlay all matter. Caching the finished moving card cannot simply
ignore those changes without displaying stale background content.

In `impeller/display_list/canvas.cc`, grouped filters reuse an input texture;
reuse of one finished filtered snapshot additionally requires
`all_filters_equal`. Glass shapes include individual bounds, so a panel and
unequal-height cards cannot generally share a finished glass result. In
`impeller/display_list/image_filter.cc`, each glass filter constructs its own
Gaussian frost input and then a shape-specific glass material.

These are code findings, not measured GPU bottlenecks. No percentage speedup is
claimed.

## 1. Share the frost input, retain individual glass shapes

Recommended main investigation. Resolve the background and its Gaussian frost
once for the panel/card group for a given frame, then let each surface apply
its own refraction, lighting, tint, and rounded edges to those inputs. Reuse
the frost across frames only while its actual source pixels and filter
parameters remain valid. Use the same source scene as today, including the
current home fade and dimming; do not freeze the background or reorder effects.

Bound the shared source to the visible group plus the blur/refraction sampling
margin. A screen-sized buffer is not automatically cheaper than several small
ones. The useful coverage and memory cost need measurement on the phone.

This is an engine/filter-input change, not just a shell-bundle edit. Keep the
slider filters separate because their source includes the panel itself.
Expected benefit: less repeated Gaussian work and fewer intermediate textures
when multiple glass surfaces are visible, without intentionally lowering
quality. Actual improvement remains to be measured.

## 2. Tighten work during notification overlap

Recommended shell-first investigation. The current implementation already
suppresses hidden output; improve the work needed to calculate and filter
partially visible rows. Investigate cheap full-coverage rejection before
boolean path operations, reusing unmodified rounded silhouettes and clip
layers, and tighter demanded filter regions for narrow exposed portions.

Keep full card/material coordinates independent of the demanded output region.
Preserve optical sampling beyond its edge. Cropping the material's own bounds
would repeat the earlier offscreen distortion and vertical clipping problems.
Keep the first card above subsequent cards and never reveal lower notification
content through an overlapping card's transparency.

The clipping/calculation part can be a bundle change. If the engine still
filters a large rectangular bounding box around a small exposed shape, reducing
that GPU work requires an engine change as well. Measure CPU path cost and GPU
filter cost separately before choosing the implementation.

## 3. Optional lower frost resolution during motion

Only if the user accepts a quality tradeoff. Glass already has a quality
parameter for its Gaussian input. Temporarily reduce that input's resolution
while moving, retaining full-resolution foreground text, icons, and shape
edges, then restore the configured quality after settling.

This can make fine background detail softer during a drag, and changing quality
can cause a visible transition or extra filter-cache churn. It should be an
optional fallback after the first two approaches, not an assumed improvement
or an unannounced material change.

## Validation after approval

Collect existing frame/render telemetry while the user operates the panel;
compare UI-thread time, raster time, filter passes, texture allocation/reuse,
and p95/p99 frame cost. Cover opening, reversing midway through entrance,
closing with partial overlap, scrolling a longer list, and a changing app
behind the glass. The user validates appearance. Do not generate notifications,
open apps, or automate gestures without a specific request.

Flutter's upstream documentation explains
[shared backdrop inputs and overlap constraints](https://api.flutter.dev/flutter/widgets/BackdropFilter-class.html)
and the cost of
[offscreen layers and clipping](https://docs.flutter.dev/perf/best-practices).
The implementation decisions above also depend on the installed Denial fork,
not just those upstream defaults.
