# Cursor baseline, 2026-09-04

User-confirmed scene: one maximized (not fullscreen), transparent glass Kitty
window with static contents and no new client frames. The synthetic shell
cursor moved over the window. No other activity was intended.

Host: `logix@192.168.1.188`, eDP-1, 1920×1080, scale 1.1, 60.033 Hz.
Three runs, each with 5 seconds warmup and 30 seconds measurement. The circle
has radius 180 logical pixels, a 2-second period, and center
(872.7273, 490.9091). `DENIA_RENDER_AUDIT=1` was enabled.

| Run | CPU (% of one core) | Mean raster (µs) | Raster p95 (µs) | Cursor ticks/s | i915 render busy |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 16.00 | 2027 | 2229 | 59.93 | 48.80% |
| 2 | 16.27 | 2066 | 2276 | 60.00 | 46.74% |
| 3 | 16.97 | 2079 | 2302 | 60.00 | 46.47% |

These are baseline observations, not optimization results. Raster duration is
not GPU execution time; cursor ticks do not prove scanout. Raw target-side
events, process/thread counters, output configuration and identities are saved
alongside this file. See `summary.json`, `capture.json`, and `run-*.jsonl`.

Engine source: Flutter `119e18cfe94de7c0176e2e5105ac3f46a11f3447`, lab
artifact `119e18cfe94de7c0-aa3ef2af98a1592f`. SHA-256 identities:

```text
engine  ba1c03f88b1a0c8c6a67010f953422690a7ae09b2e6bbfe5b35a8ba0aa6a2668
AOT     bd82201287119a1fc82b1b42f615b801392922af36ba33444ff392c9e0ebc95e
deniald 83043dc22f4788d07d8c34a47870d2e01db0cbc3a03abdfa0bc5e3426d4b871f
```

A separate profiled run is retained locally at
`~/.cache/denial/benchmarks/cursor-baseline-20260904/`, including matching
unstripped engine symbols and `cpu.data`. It is excluded from this baseline.
Self samples were concentrated in the raster thread's graphics driver,
engine command encoding, and libc. The available report does not establish
inclusive preroll cost.

Render-audit observations around these runs showed full-output frame and
buffer damage during sustained cursor animation. The native audit's
`sampled_textures_avg=0` counts fresh native sampling callbacks; it does not
mean Kitty was absent from the scene or its cached texture was not painted.
After the comparison, the corresponding journal records were recovered in
`render-audit.jsonl` and `audit-summary.json`. Only complete audit windows inside
the saved target-side CPU sampling intervals are included. These cover 5179
outputs across about 86.35 seconds; buffer damage remained full-output.

After an optimization is deployed, the user must validate rendering first.
Recreate this scene before collecting a comparison, and preserve the same
workload, audit setting, output configuration and power conditions.
