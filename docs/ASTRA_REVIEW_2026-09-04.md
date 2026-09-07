# Denial review — 2026-09-04

Review by Astra, requested by Logix. Findings are recorded as they are confirmed.

Initial source-review pass: **15 findings**, not an exhaustive inventory or a
claim that the remaining code is issue-free. The subsequent
[architecture investigation](ASTRA_ARCHITECTURE_2026-09-04.md) follows the core
render path and records deeper performance opportunities. The strongest architectural choices
are the native resource ownership boundary, separation of metadata and texture
updates, explicit frame ownership, and the signed-candidate release workflow.
The largest gaps are at failure boundaries: client metadata can escape as a
fatal error; some asynchronous state has no recovery snapshot; persistence still
enters the native frame loop; and physical rendering documentation has drifted
from implementation. These call for focused hardening and staged refactoring.

Baseline: `dev`, HEAD `fdb986e` (`feat(shell): add workspace and suspend controls`),
including the existing uncommitted working-tree changes. Findings identify whether
their relevant code is already committed or is part of that work in progress.
Line references refer to the working tree at review time.

This is a source review of correctness, performance, and maintainability. No local
or remote graphical session is changed, no UI events are triggered, and no visual
validation is performed. Runtime performance claims require measurement; structural
costs and demonstrated failures are distinguished from profiling hypotheses.

Priority: P1 = substantial correctness or session reliability risk; P2 = concrete
performance, behavior, or maintenance issue; P3 = lower-impact cleanup.

| ID | Priority | Finding | Kind |
| --- | --- | --- | --- |
| 1 | P2 | Blocking settings and placement persistence | Performance |
| 2 | P2 | Clipboard drag writes outlive cancellation | Resource lifetime |
| 3 | P2 | Cached wallpaper loses its accent to an obsolete load | Correctness |
| 4 | P2 | Full SHM copy/conversion/upload on updates | Performance |
| 5 | P2 | Settings retry overwrites unrelated edits | Durable state |
| 6 | **P1** | Long X11 window title can end the session | Client isolation |
| 7 | P2 | No notification snapshot recovery | State synchronization |
| 8 | P2 | Multi-surface updates republish the whole scene | Performance |
| 9 | P2 | Wallpaper previews download full images | Network/memory cost |
| 10 | P2 | Wallpaper response limits apply too late | Resource bounds |
| 11 | P2 | Subscriber removal revokes other clients' frame grants | WIP correctness |
| 12 | P2 | Duplicate settings transaction implementations diverge | Refactoring |
| 13 | P2 | Event-loop transaction/recovery state is dispersed | Refactoring |
| 14 | P3 | Desktop parts share excessive private scope | Refactoring |
| 15 | P2 | Architecture docs describe the old framebuffer model | Documentation |

Start with **6**, then correctness/lifetime findings **2, 3, 5, 7, 11**.
Address **1 and 12 together**. Profile **4 and 8** before choosing a rendering
optimization, and use **15** to document the actual ownership model before
undertaking **13**. Findings remain in discovery order below.

## Findings

### 1. P2 — Persistent settings perform blocking disk work on the compositor loop

**Status:** Confirmed call path; present in HEAD. No disk-latency measurement made.

`flutter_event_loop.rs:1480` calls `synchronize_settings`. Both the embedded
request (`flutter_settings_sync.rs:117`) and standalone control request
(`flutter_settings_sync.rs:650`) synchronously prepare and commit settings.
`SettingsManager::prepare` serializes the document and writes a temporary file
(`settings.rs:842`); `write_temporary` calls `write_all` and `sync_all`
(`settings.rs:1367`). Commit reads the existing file, renames the replacement,
and fsyncs its parent (`settings.rs:794`). These operations therefore stall
native event dispatch for their duration. Moving the Settings UI to its own
process does not isolate this work from the desktop frame budget.

**Recommendation:** Give persistence a bounded worker and serialize revisioned
transactions through it. Keep live input configuration and publication on the
compositor loop, with explicit prepare/commit/rollback completion messages.
Preserve the existing rename point-of-no-return behavior. Measure input and
presentation latency during saves under storage contention before and after.

The same concern also applies to saved window placement: completing a persisted
move/resize calls `remember_window_geometry` on the native loop
(`wayland_frontend/window_management.rs:997`), then serializes the complete
placement store and fsyncs it (`window_placement_store.rs:338`, `:385`). Move
this work to a coalescing persistence worker as well; it is on gesture completion,
not every pointer-motion event.

### 2. P2 — Clipboard drag transfers have no timeout or effective cancellation

**Status:** Confirmed lifetime defect in unchanged HEAD code.

`ClipboardDndSource::send` spawns a thread which calls blocking `File::write_all`
on the recipient's fd (`wayland_frontend/clipboard.rs:119`). A recipient can keep
the read end open without draining it, leaving the thread, fd, and retained
clipboard bytes alive indefinitely. `cancel` and `finished` only set `alive`
(`:148`); the writer never checks it. The eight-transfer counter belongs to each
new source (`:51`), so successive drags can accumulate more blocked workers.
The normal retained-selection path already has a nonblocking writer and a
five-second timeout (`:431`), but the drag path bypasses it.

**Recommendation:** Share a bounded, timeout-aware transfer service between
selection and drag delivery, with a global transfer limit and cancellation.
Cover a non-reading pipe recipient and cancellation with an isolated native
test; no real clipboard or visible UI event is needed.

### 3. P2 — A cached wallpaper can receive the previous wallpaper's accent

**Status:** Confirmed asynchronous ordering defect; unchanged HEAD code.

`WallpaperAccentController._load` checks the cache before incrementing
`_loadGeneration` (`dart_shell/lib/src/wallpaper/state/wallpaper_accent.dart:146`).
Sequence: resolve wallpaper A so it is cached; begin a slow extraction for B;
switch back to A before B finishes. The cache hit publishes A's color without
invalidating B's generation. B then finishes, passes the generation check, and
overwrites A's accent. The shell and its published portal accent can therefore
describe a wallpaper that is no longer selected.

**Recommendation:** Invalidate older loads on every selection, including cache
hits. Keep the build-generation guard. Verify the A → pending B → cached A
ordering with a controlled extractor future.

### 4. P2 — SHM updates copy, convert, and upload the entire client buffer

**Status:** Confirmed structural performance cost; present in HEAD. No measured
frame-rate claim.

`wayland_frontend/surface_snapshot.rs:119` obtains and initializes a full RGBA
payload, copies every source row, and converts every pixel, regardless of the
client's damaged region. The snapshot is taken during surface publication on
the native loop (`surface_pipeline.rs:190`). On the raster side, each uncached
SHM revision generates a texture and uploads the complete image with
`glTexImage2D` (`flutter_runtime/renderer/handler/open_gl.rs:632`). The cache
helps repeated sampling of one revision, not successive revisions.

A 3840×2160 snapshot is 31.6 MiB. At 60 updates/s, the full-image payload alone
is about 1.85 GiB/s at each full-copy/upload stage, before conversion and other
memory traffic. This is arithmetic for that workload, not a benchmark. Even a
small damaged area in a large software-rendered client takes the full path.

**Recommendation:** Preserve validated buffer damage through immutable SHM
generations; use reusable GPU storage with partial uploads when safe. Retain
the existing ownership/fence guarantees rather than modifying a texture still
sampled by another frame. Profile sparse-damage SHM clients separately from
DMA-BUF clients to prioritize the work.

### 5. P2 — Settings conflict retries can overwrite unrelated preferences

**Status:** Confirmed retry logic in unchanged HEAD code; executable regression
check prepared but blocked by the local Flutter source-lock mismatch.

`NativeSettingsStore._write` serializes the entire shell settings object once
(`dart_shell/lib/src/settings/settings_store.dart:78`). On any `StateError`, it
reads a newer document but uses only the new revision and resends the same old
payload (`:91`). If another settings client changes panel opacity while this
client changes corner radius, the retry can undo the opacity change. The
comment assumes conflicts arise only from native-owned keyboard updates;
the shared control API also permits other shell-document writers. The
controller's local mutation patch does not rebase the payload already captured
inside this retry.

**Recommendation:** Carry an explicit mutation patch and base revision into the
store. Rebase only changed fields onto the newly read document, or surface a
conflict for the controller to resolve. Distinguish revision conflicts from
other `StateError`s rather than retrying every failure as a conflict.

### 6. P1 — A client-controlled long X11 window title can terminate the session

**Status:** Confirmed source/error-propagation path; present in HEAD. Intentionally
not triggered against a running compositor.

An X11 title property change marks scene metadata dirty
(`wayland_frontend/xwayland.rs:821`). `flutter_scene` copies the X11 title/class
strings without bounding them (`wayland_frontend/surface_pipeline.rs:742`).
The locked Smithay revision's `read_window_property_string` requests up to
2,048 four-byte units (8,192 bytes), so a 5,000-byte UTF-8 `_NET_WM_NAME` reaches
this path. `validate_windows` rejects either
string above 4,096 bytes (`wire.rs:784`). That error propagates through
`WireBridge::update_windows` (`wire/encode.rs:55`),
`FlutterRuntime::sync_wayland_scene` (`flutter_runtime/scene_bridge.rs:58`),
`synchronize_flutter_scene`, and the `?` at `flutter_event_loop.rs:1490`, which
exits `run_flutter_event_loop`.

A mapped Xwayland client's sufficiently long title is therefore treated as a
fatal compositor error. Native Wayland metadata also lacks projection-side
truncation, but its transport limits need separate consideration; X11 is the
confirmed reachable path described here.

**Recommendation:** Bound display metadata at the native-to-shell projection
with UTF-8-safe truncation, while keeping protocol identity handling explicit.
Classify client-specific serialization/admission failures so they quarantine or
reject the offending client state instead of aborting the session. Check
aggregate snapshot size/count limits at this boundary too. Add a non-graphical
boundary regression proving an oversized title cannot escape as a fatal loop
error.

### 7. P2 — Notifications have no snapshot recovery after lost events or shell replacement

**Status:** Confirmed protocol/state design in HEAD; no notification was sent.

The native worker owns live notifications for the process lifetime, but the
Flutter side reconstructs them solely from added/replaced/closed events.
`flutter_event_loop.rs:132` silently drops the oldest event when the 512-entry
queue fills. `flutter_service_sync.rs:238` forwards the remaining deltas without
an overflow marker or resynchronization. The worker command enum has no
snapshot/replay operation (`notification_server.rs:359`).

A dropped close event can leave Dart showing an active notification the server
has already removed. Independently, replacing the Flutter runtime keeps the
native server alive (`flutter_event_loop.rs:1398`) but rebuilds the Dart
notification controller with empty state (`state/desktop_notifications.dart:140`).
Previously active persistent notifications are not replayed, so they disappear
from the new shell until the application replaces them.

**Recommendation:** Add revisioned authoritative snapshots at subscription and
runtime replacement. On queue overflow, mark the stream as requiring a
snapshot instead of silently continuing an incomplete delta history. Retain
bounded queues and coalesce updates by ID where appropriate.

### 8. P2 — Any multi-surface client update takes the full desktop metadata path

**Status:** Confirmed deliberate fallback in unchanged HEAD code; optimization
opportunity, with a correctness constraint that must be preserved.

`surface_pipeline.rs:225` permits buffer-only publication only for a simple
root surface. A window with subsurfaces or popups is placed in
`scene_complex_windows` (`:807`), and its buffer changes instead dirty the
complete scene. `flutter_scene` then walks all windows (`:681`), rebuilds
surface descriptions and texture membership, and `WireBridge::update_windows`
serializes the full snapshot for each new metadata revision
(`wire/encode.rs:40`). It does not compare the new metadata to the old snapshot
before sending it. A frequently updating subsurface therefore produces work
proportional to the entire desktop, including Dart snapshot decoding.

The comment correctly explains why simply enabling the existing fast path is
unsafe: subsurface stacking changes currently have no compositor callback.

**Recommendation:** Track structural revisions per window, either via a
Smithay hook or a bounded structural comparison of the affected tree. Rebuild
that tree only when it changes, and use the texture path for content updates.
Preserve synchronized-subsurface transaction semantics and stacking correctness.
Benchmark a multi-surface client with several unrelated windows, not only a
single root-texture workload.

### 9. P2 — Wallpaper previews download the full wallpaper

**Status:** Confirmed source path; unchanged HEAD code. Network usage not measured.

The Wallhaven parser assigns the same full-image `path` to both `previewUri`
and `downloadUri` (`wallpaper/providers/wallhaven_wallpaper_provider.dart:129`).
`wallpaperCandidateImageProvider` feeds that URL to `NetworkImage`
(`wallpaper/widgets/wallpaper_image.dart:45`). `ResizeImage` reduces decoded
dimensions but does not reduce bytes downloaded. Browsing small preview tiles
therefore retrieves full wallpaper files, and selection uses a separate
`HttpClient` download into the wallpaper directory. The materializer's 64 MiB
limit is not applied to the preview `NetworkImage` path.

**Recommendation:** Use separately validated thumbnail URLs for browsing,
with bounded downloads and a shared cache/materialization strategy. Download
the full image only when selected or explicitly prefetched.

### 10. P2 — The wallpaper search response limit is enforced after buffering

**Status:** Confirmed resource-boundary defect; unchanged HEAD code.

Search checks `contentLength`, then decodes and joins the complete response
before checking its length (`wallhaven_wallpaper_provider.dart:72`). An unknown
length/chunked response bypasses the first check and can consume far more than
the declared 2 MiB cap before rejection. The final check counts Dart string code
units, not incoming bytes. Rejected responses also use `response.drain()` with
no timeout (`:66`, `:73`), so an endless error body can keep the operation alive.

**Recommendation:** Count incoming bytes while consuming the stream, cancel
at the limit, and decode only the bounded buffer. Apply a total deadline and
cancel rejected bodies rather than waiting indefinitely for them to drain.
Test using an isolated fake HTTP stream, without contacting the real service.

### 11. P2 — One frame-timeline subscriber can invalidate every other client's grants

**Status:** Confirmed behavior in the **uncommitted** new
`wayland_frontend/frame_timeline.rs`.

Deactivating one output subscription calls `begin_new_epoch` (`:479`), as does
destroying an active subscription (`:484`). The epoch is global: the function
finishes all grants, clears all output cadence, and updates the shared epoch
guard (`:140`). All other clients' pending targeted commits then fail their
grant checks (`:663`), and already installed blockers return `Cancelled` when
the epoch differs (`:806`). Closing or pausing one participating application
therefore discards unrelated clients' work, including on other outputs.

**Recommendation:** Scope subscription cancellation to its owner and output.
Reserve broad epoch changes for actual topology or clock discontinuities.
Add a pure state/lifetime test with two subscribers showing that removing one
does not revoke the other's issued target or fence blocker.

### 12. P2 — Settings transactions are implemented twice with different failure policies

**Status:** Refactoring need confirmed in HEAD; not a claim that rollback failure
has been observed.

`flutter_settings_sync.rs` implements keyboard/touchpad/mouse/shortcut updates
inside the embedded wire-command switch and again for the control socket.
For example, embedded keyboard update performs prepare → install → commit →
rollback at `:185`; `apply_control_keyboard` repeats it at `:829`. The copies
already differ: an embedded rollback failure propagates a fatal compositor
error (`:214`), while a control rollback failure becomes an ordinary request
failure (`:857`). Control preparation also labels all errors as `conflict`,
including validation and I/O failures (`:840`, `:780`). This makes correctness
depend on which transport invoked the same operation.

**Recommendation:** Extract transport-independent native settings operations
with typed outcomes for validation, conflict, persistence, and rollback failure.
Both bridges should decode requests and encode responses around that shared
transaction implementation. Combine this with finding 1's persistence worker;
avoid moving two copies of the same state machine to separate workers.

### 13. P2 — The main event loop needs explicit reconfiguration and recovery states

**Status:** Refactoring assessment of HEAD and the current working tree.

`run_flutter_event_loop` occupies most of a 1,712-line module. It coordinates
normal presentation, DPMS, output apply/confirmation, hotplug, sensor rotation,
Flutter replacement, and service dispatch. Transaction progress is distributed
across `ready_output_apply`, `pending_output_success`,
`active_output_confirmation` (`flutter_event_loop.rs:246`), optional Flutter
ownership, and several independent flags in `RuntimeState` (`runtime_state.rs:14`).
Recovery branches must manually restore those flags before `continue`, while
ordinary `?` propagation can terminate the session, as finding 6 demonstrates.

**Recommendation:** Introduce explicit output-transaction and runtime-recovery
state types with one transition function and documented ownership of old/new
resources. Keep the deadline-critical presentation lane small. Separate
recoverable client, service, and output-transaction errors from fatal native
resource invariants. Refactor one transition at a time, retaining the existing
KMS ownership and rollback tests; a compositor rewrite is unnecessary.

### 14. P3 — Desktop shell file splitting does not establish component boundaries

**Status:** Maintainability issue in HEAD; measured on the working tree.

`desktop_shell.dart:86` includes eleven `part` files: launcher, dashboard,
Bluetooth/power controls, window scene, frames, and overlays share one private
Dart library. Together these twelve files contain 5,914 lines. A feature file
can depend on any other file's private declarations and on imports in the parent,
so the split hides dependencies rather than declaring them. Scene selection also
stores equality-affecting placement IDs in a global `Expando`
(`desktop_shell.dart:115`) instead of fields on `_DesktopSceneWindows`.

**Recommendation:** Extract ordinary widget libraries with explicit inputs,
callbacks, and imports, starting with launcher and dashboard components. Keep
scene/placement coordination together where it shares an invariant. Put the
selection's immutable placement IDs on the selection object. This reduces the
scope a contributor must understand to change one feature without changing
the state-management architecture.

### 15. P2 — The architecture document describes a superseded framebuffer model

**Status:** Confirmed documentation/source mismatch; both are in HEAD.

`docs/architecture.md:61` says all CRTCs scan distinct rectangles of one shared
desktop-wide framebuffer and that a per-output path is future work (`:85`).
The runtime module describes itself as using native per-output scanout pools;
`OutputSwapchains::allocate` allocates separate buffers for each output plan
(`kms_state.rs:640`, `:671`), and KMS plane sources begin at `(0,0)` within each
output's buffer (`output_scheduler.rs:317`). A single logical Dart scene remains
true; it is not the same as one shared physical framebuffer.

This distinction controls reasoning about mixed-refresh ownership, memory
costs, damage, and cross-GPU presentation. New contributors following the
architecture document will start from the wrong physical model.

**Recommendation:** Update the architecture and related render documentation
to distinguish the logical desktop/atlas coordinate space from physical
per-output render views, buffer pools, and presentation clocks. Trace one
client commit through those owners, including buffer release.

### Follow-up finding 16. P2 — Fractional glass texture sizes defeat cache reuse

**Status:** Confirmed by engine source and separate runtime traces during the
cursor benchmark investigation. The fix in canonical Flutter commit `58d8036b`
passes targeted engine tests and user visual validation on `.188`. Together
with the damage-planning change, its three-run comparison reduced CPU by 51%,
mean raster duration by 68% and GPU render activity by 89% for the static glass
Kitty cursor workload. See the [results](benchmarks/cursor/snapshot-coverage-2026-09-04/README.md).

`impeller/entity/contents/filters/glass_filter_contents.cc` allocates the
material with `ISize(material_size)`, truncating fractional pixel dimensions.
The returned snapshot uses only a translation, so it cannot cover the full
requested material rectangle. The next draw rejects that cached image and
rebuilds it. At scale 1.1, the large glass window's snapshot was 1887×1028 even
though its requested bounds extended beyond that allocation. Two stable
backdrop identities were found in all 778 drawing lookups and stored again
778 times each during a separate cursor trace.

**Recommendation:** Round the allocation up while retaining the original
physical geometry and optical coordinates. Keep exact fractional coverage
for cache eligibility and conservative integer bounds for damage. The first
damage experiment additionally exposed a coordinate mismatch in its own
implementation: the embedder's vertical flip is deferred until submission.
Snapshot queries must apply that mapping. See the
[comparison and diagnosis](benchmarks/cursor/backdrop-damage-2026-09-04/README.md).

### Follow-up finding 17. P2 — Backdrop cache admission forgets demonstrated reuse

**Status:** Confirmed by source and a temporary runtime trace after finding 16
was fixed. Follow-up commit `56628c5d` passes eight selected cache/glass tests,
was visually validated by the user, and completed three comparison runs on
`.188`. Raster p99 fell from 2832 to 1331 µs and full-frame redraw frequency
fell 41.3%. Mean raster and CPU were essentially unchanged; p95 rose 5.1%.
See the [measured result](benchmarks/cursor/backdrop-refresh-2026-09-05/README.md).

`impeller/entity/contents/content_context.cc` delays materialization until a
generated backdrop version is observed twice. This avoids allocating persistent
snapshots for continuously changing content, but it resets the delay after every
generation change, including for a backdrop whose previous snapshot was reused
for many frames. That leads to two filter evaluations after an occasional
change: one direct evaluation, then another to populate the cache.

A separate circular-cursor trace repeatedly observed a changed generation
rejected for materialization and accepted on the next rendered frame. The
benchmark's remaining full repaints commonly occurred in pairs. Scene preparation
and recording averaged about 117 µs in a separate stage trace; backend rendering
carried the expensive spikes.

**Recommendation:** Let confirmed renderer cache hits inform the next
generation's admission, then reset that evidence. A replacement that is never
reused should return the family to delayed admission. Preserve conservative
coverage checks, invalidation and snapshot ownership. See the
[follow-up experiment](benchmarks/cursor/backdrop-refresh-experiment.md).

### Follow-up finding 18. P2 — Impeller runs its preparation pass on frames with nothing to prepare

**Status:** Confirmed by source and runtime tracing in the user's no-effects,
three-Kitty workload on engine `56628c5d`. No implementation change yet.

`impeller/display_list/dl_dispatcher.cc::RenderToTarget` always dispatches the
display list through `FirstPassDispatcher` before dispatching it again for
rendering. The first pass collects text for the glyph atlas and plans backdrop
dependencies. It still walks nested lists and transform/save state when neither
feature is present. The baseline GPU audit records no backdrop work. In a
separate command inventory, 675 of 719 complete frames contained no first-pass
text calls, but both dispatch passes ran in all of them. There were 5805 dispatch
calls for each receiver across the capture, including nested lists.

**Recommendation:** Track whether a display list, including its descendants,
needs text or backdrop preparation and bypass the first pass when both are
absent. Preserve preparation for text-bearing or backdrop-bearing lists, even
when nested. The existing `root_has_backdrop_filter` flag is not by itself a
sufficient proof that every nested backdrop is absent. An outer-call-only trace
subsequently measured 30.5 µs mean and 28.9 µs median on 675 text-free frames.
These times include probe overhead and exclude collector construction/destruction;
they establish a modest opportunity, not a large predicted speedup.

The [no-effects baseline](benchmarks/cursor/no-effects-baseline-2026-09-05/README.md)
is saved separately from the earlier glass workload.

### Follow-up finding 19. P2 — Rounded clips draw curved geometry when only a straight edge affects the repaint

**Status:** Confirmed by source and a geometry trace in the no-effects workload.
No implementation change yet.

`Canvas::ClipGeometry` passes only outer bounds and an axis-aligned-rectangle
flag into `EntityPassClipStack::RecordClip`. A rounded clip still builds geometry
and emits stencil/cover commands when the portion intersecting the current
repaint is rectangular. `RoundRectGeometry::CoversArea` already provides a
conservative interior-coverage proof, but this clip path does not use it.

The 12-second trace contains 707 rendered rounded clips. For 331, the intersection
of the rounded bounds and the current clip, with a one-pixel margin toward the
corners, lies within a flat rectangular interior strip. Of those, 325 also satisfy
the existing rectangular clip's 0.124-pixel integral-edge tolerance. Those 325
clips emit 650 stencil/cover draw commands that could use the existing scissor
path. The count covers the traced workload, not every rounded clip or a measured
percentage speedup. It does not include the many arbitrary-path clips.

The initial idea of dropping clips that contain the entire current clip did not
match this trace: zero rendered rounded clips met that stronger condition with
the margin. The useful case is a repaint crossing a straight window edge away
from its rounded corners; the edge still needs clipping.

**Recommendation:** Prove when intersecting a rounded shape with the current
clip is equivalent to intersecting its outer rectangle, then use the existing
rectangular/scissor rules. Preserve antialiasing, clip-height bookkeeping,
restore/replay behavior and fallback near corners or unsupported transforms.
Do not infer equivalence from the rounded shape's outer bounding rectangle alone.

### Follow-up finding 20. P2 — General render auditing also enables per-draw GPU timestamp queries

**Status:** Confirmed in the source and saved benchmark logs. The exact runtime
overhead has not been isolated. This is a measurement/workflow issue, distinct
from production rendering waste.

`impeller/renderer/backend/gles/denial_gpu_audit_gles.cc` enables detailed GPU
stage timing under the same `DENIA_RENDER_AUDIT` flag used for the compositor's
aggregate damage and callback timing. `RenderPassGLES` places start/end timestamp
markers around individual root draw commands as well as render passes. Each
sample creates two GL query objects, submits two timestamps, later polls and
reads their results, then deletes the objects.

This mode is active in all saved comparisons. The no-effects capture therefore
contains thousands of additional timestamp markers per second. Matching audit
settings keep those comparisons controlled, but the reported CPU/raster values
are instrumented measurements, and reducing draw counts also reduces audit work.
Do not assume the same percentage changes with auditing disabled.

**Recommendation:** Give per-draw GPU timing a separate opt-in control from
aggregate render auditing. Retain detailed tracing for diagnosis and measure
final CPU/raster changes with detailed timing off on both sides. Do not remove
required presentation fences or classify their cost as redundant merely because
it is substantial.

## Previously documented session risks

The GPU-reset session loss and live-scale-change failure in
[KNOWN_ISSUES.md](KNOWN_ISSUES.md) deserve priority alongside finding 6.
They are not new discoveries from this review, and neither was reproduced.
For a daily-driver compositor, successful recovery and rollback are product
features: renderer/Flutter replacement should preserve surviving client state,
and a rejected display configuration should preserve the usable desktop.

## Initial review scope and validation

This section records the initial 15-finding review. The later cursor benchmark,
engine experiments and finding 16 are documented separately above and in the
linked experiment report.

Inspected the architecture and testing policies; native scene/wire publication;
SHM import and upload; clipboard transfers; notification ownership and dispatch;
settings persistence and both transports; event-loop/reconfiguration ownership;
the new frame-timeline protocol; Dart settings/accent state; wallpaper networking;
desktop component boundaries; and selected build/release workflow entry points.
The locked Smithay X11 property reader was also inspected to establish finding
6's reachable input size. This is not an exhaustive audit of every compositor
module, packaging adapter, or Flutter/Skia fork, nor a runtime performance profile.

- Source review uses the working tree; no production source files have been
  edited.
- Prepared `/tmp/denial_astra_review_test.dart` with controlled-future and
  in-memory-transport checks for findings 3 and 5. Ran the prescribed
  `tools/denial-pc flutter-test /tmp/denial_astra_review_test.dart --reporter expanded --concurrency=1`
  outside the sandbox. It stopped before running tests: canonical Flutter
  revision `119e18cfe94de7c0176e2e5105ac3f46a11f3447` differs from locked
  revision `d728e61e7d835e02c453c70ae9523a40f6c03215`.
  These checks have therefore **not** been executed; no test pass or reproduced
  runtime failure is claimed. The source lock and canonical forks were left
  unchanged.
- No complete Rust/Flutter suite, live compositor experiment, visual check,
  notification, deployment, session restart, commit, push, or GitHub issue
  publication was performed. This report is the only repository file created
  by the review; the two scratch regression checks are outside the checkout.
