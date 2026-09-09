# Standalone CPU placement component: research and design record

Updated: 2026-09-08. This is the continuity record for the discussion with the
user. Read it when resuming after compaction. It records decisions, evidence and
unresolved questions. The initial Denial affinity implementation is recorded
below; the standalone system component remains a separate design.
It lives temporarily in Denial's documentation because that is the current
workspace. The user selected a **standalone project**, whose name and repository
location have not yet been chosen.

Before implementation, also read the requested
[thread and process inventory](THREAD_PROCESS_INVENTORY.md). It combines all
56 deniald threads and seven descendant processes observed on the Moto with the
native, Flutter/Dart and Mesa creation-site catalog, transient workers and
indirect service boundaries. Raw task/attribute snapshots are retained alongside
it. The inventory found ordinary-priority cache/compilation queues, mixed Dart
and Flutter worker pools, Mesa disk workers that reset affinity, and application
launch paths that, at inventory time, reset priority but not affinity. One extra thread's
creator remains unresolved; do not invent a background classification for it.

## User decisions and priorities

- Performance is the primary objective. Repeated problems on heterogeneous CPUs
  motivate a reusable system component rather than another phone-specific fix.
- Separate **CPU placement** from **frequency scaling/interaction frequency
  boosts**. Work on placement first; frequency policy comes later.
- Build an installable, low-level component that can serve Denial and other
  applications. A static setting or thread-name tuning script is not the goal.
- Abstract kernel integration behind backends. Optimize the backend for our
  kernel; other kernels can implement the same contract. Unsupported kernels
  should get an actionable warning. Do not restrict the whole design to the
  least capable common interface or make a Linux upgrade the default answer.
- Understand Android's actual implementation before inventing our policy.
  Repeated user questions concern how Android recognizes important threads and
  protects the first frame, rather than merely measuring misses afterward.
- The user wants Denial to avoid dropped frames. An algorithm that tries a
  little core first and only upgrades after missing a deadline fails that intent.
- Preserve this thought process in a document across compaction.
- Initial policy: three groups, specified by the user. Absolute performance is
  restricted to big cores; medium may use both and migrate with demand;
  "out of my way" is restricted to little cores. See the contract below.
- Integration must be optional. Denial must run normally without the standalone
  component or a required client-library dependency.
- Latest Denial workload policy: **big-only by default, with explicit little-only
  background exceptions**. This includes embedded Flutter UI/raster threads and
  ordinary Mesa rendering/submission workers in the deniald process. Denial
  identifies its own background roles; the component must also handle Mesa's
  existing background markers. This supersedes the earlier objection to a broad
  big default, provided background exceptions are actually enforced. The global
  three-group model and standalone, optional component remain the design.
- Clarification: by thread attributes, the user means **adding explicit metadata
  to a thread**, not inferring its role from existing priority/name attributes.
  The assistant initially misunderstood this. Explore a per-thread placement
  class attribute as the registration mechanism; inference is not the requested
  solution to this question.

These choices supersede earlier suggestions to make a persistent per-Mesa-thread
uclamp adjustment the final solution. Such an adjustment was a diagnostic trial.
No standalone project name, production metadata API or prediction algorithm has
been chosen. The user subsequently authorized the initial allocation in Denial.

## Initial Denial implementation: 2026-09-08

The user said **"Proceed with the correct allocation now"** after the inventory.
The native implementation is opt-in with `DENIAL_CPU_PLACEMENT=1`. It uses Linux
`sched_getaffinity`/`sched_setaffinity` through a small safe Rust backend in
`compositor/src/cpu_affinity.rs`; classification and lifecycle integration are in
`compositor/src/bin/deniald/cpu_scheduling/placement.rs`. It requires no kernel
patch, external daemon or Flutter/Mesa rebuild. This is an initial integration of
the agreed allocation, **not completion of the standalone component**.

The allowed CPU domain is captured before Denial creates workers. Kernel
`cpu_capacity` values identify the lowest tier as little and all higher tiers
as big. On the Moto this means **little 0–2, big 3–7** (capacity 429 versus
854/1024). A platform without complete heterogeneous capacity data can provide
both `DENIAL_BIG_CPUS` and `DENIAL_LITTLE_CPUS`; these must be nonempty, disjoint
subsets of the inherited domain. Invalid/unsupported configuration warns and
leaves placement disabled. Default-off behavior is preserved on other hosts.

| Work | Allocation |
| --- | --- |
| Main/platform, Flutter UI/raster, Volition | Big |
| Mesa Zink submission `zfq`, all `gdrv` and `gl` lanes | Big |
| Mixed `zcfq` compilation/cache-get, Flutter IO/concurrent, Dart IO/workers, unidentified and mixed library workers | Big |
| Denial portal IPC, control listener/clients, authentication, audio controls, brightness, power controls, notification handling, orientation, screenshot encoding/writing, tray, child reaper, clipboard transfer | Little |
| Mesa minimum-priority `SCHED_BATCH`/nice 19 workers and cache-put `zcq`, Smithay SHM disposer, Dart profiler thread | Little |
| Separate applications and Xwayland | Original domain (all 0–7 on Moto) |

The main thread enters big before creating native/driver/engine workers. Owned
background workers place themselves at entry, and Flutter's thread callbacks
place its lanes explicitly. The screencopy renderer stays big. Nice 0 alone is
never evidence of background work. The `zcfq` pool is not treated like `zcq`.
The unknown thread from the inventory retains the big default.

Mesa can override inherited affinity, notably its full-affinity disk queue.
The existing one-second priority guard therefore also reconciles live workers
in `/proc/self/task`. Its work runs on little, with another reconciliation
before entering the compositor loop. This is **eventual classification for
unmodified library workers**, not a pre-first-job guarantee: new library
background workers can initially run on big, or briefly on all CPUs if they
override the inherited mask. A later strict implementation needs creation-time
library integration or an equivalent reliable hook. Thread-name exceptions
are bounded compatibility rules from the inventory, not a universal metadata
API. CPU hotplug/cpuset changes are constrained by the kernel; the backend
reports failures and never intentionally falls back across classes.

Native applications restore the saved domain in the existing pre-exec
scheduling reset. Smithay exposes no Xwayland pre-exec hook, so its synchronous
spawn temporarily restores only the calling thread's application mask and
restores the Denial mask afterward, including error/unwind paths. A mutex
coordinates this brief startup scope with the guard. No such lock runs in a
post-fork callback or on the steady-state rendering path. Denial-owned command
line tools also recognize `DENIAL_APPLICATION_CPUS` for the direct Dart tool
spawn path; ordinary application launch removes that internal metadata.

This allocation does not modify frequency governors, clock limits, nice levels,
RT policy or utilization clamps. Existing priority/clamp code still operates.
Reboot removes the earlier live-only three-Mesa-worker clamp trial; hard affinity
then supplies those workers' placement. Existing configured UI minimum remains.
Changes in observed clocks due to changed cluster load are still possible.

Validation: seven focused scheduling tests passed, including actual kernel
inheritance, little override, child exec restoring all CPUs, parent mask
preservation, scoped library-spawn restoration on success/error/unwind, and
classification/topology checks. No visual tests or input events were generated.
Native cross-build/activation evidence is retained under
`/mnt/development/moto70edge/build/denial-affinity-20260908/`; activation status
is confirmed by `activation.json` and `allocation-verification.json`. The
existing profile engine and shell were reused.

Activation completed on boot `ecbda8eb-af2e-49ae-952c-437c8efbae34`, deniald PID
**1068**, candidate `/var/lib/moto70-denial/affinity-e6ad915bb93e`, native SHA-256
`e6ad915bb93e782a1d0aa326ae47755723cef1973690ccfeb39483cbceb521ba`.
All 43 packaged files, native dependencies and the on-device Flutter ABI test
passed. The normal reboot gate verified 251 boot-critical files. No failed
system units or allocation warnings were observed. Engine SHA-256 remains
`a923666d552128c290112fa728abb56238ccf7a867d9378fc5c29d24d00a9192` and shell AOT
`098b5518add35db79621d1bd55467a37582a56ed9d422cb9af9200db59594cb8`.

[Two post-boot allocation snapshots](research/thread-inventory/2026-09-08-allocation.json)
verified every observed Denial thread. The latest (11:19:02 UTC) contains
**36 big-only and 16 little-only threads**; a transient Dart worker accounts for
one additional big thread in the first sample. All six Mesa GL/driver pairs,
submission queue, UI/raster and Volition are big. Xwayland retained 0–7.
Main/UI/raster still have RR priority 1 and minimum 512; Volition has RR 1,
minimum 0; submission is normal/minimum 0. The old transient three-worker hint
is gone, as intended. These are identity-bound snapshots, not stable TID labels.

The existing guard plus allocation reconciliation consumed approximately
8.30 ms of scheduled CPU time over the 3.07-second passive snapshot interval
(about 0.27% of one CPU), on little. This includes the old priority guard and
is not a controlled measurement of the added allocation overhead. No new frame
performance comparison or visual acceptance is claimed.

The added service drop-in is `99-moto70-zzzz-affinity.conf`. Removing only that
drop-in and using the normal gated reboot returns to the retained prior native
candidate; workspace `ROLLBACK.md` records the exact procedure and limitations.
DevTools HTTP/DDS WebSocket connection to PID 1068 was verified and its current
URL is in workspace `connection.json` (also refreshed in the previous audit
workspace for continuity). No applications or visible test events were launched.

## Droidloom follow-up

After accepting Denial's allocation, the user requested inspection of
`/mnt/development/droidloom`. Findings and proposed role boundaries are saved in
that repository's existing `docs/architecture.md`, section **CPU placement and
Android task profiles**. Raw evidence stays outside Git in the Moto workspace's
`droidloom-prep/cpu-placement-audit/`.

The live Android cell has missing CPU/cpuset controller integration: its legacy
paths are empty tmpfs directories, its delegated v2 view exposes only memory
and pids, and performance/capacity profile applications fail in the journal.
427 selected tasks all allowed CPUs 0–7; SurfaceFlinger/RenderEngine/submission
workers were last observed on little even with FIFO priority 2. Composer's
`ServiceCapacityLow` maps to `system-background`, a policy mismatch to correct
when the controller backend is repaired. Native presenter exceptions, Android
state-based profiles and lifecycle-child affinity reset need separate treatment.
No Droidloom allocation or code change was performed in this inspection.

## Motivation and measured evidence

Moto Edge 70 / roadstr, serial ZY22MMG59D. Wi-Fi SSH 192.168.1.154; USB SSH
10.77.71.2. This is native Denial on Arch with a vendor Android-derived kernel.

The user was profiling home-page swipes in Flutter DevTools. A preceding Denial
fix rejected broken DRM timestamps/counters before phase training; the user
reported visibly improved behaviour. Remaining EGL native-fence creation was
around 2.26 ms in an audit interval. Investigation showed the call includes
draining GL work and CPU-side submission, not merely allocating a fence object.

Passive probes of the matching Mesa 26.2.2 binary and scheduler switches compared
two user-performed swipe captures in the same Denial process:

| Measurement | Baseline | Worker capacity trial |
| --- | ---: | ---: |
| Native fence calls | 1,886 | 3,012 |
| Average fence creation | 2.638 ms | 1.101 ms |
| Fence creation p95 | 6.501 ms | 1.836 ms |
| Raster on CPU inside fence, average | 0.564 ms | 0.511 ms |
| Raster off CPU inside fence, average | 2.074 ms | 0.591 ms |
| Submission worker call, average | 0.968 ms | 0.422 ms |
| Submission worker on CPU inside call, average | 0.758 ms | 0.396 ms |
| Submission worker off CPU inside call, average | 0.209 ms | 0.026 ms |

The three active Mesa workers initially ran over 99.8% of measured CPU time on
CPUs 0–2, capacity 429/1024. Giving them uclamp.min=512 moved their measured
execution to CPUs 3–6, capacity 854. CPU 7 has capacity 1024. Flutter's critical
threads already had a 512 request; the driver workers originally had zero.

Do not call this a controlled FPS or placement-only benchmark. The manual
gestures/frame counts differ, tracing adds overhead, and uclamp can affect
frequency as well as placement under schedutil. Frequencies were not isolated
in this comparison. Off-CPU duration includes both blocking and scheduler delay.
The trial's maximum fence call was still 10.703 ms. Power and sustained thermal
behaviour were not measured.

Evidence directory:
`/mnt/development/moto70edge/build/denial-feedback-audit-20260908/`.
Read `FENCE_INVESTIGATION.md`, `fence-trace-110209/summary.json`,
`fence-trace-110819/summary.json` and the retained raw captures/parser there.
All investigation probes and trace instances were removed and cleanup verified.

### Last verified device state, not a permanent identity

- Boot: cf4bf14d-35de-4158-b542-c1fb4a47c3e7; Denial PID 1095.
- Active candidate: /var/lib/moto70-denial/feedback-audit-897ea11dab8c.
- Trial hints remain on TIDs 1109 (deniald:zfq0), 1262 (deniald:gdrv0),
  1263 (deniald:gl0). They disappear when those threads exit.
- Each remains SCHED_OTHER, nice 0, minimum 512, maximum 1024. The trial initially
  set reset-on-fork on all three. Later it was cleared on 1109 by an unidentified
  actor; the minimum remained 512. Do not claim the inheritance guard is proven
  stable. Investigate competing policy writers before a persistent design.
- Saved attributes and start times are in driver-capacity-trial.json and on the
  phone at /var/lib/moto70-denial/driver-capacity-trial-20260908.json.
- driver-capacity-check-restore-remote.py checks identity/state by default;
  --restore restores original attributes. Check mode passed; restore was not run.
- Native, engine and AOT package verification passed; no failed systemd units.
  No engine rebuild was required for the trial.

Always recheck boot/process identity before using these historical TIDs.

## Kernel capability audit

Read-only audit on the same boot found:

- Kernel 6.6.98-moto70-droidloom2-4k, aarch64, PREEMPT.
- CONFIG_UCLAMP_TASK=y and CONFIG_UCLAMP_TASK_GROUP=y.
- CONFIG_ENERGY_MODEL=y; debugfs energy models for cpu0, cpu3, cpu7.
- CPU capacities 429 / 854 / 1024 for the three clusters.
- qcom-cpufreq-hw with schedutil on all clusters; WALT governor also available.
- Qualcomm sched_walt module loaded. CONFIG_SCHED_WALT unset in the core config
  does not mean the separately built vendor module is absent.
- sched_energy_aware=1. This switch alone does not establish use of upstream EAS
  on every wakeup: WALT registers its own fair and RT placement hooks.
- WALT global sched_boost=0. Prior work deliberately released a boot boost.
- sched_util_clamp_min_rt_default=0. Global sched_util_clamp_min=1024 is the
  allowed request ceiling, not a floor applied to every task.
- BPF syscall/JIT, BPF events and BTF are enabled; /sys/kernel/btf/vmlinux exists.
- /sys/kernel/sched_ext is absent; no sched_ext implementation was found in the
  inspected vendor scheduler source. Ordinary BPF support is not sched_ext.
- cgroup v2 CPU controller is available. Denial actually resides in
  /user.slice/user-0.slice/session-4.scope, not its empty service cgroup.
  The session has other processes and no cgroup CPU minimum request.

Audit collector and output are preserved in the evidence directory above as
kernel-placement-audit.py and kernel-placement-audit.json. The collector writes
to /tmp/moto70-scheduler-audit.json when rerun; archive fresh output deliberately.

Matching workspace source for inspection:
/mnt/development/moto70edge/kernel-prep/src/kernel/kernel/sched/.
Relevant WALT files: walt_cfs.c (walt_select_task_rq_fair), walt_rt.c, walt.h
(uclamp_task_util and capacity fitness), walt.c (related thread groups),
pipeline.c, walt_config.c, mvp_locking.c. Source inspection found vendor Binder
boost propagation and kernel-mutex waiter handling. This does **not** establish
generic propagation through Mesa's userspace queues/futexes.

## Android: established mechanisms and evidence

Android is Linux plus framework/vendor integration, not a separate universal
scheduler. Heterogeneous scheduling predates hybrid desktop CPUs. Upstream
uclamp dates to 5.3 (tasks) / 5.4 (cgroups). sched_ext is newer and optional to
our direction. See [kernel uclamp documentation](https://kernel.org/doc/html/latest/scheduler/sched-util-clamp.html).

### Task identity and lifecycle

Android applies profiles to task/process groups, with foreground/top-app and
background distinctions. The abstraction permits vendor-specific mappings to
kernel controls. See [Android cgroup/task-profile documentation](https://source.android.com/docs/core/perf/cgroups)
and [AOSP profile definitions](https://android.googlesource.com/platform/system/core/+/refs/heads/main/libprocessgroup/profiles/task_profiles.json).

OomAdjuster moves top apps into their scheduling group and separately handles
UI/render thread priority on transitions. This is lifecycle knowledge, not an
inference that first requires a slow frame. Priority and CPU placement remain
different mechanisms. [OomAdjuster source](https://android.googlesource.com/platform/frameworks/base/+/master/services/core/java/com/android/server/am/OomAdjuster.java).

HWUI knows UI and render thread IDs explicitly. The inspected main-branch
CanvasContext constructs a HintSessionWrapper with those IDs and calls
startHintSession while setting a surface. That is stronger evidence than assuming
all threads are discovered by a system-wide heuristic.
[CanvasContext source](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/libs/hwui/renderthread/CanvasContext.cpp).

The pinned RenderProxy constructor shows exactly where the IDs come from:
pthread_gettid_np(pthread_self()) supplies the calling UI thread ID;
getRenderThreadTid() returns the owned RenderThread object's ID. It passes both
to CanvasContext::create and posts startHintSession. The wrapper then adds its
known CommonPool thread IDs. This is classification by the rendering framework's
knowledge of thread roles, not a kernel heuristic inspecting utilization or
thread names. The inspected registration does not enumerate arbitrary driver
workers. [Matching RenderProxy revision](https://android.googlesource.com/platform/frameworks/base/+/7d59d89f035a/libs/hwui/renderthread/RenderProxy.cpp).

Earlier proposal: participating frameworks/libraries register known roles while
the standalone component owns enforcement. The user subsequently challenged the
implicit requirement to modify Mesa. Explicit registration only solves threads
whose owner participates; it is not a complete design for unmodified libraries.
See the Mesa/inheritance section below. Do not equate an Android performance
session with our new hard big-only class: Android's actuator semantics differ.

### First-use, renewed activity and feedback

Android exposes interaction/display-update hints that anticipate upcoming work.
These are distinct from steady feedback and can affect multiple hardware domains.
[Power HAL boost interface](https://android.googlesource.com/platform/hardware/interfaces/+/master/power/aidl/android/hardware/power/Boost.aidl).

In the inspected Pixel PowerHintSession implementation, creation installs initial
CPU votes using configured mUclampMinInit and mUclampMinLoadReset. CPU_LOAD_UP,
CPU_LOAD_RESET and CPU_LOAD_RESUME supply bounded requests for workload changes.
Later duration reports feed a PID controller. Pause removes the session's threads
from its active performance management. These mechanisms demonstrate proactive
initialization followed by adaptation; configured values and support vary by device.
[Pixel PowerHintSession source](https://android.googlesource.com/platform/hardware/google/pixel/+/refs/heads/main/power-libperfmgr/aidl/PowerHintSession.cpp).

A pinned HWUI HintSessionWrapper revision implements load-reset/increase hints
and asynchronous session initialization. Its init() explicitly combines
CommonPool::getThreadIds() with the UI and render thread IDs before creating the
session. Thus this implementation includes known HWUI worker-pool threads, not
just the two principal threads. That is explicit membership, not arbitrary GPU
driver-worker discovery. sendLoadResetHint() emits CPU_LOAD_RESET after an
inactivity threshold, with a bound on repeated resets before a duration report.
Check call sites and version before
asserting exact startup timing; session creation is not a universal guarantee
that a CPU request takes effect before every first frame.
[Pinned HWUI wrapper](https://android.googlesource.com/platform/frameworks/base/+/7d59d89f035a/libs/hwui/renderthread/HintSessionWrapper.cpp).

The public performance-hint API supplies thread IDs, target duration and actual
duration. SurfaceFlinger has its own hint-session integration. A published Pixel
PowerSessionManager implementation applies uclamp through sched_setattr while
preserving scheduling policy/parameters.
[API documentation](https://source.android.com/docs/core/perf/performance-hint-api?hl=en),
[SurfaceFlinger integration](https://android.googlesource.com/platform/frameworks/native/+/fd000402301304f9b0436d11407c0afcc003a424/services/surfaceflinger/DisplayHardware/PowerAdvisor.cpp),
[Pixel syscall implementation](https://android.googlesource.com/platform/hardware/google/pixel/+/97d4c083534eee7c18e894ef54d5ff80473e3c2e/power-libperfmgr/aidl/PowerSessionManager.cpp).

These are AOSP and Pixel examples, not proof of every detail of Motorola's
shipping Power HAL. Do not assume Pixel tuning values transfer to this phone,
or that Android guarantees no dropped frames/identifies every driver dependency.

## Proposed abstraction, not a finalized API

Separate portable policy from kernel integration:

| Shared policy | Kernel backend |
| --- | --- |
| Identify work, deadlines and dependent workers | Discover/report actual placement capabilities |
| Select relative capacity and urgency | Apply requests through its supported mechanism |
| Maintain activity lifetime and expiration | Release requests and report their effective state |
| Evaluate latency and fairness | Respect existing CPU eligibility and kernel constraints |

Earlier illustrative interface:
request_placement(thread, minimum_capacity, urgency, expires_at), plus release.
It may need to become a work-session interface with explicit lifecycle and
dependencies; do not freeze the per-thread sketch before studying Android.

Backends must distinguish soft placement preferences, hard affinity restrictions
and performance requests coupled to DVFS. Unsupported semantics must be reported,
not silently approximated. Detect capabilities rather than relying on uname alone.
No mandatory sched_ext dependency. It is a possible future backend, not the
current Moto backend. scx_lavd is a useful existing research reference for
latency/dependency-aware policy on supported kernels, not installed or validated
here: [project](https://github.com/sched-ext/scx/tree/main/scheds/rust/scx_lavd).

## Initial three-group placement policy

The user explicitly accepted trying this initial policy ("let's try it like
this"). They accept that saturated eligible cores do not justify spilling the
hard groups into the opposite class. This is the agreed first experiment:

| Group | CPU eligibility | Initial policy behaviour |
| --- | --- | --- |
| Absolute performance | Big cores only | Never voluntarily place members on little cores, even when idle big cores are unavailable |
| Medium | Big and little cores | Let the existing capacity-aware scheduler select cores with demand; little residency is an objective, not a hard restriction |
| "Out of my way" | Little cores only | Never voluntarily place members on big cores, even when little cores are busy |

The outer groups are **hard eligibility restrictions**, not ordinary performance
hints. Multiple threads may run on different eligible cores concurrently. This
does not reserve cores exclusively, change scheduler priority or force clocks.
Medium tasks remain eligible to compete on big cores; exclusive big-core access
for the first group has not been requested. "Absolute performance" names the
placement class, not a hard execution-time guarantee.

Proposed Moto mapping for this first version: CPUs 0–2 (capacity 429) are little;
CPUs 3–7 (capacities 854 and 1024) are the big pool, including prime. This mapping
is an implementation proposal, not a universal formula: discovering the split
on other three-tier or hybrid systems remains backend/topology work. Do not
hard-code these CPU numbers into shared policy.

Membership stays effective until explicitly changed or released. Automatic
activity-based release and deadline adaptation are later possibilities, not
implicit exceptions to the user's "no matter what" requirement. Medium's first
implementation can delegate demand-based movement to the existing scheduler;
if a stronger little preference is required, it must become an explicit policy.

Hard-class requests must be checked against kernel-enforced CPU eligibility and
online CPUs. An unsupported or empty eligible class must be reported rather
than silently substituted with the opposite class. Hotplug/cpuset changes and
kernel-forced fallback require an explicit backend failure contract; ordinary
affinity alone must not be claimed to override every kernel recovery behaviour.

The class-selection API and the means to assign existing/new driver workers are
still open. Assignment before first execution is needed to protect the first
frame; applying a mask to an already-running thread is insufficient proof.
No backend or live affinity change has been implemented from this proposal.

### Portable baseline for explicit CPU selection

The user asks whether Denial can readily implement this on any kernel supporting
manual big/little selection. For kernels exposing the cores as individually
selectable CPUs and permitting task affinity changes, **the placement operation
already has a longstanding Linux API: sched_setaffinity** (since Linux 2.5.8).
The syscall accepts a CPU mask, not a semantic big/little label. Map Absolute to
the chosen big mask, background to little, and Medium to both within the allowed
CPU domain. This baseline needs neither EAS/uclamp/sched_ext nor a new kernel
patch. It does not prescribe a frequency or clock governor.
[Linux affinity API](https://man7.org/linux/man-pages/man2/sched_setaffinity.2.html).

Earlier discussion of no universal "prefer big" API concerned soft, scheduler-
integrated preferences. It must not be used to imply that hard explicit CPU
selection lacks an existing portable Linux mechanism. Denial can set affinity
for its own threads under ordinary ownership permissions, subject to cpuset and
security restrictions; a privileged standalone service is not inherently needed
for that syscall. This observation does not cancel the user's standalone project
choice: the same baseline can implement its backend.

The remaining adaptation concerns discovery and lifecycle rather than inventing
an affinity syscall. Discover relative core capacity where reliable kernel
topology/capacity data exists; otherwise require an explicit device CPU mapping
and explain what is missing. Do not infer capacity from CPU numbering or MHz
alone. Validate effective allowed/online masks, cover existing threads, establish
inheritance for new ones, and handle background exceptions and library resets.
New pthreads inherit the creator's mask, not an abstract process-wide default.
[Thread inheritance](https://man7.org/linux/man-pages/man3/pthread_create.3.html),
[kernel capacity model](https://docs.kernel.org/scheduler/sched-capacity.html).

Mesa's nice 19/SCHED_BATCH background marking does not itself change CPU affinity.
Observing that marker and applying little-only placement is still userspace
integration work; normal affinity alone does not guarantee classification before
a third-party worker's first instruction. The hotplug, cpuset and competing-writer
limits above remain part of the backend contract. Do not promise every vendor
kernel/device is fully automatic without checking these capabilities.

## Optional registration and attribute-based classification

### Latest clarification: an explicit per-thread attribute

The user asks whether we can attach a new attribute such as
placement_class = performance / balanced / background to a thread. Yes, this
can be part of our component's interface. Linux does not expose an existing
generic arbitrary per-thread key/value namespace for this purpose; the component
must define where the metadata lives and how it is set/read.

A kernel-backed design could expose an optional device ioctl that tags the
calling thread. The backend owns task-lifetime-bound metadata and applies the
class before acknowledging success. This is a design option, not an existing
ioctl or implemented module. Do not imply that an ordinary module can simply
add a generic prctl operation on every stock kernel; kernel integration and
available hooks must be established for each backend.

Denial would only need a small protocol/UAPI definition and normal open/ioctl
calls. An absent device or unsupported operation leaves Denial operational with
its existing policy. A tiny optional client helper could wrap those calls without
a required external shared-library dependency. If metadata instead lives in a
userspace registry, that is component-owned registration rather than a new kernel
task attribute, and enforcement/timing semantics must be stated accordingly.

Keep labeling separate from enforcement. Class changes, thread exit and reuse,
fork/clone inheritance, component unload and backend availability require defined
lifecycle semantics. Prefer addressing the calling thread to ambiguous external
numeric TIDs for the initial registration API. Exact transport/storage and
inheritance policy remain open; no new thread attribute has been implemented.

Further user direction: set the attribute regardless of whether the placement
backend is present. The backend consumes it when available; otherwise it has no
placement effect. Therefore metadata storage must be independent of the optional
enforcer. A minimal kernel tagging facility could retain the class while no
placement backend is loaded. Its storage/API must itself exist on that kernel:
an absent ioctl device or unsupported prctl cannot retain an attribute. On an
unmodified kernel, equivalent retained annotation would need application-owned
storage plus an explicit discovery interface, or tagging must report unavailable.
Do not conflate backend absence with absence of the tagging facility. An optional
enforcer starting later must be able to discover existing live tags. This is the
desired separation, not an implemented or universally available Linux feature.

User objection to that kernel-storage proposal: it adds kernel code and forces
users to build/install supporting kernels. Acknowledge this consequence; do not
present the proposal as solving compatibility merely because enforcement is
optional. It conflicts with the earlier goal of avoiding required kernel upgrades.

Alternative to evaluate: retain labels in application-owned userspace metadata,
published through a defined discovery/update interface. A small embedded client
can maintain this without a required shared library or running service. The
optional standalone component reads labels and uses existing kernel placement
interfaces (e.g. affinity for the hard classes), or an optimized backend when
available. This is metadata about threads, not a new intrinsic Linux task field.
Discovery, permissions, lifetime and acknowledgement still need design; no
registry/transport has been selected or built. Do not claim Linux already has
arbitrary persistent per-thread annotations without any supporting code.

### Earlier inference discussion (not what the user was asking)

No standard Linux placement-role attribute was identified for our exact three
classes. Existing scheduling class, nice value, uclamp request, cgroup membership
and thread name are observable signals. They describe scheduling policy or
identity, not necessarily the capacity required to meet a frame deadline.
[sched_getattr documentation](https://man7.org/linux/man-pages/man2/sched_getattr.2.html),
[thread-name interface](https://man7.org/linux/man-pages/man2/PR_SET_NAME.2const.html).

Current Denial source already promotes its known critical roles to SCHED_RR when
possible, with a high-priority normal-policy fallback. Those attributes could
seed inference. However, our measured Mesa workers were SCHED_OTHER/nice 0 despite
being on the critical path. That is direct evidence against treating ordinary
priority as proof of noncritical work. Conversely, real-time/nice priority does
not universally prove that a task requires a big core. Do not change scheduling
priority merely to smuggle a placement label into an unrelated kernel attribute.

Proposed layering, not yet an accepted implementation:

- Explicit optional registration is authoritative for opted-in threads, subject
  to backend capability and ownership validation.
- Existing attributes can support classification rules for unmodified software;
  application/cgroup context is preferable to global RT-to-big rules. Unknown
  workloads default to Medium rather than being forced into little-only
  placement. The latest explicit Denial workload default is Absolute performance;
  an otherwise unclassified thread inside Denial inherits that workload default.
- Thread names can support compatibility rules but are mutable/short and are
  not a stable semantic contract. These rules are not the project's foundation.
- Dependency observation could supplement both paths later. It is not proof of
  first-execution classification and is not an implemented feature.

An optional registration transport could use a small versioned local Unix-socket
protocol through normal OS APIs, without linking a required external library.
Denial would register at thread startup; absent/unsupported service returns an
unavailable result and preserves its ordinary operation. A tiny vendored client
helper is another packaging choice. Protocol, implementation language and exact
transport remain undecided. An optional API is not a required package dependency.

Distinguish first-frame guarantees from asynchronous discovery: if registration
is used to establish hard eligibility before work, successful backend application
must be acknowledged before that thread's first critical work. A best-effort
message or a later observer scan cannot establish that property. Service absence
intentionally leaves Denial with its existing behaviour; ordinary frame execution
must not depend on the placement service remaining available.

## Unmodified Mesa: creation ownership and inherited workload membership

The user explicitly challenged the labeling discussion: Denial can describe its
own threads, but Mesa creates its own workers and should not need a source change
just to participate. Treat support for unmodified third-party workers as a central
design requirement. Do not keep proposing a metadata transport as though it
answers who classifies those workers.

Source inspection of the actual local Mesa 26.2.2 tree found:

- Mesa's workers are threads **inside the deniald process**, not a separate Mesa
  daemon. Library code running on an existing host thread creates them.
- util_queue_create_thread in src/util/u_queue.c calls u_thread_create;
  src/util/u_thread.c delegates to thrd_create. Denial does not explicitly invoke
  those individual worker creations or directly own their role descriptors.
- zink_screen.c creates the zfq submission queue during screen creation.
- glthread.c creates the gl command queue during GL-thread initialization.
- u_threaded_context.c creates the gdrv queue during threaded-context creation.
- The inspected gl/gdrv queue flags are zero; zfq uses RESIZE_IF_FULL. None of
  these three queue initializations requests SET_FULL_THREAD_AFFINITY.
- The generic queue helper does support SET_FULL_THREAD_AFFINITY, which resets
  other queues to a full mask, and USE_MINIMUM_PRIORITY for background queues.
  Do not assume that every Mesa queue or driver preserves inherited attributes.

Linux pthread creation inherits a copy of the creator's CPU affinity. Cgroup
membership also provides an existing inheritance mechanism. These facts suggest
a route that does not require every library to call a new metadata API.
[pthread inheritance](https://man7.org/linux/man-pages/man3/pthread_create.3.html),
[cpuset interface](https://man7.org/linux/man-pages/man7/cpuset.7.html).

Latest user-selected initial policy: classify the Denial workload by default as
Absolute performance before graphics and Flutter worker initialization, then apply
little-only overrides to background threads. Flutter UI/raster threads and the
three measured Mesa rendering/submission workers belong to the big-only default;
they are all threads in deniald, not separately scheduled library processes.
This removes the need to discover every ordinary Mesa rendering worker's exact
role before granting the workload default. It does not remove the need to identify
background exceptions. Denial can explicitly describe its own roles; Mesa's
USE_MINIMUM_PRIORITY markers provide existing information for those library
queues. Do not claim the marking moves a thread to little cores by itself: the
component/backend must apply the placement override. Classification timing and
library affinity resets still need an implementation and verification.

Plain affinity inheritance is narrower than a durable workload rule: it follows
the actual creator, not a logical rendering dependency; later parent changes do
not retroactively update children, and a library may change affinity. A cpuset
constraint can bound a library's affinity changes, but cgroup topology/delegation,
per-thread overrides and kernel support must be checked. Do not put an entire
process in a hard big-only parent and claim a child override can run on little
cores outside that parent's allowed set. A threaded hierarchy with suitable
sibling groups is a possible design, not a verified feature on this host.

Denial-launched applications must receive their own workload policy rather than
accidentally inheriting compositor restrictions. Creation from already-existing
unclassified helpers, late component startup, library affinity changes and first
critical work all need explicit handling. No process-default policy, cpuset change
or thread-creation interceptor has been implemented or deployed.

The selected direction is inherited workload membership plus background
exceptions. Transport/API and backend design follow that policy. Applying an
affinity mask to only the deniald main TID after workers exist does not implement
it: existing threads need coverage, newly created threads need the right default,
and explicit overrides must survive routine priority changes. A little-only
helper creating a new critical worker must not accidentally determine that
worker's logical class. Kernel instrumentation/interposition may provide creation
information, but does not reveal a queue's semantic role by itself.

### Priority classification clarification

The user initially rejected a broad Denial-default-to-big suggestion because it
could leave low-priority Mesa work on big cores too. After clarifying that Mesa's
fence-creation wait executes on Flutter's raster thread, the user selected the
big-only default **with little-only background exceptions** described above.
Do not implement the default without the exceptions. Moving the component inside
Denial still does not reveal Mesa's internal worker roles; the standalone design
remains applicable.

Mesa's USE_MINIMUM_PRIORITY queues explicitly request nice 19 and SCHED_BATCH.
The three critical workers measured in our trace instead had SCHED_OTHER/nice 0.
These are different populations: background marking and critical workers landing
on little cores do not contradict one another. Mesa marking some tasks as
background does not mark every remaining task as requiring a high-capacity CPU.

The user agrees Denial should mark its own roles appropriately. Audit existing
behaviour first: core compositor/Flutter/Volition roles already have priority
promotion in cpu_scheduling.rs, with fallback handling. Do not claim Denial has
no role marking or elevate arbitrary helpers to RT merely to encode placement.
Low-priority markers can aid background classification, but a policy mapping all
ordinary-priority threads to Medium still leaves the observed critical Mesa
workers eligible for little cores. Resolving those workers requires additional
role/library/dependency context. A new placement attribute alone does not provide
that context for an unmodified driver.

### Challenge: could faster cores be masking a driver bug?

The user challenged the inference that these threads inherently need big cores:
could an unintended wait, serialization or unnecessary work explain the cost?
**This has not been ruled out.** The capacity experiment establishes an observed
improvement, not that the underlying work is minimal or correctly placed on the
frame's critical path. Do not present the trial as a proven root-cause fix.

The user's latest question inverted the priority direction: nice **+19** lowers
priority, and SCHED_BATCH describes latency-insensitive work. Mesa's
USE_MINIMUM_PRIORITY flag requests these for background queues. Leaving the
submission workers at nice 0 does not certify either a driver bug or its absence,
and does not encode a frame deadline or minimum CPU capacity.
[Linux scheduling semantics](https://man7.org/linux/man-pages/man7/sched.7.html).

Reanalysis of both saved captures intersected each submit_queue entry/return span
with that thread's sched_switch running intervals. In the baseline, 78.35% of
aggregate call duration was scheduled on CPU; with the hint it was 93.80%.
The baseline's 0.2095 ms off CPU per call comprised approximately 0.1874 ms in
intervals switched out runnable (R/R+) and 0.0221 ms in intervals switched out
sleeping (S/D). This argues against a long blocking wait explaining most of the
submission worker's average wall time. It does not exclude spinning, extra CPU
work, expensive kernel execution, or rare blocking outliers. Scheduled-on-CPU
intervals include tracing/interrupt overhead. No sched_wakeup events were
captured, so a sleeping interval cannot be divided into actual sleep versus
subsequent runqueue delay. These figures concern the submission worker, not all
three Mesa workers or all raster waits.

Further inspection of the matching Mesa source found concrete paths to measure:

- zink_batch.c: submit_queue ends command buffers, takes queue_lock, submits
  Vulkan work, handles exported resources, runs post_submit, then resets older
  active batches under two locks. util/u_queue.c signals flush_completed only
  after the entire job returns. Therefore the synchronous caller can wait through
  this housekeeping after submission. Its measured contribution and whether any
  part can safely leave that critical path are unknown; early signalling alone
  could introduce lifetime/reuse races.
- zink_screen.h: VRAM_ALLOC_LOOP retries only on VK_ERROR_OUT_OF_DEVICE_MEMORY,
  with escalating sleeps. Existing probes did not record return codes or retry
  counts; no evidence establishes that this error path ran.
- freedreno/vulkan/tu_knl_kgsl.cc: kgsl_queue_submit hands dependency timestamps
  or fence FDs to KGSL and issues IOCTL_KGSL_GPU_COMMAND. safe_ioctl retries
  EINTR/EAGAIN. Existing probes do not split driver preparation, kernel ioctl
  execution, retries and post-submit cleanup.
- That file contains a profiling-only busy-wait for gpu_ticks_queued inside
  HAVE_PERFETTO. The retained matching build's meson-info/intro-buildoptions.json
  has perfetto=false, buildtype=release and optimization=3. This particular
  profiling spin is excluded from that build; other spinning is not ruled out.

The next useful trace should separately time command-buffer finalization,
Vulkan/Turnip submission, KGSL ioctls (including errors/retries), batch reset and
queue wakeups. Add wakeup events to distinguish blocked from runnable delay and
CPU sampling if time remains unattributed. Use user-driven activity and preserve
the current trial until deliberately comparing configurations. No new capture,
driver modification or device policy change was performed for this reanalysis.

## First-frame policy discussion and unresolved questions

An explicit frame/work-start signal can identify critical work before execution.
Observed history can estimate capacity but cannot perfectly predict unseen work.
An earlier proposed policy favoured faster cores for active frame work and
released that preference after activity ended. The latest three-group proposal
above is the starting model instead; do not implicitly expire hard membership.
Both discussions reject intentionally missing a frame as a prerequisite to
granting appropriate placement.

Open questions to resolve next:

1. Trace the exact HWUI/SF first-use and resume call paths, including asynchronous
   session setup, to distinguish proactive requests from timing guarantees.
2. How does the Moto's actual Android policy cover GPU driver worker threads?
   Separate process-group effects, explicit registration, inheritance and vendor
   dependency propagation. No generic automatic solution has been established.
3. What is the best placement-specific WALT integration? Which hook/API can apply
   a request before wakeup CPU selection while respecting existing WALT policy?
   Kernel changes, module interface and build requirements are not yet settled.
4. What constitutes a work session, how are requests composed, and how are stale
   ownership, thread replacement and activity gaps handled without polling races?
5. How do we isolate placement from DVFS in measurement? Changing placement itself
   changes cluster load, so unchanged frequency policy does not imply unchanged
   observed clocks. Do not attribute all prior gains exclusively to placement.
6. Establish backend conformance tests and repeatable latency tests, including
   the first frame after idle, dependent workers, background fairness and overhead.
7. Choose standalone project name/location only when implementation starts.

## Continuation rules

Keep new evidence and user decisions in this document. Mark hypotheses as such;
replace disproved statements rather than preserving a misleading recommendation.
Read Denial AGENTS.md and Moto workspace/procedure rules before device work.
The user performs visual validation; do not inject UI events or take screenshots.
The design discussion itself made no deployment changes. The subsequent
authorized native allocation is tracked in the implementation section above;
use its activation evidence to establish the current device state.
