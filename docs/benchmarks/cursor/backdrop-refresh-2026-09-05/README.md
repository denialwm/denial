# Backdrop refresh comparison, 2026-09-05

After the user confirmed visual correctness, engine `56628c5d` completed three
cursor-circle runs on `.188` with the same static maximized glass Kitty scene.
Each run used a 5-second warmup and 30-second measurement, a radius of 180 logical
pixels and a 2-second period. Native compositor, shell AOT, host, kernel, CPU
policy, environment, output geometry and cursor path match both earlier captures.
Only the engine changed. Exact hashes and control checks are in
[`comparison.json`](comparison.json).

**The change reduces repeated full redraws and the expensive raster tail.
Average CPU and raster time are essentially unchanged from the coverage fix.**

| Metric | Original baseline | Coverage fix `58d8036b` | Refresh fix `56628c5d` |
| --- | ---: | ---: | ---: |
| CPU, % of one logical core | 16.411 | 8.056 | 8.044 |
| Mean raster, µs | 2057 | 649 | 644 |
| Raster p95, µs | 2268 | 799 | 840 |
| Raster p99, µs | 2485 | 2832 | 1331 |
| Raster frames over 3 ms | 3 | 50 | 11 |
| i915 render busy | 47.337% | 5.123% | 4.730% |
| Average frame damage | 99.981% | 1.991% | 1.198% |
| Average buffer damage | 100.000% | 2.912% | 2.053% |
| Full-frame damage outputs per audit second | 59.968 | 1.144 | 0.672 |

Compared with the coverage fix, raster p99 fell 53.0%, the full-frame redraw rate
fell 41.3%, and measured GPU render activity fell 7.7%. Mean raster moved only
0.7% and CPU only 0.1%; those differences do not establish an additional average
CPU or raster speedup. Raster p95 rose 5.1%. Maximum raster fell from 5945 to
3897 µs. These sequential three-run captures describe this workload; they are
not a randomized comparison or an all-workload speedup estimate.

Across all iterations, measured CPU is 51.0% below the original baseline, mean
raster is 68.7% lower, and GPU render activity is 90.0% lower.

| Run | CPU, % of one core | Mean raster, µs | Raster p99, µs |
| --- | ---: | ---: | ---: |
| 1 | 7.600 | 613 | 1190 |
| 2 | 8.200 | 652 | 1510 |
| 3 | 8.333 | 667 | 1222 |

CPU/GPU aggregates are weighted by measurement wall time. Raster statistics pool
all 5361 frame samples, using nearest-rank percentiles.

## Damage evidence

The audit covers 5145 presented outputs in 85 complete windows, totaling
86.35 seconds inside the 90 measured seconds. There were 58 outputs with full
frame damage and 101 with full buffer damage, compared with 100 and 147 in
87.38 audit seconds for the coverage fix. The table normalizes full-frame counts
by audit duration.

Previously, 41 audit windows contained two full-frame updates. This capture has
41 windows containing one full-frame update, consistent with retaining the
refreshed backdrop on its first evaluation. Two windows in run 2 contain seven
and ten full-frame updates; these bursts remain included. Their underlying
invalidation trigger has not been identified. The cache policy still falls back
to delayed admission when replacements have not demonstrated reuse.

Mean Flutter GPU duration in the selected audit windows fell from 823 to 753 µs.
No buffer exhaustion, raster restarts, GPU timer disjoint events or abandoned
GPU timers were recorded.

## Cadence and validation

Cursor ticks averaged 59.566/s in both the coverage and refresh captures. Both
contain 42 intervals longer than 1.5 refresh periods, approximately two-refresh
intervals. Ticker intervals do not establish physical scanout cadence. This
iteration changed cache admission; it did not change scheduling, and no cause
for the existing cadence behavior is inferred.

The release engine built successfully and all eight selected OpenGLES/cache/glass
tests passed, including an ordinary Gaussian-blur renderer regression covering
successful reuse, immediate refresh, continuously changing generations and stale
reuse evidence. The user performed visual validation before measurement.

The deployed artifact is `56628c5de8550d1e-42912d6292277854`, running as `deniald`
PID 21063 at capture. The source lock remains unchanged. See the
[`experiment notes`](../backdrop-refresh-experiment.md) for the implementation
and deployment controls.

Raw benchmark events, request and per-run summaries are retained beside this
file. [`render-audit.jsonl`](render-audit.jsonl) contains only complete journal
audit windows inside each target-side CPU measurement interval;
[`audit-summary.json`](audit-summary.json) summarizes them per run.
[`pacing-and-damage.json`](pacing-and-damage.json) retains pooled timing tails,
cadence counts and damage aggregates for all three compared engines. Diagnostic
profiling runs and their temporary probes are excluded from these comparisons.
