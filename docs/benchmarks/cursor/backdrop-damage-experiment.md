# Experiment 1: cached backdrop damage

The baseline's stationary glass Kitty receives full-output damage while only
the cursor moves. `DiffContext` expands overlapping damage to a filter's paint
and input regions; Impeller's existing filtered-background cache is consulted
later, during rendering. Damage planning therefore retains the cost of
reconstructing a background even when its filtered pixels can be reused.

The experiment passes current backdrop cache identities into damage planning.
A dependency can be omitted only when Impeller has the exact version cached
with coverage containing the complete filter paint rectangle. A scoped
reservation keeps that snapshot available through DisplayList recording and
surface submission, including if ordinary cache entries are evicted or retired
while earlier layers render. The current cache generation is resolved after
the complete diff, including autonomous external-texture invalidation.

Missing or undersized snapshots retain ordinary readback expansion. Shared or
multiply used cache identities, ancestor image filters, and nonidentity root
surface transformations also retain that path. Unknown framebuffer contents
still require a full repaint. Historical buffer repair remains separate from
new frame damage.

Regression coverage includes moving foreground content above a cached filter,
uncached fallback, old framebuffer repair, background-texture invalidation,
ambiguous coverage, and reservation lifetime across cache retirement and nested
recording. The engine test build also required correcting an existing glass
test's scalar `Vector2` construction to supply both coordinates.

Committed in the canonical Flutter fork as `23bfb1e3` (parent `119e18cf`).
The release engine builds successfully. All 291 flow tests outside the
performance-overlay suite passed, including the damage regression. The initial
unfiltered flow invocation stopped in an unrelated overlay golden test because
its golden resource path was unavailable. The final run excludes that suite.

All six selected OpenGLES snapshot cache and glass geometry tests passed in an
isolated virtual display. A broader backend selection stopped because the
local machine lacks Vulkan validation layers; the lab workload uses OpenGLES.

Deployed to `.188` as artifact `23bfb1e3ba97ddc9-fb2fc8b33f069c1b`.
Restarted greetd and verified new `deniald` PID 8626 with the experimental
library mapped. The benchmark endpoint is healthy and idle; output geometry
and refresh rate match the baseline. Shell AOT and compositor hashes are
identical to the baseline. The engine SHA-256 is:

```text
7cc19f194d6631aacfc4edcd79bbc433d1c520d4c7caa62c41100c82c8993310
```

The source lock remains unchanged. The user confirmed that glass renders
correctly. The first comparison start was rejected because the shell cursor was
unavailable; no animation or measurement ran. That rejected attempt is retained
at `/tmp/denial-cursor-unavailable-1788554882`. The user then confirmed readiness
and the three comparison runs completed. See the
[results](backdrop-damage-2026-09-04/README.md): full-output damage persisted,
so the intended repaint reduction was not achieved.

## Follow-up: snapshot coordinates and fractional coverage

Separate temporary traces confirmed that snapshots exist but fail coverage
checks in both damage planning and rendering. For two stable cache identities,
all 778 planning lookups and 778 drawing lookups found a snapshot, yet each
snapshot was rebuilt/stored 778 times. The successful bounds trace after the
user woke the output collected 1209 samples; all probes were removed afterward.
The raw traces and decoded bounds are retained under
`~/.cache/denial/benchmarks/cursor-backdrop-23bfb1e3/`.

The follow-up carries the embedder's eventual root-to-target transform into
snapshot pinning. It preserves the filter's fractional extent separately from
the rounded integer damage bounds. Unknown mappings and transforms beyond
finite translation/scale keep conservative readback repair.

Glass material textures now round their allocation up. Their quad and optical
coordinates remain at the original physical dimensions, so the added texture
padding does not stretch the material. Previously, `ISize(material_size)`
truncated those dimensions while the snapshot transform only translated them,
making cache reuse fail even without the damage-planning experiment.

The regression uses a fractional panel element and a large window whose width
is just above an integer. It checks actual generated snapshot dimensions,
coverage, unchanged scale and pinning through the vertical reflection. The
existing moving-foreground regression now also uses fractional filter bounds,
including the reused-tree path.

Committed in the canonical Flutter fork as `58d8036b`, on top of `23bfb1e3`.
The release engine and the flow, Impeller and embedder test executables built.
All 291 flow tests outside the performance-overlay suite, all seven selected
OpenGLES/cache/glass tests and both external-view embedder tests passed. The
new GPU test creates synthetic textures in an isolated virtual display and
asserts dimensions/transforms; it performs no screenshot or pixel inspection.
Logs are the `coverage-*.log` files in the trace directory above.

Deployed to `.188` as `58d8036b4bce4b8a-ed26fe4f77abbd64`. The deployment
restarted greetd; an independent check confirmed new `deniald` PID 14001 maps
that artifact's engine. Shell AOT and compositor SHA-256 hashes still match
the baseline exactly. The engine SHA-256 is:

```text
4a0f63b644477305cba26e0dca0fccf44502082abb087479167b4799e3f98fc2
```

The source lock is unchanged. The user confirmed correct rendering and prepared
the same benchmark scene. The [three-run comparison](snapshot-coverage-2026-09-04/README.md)
reduced CPU by 50.91%, mean raster duration by 68.47% and i915 render activity
by 89.18%. Average frame damage fell to 1.99% and buffer damage to 2.91%.
Timing tails and slightly reduced cursor cadence are recorded alongside those
results; further investigation focuses on remaining raster work.
