# No-effects, three-Kitty baseline, 2026-09-05

The user disabled glass and blur and prepared three Kitty windows: htop, btop,
and an otherwise idle terminal. Persisted `appearance.transparencyMode` is
`off`; window opacities are 1.0. The layout and visual validation belong to the
user. This is a new workload; it is not a controlled comparison against the
earlier single maximized glass Kitty scene.

Three runs on `.188` used 5-second warmups, 30-second measurements and the same
180-logical-pixel cursor circle with a 2-second period. Engine `56628c5d`, native
compositor and shell AOT are unchanged from the preceding refresh experiment.
PID 21063 remained running. Exact hashes, output geometry and CPU policy are
retained in the raw events; appearance settings are in `scene.json`.

| Metric | Baseline |
| --- | ---: |
| CPU, % of one logical core | 19.009 |
| Raster thread CPU, % of one logical core | 9.821 |
| Mean raster | 1511 µs |
| Raster p95 | 1894 µs |
| Raster p99 | 2647 µs |
| i915 render busy | 5.237% |
| Cursor ticks/second | 60.033 |
| Timed frames | 5403 |

Per-run CPU was 19.193%, 18.900%, and 18.933%; mean raster was 1520, 1504, and
1508 µs. CPU/GPU aggregates are weighted by measurement wall time, and raster
statistics pool the individual frame samples using nearest-rank percentiles.

Complete render-audit windows cover 5181 presented outputs in 86.28 seconds.
There are **zero full-frame or full-buffer damage updates**. Average frame damage
is 1.470% and average buffer damage is 2.511%. The new texture sample callbacks
recorded 185 generation advances and no repeated generations; this counter does
not count painting an already retained client texture. No buffer exhaustion,
raster restarts, disjoint GPU timers or abandoned GPU timers were recorded.

The full-output damage failure from the glass investigation is absent in this
capture. Work remains on the raster thread despite small damaged regions.
The [separate investigation](../no-effects-investigation-2026-09-05/README.md)
records preparation-pass and rounded-clip opportunities; profiler runs are
excluded from this baseline. No speedup is claimed.

This capture used `DENIA_RENDER_AUDIT=1`, including per-draw GPU timestamp queries.
Auditing was disabled at the user's request after the investigation, with a
session restart to PID 27244. Future audit-off measurements form a new series.

`aggregate.json` retains pooled metrics and audit totals. `render-audit.jsonl`
contains only complete journal windows inside the target-side CPU measurement
boundaries. Raw events, requests and per-run summaries are retained beside it.
