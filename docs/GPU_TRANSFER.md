# Scene rendering and cross-GPU presentation

The Flutter scene device and the KMS output owner are independent. For the
current single-card KMS backend, select them with `--render-device` and
`--device`, respectively. The packaged session accepts `DENIAL_RENDER_DEVICE`
and `DENIAL_DRM_DEVICE`. These select devices, not Flutter rendering APIs:
Flutter continues using GLES.

This first implementation supplies the native transfer boundary. Multi-card
KMS discovery and the independent persistent compositor/application GPU policy
are separate work. It does not change application launch preferences.

## Capability-driven import policy

Output storage belongs to the KMS owner. Physical device identity verifies the
requested scene EGL device; it does not choose a transfer route. During pool
allocation, Denial first probes the actual output-local DMA-BUF as a scene GLES
FBO. Success retains the existing direct Flutter pool (and optional
`--flutter-offscreen-blit` shader path), with no Vulkan requirement. Separate
GEM handle namespaces still require PRIME framebuffer registration when needed.

If the scene cannot render output-local scanout directly, Denial allocates a
source on the selected scene GPU and tries destination GLES import of that
actual source DMA-BUF first. Successful import keeps two distinct allocations:
scene source and output-local scanout. The worker draws the full source into
scanout; it allocates neither a LINEAR bridge nor a Vulkan device for this route.

Rejected direct imports try the existing Vulkan bridge route, with three
distinct allocations:

1. **Scene source:** GBM storage on the requested Flutter GPU, both GLES
   FBO-renderable and Vulkan-importable for image-to-buffer transfer.
2. **Bridge:** explicit single-plane LINEAR storage allocated by the output
   GPU, imported as a dedicated Vulkan buffer on the scene GPU.
3. **Presentation:** output-local GBM storage renderable by destination GLES
   and compatible with that output's KMS primary plane.

The source format is negotiated independently of the plane format. Packed
ABGR/ARGB/XBGR/XRGB 8-bit sources are considered; the current final scanout is
XR24. For direct import, Denial tries native GBM allocation and compatible
LINEAR storage using scene render and destination texture formats. An EGL
import advertisement alone does not prove that GBM can allocate an arbitrary
modifier. Vulkan fallback additionally uses DRM-modifier and external-memory
queries before explicit layout allocations. The bridge preserves the source's
channel layout. Actual returned modifiers, FD extents, pitches and offsets,
source FBO imports and destination imports are checked; fresh plans probe the
full draw/copy and final-fence completion. There are no vendor-specific
modifier constants or PCI IDs.

Vulkan physical-device selection matches the source DRM FD's major/minor
against physical-device DRM properties. The loader is dynamic, and a Vulkan
device is initialized only after direct-import candidates fail. If all imports
fail, setup reports a stage-specific error; there is no renderer substitution
or CPU pixel-copy fallback.

Dedicated DMA-BUF imports are used for one non-sparse resource per allocation,
with binding offset zero, actual FD memory-type intersections and backing-size
validation. False dedicated-allocation preference/requirement flags do not
exclude this optional dedicated declaration. Row padding and data offsets are
retained in the image-to-buffer copy rather than assuming tightly packed rows.

## Completion and ownership

Flutter flushes and exports its source native fence. A bounded queue hands the
source fence and allocation leases to a context-owning transfer worker. The
worker waits for the source, then destination GLES samples it directly into
local scanout. On rejected-direct fallback only, Vulkan first copies into the
LINEAR bridge with EXTERNAL/FOREIGN ownership barriers, and destination GLES
samples that bridge instead. It exports the **destination writer's** EGL native fence for KMS.
Flutter's earlier fence never represents scanout readiness on this route.

This milestone serializes Vulkan completion and destination-reader completion
with finite worker-side waits. Raster and KMS threads do not wait for those
copies. Sync-file Vulkan semaphore pipelining is a future optimization.

The broker pins the slot as `Transferring` until destination completion, even
across later raster transactions. Client surfaces sampled only by Flutter can
be released with the source fence. Source and optional bridge readers finish before
the worker returns; final scanout remains leased until KMS retires it. The
route's allocations share one conservative pool index, so source
reuse can be delayed until scanout retirement. Transfers redraw the complete
frame, preserving partial-repaint source history without stale bridge pixels.

A failed or uncertain completion poisons the route, reports a fatal render
error and retains its allocations/import graph for process-lifetime diagnosis.
It does not recycle the slot or select a previous release. Plan destruction
drains accepted jobs on the worker; it does not join GPU work on the event or
raster thread. Allocation reservations include actual source/optional-bridge/scanout
FD extents (conservatively counting repeated auxiliary-plane FDs).

## Hardware validation

Startup logs identify the scene EGL node when available, destination
DRM/EGL/GL identity, direct-pool imports or negotiated worker layouts, and
the matched Vulkan device/queue only when fallback is required.
The first runtime transfer completion is logged separately from setup probes.
`DENIAL_RENDER_AUDIT=1` adds existing render and DRM completion diagnostics.

### Transfer stage audit and direct-first qualification

With audit enabled, each accepted worker job reports `queue_us`,
`source_wait_us`, `vk_record_us`, `vk_submit_us`, `vk_wait_us`, `gl_draw_us`,
`gl_wait_us` and queue-to-completion `total_us`. Queue time begins at the
producer's enqueue attempt; the source wait measures residual producer-fence
completion, not the producer's entire raster. Vulkan record/submit are CPU
intervals. Both completion waits include GPU execution and host wakeup latency.
GLES draw includes submission, flush and destination-fence export. Optional
`vk_gpu_us` / `gl_gpu_us` timestamps measure GPU copy/barriers and final draw,
respectively, and overlap the CPU intervals: do not add them to the total.
Timestamp reads follow the existing completion waits and never add a wait;
unsupported/unavailable/disjoint measurements report `None`.

The output scheduler's `render_to_publish` starts at the Flutter present
callback. On this worker route it includes source completion, scheduling,
copies and final completion, whereas Flutter-context `gpu_scanout_blit` does
not measure this worker. An async completion outside the raster tracking
interval can yield `raster_to_output_ready=0` without implying a free transfer.

Direct destination source import is now the normal policy. The old
`DENIAL_GPU_TRANSFER_DIRECT_SOURCE` opt-in is no longer read. Both direct and
bridge worker paths redraw the entire output-local scanout, wait for the source
fence and destination completion, export the destination writer fence, and
retain the same slot leases and failure quarantine. Import rejection during
fresh plan setup is recoverable; a failed or uncertain GPU completion is
terminal and never triggers a route switch on in-flight storage.

T142's offscreen harness accepts `DENIAL_GPU_TRANSFER_REJECT_DIRECT_IMPORT=1`
to inject direct import rejection before any draw and exercise real Vulkan
fallback. Normal compositor sessions never read that fault-injection flag.
At native 2944×1840, 120-frame probes on TB373FU passed changing-pattern pixel
checks and final-writer completion for both routes. Direct import also passed
with `VK_DRIVER_FILES=/dev/null`, proving Vulkan-device initialization is not
required. These short probes qualify routing, not performance or visual output;
the rejected-direct probe is injected, not a naturally incompatible GPU pair.
Evidence is in the TB373FU repository's
`artifacts/presentation/2026-10-12-T142/`.

The normal T142 compositor was also activated on TB373FU with both transfer
flags absent. Its actual output-local XR24 buffers passed the scene FBO probe,
so it retained direct Flutter pools despite distinct physical sysfs identities.
This removes both worker copies, not merely T138's Vulkan copy. Passive logs
confirm source/scanout writer fences and physical DRM presentation feedback;
process/artifact identity and unchanged engine/shell/boot were checked. Visual
acceptance and sustained motion-rate qualification remain separate. The T138
trial and new T142 candidate are retained under `/opt/denial/tests/`.

The earlier T138 opt-in trial measured the redundant copy's cost:

On TB373FU (2026-10-12), three interleaved 1,000-frame runs per route at native
2944×1840 and absolute 144Hz pacing, excluding eight warmup frames, measured:

| Offscreen readiness metric | Vulkan bridge | Direct source |
| --- | ---: | ---: |
| Mean draw-to-ready | 6.621ms | 3.962ms |
| p95 / p99 draw-to-ready | 7.221 / 7.553ms | 4.607 / 4.883ms |
| Mean worker queue-to-completion | 6.153ms | 3.492ms |
| Mean source-fence wait | 1.445ms | 1.414ms |
| Mean Vulkan record / submit / wait | 0.101 / 0.079 / 2.555ms | skipped |
| Mean Vulkan GPU copy/barriers | 2.152ms | skipped |
| Mean destination draw / wait | 0.594 / 1.304ms | 0.682 / 1.330ms |
| Mean destination GPU draw | 1.246ms | 1.253ms |
| Missed scheduled readiness deadlines | 1,153 / 3,000 | 0 / 3,000 |
| Process CPU, one-core equivalent (run range) | 20.5–21.4% | 17.7–18.8% |

Both routes passed changing-pattern pixel checks. This removes about 2.66ms
(40%) of measured readiness latency, dominated by a real GPU copy rather than
worker queueing. AUDIT was enabled for both routes, including timestamps.
The probe uses only render nodes, not DRM master/KMS or Flutter; its negotiated
AB24 output differs from the real MTK display-node XR24 scanout, even though
both negotiated the same output modifier. These are readiness results, not
proof of 144Hz physical UI motion. Passive activation of the direct compositor
confirmed destination-writer completion, physical DRM presentation feedback
and service health; the mostly-idle startup sample is not motion-comparable
to the earlier interactive capture. Live GLES GPU timestamps were unavailable.
Device evidence is in the TB373FU repository's
`artifacts/presentation/2026-10-12-T138/`.

The `denial-transfer-benchmark SOURCE_RENDER_NODE DESTINATION_RENDER_NODE
[WIDTH HEIGHT FRAMES]` binary defaults to 2944×1840, 400 frames and fixed
144Hz pacing. It verifies pixels outside the timed stream and prints per-frame
CSV plus latency/CPU summaries. It retains its complete probe ownership graph
until process exit to avoid asynchronous worker/harness destruction races;
it measures runtime readiness, not clean EGL teardown. Production worker
destruction is unchanged.

An import/copy probe and atomic `TEST_ONLY` success are not proof of real
Flutter presentation. Validate a candidate through normal session activation,
new process/artifact identity, source/destination diagnostics, successful
runtime transfer and real KMS pageflip feedback. The user performs visual
validation. See [session startup](SESSION_STARTUP.md) for device overrides and
[building](BUILDING.md) for candidate compilation.
