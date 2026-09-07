# Cached backdrop damage comparison, 2026-09-04

The user confirmed correct glass rendering and prepared the static, maximized
glass Kitty scene. Three runs used the baseline's circle, output, warmup and
duration. Captured host, kernel, CPU policy, environment, shell AOT, compositor,
output and trajectory match. The engine changed from `119e18cf` to `23bfb1e3`.

| Metric | Baseline | Experiment | Observed change |
| --- | ---: | ---: | ---: |
| CPU, % of one logical core | 16.411 | 15.634 | −4.74% |
| Mean raster, µs | 2057 | 1985 | −3.49% |
| Pooled raster p95, µs | 2268 | 2191 | −3.40% |
| i915 render busy | 47.337% | 46.840% | −1.05% |
| Cursor ticks/s | 59.977 | 59.933 | −0.07% |

**The intended reduction in repaint work did not occur.** Every output in the
experiment's complete audit intervals still had full frame and buffer damage.
Small before/after timing differences are not enough to attribute a speedup to
the patch. Both captures maintained approximately 60 cursor updates/s; this is
not proof of scanout cadence.

`comparison.json` records calculations and control checks. CPU/GPU aggregates
are weighted by measured wall time; raster statistics pool individual frame
samples. Raw events and per-run summaries are retained beside this file.

`render-audit.jsonl` was recovered from the target journal after capture.
Only complete audit windows within each target-side CPU measurement interval
are included, using journal monotonic timestamps and the reported interval
duration. This covers 5175 presented outputs in 85 windows (about 86.35 seconds).
No buffer exhaustion, raster restarts or GPU timer disjoint events were reported
in those windows. The corresponding baseline audit was recovered using the same
method. GPU timer results are supplementary to the DRM engine counters.

A separate temporary trace on the running engine found existing backdrop
snapshots repeatedly being stored again on cursor frames. Two unchanged cache
identities were found on all 778 lookups from damage planning and all 778
lookups from drawing, yet were rebuilt/stored 778 times each. Coverage rejection
was then confirmed with a second trace. Diagnostic runs are outside this comparison, under
`~/.cache/denial/benchmarks/cursor-backdrop-23bfb1e3/`.

The bounds trace found a coordinate-space mismatch in the first experiment:
damage's top-left target `[1465, 5, 1564, 30]` was compared to a cached snapshot
at `[1465.8098, 1050.3000, 1562.8098, 1074.3000]`. The embedder applies its
vertical reflection later, when submitting the recorded DisplayList, so the
scoped frame's identity root transform does not describe snapshot coordinates.

It also found undersized snapshots. Glass material allocation uses
`ISize(material_size)`, which truncates fractional widths and heights, while its
snapshot transform only translates the texture. The resulting image cannot
cover the original fractional material extent. Impeller consequently rejects
existing entries and rerenders them. The follow-up fixes these two causes and
preserves precise floating-point filter coverage during damage planning.

All temporary probes were removed after collection. One attempted bounds trace
produced no samples because the output had powered off; the user woke the host
and the successful trace captured 1209 samples. No screenshot or pixel inspection
was used; the trace records only keys, dimensions and transforms.
