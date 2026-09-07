# Circular cursor raster benchmark

The first saved capture is the [2026-09-04 glass Kitty baseline](
benchmarks/cursor/baseline-2026-09-04/README.md).

This opt-in lab workload moves the shell's existing retained cursor transform.
It does not inject mouse input, change application focus, or generate hover
events. It measures the cost of presenting a small moving shell element in an
otherwise user-prepared scene. It is not an input-latency benchmark.

The workload is disabled unless the compositor's startup environment contains:

```sh
export DENIAL_CURSOR_BENCHMARK_SOCKET=/run/user/1000/denial/cursor-benchmark.sock
```

The socket's parent must already be private to the session user. The endpoint
is lab instrumentation, separate from Denial's public control protocol. Merely
enabling the endpoint does not animate anything. On `.188`, the setting lives
in `/etc/denial/session.conf`; deploy with `tools/denial-lab-deploy` and verify
that the replacement Denial process is running.

The user prepares and visually validates the scene. Keep the same windows,
positions, focus, settings, display configuration and power conditions for
comparisons. Leave the physical cursor visible on an empty desktop area before
starting. Physical pointer movement cancels a run; display, cursor-theme and
cursor-size changes also cancel it. Initial visibility and output scale affect
cursor preparation and must settle before measurement.

```sh
tools/benchmark-denial-cursor \
  --host logix@192.168.1.188 \
  --output docs/benchmarks/cursor/BASELINE_NAME \
  --runs 3 --warmup 5 --duration 30 --period 2 --radius 180
```

The default path is a circle centered on the output driving the Flutter frame
clock. Coordinates and radius are logical pixels. Override the location with
`--monitor-id`, `--center-x` and `--center-y`. The entire circle must fit inside
one output with a 32-pixel margin. Position follows elapsed frame time, so
missed frames do not slow the requested trajectory. The original physical
cursor position is restored on completion or cancellation.

Each run streams start, measurement-start, measurement-end and completion
events. CPU sampling runs on the target host at those event boundaries; SSH
latency does not define the sampling interval. Frame timing collection drains
after measurement because release engines batch timing callbacks. No per-frame
logging is introduced by the benchmark itself.

The output directory must not already exist. It retains the request, raw events,
and a summary containing:

- process CPU seconds and utilization, where 100% means one logical CPU;
- CPU breakdown for threads present at both measurement boundaries;
- available DRM per-engine busy counters, deduplicated by client identity;
- cursor tick count/cadence and completed Flutter frame timings;
- build, raster and total frame-span distributions;
- exact executable, engine and AOT image hashes, output geometry, kernel and
  CPU policy metadata.

CPU counters have the kernel's jiffy resolution. Frame raster duration includes
raster-thread work and is not GPU execution time. DRM engine counters may be
unavailable or overlap; do not sum them into a universal GPU utilization value.
Cursor ticks describe scheduled updates, not proof that every update reached
scanout. Use Denial's existing render audit to assess actual presentations and
missed deadlines. Keep audit settings identical across comparisons. The current
`DENIA_RENDER_AUDIT` flag also enables per-draw GPU timestamp queries; use it for
separate diagnostic captures and measure final performance with auditing disabled
on both sides. The first five saved series below used auditing, so their measured
percentage changes should not be assumed to hold with auditing disabled.

Collect CPU profiles in separate runs to keep profiler overhead out of the
baseline. Preserve matching engine symbols before rebuilding the engine.

After implementing an optimization, deploy it for the user's visual validation
first. Run the comparison workload only after that validation succeeds. Lower
CPU or raster time is useful only alongside correct effects, unchanged update
cadence, and acceptable presentation timing.

Recorded iterations:

- [Baseline](benchmarks/cursor/baseline-2026-09-04/README.md).
- [First damage experiment](benchmarks/cursor/backdrop-damage-2026-09-04/README.md):
  full-output damage persisted.
- [Snapshot coverage fix](benchmarks/cursor/snapshot-coverage-2026-09-04/README.md):
  51% lower CPU, 68% lower mean raster time and 89% lower GPU render activity
  in the validated static glass Kitty cursor workload.
- [Backdrop refresh fix](benchmarks/cursor/backdrop-refresh-2026-09-05/README.md):
  user validated and measured; 53% lower raster p99 and 41% fewer full-frame
  redraws per second than the coverage fix. Average CPU and raster time are
  essentially unchanged; raster p95 rose 5%.
- [No-effects three-Kitty baseline](benchmarks/cursor/no-effects-baseline-2026-09-05/README.md):
  a different user-prepared workload with glass and blur off; no full-output damage.
- [No-effects investigation](benchmarks/cursor/no-effects-investigation-2026-09-05/README.md):
  preparation traversal, rounded clips and audit overhead; includes the subsequent
  switch to auditing off on `.188`.
