# No-effects raster investigation, 2026-09-05

These diagnostic runs investigate the user's three-Kitty scene with glass and
blur disabled on `.188`, using engine `56628c5d`. They are separate from the
[three-run baseline](../no-effects-baseline-2026-09-05/README.md): perf sampling
and uprobes add overhead, so their durations are diagnostic, not benchmark
results. `diagnostic-controls.json` records the matching artifacts and output.
All completed captures here used `DENIA_RENDER_AUDIT=1` and PID 21063.

The baseline averages 1511 µs raster time despite only 1.47% frame damage and
no full-output damage. Its GPU stage audit contains no backdrop or blur work.
The investigation found two opportunities in ordinary scene rendering, recorded
as findings 18 and 19 in the [review](../../../ASTRA_REVIEW_2026-09-04.md).
Neither has been implemented or measured as a speedup.

- **Preparation traversal:** both display-list passes ran in all 719 inventory
  frames, including 675 with no first-pass text calls. Each receiver dispatched
  5805 lists including descendants. A separate trace bracketing only the outer
  preparation dispatch measured 30.5 µs mean and 28.9 µs median for 675 text-free
  frames. This suggests a modest saving from recursively tracking whether text
  or backdrop preparation is needed. Probe overhead is included; preparation
  object construction/destruction is excluded.
- **Rounded clipping along straight edges:** 707 rounded clips were rendered in
  a 12-second trace. For 331, intersecting the current clip with the rounded
  shape is equivalent to intersecting its outer rectangle, with a one-pixel
  margin toward the corners. Of those, 325 also meet the existing rectangular
  scissor path's 0.124-pixel edge tolerance. Their 650 stencil/cover commands are
  candidates for replacement by scissor clipping. Zero rounded clips satisfied
  the stronger condition of containing the entire current clip; dropping the
  edge clip altogether would be wrong. Corner cases and unsupported transforms
  still need the existing geometry path.

The stage trace covers 959 complete frames. Scene raster work averaged 265.6 µs,
including 79.5 µs painting. `RenderToTarget` averaged 563.2 µs, including 314.5 µs
GLES encoding. These nested scope measurements include instrumentation and
scheduling delays. They should not be added to values from other captures or
treated as entirely removable work. CPU sampling did not provide reliable C++
inclusive stacks, so no inclusive hot-path claim is made from that profile.

`stage-summary.json` and `inventory-summary.json` retain scope and command
measurements. `clip-records.json`, `first-pass-records.json`, their summaries,
and `summarize-clip-scissors.py` retain the rounded-clip and preparation-pass
evidence. Raw perf data, probe scripts and the matching unstripped engine are
kept outside the checkout in
`/home/logix/.cache/denial/benchmarks/no-effects-56628c5d/`. The first clip attempt
stalled when the panel slept and is excluded; the completed capture followed
the user's wake confirmation. No visual validation was performed by the agent.

## Audit overhead and session cutover

Finding 20 records a measurement limitation: `DENIA_RENDER_AUDIT` also enables
per-draw GPU timing. The baseline's detailed GPU windows contain 93,567 samples
over 86.275 seconds, approximately 2,169 additional timestamp markers per second.
Each sample creates, reads and deletes two query objects. Matching audit settings
control this variable between experiments, but draw reduction also reduces audit
work. The production benefit with auditing off has not yet been measured.

At the user's request, `/etc/denial/session.conf` was changed to
`export DENIA_RENDER_AUDIT=0` on `.188`. Its previous configuration is saved as
`/etc/denial/session.conf.before-audit-off-20260905-005305`. After restarting
`greetd.service`, the replacement Denial process is PID **27244**, started at
00:56:50 CEST on September 5. Its actual process environment contains `0`, its
compositor/engine/AOT hashes match the baseline, and its benchmark status endpoint
is available and idle. No render-audit entries were present in its journal at
verification. No new cursor run was triggered after this restart.

All five previously saved benchmark series had auditing enabled. Future runs
with auditing disabled must be recorded as a new series after the user prepares
the scene again; they must not silently replace or be pooled with those captures.
