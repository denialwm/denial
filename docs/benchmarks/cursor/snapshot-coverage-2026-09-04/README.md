# Snapshot coverage comparison, 2026-09-04

The user validated the glass/window rendering of engine `58d8036b` and prepared
the same static maximized glass Kitty scene on `.188`. Three runs used the
baseline's 5-second warmup, 30-second measurement, 180-logical-pixel circle and
2-second period. Host, kernel, CPU policy, environment, shell AOT, compositor,
output and cursor path match the earlier captures. Only the engine changed.

**This iteration substantially reduces repaint and raster work.**

| Metric | Baseline | Snapshot coverage fix | Change |
| --- | ---: | ---: | ---: |
| CPU, % of one logical core | 16.411 | 8.056 | −50.91% |
| Mean raster, µs | 2057 | 649 | −68.47% |
| Raster p95, µs | 2268 | 799 | −64.77% |
| i915 render busy | 47.337% | 5.123% | −89.18% |
| Average frame damage | 99.981% | 1.991% | −98.01 percentage points |
| Average buffer damage | 100.000% | 2.912% | −97.09 percentage points |

Per-run CPU was 8.067%, 8.000% and 8.100%; mean raster was 656, 641 and
650 µs. All three runs show the reduction. CPU/GPU aggregates are weighted by
measurement wall time; raster statistics pool individual frame samples.

The audit covers 5206 presented outputs in 86 complete windows, totaling
87.38 seconds inside the 90 measured seconds. There were 100 outputs with full
frame damage and 147 with full buffer damage. Most audit windows alternate
between zero and two full-frame updates; one window in run 3 contains 17.
Those remaining updates are included in the results. Their trigger has not yet
been identified. No new native texture sample callbacks, buffer exhaustion,
raster restarts, GPU timer disjoint events or abandoned GPU timers were recorded
in these windows. The native callback count does not indicate whether a retained
client texture was painted.

GPU timer results support the DRM counters: mean Flutter GPU duration in the
complete audit windows fell from 8350 to 823 µs. These are descriptive results
for this workload, not an all-workload speedup estimate.

## Timing observations

Raster p99 increased from 2485 to 2832 µs; maximum raster increased from 3209
to 5945 µs. Cursor ticks averaged 59.566/s instead of 59.977/s. There were 42
tick intervals longer than 1.5 refresh periods, versus five at baseline; these
were approximately two-refresh intervals. Ticker intervals do not establish
physical scanout cadence. Reduced work could affect CPU/GPU frequency scaling,
but actual clock behavior was not captured, so the cause remains unproven.
The 0.69% reduction in tick rate is far smaller than the measured reduction in
work. Subsequent experiments will focus on the remaining raster work.

`comparison.json` includes the first unsuccessful damage experiment as well as
this result, with all control checks and exact artifact hashes.
`pacing-and-damage.json` retains timing tails and damage aggregates.
`render-audit.jsonl` contains only complete journal audit windows inside each
target-side CPU measurement interval. Raw benchmark events, request and per-run
summaries are retained beside this file. Separate profiling runs are excluded.

The source lock remains unchanged. The deployed artifact is
`58d8036b4bce4b8a-ed26fe4f77abbd64`, running as `deniald` PID 14001 at capture.
