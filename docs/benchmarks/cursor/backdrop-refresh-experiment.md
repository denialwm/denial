# Experiment 3: refresh backdrops that have demonstrated cache reuse

The accepted snapshot coverage experiment reduced mean raster time to 649 µs.
The next investigation targets remaining raster work. Scheduling is unchanged.

A separate 25-second cursor profile collected 823 user-space CPU samples.
Self samples remained split between the engine, driver and other work. C++
unwinding was unreliable even with exact matching libraries; this profile does
not establish inclusive preroll cost.

Temporary entry/return probes then measured 488 complete raster frames during
8.18 seconds inside a separate cursor run. `ScopedFrame::Raster` averaged
117 µs, including 22 µs of layer-tree paint recording. `RenderToTarget` averaged
248 µs, including approximately 154 µs per target in GLES command encoding.
These scopes do not cover every component of Flutter's reported raster time.
Backend rendering carried the large spikes: its p99 was 1962 µs, while the
preparation/recording scope's p99 was 186 µs. Probe overhead is included; these
diagnostics are excluded from benchmark comparisons.

The accepted comparison's remaining full repaints usually arrived in pairs.
A further trace confirmed the admission policy's contribution: one backdrop
family repeatedly returned `false` for a changed generation, then `true` on
the next rendered frame. The filter was evaluated first without retaining its
result, then evaluated again to create its persistent snapshot. The policy
waited for repeated generations even after an earlier snapshot had demonstrated
successful reuse.

The follow-up records successful renderer cache hits, after the coverage check.
When such a family's generation changes, it can materialize the replacement
immediately. That decision resets the reuse evidence. If the replacement is
never reused because content starts changing continuously, subsequent versions
return to delayed admission. Finding an entry, pinning one during damage
planning, or rendering an older pinned generation does not teach the new
generation that caching is useful. Existing bounds and lifetime checks remain.

The new regression exercises an actual ordinary-blur cache hit through Canvas,
then checks immediate refresh, transition to continuous changes, and rejection
of stale reuse evidence. Existing tests retain the cold-family delay and
generation-retirement coverage.

The release engine and Impeller test binary built successfully. All eight
selected OpenGLES/cache/glass tests passed, including the new ordinary-blur
renderer regression. Committed in the canonical Flutter fork as `56628c5d`
(parent `58d8036b`). The user confirmed visual correctness and the subsequent
[three-run comparison](backdrop-refresh-2026-09-05/README.md) completed.

Raster p99 fell from 2832 to 1331 µs, and frames exceeding 3 ms fell from 50 to
11. Full-frame damage frequency fell from 1.144 to 0.672 outputs per audit
second. The recurring pairs became single updates: 41 windows previously had
two full-frame updates, while 41 now have one. Larger bursts remain included.
GPU render activity fell from 5.123% to 4.730%. Average CPU and raster time
were essentially unchanged (8.056% to 8.044% of one core; 649 to 644 µs), while
raster p95 rose from 799 to 840 µs. This supports reducing repeated backdrop
work and the expensive raster tail; it does not establish another average CPU
speedup. Cadence remained at 59.566 cursor ticks/s with 42 long intervals in
both captures. Scheduling is unchanged.

Deployed to `.188` as `56628c5de8550d1e-42912d6292277854`. The normal deployment
also rebuilt concurrent native compositor edits, producing a different native
hash. Before any visual-validation or benchmark round, the captured baseline
native binary was restored atomically from immutable native artifact
`e5de786f858d35eeb6f30dfe`. The working-tree edits and new local build were left
intact. The session restart needed the existing bounded retry after UWSM cleanup.

An independent check confirmed new `deniald` PID 21063 maps the new engine,
while native and shell AOT hashes match the original baseline. All three
benchmark runs independently recorded matching controls, output geometry and
refresh rate.
The engine SHA-256 is:

```text
d9abf12eacf4ec6e17b8ea365ab305701b95ec5b2e71573c9a5d16a2a71abeb2
```

The source lock remains unchanged. Keep native artifact
`e5de786f858d35eeb6f30dfe` fixed for further engine comparisons; the general lab
deployment command rebuilds the current native working tree.

Raw samples, stage traces, decoded summaries, bounded diagnostic runs and build
logs are under `~/.cache/denial/benchmarks/cursor-raster-58d8036b/`.
Both temporary probe groups were independently verified removed. No screenshots
or pixel inspection were performed.
