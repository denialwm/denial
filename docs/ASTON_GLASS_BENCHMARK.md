# Aston glass profiling without a session restart

Current result: phase-controlled headless measurements support bounded reuse of
padded glass layer and material targets. Retaining them without timed expiry
removed the observed cleanup spike after glass removal, while keeping the
256 MiB extra-idle cap. A separate MSAA resolve change reduced nested-entry
frames above 10 ms from six to one in the matched direct-render comparison.
Cold-entry stalls remain; the final-copy confirmation has three such frames.
The full-shell candidate `profile-a972794f-47f44948` was accepted on Aston
by the user on 2026-09-05 after their manual reboot. The
authorized attempt to restart the old compositor lost device contact; remote
work stopped until the user reported recovery. Post-reboot process and library
hashes confirmed that compositor, engine and shell. A subsequent authorized
restart from this candidate reproduced the kernel hang: the shutdown mitigation
is insufficient. After another user-performed reboot, Aston is running the
release candidate `native-insets-arm64-release-00b84636-34dd6451`; see
[the native inset deployment record](MOBILE_APP_INSETS.md#validation-and-build-coupling).
See [the controlled result](#controlled-result-and-inactive-full-shell-candidate)
below for the measurements collected before activation. Earlier performance tables are historical: animation timing relative to
driver cache cleanup confounded several initially promising comparisons.

On 2026-09-05 the same clean engine revision and native changes were also
deployed to the x86-64 host `.188`, using **release mode** at the user's request.
The immutable artifact is `glass-release-a972794f-5f2f982806e1ebb4`. Engine,
shell AOT and native builds passed; all 39 packaged files passed checksum
verification. Direct greetd restart required one bounded retry after UWSM
cleanup. The new compositor PID was `4030` (previously `607`), on the same
boot, with verified engine/AOT mappings and native executable hash. Settings,
output configuration and shortcuts were unchanged by deployment. The existing
standalone Settings bundle was preserved.

`.188` selected Impeller OpenGLES, direct native output pools, and 4x offscreen
MSAA. Its driver lacks both render-to-texture extensions, so the requested
implicit-MSAA optimization correctly remained disabled; the other candidate
glass flags were active. One backing-store creation error appeared during
startup; it did not repeat in the inspected startup/session log, and the same
process continued handling the user's session. This observation does not
establish the error's cause. No agent visual validation or interactive test
events were performed. Deployment evidence is in
`/mnt/exty/denial-glass-artifacts-20260905/pc188-release-a972794f/activation-verified.json`;
the remote configuration and executable backups are under
`/var/lib/denial/lab-deployments/glass-release-a972794f-5f2f982806e1ebb4`.

The native Flutter runtime switch preserves Denial's process, Wayland clients,
DRM ownership and scanout buffers. Use this path for Dart-only investigations on
Aston while full compositor teardown remains capable of hanging the kernel.
It avoids that teardown; it does not establish or repair the kernel root cause.

`tools/denial-aston-live-ui.py` runs on Aston as root and activates an already
staged immutable profile bundle. It validates the manifest, device, boot,
compositor PID and executable, shell settings, AArch64 artifacts, and ICU.
The proposed engine must match an engine already mapped by the compositor.
New native engine revisions remain inactive until a session restart is suitable.

```sh
python3 /var/lib/denial/policy-updates/denial-aston-live-ui.py \
  /var/lib/denial/policy-updates/STAGE --check
python3 /var/lib/denial/policy-updates/denial-aston-live-ui.py \
  /var/lib/denial/policy-updates/STAGE
```

The stage contains `manifest.json` and `bundle/`, with the normal embedded
Flutter layout and a `workspace.path` matching the established profile bundle.
The manifest records `mode` (`profile`), `stage`, `boot_id`, `pid`,
`compositor_sha256`, `settings_sha256`, `engine_sha256`, `app_sha256`, and `files`
(all bundle-relative file paths prefixed with `bundle/`, mapped to SHA-256).
Bundle files and directories must have no write bits. The existing profile
bundle alias must already be a symlink. The helper records its previous target
and an activation receipt; it never overwrites mapped libraries.

If profile mode is already active, the helper switches Flutter to the packaged
UI and back to profile. It checks the same boot and PID throughout, waits for
native idle status, and checks the new AOT mapping and runtime generation.
A timeout or error stops the helper without restarting any service. Loss of
device contact is the boundary for remote work: retain local build evidence
and continue code work only.

## Framebuffer ownership during session handoff

Local review found a teardown operation that DRM pause does not suppress:
Smithay's GBM framebuffer destructor and Denial's PRIME framebuffer destructor
both call `DRM_IOCTL_MODE_RMFB`. In Aston's 7.1.8 kernel,
`drm_mode_rmfb()` schedules framebuffer removal and calls `flush_work()` when
other references remain. Removal can disable a plane still using that buffer.
Consequently, releasing DRM master alone does not avoid every implicit modeset.

Denial now owns both kinds of scanout framebuffer and releases them with
`DRM_IOCTL_MODE_CLOSEFB`. This drops userspace's framebuffer reference while an
active plane keeps its own reference until a replacement or explicit disable.
Inactive buffers are still freed. Pool retirement uses the same lifetime rule;
output removal continues to use its existing explicit plane clear. GBM keeps
ownership of its GEM handles, and the cross-device path closes only its PRIME
imports. Registration retains ADDFB2 modifiers and the previous single-plane
legacy ADDFB fallback. No dependency or engine source lock change is needed.
The API's handoff semantics are described in the
[kernel DRM UAPI documentation](https://docs.kernel.org/6.18/gpu/drm-uapi.html#drm-ioctl-mode-closefb).

Older kernels without CLOSEFB retain legacy RMFB behavior and emit a one-time
warning. Unexpected CLOSEFB errors are reported without attempting a second,
potentially disabling operation. Aston's checked kernel source implements
CLOSEFB. This removes a concrete blocking teardown path; it does **not** prove
that this path caused the observed kernel hang. A controlled exit from the
`47f44948` compositor on 2026-09-05 reproduced the hang despite this mitigation.
The ARM64 compositor build passed with the existing Flutter feature; its
initially accepted candidate used a profile engine.
The combined candidate `profile-a972794f-47f44948` was initially
staged inactive and all 36 payload files verified, with the same compositor PID,
boot, settings and startup configuration before and after staging.

The review also checked destruction against the locked Smithay revision. Its
paused atomic surfaces skip plane clearing, and its paused atomic device skips
restoring the captured state. Temporary mode-validation framebuffers still use
RMFB, but their commits are TEST_ONLY and never put those buffers on scanout.
Startup retains ownership of the Flutter runtime outside the event loop so
that errors or panics cannot destroy it before KMS is paused.

The kernel's final DRM-file close can invoke `drm_client_dev_restore`. Read-only
checks of Aston's running kernel ruled out a framebuffer-console client on this
boot: `CONFIG_DRM_FBDEV_EMULATION` and `CONFIG_DRM_CLIENT_LOG` are disabled,
`/proc/fb` is empty, and no framebuffer devices are registered. An extra daemon
holding a DRM descriptor is therefore not supported by this hypothesis. Other
driver work during context, buffer, or file release remains a possible cause.
The replacement binary also cannot change the old live process's first exit.

## Native workload

`GlassBenchmarkLayer` is inactive unless `DENIAL_GLASS_BENCHMARK_OUTPUT` is set
to an absolute JSON output path in an existing private directory. It does not
allocate a ticker or timer in a normal session. Preserve the user's glass,
opacity, output resolution, scale and refresh settings.

An unused output starts one finite measurement after ten seconds. An existing
output suppresses that automatic start. In both cases Denial exposes a private
Unix socket at the output path plus `.sock`. Its newline-delimited JSON methods
are `status`, `run` (optional simple `name`), and `cancel`. A run returns its
unique result path immediately; Denial's own ticker performs all motion.
This endpoint is a lab facility, not a general input-injection API.

Each run has four 15-second phases, with three seconds of warmup and twelve
seconds of measurement: hidden glass, stationary glass, a moving real quick
settings panel, and a moving backdrop beneath that panel. The settings panel
does not take focus or change global shell state. Foreground frame markers and
the moving backdrop have repaint boundaries so instrumentation does not
invalidate unrelated backdrop pixels. Results include raw Flutter frame timings
and ticker intervals, plus the exact glass settings and output geometry.

Collect compositor logs by PID (`journalctl -b _PID=PID -o cat`); service-unit
filtering can miss logs after user-session association. Profile VM timelines
can supply CPU spans without screenshots, input events or debugger pauses.
Never include the authenticated VM-service URI in reports.

## September 5, 2026 measurements

Aston ran at 1264×2780, scale 2, 120 Hz, with glass sigma 11, thickness 42,
quality 1 and its existing other settings. The baseline and Dart candidate
used the identical profile engine (`e7f32a3e1cec…`). The compositor remained PID
482 in boot `7adb51fb-08c9-4770-b60f-526d52fa93bf` throughout the runtime switches.

| Phase | Baseline fps | Candidate fps | Baseline raster p95 | Candidate raster p95 |
| --- | ---: | ---: | ---: | ---: |
| Hidden | 118.99 | 118.90 | 0.359 ms | 0.374 ms |
| Stationary | 119.00 | 118.73 | 0.373 ms | 0.354 ms |
| Moving panel | 56.96 | 69.01 | 26.217 ms | 7.383 ms |
| Moving backdrop | 59.56 | 59.51 | 7.199 ms | 7.342 ms |

A repeat of the same candidate measured 62.45 fps for panel motion with raster
p95 6.705 ms and maximum 10.014 ms; moving-backdrop raster p95 was 6.354 ms.
The frame cadence varies, but both runs remove the large baseline raster stalls.

The candidate paints panel controls after an empty backdrop filter under the
same outer clip. Engine counters confirm that this enables its existing direct
backdrop plan instead of the multisampled intermediate color layer. Stationary
glass already caches successfully. Changing glass still has a material cost,
and moving-backdrop performance remains unresolved.

These are instrumented measurements, not visual validation. General render
auditing currently enables per-stage GLES timestamp queries in the baseline
engine. The locally inspected Freedreno driver warns that those timestamps
represent the last tile, so nested stage sums are not a reliable whole-frame
GPU cost breakdown. Query overhead has not yet been isolated. Prefer the
measured frame cadence and CPU raster durations for this comparison.

Offline profile engine candidates defer persistent snapshots until changing
backdrops settle, skip refraction and duplicate texture samples in flat glass
interiors, and require `DENIA_GPU_STAGE_AUDIT=1` for the invasive per-draw GPU
queries. Ordinary `DENIA_RENDER_AUDIT` diagnostics remain available separately.
These native candidates have not been activated in the Aston desktop session.
The isolated comparison below measures them without replacing that runtime.

Raw artifacts and immutable candidate builds are retained under
`/mnt/development/denial-ace3/work/glass-performance-20260905/`.

## Isolated native engine comparison

`denial-glass-benchmark` is a separate Denial executable using the same
`denial-flutter-engine::EngineHost`. It opens `/dev/dri/renderD128` through
GBM/EGL and renders into a private framebuffer. It never acquires DRM master,
configures an output, connects to Wayland, sends input, or captures pixels.
The supplied compositor PID, process start time and boot ID must remain stable.
Its lifetime is bounded, including a watchdog which exits only the worker.
Before starting any threads, it copies the compositor's CPU affinity to itself.
It leaves the parent's affinity and policy untouched. Its raster thread uses
ordinary scheduling by default; `--desktop-render-priorities` selects the
matching desktop context and thread priorities described below.

Build this executable with Cargo's `flutter` feature and assemble
`lib/glass_offscreen_benchmark.dart` as a profile AOT bundle. Put the same app,
assets and ICU beside each profile engine revision being compared; use fresh
worker processes so process-global engine state cannot cross revisions.
The separate Dart entry point exercises the actual `ShellBackdropBlur` with
the user's copied appearance settings and a representative control panel.
It starts no shell services and writes no user settings.
Workload version 2 uses the foreground frame marker only during stationary
glass; motion in the other phases already drives rendering.

```sh
denial-glass-benchmark BUNDLE SETTINGS_COPY RESULT.json COMPOSITOR_PID BOOT_ID
```

The four phases cover stationary glass, moving glass with separate foreground
controls, a moving backdrop, and moving glass with nested controls. Motion and
timing collection run inside Denial. Each frame finishes with `glFinish`, so
the measurements include GPU completion. Compare these results only against
other runs of this worker: they exclude KMS scheduling and are not directly
comparable to the live shell's frame rate. No image is read back or displayed.

By default, both render-audit environment flags are disabled only in the worker.
`--gpu-stage-audit` enables them in that worker for an otherwise identical
comparison of instrumentation overhead. Results include raw Dart phase timings
and a separate `.native.json` file with engine/app/settings hashes and complete
frame durations. The active compositor's environment and engine remain intact.
Exact frame damage is collected from the root surface's standard present
callback. The earlier external-view callback identifies the physical target;
its paint region is not the exact damage signal used by the desktop.

The earliest exploratory worker finished GPU work in both presentation
callbacks and used the external-view paint region. Its absolute timings and
damage figures are not comparable to the corrected worker's results. Historical
numbers below describe how the investigation progressed; the final comparisons
use the corrected callback sequence and one GPU completion wait per frame.

A later code audit found another gap in those historical measurements: the
worker's root color FBO lacked the desktop's D24S8 depth/stencil attachment.
The engine wraps host-supplied attachments with placeholder descriptors; it
does not allocate that storage for the host. Root-target version 2 now supplies
and verifies the attachment, and records depth bits, stencil bits and samples.
Numbers from the earlier root target remain exploratory until their focused
comparison is repeated with this complete framebuffer. The actual desktop
already supplies D24S8 and is unaffected by this worker correction.

Repeating the same-engine pooling comparison with verified 24-bit depth,
8-bit stencil and single-sample root storage confirmed the long-frame gain:

| Nested motion, complete root target | Exact-size targets | Pooled targets |
| --- | ---: | ---: |
| Raster median | 3.803 ms | 3.938 ms |
| Raster p95 | 7.959 ms | 5.095 ms |
| Raster p99 | 24.359 ms | 5.382 ms |
| Maximum measured raster time | 85.249 ms | 6.147 ms |
| Measured frames above 10 ms | 58 | 0 |
| Measured frames above 33 ms | 11 | 0 |
| Average sampled GPU frequency | 499 MHz | 437 MHz |

Both runs used the same engine, app, appearance settings, desktop contexts and
thread priorities, with native fence deadlines and normal Mesa driver
threading. Only the pooling flag differed. The complete root attachment raised
stationary median time to about 2 ms at 124.8 MHz; the older color-only root
understated that cost. Use this pair as the primary pooling comparison.

The worker also supports `--root-storage=texture|linear|compressed`. The first
uses private RGBA8 texture storage. The latter choices import a GBM XR24 image
with the explicitly requested linear or Qualcomm compressed modifier. All
three have the same D24S8 root attachment. Allocation uses the render node only,
with no KMS framebuffer or display commit. The report verifies the actual
modifier rather than accepting a silent fallback.

The imported-root pair used the same pooled engine and worker, AOT, settings,
desktop priorities and fence deadlines. Only the storage argument changed:

| Measurement | Linear XR24 | Compressed XR24 |
| --- | ---: | ---: |
| Stationary raster median | 4.649 ms | 2.002 ms |
| Moving-panel raster median | 4.454 ms | 4.050 ms |
| Moving-panel average GPU frequency | 510 MHz | 272 MHz |
| Moving-backdrop average GPU frequency | 552 MHz | 332 MHz |
| Nested raster p95 | 5.571 ms | 5.204 ms |
| Maximum nested raster time | 82.206 ms | 31.171 ms |
| Nested frames above 10 ms | 17 | 24 |
| Nested average GPU frequency | 619 MHz | 449 MHz |

These results expose residual long frames with imported storage, despite
pooling. They limit the earlier private-RGBA8 result: pooling does not yet
establish smooth behavior for display buffers. Linear storage also requires
substantially higher GPU clocks for this workload. This isolates root storage,
not the complete offscreen-blit setting: it excludes the final native shader
copy and KMS, and uses one fixed target instead of the desktop's rotating pool.
Both reports recorded zero fence and thread-priority errors. A diagnostic
single-thread trace reduced nested maximum to 8.373 ms, but repeating that
configuration without tracing restored 24 frames above 10 ms and a 31.513 ms
maximum. Driver threading alone is therefore not a reliable fix; the trace
perturbs the remaining behavior. A separate opt-in resource timing probe
records slow creation/deletion calls and allocation counts without GPU queries,
extra synchronization or VM timeline recording. It is diagnostic only.

With that lightweight probe enabled, nested motion averaged about 303 texture
storage allocations and 14 renderbuffer allocations per one-second window,
covering about 116 million new pixel positions. Stationary glass and the moving
backdrop needed no new texture storage in their measured windows. The probe
again changed the timing of the outliers, so its allocation counts are useful
but its smooth trace does not identify the uninstrumented slow call.

An experiment drew the glass shader directly into the existing multisampled
child layer. An untraced, same-engine comparison rejected that approach: nested
maximum increased from 7.437 to 57.987 ms, frames above 10 ms increased from zero
to 18, and average GPU frequency rose from 455 to 544 MHz. The experiment was
reverted. The healthy untraced control also shows that imported-root outliers
vary between runs; enabling tracing is not their only influence.

The replacement experiment (`--pooled-glass-material` in its archived worker)
retained the existing single-sample material pass. It rounded allocations to
128-pixel sizes for reuse. The original geometry and source rectangle remain
unchanged, and strict source-rectangle sampling clamps to the original edge
texel centers. This excludes allocation padding even at fractional translations.
Canvas permits this only for immediate, uncached GLES glass in multisampled
child layers without alpha thresholds or restore image/color filters.
Persistent snapshots kept their existing path. Its matched untraced comparison
also rejected it: nested p99 increased from 5.697 to 15.256 ms, and frames above
10 ms increased from 2 to 24, with similar average GPU clocks (415/413 MHz).
It was reverted without being activated in the desktop. The original MSAA
color-target pooling remains separate from this rejected material experiment.

The worker now accepts `--root-format=xrgb|xbgr|argb|abgr` for GBM storage and
records the requested DRM fourcc plus the actual OpenGL texture internal format.
This changes only the headless root allocation. The live compositor's formats
and output configuration remain unchanged.

The initial exploratory runs completed with the original compositor unchanged.
The worker's graphics descriptors referenced only `/dev/dri/renderD128`.
With detailed auditing disabled in both workers, the combined engine candidate
improved direct-motion frame cadence from 73.37 to 82.27 fps and raster p95
from 30.181 to 22.869 ms. Nested-motion p95 did not improve (50.233 versus
52.697 ms), so this candidate does not yet resolve the remaining stalls.

Enabling the detailed queries on the baseline engine changed direct-motion
cadence to 109.24 fps and p95 to 9.628 ms. It improved rather than simply added
cost to that run. Frequency scaling and driver submission behavior therefore
need separating before attributing a cost to individual passes. The worker
now also samples GPU frequency, the raster thread's CPU/frequency and its
scheduling policy every 250 ms, without changing any of them.

Those first runs allowed the worker onto efficiency cores, unlike the actual
shell's CPU affinity (cores 3–7). A repeat without auditing already reached
106.83 fps for direct motion, so the initial query-related speedup is not a
stable result. After the worker inherited the shell's eligible CPUs, the
baseline measured 115.33 fps / 8.735 ms raster p95 for direct motion, 115.58 fps /
8.146 ms for a moving backdrop, and 102.25 fps / 14.495 ms for nested motion.
Use matched-affinity runs for subsequent engine comparisons; the earlier
numbers do not establish an engine regression or improvement.

`--direct-glass` sets `DENIA_GLASS_DIRECT_MATERIAL=1` only in the worker for
engines containing the experimental direct material path. It is disabled by
default. The experiment skips the final full-size material texture only for
uncached, direct GLES glass without an alpha threshold. Persistent snapshots,
transparent-window threshold composition and nested color layers keep their
existing materialized result. Visual equivalence remains user-owned validation.

A same-engine comparison measured moving-backdrop median raster time of
6.314 ms with direct material rendering versus 7.242 ms without it; p95 was
7.592 versus 8.126 ms. Both sampled an average GPU frequency of 348 MHz.
This is a modest isolated improvement, not proof of desktop frame cadence.

`--inward-glass-bounds` enables another experimental engine option. For a
complete axis-aligned, non-threshold material, its source bounds account for
refraction toward the material centre, including rays which cross the centre,
plus the full Gaussian halo. Cropped and rotated materials retain the current
general bound. This option is also disabled by default.

`--fence-only` and `--fence-deadline` compare native EGL fence export with and
without `SYNC_IOC_SET_DEADLINE` on the worker's own sync file. The deadline is
the engine's absolute monotonic presentation target. Both modes retain the
same final GPU completion wait; neither writes clock or governor settings.
The output records successful exports, accepted hints and errors. These modes
are mutually exclusive and disabled by default.

The kernel documents missed-vblank feedback as a weakness of utilization-only
GPU frequency scaling and provides fence deadline hints for that case:
[DMA fence deadline hints](https://docs.kernel.org/6.11/driver-api/dma-buf.html#dma-fence-deadline-hints).
Aston's running 7.1.8 kernel includes the MSM deadline callback. Its source
schedules a conditional GPU boost three milliseconds before the hinted
deadline. A successful ioctl alone does not establish a performance benefit.

With workload version 2 and the desktop's presentation callback sequence,
the same engine/app/CPU affinity measured the following. Both runs exported
native fences; only the second supplied deadlines. Inward bounds were off.

| Phase | Control median | Deadline median | Control p95 | Deadline p95 |
| --- | ---: | ---: | ---: | ---: |
| Stationary | 1.207 ms | 1.222 ms | 1.830 ms | 1.782 ms |
| Moving panel | 4.724 ms | 3.649 ms | 6.066 ms | 5.052 ms |
| Moving backdrop | 5.514 ms | 3.635 ms | 6.040 ms | 5.390 ms |
| Nested panel | 5.304 ms | 4.037 ms | 6.984 ms | 5.404 ms |

Moving-backdrop average sampled GPU frequency rose from 220 to 487 MHz;
stationary glass remained at 124.8 MHz. The change conveys frame urgency to
the existing governor. It does not reduce the shader's amount of work or
establish the desktop's resulting frame rate.

The first hint run accepted 6,803 deadlines but omitted 51 frames for which
Flutter supplied zero. The engine intentionally omits a target already missed
before rasterization. The shared compositor/worker helper now uses the current
monotonic time for those urgent frames. It disables further attempts on a
renderer if its kernel rejects this optional ioctl; normal presentation and
fence ownership continue unchanged.

The compositor carries the target through `PendingOutputPresentation` and
applies the hint to the existing exported render fence before publishing it
to the output broker. No additional GL flush or native fence is created in
the desktop. The ARM64 compositor build is retained as a local artifact and
has not replaced the running compositor during this investigation.

The worker run using that shared helper accepted all 6,675 exported fences,
including 119 urgent deadlines, with no errors. Moving-backdrop median raster
time was 3.624 ms and stationary GPU frequency remained at 124.8 MHz. Nested
glass still showed intermittent stalls (raster p95 18.927 ms), so deadline
hints do not resolve every source of raster latency.

The inward-bounds experiment lowered moving-backdrop damage from 60.65% to
50.06%, but its nested-motion run reached raster p95 29.309 ms compared with
5.404 ms in the preceding run. Later stalls without the bounds option show
that this variation cannot be attributed to bounds alone. It remains disabled
without a demonstrated, repeatable benefit and user visual validation.

`--timeline` asks the offscreen Dart entry point to enable CPU timeline streams
through its own loopback VM service. After animation and timing collection stop,
it writes a bounded trace to `OUTPUT.json.timeline.json`. The result records
whether capture succeeded; VM service addresses and authentication tokens are
never included. Workload version 3 also records each frame's vsync and raster
start time for correlation. The scene and glass settings are unchanged.

Tracing is optional and can affect frame timings. Use its event spans to locate
work, then compare performance with tracing disabled. It creates no visible
window or UI events and requires no change to the resident compositor.

The first successful trace retained 32,527 events covering the end of nested
motion. A 21.276 ms raster frame spent 20.025 ms in `SurfaceFrame::Submit`;
its command encoding took 0.678 ms and individual texture initialization calls
stayed below 0.2 ms. This capture locates that spike in submission/completion,
rather than widget layout or synchronous texture initialization. The worker
also records wall and thread CPU time separately for native fence preparation
and its final GPU completion wait, to distinguish those submission stages.

Granular fence measurements then located 93 of 94 slow preparations in
`eglCreateSync`, which includes flushing queued Mesa work. Some stalls spent
most of their duration on the calling CPU; others waited. Native fence export,
destruction and the deadline ioctl were short in those samples. This does not
yet identify the expensive operation inside the driver.

`--desktop-render-priorities` enables a closer desktop comparison: it reuses
Denial's shared EGL context helper, including high GPU priority and explicit
flush control, and assigns the worker's Flutter UI/raster threads the same
lowest realtime priority as the identified live compositor. The worker's
platform loop keeps normal scheduling. Failures are recorded, and the parent
process and its thread policies are never modified. Earlier runs used ordinary
thread/GPU priorities, despite matching the desktop's CPU affinity.

`--driver-single-thread` sets `GALLIUM_THREAD=0` before creating this worker's
EGL contexts. It isolates Mesa's queued driver handoff from the calling raster
thread; it does not change the live compositor's environment. The native
report records the option and effective environment value. It is a diagnostic
comparison, not a recommended desktop setting without measured benefit.

With desktop priorities, the single-thread experiment reduced nested fence
preparation p95 from 3.730 ms to 0.383 ms. Whole-frame raster p99 fell from
34.335 ms to 12.347 ms in that pair, while raster p95 was similar (5.878 versus
5.986 ms) and occasional long frames remained. Removing the handoff can move
CPU work into earlier GL calls, so fence timing alone cannot establish a fix.

The single-thread trace exposed recurring whole-second stalls in resource
retirement: a 61.032 ms frame spent 57.315 ms in `ConsolidateHandles`, while
its GL command execution took 0.589 ms. Two other frames spent 51.257 and
46.001 ms in handle consolidation. Mesa 26.1.2's Freedreno buffer cache expires
old buffers on whole monotonic seconds; this matches the observed cadence,
although a driver stack capture is still needed to name the precise call.

The experimental `--pooled-glass-targets` engine option rounds temporary
multisampled glass color targets up to 128-pixel allocation sizes. The original
coverage, origin and clip remain unchanged, and restoration explicitly crops
to the original pixel region. This aims to reduce allocation/retirement churn
during clipped motion. It applies only to GLES glass layers without alpha
thresholds or restore image/color filters, and is disabled by default. No
visual equivalence is established merely by building it.

The matched on/off comparison used the same profile engine
`1abfc4baf9c851d5737977709ca242ca0cb43fdf`, workload version 3, desktop
contexts/priorities, direct material rendering and fence deadlines. Mesa driver
threading stayed enabled; tracing and inward bounds stayed disabled.

| Nested-motion measurement | Exact-size targets | Pooled targets |
| --- | ---: | ---: |
| Raster median | 3.874 ms | 3.583 ms |
| Raster p95 | 6.323 ms | 4.993 ms |
| Raster p99 | 37.106 ms | 5.601 ms |
| Maximum measured raster time | 53.625 ms | 8.411 ms |
| Measured frames above 10 ms | 51 | 0 |
| Measured frames above 33 ms | 14 | 0 |
| Average sampled GPU frequency | 374 MHz | 358 MHz |

Stationary glass remained at 124.8 MHz in both runs. This pair supports reduced
allocation/retirement churn as a substantial improvement for this workload;
it does not establish every shell scene's behavior or visual equivalence.

A further run put the original pinned profile engine (`e7f32a3e1cec…`) under
the same corrected worker, AOT image, settings, desktop priorities and native
deadline hints. The old engine ignores the new direct-material/pooling flags.
Compared with the complete candidate, this measures the combined engine changes
on top of the already separated Dart foreground, not the original shell UI.

| Measurement | Pinned engine | Complete candidate |
| --- | ---: | ---: |
| Moving-panel raster p95 | 5.174 ms | 4.823 ms |
| Moving-backdrop raster median | 4.196 ms | 4.685 ms |
| Moving-backdrop raster p95 | 4.509 ms | 4.855 ms |
| Nested raster p95 | 5.612 ms | 4.993 ms |
| Nested raster p99 | 12.122 ms | 5.601 ms |
| Maximum nested raster time | 63.803 ms | 8.411 ms |

The candidate improves long-frame behavior, but this comparison does not show
a uniform throughput improvement. Sampled GPU and CPU frequencies also differ;
for the moving backdrop they averaged 301/1026 MHz originally and 286/915 MHz
with the candidate. Both engines retained 124.8 MHz for stationary glass.
Both native reports recorded zero fence errors and zero priority failures.

A follow-up pooled trace, with driver threading disabled only to expose GL
retirement on the raster thread, measured `ConsolidateHandles` median 19 us,
p95 36 us and maximum 10.450 ms. The earlier unpooled diagnostic trace reached
57.315 ms. A remaining 10.017 ms texture initialization also appeared. Pooling
greatly reduced these stalls but does not eliminate every allocation delay.
Tracing and driver-thread changes make this a diagnostic comparison, separate
from the matched performance table above.

The complete shell candidate is packaged with the profile engine, the actual
shell AOT image and the compositor deadline helper. It is prepared but not
armed. The running compositor remains on its resident engine; no native
compositor restart, KMS teardown or experimental-engine activation was needed
for the offscreen investigation. Glass settings are unchanged. The restart
hang itself has not been fixed or reproduced deliberately.

A separate native teardown review found that the event loop owned the Flutter
runtime. Returning an error or unwinding from that loop could therefore destroy
the engine before startup's existing last-resort DRM handoff. The loop now
borrows the runtime from startup instead. When an exceptional exit leaves a
runtime present, startup retains it through the DRM handoff; normal orderly
shutdown keeps its existing sequence. The ARM64 compositor build passes. This
closes an ownership-order gap without establishing the cause of the observed
kernel hang, and has not been activated in the running session.

### Animation phase and driver cache cleanup

A later audit identified a timing confound in the earlier performance pairs.
The worker animation repeats every two seconds, while Mesa 26.1.2
`src/freedreno/drm/freedreno_bo_cache.c` ages cached buffers using whole
`CLOCK_MONOTONIC` seconds and cleans them once per second. Across the existing
runs, nested animation starts near 0.1 or 0.85 seconds frequently coincided
with long frames; starts around 0.4–0.7 seconds were usually much smoother.
This is a correlation, not yet proof that cache expiry causes the stalls.

Consequently, the earlier pooling, direct-subpass, material-padding, root-format
and tracing comparisons cannot independently establish causality when their
animation phases differ. Their recorded timings remain valid observations,
but improvement/regression claims based solely on those pairs are provisional.
The rejected experiments remain reverted and no additional engine is activated.

Workload version 4 adds `--start-phase-us=0..999999` in the native worker.
The Dart workload retains its three-second startup minimum, waits for the
requested fractional monotonic second, and records requested, scheduled and
actual first-frame times. The scene, two-second animation and measurement
windows are unchanged. This permits phase-matched comparisons while checking
that scheduler delay did not miss the intended window.

The first controlled pair used the same `b9f284e1` profile engine, worker, AOT
image, compressed XRGB target and settings, with pooling enabled. Actual starts
were 112.3 and 563.6 ms within the monotonic second. The former produced 24 nested
frames above 10 ms, maximum 50.791 ms; the latter produced none, maximum 9.144 ms.
Thus start timing alone substantially changes the result. The alignment with
Mesa's cleanup clock remains a driver hypothesis pending attribution of its
individual allocation/retirement calls. A phase-matched pooling comparison
is the next control.

The phase-matched pooling control subsequently placed both nested starts near
0.115 seconds. With pooling disabled, nested p95 was 10.874 ms, p99 27.071 ms
and maximum 91.431 ms. With pooling enabled these were 5.441, 17.574 and
50.791 ms. Pooling therefore still helps at the unfavorable phase, although
the periodic stalls remain and the earlier smooth run overstated their removal.
All three controlled runs completed with zero fence/priority errors and the
same running compositor PID and boot ID.

With resource logging enabled and driver threading disabled, the controlled
unfavorable phase still produced 24 nested frames above 10 ms. Texture
retirement took roughly 9–19 ms at whole-second boundaries; initializing padded
1280×1024 and 1280×1152 textures also took 8.5–10.3 ms. The nested phase averaged
303 texture and 14 renderbuffer storage allocations per second. These are
diagnostic timings, not a same-configuration throughput comparison.

Candidate `6ae9cfbe` adds optional `DENIA_GLASS_RETAIN_TARGETS=1` retention for
GLES MSAA targets labeled specifically by the padded glass-layer path. The
existing cache still handles active targets and its ordinary four-frame
retention. Additional idle targets remain eligible for 2.5 seconds under a
256 MiB estimated attachment-storage budget, with the most recently used
retained first. Aliased depth/stencil and resolve references count only once;
multisample storage is included. This is a bounded allocation-reuse experiment,
not yet a validated shell change. It changes no coordinates, filtering, clips
or stored settings. The native worker exposes `--retain-glass-targets` and
records its state; the live compositor is not activated with this engine.

The phase-matched `6ae9cfbe` retention comparison completed: with retention
disabled, nested p99 was 17.460 ms, maximum 44.052 ms and 24 frames exceeded
10 ms. Enabled, those values were 6.383 ms, 24.355 ms and 11 frames. All remaining
long frames started within the first 8 ms of a monotonic second. Thus large
target retention reduces the stalls but leaves periodic retirement work.

Candidate `2e168e69` therefore revisits temporary material-target padding under
the now-controlled timing. It combines strict cropping to the original texel
rectangle with retention of that material target under the same shared 256 MiB
idle budget. Both features remain opt-in. The earlier unaligned material pair
is not treated as proof for or against this combined change.

Workload version 5 adds a final `glass_removed` phase with no warmup exclusion.
A later source audit found that it removed the marker as well as the glass,
leaving only its ticker running over a static scene. Its timings therefore
describe idle post-removal work and do not establish active raster cleanup.
Version 6 keeps the marker visible after
glass disappears. The original four phase contents and timings remain unchanged.
The complete workload still fits the existing native worker lifetime bound.

### Controlled result and inactive full-shell candidate

The combined candidate passed the unfavorable 0.1-second start phase with the
same engine, worker and version-5 AOT image in both runs. Target retention was
enabled in both; only material padding/reuse differed.

| Nested measurement | Material reuse off | Material reuse on |
| --- | ---: | ---: |
| Actual start within monotonic second | 112.186 ms | 111.700 ms |
| Raster median | 4.075 ms | 3.935 ms |
| Raster p95 | 5.154 ms | 4.857 ms |
| Raster p99 | 7.271 ms | 5.330 ms |
| Maximum raster time | 13.306 ms | 6.949 ms |
| Frames above 10 ms | 11 | 0 |

In version 5's idle post-removal phase, with no warmup exclusion, the
maximum was 2.662 ms with material reuse off and 4.120 ms with
it on. Neither run had a removal frame above 10 ms. The moving-backdrop phase
still had one 12–14 ms boundary frame in each run; the result is not a claim
that every frame in every scene meets a 120 Hz presentation deadline.

A final allocation diagnostic recorded about 5.4 million allocated pixel
positions per roughly one-second nested count window, compared with 115.9
million in the earlier unfavorable-phase diagnostic: about 95% less. Texture
storage calls fell from about 303 to 185 per window and renderbuffer storage
from 14.2 to 1.1. No resource call exceeded the diagnostic's 2 ms logging
threshold in any measured phase. Stationary, moving-backdrop and glass-removed
phases allocated no texture/renderbuffer storage during their complete count
windows. The version-5 removal phase could skip rendering, so it does not
prove that deferred cache retirement was exercised during active painting. These are allocation counts; the earlier diagnostic disabled driver
threading, so its call durations are not a matched throughput comparison.

The complete **inactive** shell candidate is staged at
`/var/lib/denial/engine-candidates/profile-2e168e69-47f44948`. It contains the
actual shell AOT `660c74d4…`, profile engine `9894a661…` from `2e168e69`, and
compositor `47f44948…` with the exceptional-exit ownership fix and non-disabling
framebuffer cleanup described above. The previous `3c1049bb` and `0eee9699` candidates are
retained separately. The current manifest
enables direct material, padded layers, padded material and bounded target
retention, and disables diagnostic logging. All 36 payload files were verified.

No session restart or activation occurred. The live compositor remains PID 482
on the same boot with unchanged settings and startup configuration. The kernel
journal contained no fault/hang/timeout/lockup/stall matches during the controlled
runs. This avoids exercising the problematic full-session teardown; it does
not establish that the kernel restart hang itself is fixed. Visual validation
remains user-owned and outstanding. The source lock was not advanced.


### Native final-copy comparison

The worker now calls the compositor's exact scene-to-scanout shader-copy
routine. Its GL state save/restore and draw sequence were extracted unchanged
into `gl_resources::copy_to_scanout`; the shader compiler is shared too.
`--scanout-copy=on|off` requires a linear XR24 source. Both values retain the
same compressed XR24 destination and compiled program; only the draw differs.
The copy uses ordinary texture sampling, never `glBlitFramebuffer`.

Three runs used worker `c4353f53…`, profile engine `9894a661…` from `2e168e69`,
workload-v5 AOT `6fe8d964…`, the same settings and enabled reuse features,
normal driver threading, and a requested start phase of 100,000 us. Actual
start fractions were 117,835 us (copy on), 109,601 us (copy off), and 110,044 us
(direct compressed). The existing single end-of-frame GPU completion includes
the copy; there is no extra GPU wait or timestamp query around it.

| Nested-glass path | Median | p99 | Maximum | Frames >10 ms | Average GPU clock |
| --- | ---: | ---: | ---: | ---: | ---: |
| Linear source, copy disabled | 4.397 ms | 5.330 ms | 8.371 ms | 0 | 574.4 MHz |
| Linear source plus compressed copy | 4.611 ms | 5.629 ms | 7.072 ms | 0 | 615.1 MHz |
| Direct compressed target | 4.053 ms | 5.547 ms | 7.023 ms | 0 | 388.7 MHz |

The full-copy path did not reintroduce the recurring nested-motion stalls.
The direct compressed path required a substantially lower average GPU clock
in this workload. Because the governor selected different frequencies, median
frame-time differences are not fixed-cost measurements of the copy alone.

In version 5's idle phase after glass disappeared, both linear runs held 124.8 MHz. Median time was
1.842 ms with the copy and 0.500 ms without it, a 1.342 ms difference; their
maxima were 2.861 and 2.963 ms. Direct compressed rendering measured 0.556 ms
median and 2.342 ms maximum. The copy's CPU submission took about 7–12 us
median; those CPU times do not measure the GPU's copy duration. All three runs
had zero fence and priority errors and no frames above 10 ms after glass was
removed. Each retained the previously observed single roughly 15 ms frame at
a moving-backdrop measurement boundary.

These results cover the final native copy as well as root storage. They still
use a fixed render target, synchronous completion and synthetic frame pacing,
so rotating desktop pools and actual KMS presentation remain outside this
comparison. No display state, settings, engine source lock or live session
changed. Both native binaries compiled for ARM64. The current full-shell
candidate `profile-2e168e69-47f44948` includes the shared copy routine and the
CLOSEFB ownership change; it remains staged inactive with all 36 payload files
verified. The profile engine and actual shell AOT are unchanged from the
previous candidate.


### Rotating pools and corrected active-removal phase

The worker can now select `--root-buffers=1|3`. Each slot has independent
storage and repair history, using Denial's existing bounded `DamageRegion`
implementation and the compositor's rule for accumulating changes in other
buffers. It rotates after GPU completion; this models buffer age and storage,
while actual KMS ownership and asynchronous queueing remain outside the test.
The copy path has three destination buffers and one shared shader program.
The reports verify distinct FBOs/textures, D24S8 attachments, and balanced
presentation counts for every slot.

With workload v5, nested-motion maxima were 6.908 ms with one compressed
buffer, 7.351 ms with three, and 7.797 ms with three linear buffers plus the
compressed copy. All had zero nested frames above 10 ms. Repair grew as
expected: nested damage was about 41.9% of the frame, while three-buffer repair
covered about 42.2%. The final v5 phase was idle, as corrected above.

Workload v6 keeps its marker visible after removing glass. In both corrected
three-buffer runs, every sampled final-phase buffer-damage region was nonempty.
The original four phases are unchanged; nested maxima remained 7.582 ms for
direct compressed rendering and 7.091 ms with the copy.

| Active painting after glass removal | Direct compressed | Linear plus copy |
| --- | ---: | ---: |
| Median | 2.052 ms | 3.697 ms |
| p99 | 2.773 ms | 4.328 ms |
| Maximum | 13.026 ms | 10.719 ms |
| Frames above 10 ms | 1 | 1 |
| Slow frame's offset from removal | 1.184315 s | 1.184298 s |
| CPU time in slow fence preparation | 11.237 ms | 8.627 ms |

The slow CPU span occurs inside EGL fence creation, while the subsequent GPU
completion wait is only 1.569/1.871 ms. Its repeatable offset makes delayed
resource retirement the leading hypothesis. It is not proof of the individual
driver operation responsible. The cache currently expires retained targets
2.5 seconds after their last use, which can precede glass removal by part of
an animation cycle.

An isolated profile-engine experiment adds opt-in
`DENIA_GLASS_RETAIN_TARGETS_BY_BUDGET=1`: retain eligible idle targets under the
same 256 MiB estimated-attachment budget, evicting by recency when space is
needed, without a timer expiry. This trades longer bounded retention for
avoiding timed disposal after glass disappears. It does not add an operating
system memory-pressure listener.

The matched comparison uses profile engine `24f6b3c2`, worker `d533c228`,
the same corrected v6 AOT, three rotating buffers, the 100 ms start phase,
and normal Mesa threading. Only the retention-policy flag changes between
the two direct-render runs. The copy run enables the same policy and uses
the production shader-copy routine.

| Active painting after removal | Timed expiry, direct | Budget only, direct | Budget only, copy |
| --- | ---: | ---: | ---: |
| Median | 1.993 ms | 1.971 ms | 3.711 ms |
| p99 | 2.682 ms | 2.672 ms | 4.273 ms |
| Maximum | 9.552 ms | 5.297 ms | 4.487 ms |
| Slow fence-preparation records (at least 2 ms) | 1 | 0 | 0 |

The timed-expiry peak occurs 1.188 s after removal and spends 8.57 ms of CPU
time inside EGL fence creation. Budget-only direct rendering peaks much later,
at 9.207 s, with no recorded slow fence call. Every final-phase buffer repair
remains nonempty. This supports the retention change as a fix for this specific
cleanup spike; it does not prove the behavior of every shell transition.

The saved native completion spans also cover the first three seconds excluded
from the Dart phase summaries. Pairing them with presentation records shows
that entry into nested glass still has three/four frames above 10 ms with timed
expiry/budget-only retention. Their maxima are 12.565/16.249 ms; the copy run
has five such frames and peaks at 15.386 ms. These are native wall spans from
making the render context current through GPU completion, not Dart raster
durations. Thus steady-state improvements must not be reported as eliminating
all transition stalls.

One focused diagnostic run uses the same artifacts with allocation logging
enabled and Mesa threading disabled, solely to attribute calls. It records
10.059 ms in texture storage at 1280×640 immediately on nested entry, then
4.730 ms at 1280×384 about 180 ms later. The later native pauses around
1.0–1.3 seconds remain, but no individual instrumented allocation/deletion call
there exceeds 2 ms. Disabling driver threading shifts their cost out of fence
creation. This does not identify the remaining driver work, and those diagnostic
timings must not be used as an ordinary performance comparison.

The updated actual-shell candidate is staged inactive at
`/var/lib/denial/engine-candidates/profile-24f6b3c2-47f44948`. Its profile engine
is `020eaedac841c4d5268bbf5c0b98137c1d1b56d4da6be5fac207513d96b9782d`.
It keeps the actual shell AOT `660c74d4` and native compositor `47f44948`,
including CLOSEFB ownership and the shared final-copy routine. All 36 payload
hashes were verified. Normal driver threading and the budget-only policy are
recorded in its manifest, with diagnostic logging disabled. No startup
configuration changed; the original process, boot and settings remain intact.
The prior `2e168e69` candidate is retained separately. Neither candidate's native
teardown mitigation has been exercised by restarting Aston during this work.

### Remaining entry stalls: explicit MSAA resolves

A broader opt-in GL-call timer in profile engine `b7bbfb42` closes the gap in
the allocation-only probe. It times existing function calls without adding GL
queries, waits or readback, logs calls taking at least 2 ms, and limits output
to 512 records. With diagnostics disabled, it does not read a clock. The
diagnostic run retains the same v6 workload, three compressed buffers and
budget-only target retention, with Mesa threading disabled for attribution.

Of twelve slow-call records, six nested-entry calls are `glBlitFramebuffer`.
The calls at 0.999, 1.085, 1.189 and 1.309 seconds take 6.335, 7.613, 8.937
and 8.774 ms respectively. Those are Flutter's explicit MSAA resolves, separate
from Denial's shared shader copy into scanout storage. Texture storage and two
buffer uploads also appear in the short entry interval. There are no slow GL
calls during active painting after glass removal. This identifies the API span;
it does not yet establish every internal driver operation within it.

Source review found an earlier Denial change, `6be63064cf98` (August 5), that
prefers explicit resolves on all GLES 3 drivers. Upstream selected implicit
render-to-texture when its extension was advertised. The local Mesa source
supports surface sample counts on Adreno generations 6 and later, advertises
the corresponding extension, and sends explicit multisample blits through its
general blitter rather than the ordinary 2D copy path.

An isolated profile experiment, `a972794f`, adds opt-in
`DENIA_GLES_IMPLICIT_MSAA=1`. It requires GLES 3, both render-to-texture
extensions and their function pointers; the existing default and four-sample
antialiasing remain unchanged. Its startup log records the requested and actual
path plus four-sample support. The worker records the request in JSON, and the
runner requires the actual path to match.

The matched comparison uses the same `a972794f` profile engine, worker
`70399975`, v6 AOT, three compressed buffers and 100 ms start phase. Both
retain the budget-only cache policy and normal Mesa threading, with diagnostic
timing disabled. Runtime logs confirm that the two requested paths were
selected and both retained four-sample offscreen support.

| Nested glass | Explicit resolve | Implicit resolve |
| --- | ---: | ---: |
| Steady raster median | 3.995 ms | 3.875 ms |
| Steady raster p99 | 5.563 ms | 5.555 ms |
| Native entry frames above 10 ms | 6 | 1 |
| Native entry maximum | 17.990 ms | 12.213 ms |
| Mean GPU frequency during steady motion | 441.7 MHz | 357.5 MHz |

The frequency change is an observation under the normal governor, not a fixed
clock throughput comparison. The remaining implicit-entry peak occurs around
1.306 seconds and still spends 9.66 ms of CPU time preparing the frame fence.
Both direct paths also have one slow initial moving-direct frame. Thus implicit
resolve reduces the observed stalls without eliminating all first-use costs.

The implicit final-copy confirmation has a steady nested median of 4.450 ms,
p99 of 5.608 ms and maximum of 7.483 ms. Active painting after glass removal
peaks at 4.672 ms. All measured phases remain below 10 ms, while the full native
entry window contains three frames above 10 ms and peaks at 14.617 ms. Every
final-phase buffer repair is nonempty; fence and priority error counts are zero.

The updated full-shell candidate is staged inactive at
`/var/lib/denial/engine-candidates/profile-a972794f-47f44948`, with profile
engine `dedf94725da7043ee291d83517243744b1e92de092eb23fbc316e90af8e40729`.
It retains actual shell AOT `660c74d4` and native compositor `47f44948`.
Its manifest enables the supported implicit resolve and bounded cache reuse,
disables diagnostics, and records both performance results and remaining
cold-entry limitations. All 36 payload files were verified without changing
the live process, boot, settings, or startup configuration. The previous
`24f6b3c2` stage is retained separately. Visual and actual KMS acceptance remain
outstanding; the native restart mitigation remains untested on a session exit.

A final attribution run enables the same bounded GL timer with implicit MSAA
and Mesa threading disabled. Its eleven slow-call records contain no
`glBlitFramebuffer` call. Instead, six nested-entry `glDrawArrays` calls take
2.259–6.475 ms; four occur around 1.002, 1.088, 1.184 and 1.314 seconds.
Two buffer uploads and an earlier texture deletion are also recorded. There
are no slow GL calls after glass removal. This shows residual first-use driver
work moving into draw submission; it does not prove that every internal resolve
or allocation cost disappeared. No further functional change was made from
this diagnostic, and the staged candidate's bytes remain unchanged.

Correlating those existing records with the one-second resource summaries puts
all six nested slow draws, plus one call straddling phase entry, in the three
intervals containing new renderbuffer storage. Those intervals account for
eight renderbuffer-storage calls; subsequent motion intervals have none and no
slow draws. This supports first-cycle attachment growth as a remaining lead,
but the aggregated records cannot associate an individual draw with a specific
allocation. Larger allocation buckets or prewarming could increase memory use
or move the stall elsewhere, so this correlation alone does not justify either
change. The analysis required no additional device run.
