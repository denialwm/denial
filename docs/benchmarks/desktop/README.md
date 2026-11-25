# Denial desktop performance benchmarks on Pad4

The tablet has an opt-in shell automation socket, a declarative benchmark
runner, and a native continuous EGL render client. The runner schedules actions
on the tablet's monotonic clock; SSH only starts the run and retrieves results.

The current scenario is [pad4.json](pad4.json).
It verifies device identity and the 120 Hz output, requests normal closure of
all application windows, and waits for an empty window list. A close refusal,
dialog, locked session, or timeout fails the run rather than silently continuing
with a different scene. Firefox gets a fresh profile retained with the run. The runner
verifies Firefox on workspace 1 and Settings on workspace 2 before measuring.
The native render client opens on workspace 3 for the last three phases.
The runner waits for its first actual presentation before phase warm-up, and
records launch-to-presentation timing separately in `workload-ready.json`.

| Phase | Duration | Action interval |
|---|---:|---:|
| Idle | 8 s | None |
| Workspace switching | 12 s | 650 ms |
| Interrupted workspace switching | 12 s | 80 ms |
| Overview | 10 s | 500 ms |
| Interrupted overview | 10 s | 80 ms |
| Visible render client | 12 s | Frame callback |
| Render client + workspace switching | 12 s | 80 ms |
| Render client + overview | 12 s | 80 ms |

The default workspace animation is 500 ms and overview animations are
380/280 ms, so the 80 ms phases exercise reversals before animation completion.
The scenario also supports changing workspace sequences, commands, durations,
warm-up, sampling interval, and the output refresh requirement. Output IDs and
installed binary paths must match the target device.

## Run and inspect

The tools are staged in `/home/logix/denial-benchmark` on the tablet. Run there:

```sh
python3 denial-benchmark state
sudo python3 denial-benchmark run scenario.json --output results/my-run-01
python3 denial-benchmark report results/my-run-01
sudo python3 denial-benchmark observe --seconds 12 --output results/manual-01
```

Each output directory must be new. Every run closes existing application
windows at the start, drives the visible test scenes, and closes its test
applications afterward. Final window, workspace, overview, and capture state
are recorded. Visual validation belongs to the user. This harness checks
protocol state and timing, and does not take screenshots.

On the development workstation, the explicitly authorized current-session
helper uses the lab's existing SSH configuration and sudo credential without
printing it:

```sh
python3 out/denial-benchmark-20261015/run-remote.py state
python3 out/denial-benchmark-20261015/run-remote.py run \
  /home/logix/denial-benchmark/scenario.json \
  --output /home/logix/denial-benchmark/results/my-run-01
```

That helper is local session glue and does not embed a credential. Credential
authorization for this benchmark was explicitly given in this conversation.

## Measurements

Results retain raw JSON and JSONL files as well as `summary.json` and
`summary.md`. They include:

- Compositor identity, executable/engine/AOT hashes, kernel and boot ID, output
  mode, CPU and huge-page policies, USB/charging state, thermal-zone names, and
  render settings.
- Launched application PIDs, start identities, thread names, and mapped
  engine/AOT/executable hashes. These are captured before phase warm-up so an
  unchanged application launcher cannot hide a different Flutter AOT bundle.
- Per-phase compositor and per-thread CPU, system CPU, RSS, deduplicated DRM
  client GPU busy counters, CPU/GPU clocks and frequency limits, temperatures,
  cooling states, pressure and memory information.
- Flutter build, raster, total-span, and vsync timing distributions; over-budget
  counts; action scheduling lateness; initial and settled state.
- Native client's `wp_presentation` timestamps, intervals, discarded frames,
  and actual presented fps. CLOCK_MONOTONIC is required before comparing client
  timestamps to scenario boundaries.

CPU percent for deniald is relative to **one core**, so 100% means one fully
occupied core. System CPU percent is relative to all cores. GPU counters are
for deniald's DRM clients; they do not include every other process's GPU work.
Resource collection also records its wall time and, in the final runner, its
own thread CPU time. It is an observer with measurable overhead.

The final collector reads thread/DRM counters every 0.5 s and refreshes full
DRM descriptor discovery, clocks and temperatures every 2 s. Empty `metrics`
objects between those detailed samples mean no new sensor observation.
`observe` records resources without any UI actions and works while locked.

Flutter FrameTiming measures newly built Flutter frames, not every native
composition or display presentation. Denial can update client content using
retained shell output without producing new Dart frames. Never derive display
fps from Flutter's timing record count. Likewise, a client on a hidden workspace
is expected to receive fewer frame callbacks: its whole-phase fps during
workspace switching is not a continuously visible 120 fps score.

The automation calls the normal workspace bridge and overview controller. It
does not measure touchscreen-to-photon latency or input-dispatch overhead.

## Fixed CPU frequency comparisons

Use a moderate common OPP to expose software costs without max-frequency boost
masking them. The initial comparison target is **2.112 GHz on both clusters**:
58% of policy0 maximum and 48% of policy6 maximum. Keep the GPU policy, USB/power
state, scene, and native/engine/shell hashes identical between runs.

```sh
sudo python3 pad4-test-cpu-frequency --khz 2112000 \
  --record results/fixed2112-policy.json -- \
  python3 denial-benchmark run eventloop-scenario.json \
  --output results/fixed2112
```

The wrapper sets each cluster's min and max to the target without changing its
governor. It waits for asynchronous policy updates and five consecutive hardware
clock readbacks at the target before starting the command. A finite timeout,
command failure, or terminal signal triggers restoration of the original limits;
normal, failed, and timed-out child restoration were checked on this tablet.
Do not overlap it with another CPU policy experiment. SIGKILL or power loss cannot
run Python cleanup; the policy record contains the original settings.

Thermal cooling remains enabled. The benchmark records `cpuinfo_cur_freq` and
both frequency limits every two seconds and at phase boundaries. Each phase's
`cpu_frequency` summary counts reported-clock and limit deviations from the fixed
target. Missing samples and deviations must be considered when comparing runs;
matching sampled clocks establish sampled agreement, not continuous verification.
Normal boost-policy validation remains a separate test. No CPU clamp is persisted
outside these experiments.

For GPU-sensitive comparisons, add `--gpu-hz 646000000`. This moderate GPU OPP
is about 54% of the device maximum. The wrapper verifies it is advertised, sets
both devfreq bounds, waits for five matching clock readbacks, and restores the
original GPU limits and governor alongside the CPU policies. Success, nonzero
exit, and timeout restoration were verified on this tablet. Keep thermal cooling
enabled and inspect sampled clocks throughout the run. A GPU clamp can lower
delivered FPS, which must remain visible in the results.

## Work per native presentation

FPS is a delivery check. At the 120 Hz ceiling, optimize the work needed to
produce each frame and the slow end of the pipeline timing distributions.
The comparison run now supports:

```sh
sudo python3 pad4-test-cpu-frequency --khz 2112000 \
  --record results/work-policy.json -- \
  python3 denial-benchmark run eventloop-scenario.json --output results/work \
  --measure-work --perf /home/logix/denial-benchmark/perf-runtime/usr/bin/perf
```

`--measure-work` counts actual native KMS deliveries using a private, loss-checked
trace instance. It verifies that Denial shares the primary DRM master file and
requires a single unambiguous active file/CRTC stream for each phase's denominator.
It does not use Flutter timing-record counts or the sometimes-hidden client fps
as the compositor frame count. Raw events, identity and per-CPU loss counters
are retained; the instance is removed after capture.

The report shows CPU milliseconds summed over Denial threads, GPU execution
milliseconds and GPU CP cycles per native presentation. GPU time comes from the
MSM driver's 19.2 MHz always-on timestamp delta; cycles come from its hardware
CP counter. Their ratio also reports the average GPU frequency during execution.
Keep that frequency and background load comparable when judging GPU-time changes.
CPU and GPU work overlap; adding their times gives no valid frame headroom score.
Per-thread CPU utilization and build/raster/span p95/p99 remain separate checks.
Idle scenes may intentionally present few frames; retain total work and per-refresh
interval costs alongside per-presentation costs.

Low-overhead CPU PMU counts include cycles, instructions, L2 refills, memory
accesses and bus accesses. Raw perf CSV retains event availability and running
percentage so multiplexed or unsupported counts are visible. Counter command
start/observed-exit times are stored separately from phase boundaries; their
windows have small process-start/stop skew and are intended for long phase
comparisons, not individual-frame attribution. Kernel work executed on Denial's
threads is included; independent kernel workers and other applications are not.

These cache/bus events measure memory pressure. No DDR/LLCC PMU is exposed by
this kernel, so the report does not label them as DRAM bytes or bandwidth.
RSS, minor/major faults and memory/CPU pressure are available alongside them.
Cached GPU samples read one representative descriptor per DRM client. Periodic
full discovery handles new/replaced descriptors; counters are still deduplicated
by client identity. This reduces observer work without suppressing any client.
`gpu_memory_mib` reports first, last and peak DRM total, resident, shared and
purgeable memory gauges. Duplicate file descriptors for the same DRM client
count once. Resident memory includes purgeable allocations, and shared objects
can appear in multiple clients: these gauges must not be added as independent
physical memory totals. GPU memory footprint is separate from memory traffic.
The report also shows minimum system `MemAvailable` and maximum shmem. These
expose system-wide memory pressure alongside process RSS and GPU residency.
A compatible diagnostic audit can also provide native CPU-stage and per-frame
GPU timer distributions. Audit capture is separate from the ordinary cost run.

## Isolated profiles and memory pressure

Each run retains its fresh Firefox profile at `RUN/firefox-profile`; its path is
recorded in metadata. Use a persistent output filesystem on the tablet, such as
`/home/logix/denial-benchmark/results`. Profiles can be inspected with the rest of
the run artifacts.

The earlier harness used RAM-backed `/tmp` and retained profiles across tests.
Forty-three accumulated profiles consumed 5.2 GiB and drove GPU allocations into
direct reclaim. Those inactive profiles were content-verified and archived to
persistent storage. Results collected under that pressure must be qualified;
minimum available RAM and maximum shmem now appear in the ordinary summary.

## GPU diagnostic attribution and discarded work

For a diagnostic session already launched with `DENIAL_RENDER_AUDIT=1`, add
`--capture-audit` to `run`. It saves raw journal JSON as
`audit-journal.jsonl.gz` and produces `audit-summary.json`/`.md` automatically.
The runner does not enable tracing or restart the session. Enable/remove the
temporary environment setting through the test host's normal session workflow.

The summary attributes complete audit intervals to each benchmark phase. It
reports GPU render-marker averages, the range of interval p95s, and the fraction
of published ready frames discarded as late. Rendered-but-discarded work is
especially useful when FPS alone obscures wasted CPU/GPU effort. Late frames
still retain their exact timeline identity; their discard count is a measurement,
not permission to retarget them to another presentation opportunity.

Existing raw logs can be reported separately:

```sh
python3 denial-benchmark audit-report results/run \
  --journal results/run/audit-journal.jsonl.gz
```

Only journal rows matching the run's PID and boot ID are accepted. Binary/ANSI
MESSAGE fields are decoded. Intervals crossing phase boundaries are excluded.
Render markers include discarded renders and exclude work before backing-store
acquisition. They have a different scope from DRM work per delivered frame.

`DENIA_GPU_STAGE_AUDIT=1` additionally enables the engine's invasive per-pass/draw
queries. The report labels this capture and preserves disjoint/abandoned sample
counts. `timings_usable` is false when queries are rejected or abandoned;
partial stage totals remain diagnostic observations and cannot rank stages.
The native and engine collectors share the GL disjoint acknowledgement flag,
so native GPU timings are also withheld when the concurrent stage capture has
rejected samples. A native-only capture has its own quality check.
These queries can perturb tiled GPUs; root-command spans overlap their
containing passes, and pixel counts are target/scissor extents. Do not sum nested
spans, treat these pixels as traffic, or compare this trace's throughput directly
with ordinary runs. Validate optimizations with both audit settings removed.

## Native CPU stacks

`tools/pad4-stage-perf.py` downloads signed Arch ARM packages, verifies them
against the tablet's installed package keyring, and extracts them privately.
It installs no system packages. `perf-runtime` is already staged on this tablet.

```sh
sudo python3 denial-benchmark run profile-scenario.json \
  --output results/profile-new \
  --perf /home/logix/denial-benchmark/perf-runtime/usr/bin/perf \
  --profile-phase workspace-settled --profile-phase workspace-interrupted

sudo python3 denial-benchmark profile-report results/profile-new \
  --perf /home/logix/denial-benchmark/perf-runtime/usr/bin/perf \
  --engine-symbols /home/logix/denial-benchmark/engine-symbols.so
```

This running kernel accepts `cycles` sampling; `cpu-clock` and `task-clock`
sampling return an unsupported-event error. The runner uses 199 Hz cycle
sampling with 8 KiB user stack dumps. Profiled runs are separate diagnostic
runs. Cycle shares depend on clock rate and are not percentages of elapsed CPU
time. Engine symbols were checked for byte-identical `.text` and matching build
ID before use. Release Dart AOT samples currently lack Dart function names;
a compatible Flutter profile build remains useful when Dart becomes the
bottleneck. Native stacks are already available without that build.

Profiler failures fail the run after saving that phase's timing/resource data
and the profiler's exit code. The runner still closes its applications and
cancels frame capture. Keep the failed capture for diagnosis.

## Shared-memory policy experiments

The tablet's `pad4-vm-tuning.service` enables shared-memory huge pages within
file size and sets THP allocation defragmentation to `never`. Measurements found
less SHM cleanup CPU and shorter animation raster times. This changes runtime
VM policy and requires no kernel image or flash. It also changes allocation
defragmentation for anonymous THP. Existing allocated pages retain their layout.

The service saves the previous settings in `/run/pad4-vm-tuning/state.json`.
Stopping it restores those settings; disabling it also prevents application on
the next boot:

```sh
sudo /usr/local/libexec/pad4-vm-tuning status
sudo systemctl disable --now pad4-vm-tuning.service
```

For a controlled experiment, stop the persistent service first and keep USB,
the native/engine/shell builds, output geometry, and background workload fixed.
The helper records policy, allocation/compaction counters and power state, runs
one command, and restores the original settings even when the command fails:

```sh
sudo python3 pad4-test-shmem-thp --policy within_size --defrag never \
  --record results/thp-trial-policy.json -- \
  python3 denial-benchmark run scenario.json --output results/thp-trial
```

`--size-kib 64` instead tests only the size-specific policy. It did not show a
useful benefit for the current Firefox workload. Always verify allocation
counters; a policy setting alone does not establish that clients use it.

For periodic frame gaps, `pad4-capture-frame-trace` records a finite private
ftrace instance around one command. It filters scheduler events to Denial,
Flutter, the render client and healthd, plus selected timer/CPU-control/RPMh/GPU/
display IRQs. It saves compressed trace data and per-CPU overrun counters, then
removes its own instance. The global tracer is unchanged. Tracing adds overhead;
use it for stall diagnosis and retain untraced runs for performance comparisons.
`--gpu` adds GPU submission, retirement, frequency, reclaim and fence-wait events.
`--buffer-kib 16384` increases the private per-CPU buffer when needed. The trace
record preserves all loss counters and `loss_detected`; a capture with overruns
cannot establish complete scheduler or GPU-job attribution.

```sh
sudo python3 pad4-test-cpu-frequency --khz 2112000 \
  --record results/trace-policy.json -- \
  python3 pad4-capture-frame-trace --output results/frames.trace.gz -- \
  python3 denial-benchmark run steady-scenario.json --output results/frames
```

For a session restart investigation, run `pad4-capture-session-transition` in an
independent root SSH connection before the authorized restart. It records a
finite heartbeat, blocked task stacks, IRQ counters, and CPU idle usage. It
does not restart anything itself. Keep the capture outside benchmark phases.

## Build and enable the shell API

`DesktopBenchmarkBinding` is in Denial's reference desktop plugin. The shell
opens `$XDG_RUNTIME_DIR/denial/benchmark.sock` only when the private runtime
directory contains `benchmark.enabled` at bundle load. Ordinary sessions do not
install benchmark frame callbacks or timers. The socket accepts one JSON object
and responds with one JSON object per connection. It rejects mutations while
locked. Requests are bounded and frame captures have a five-minute watchdog.

| Method | Parameters |
|---|---|
| `state` | None |
| `windows.close_all` | None |
| `window.move` | `object_id`, `monitor_id`, `workspace_id` |
| `workspace.switch` | `monitor_id`, `workspace_id` |
| `overview.set` | `monitor_id`, `open` |
| `frames.begin` / `frames.end` / `frames.cancel` | None |

Frame callbacks are active only during a requested capture. `frames.end` drains
release-engine batched timing reports for 1.6 s outside the resource measurement.
The runtime marker disappears on reboot. Removing it takes effect on the next
shell bundle load. Bundle activation can lock the tablet and requires the user
to unlock it before testing.

Build the native workload with recorded compiler/protocol provenance:

```sh
python3 tools/build-denial-render-workload --output out/my-render-client
python3 -m unittest discover -s tests -p test_denial_benchmark.py -v
```

The workload also accepts `SECONDS --static --scale=N` for a composition
control. `--static` retries an unchanged startup image until presentation
feedback acknowledges it, then sleeps until an actual resize;
`--scale=N` sets the Wayland buffer scale and multiplies buffer dimensions
while preserving logical window size (1–4, default 1). The configuration log
records both sizes. Match buffer resolution when comparing another client:
Firefox on this tablet uses scale 2. Keep the continuous workload as the main
120 Hz test, and install control builds at separate versioned paths.

For a static application's JSONL log, set `wait_for_presentation: true` in its
scenario entry to require the same presentation handshake as the continuous
render client before proceeding. Metadata retains the first presentation and
readiness time. `--carrier` adds a shared-memory parent with Firefox's shadow
padding, while `--border-alpha` gives the window partially transparent borders.
They can be combined to isolate surface composition from backdrop processing.
Control logs record carrier dimensions and every startup submission; verify
that no client submissions overlap a supposedly static measurement phase.

The benchmark shell reused the tablet's existing matched release engine and
compiler caches. Native performance and shutdown changes are deployed as
separate candidates with source archives and executable hashes. The service
launcher omits `--start-locked`. Previous bundle selection is retained as
`/home/logix/denial-benchmark/selection-before.json`. Switching back requires
the user's direction under Denial's deployment policy.
