# Denial thread and process inventory

Captured 2026-09-08. Companion to [CPU placement research](CPU_PLACEMENT_RESEARCH.md).
This is the reference inventory requested before implementing placement. It
describes ownership and creation paths; it does not apply scheduling changes.
This is the **pre-allocation** snapshot. The subsequently authorized native
allocation and its lifecycle limits are recorded in
[the implementation record](CPU_PLACEMENT_RESEARCH.md#initial-denial-implementation-2026-09-08).

## Scope and evidence

Two passive `/proc` snapshots, three seconds apart, found **56 OS threads in
deniald and seven descendant processes**, containing **126 OS tasks in total**
(including each process's main thread). The second snapshot is timestamped
2026-09-08 10:36:15 UTC. A separate read of the existing VM service enumerated
Dart isolates. No applications, input, notifications, screenshots, authentication
attempts or session transitions were triggered.

Moto Edge 70, Wi-Fi `192.168.1.154`, kernel `6.6.98-moto70-droidloom2-4k`.
Boot `cf4bf14d-35de-4158-b542-c1fb4a47c3e7`, deniald PID **1095**, executable
`/var/lib/moto70-denial/feedback-audit-897ea11dab8c/deniald`, SHA-256
`897ea11dab8cb7fc609b5e07f165561e899a16fc0edaedc5c237d4c886158f75`.
The service remained active. This boot/process identity must be rechecked before
using any recorded PID/TID.

Evidence files in [research/thread-inventory](research/thread-inventory/):

- [2026-09-08-moto70.json](research/thread-inventory/2026-09-08-moto70.json): both
  snapshots, every selected task's start time, affinity, scheduling attributes,
  wait channel, CPU accounting and actual cgroup. The ancillary service index is
  filtered; it is not the complete machine process list.
- [2026-09-08-isolates.json](research/thread-inventory/2026-09-08-isolates.json):
  Dart isolate identities, without VM connection credentials.
- [Service metadata](research/thread-inventory/2026-09-08-services.json) and
  [addendum](research/thread-inventory/2026-09-08-service-addendum.json): actual
  systemd relationships and Kitty helper subcommands.
- [Source comparison](research/thread-inventory/2026-09-08-source-comparison.json):
  audited native creation-site files and Cargo lock match the staged native source
  byte-for-byte. Other current checkout files are dirty; no whole-tree identity
  claim is made.
- [collect_moto70.py](research/thread-inventory/collect_moto70.py): read-only
  collector, intended to run over SSH stdin on the Moto. It requires AArch64,
  Python and the existing `denial-moto70.service`; it does not set attributes.
- [Subsequent allocation verification](research/thread-inventory/2026-09-08-allocation.json):
  separate post-deployment boot/PID and two complete Denial mask checks. The
  final snapshot has 36 big-only and 16 little-only threads, with Xwayland on
  all CPUs. This does not replace the original pre-allocation inventory below.

The deployed profile engine was reused, with SHA-256
`a923666d552128c290112fa728abb56238ccf7a867d9378fc5c29d24d00a9192` and package
Flutter lock `9f9691d29cc14310d68f77445a7f2f15f97c5847`. Inspected engine
thread-host/concurrent-loop/DartVM files have no differences between that lock
and the current canonical Flutter commit. The matching Mesa 26.2.2 source/build
used for the earlier binary-matched probes is under
`/mnt/development/moto70edge/investigation/graphics-v4/mesa-26.2.2`.

This inventory combines a complete contemporaneous descendant snapshot with
creation sites for conditional and transient work. It is **not a historical
fork/clone trace**: already-exited children, workers born between samples and
reparented processes cannot all be recovered from `/proc`. Arbitrary applications
and their future subprocess trees are open-ended. Same-process thread status
does not reveal the original creator thread or the EGL context it serves.

## Ownership model

`deniald` contains Denial's native code, its embedded Flutter shell, Dart VM,
Mesa, and helper libraries. The Flutter platform runner uses the existing Denial
main thread. UI/raster/IO are separate engine threads on this device. A call into
Mesa normally executes on the caller until Mesa explicitly queues work.

An EGL fence-creation wait observed inside Mesa executes on **Flutter raster**;
it is not another hidden fence thread. The previously hinted Mesa workers were
only TIDs **1109, 1262 and 1263**, out of the larger Mesa population below.

| Population inside deniald | Observed OS tasks |
| --- | ---: |
| Denial main plus named native workers | 16 |
| Mesa queues | 20 |
| Flutter UI/raster/IO and concurrent pool | 7 |
| Dart IO, VM workers and profiler | 6 |
| Rust async/D-Bus helper libraries | 5 |
| Smithay SHM disposer | 1 |
| Additional thread with unresolved creator | 1 |
| **Total** | **56** |

## Denial-owned native thread creation sites

There are **16 explicit production worker-spawn sites** in the native compositor
and Volition source, plus the existing main thread. A site can create no threads,
one thread, replacement threads, or several concurrent instances. Unit tests and
the separate benchmark/tool binaries are excluded from this count.

"Ordinary" below describes observed priority, not a proven little-only role.
Non-frame service work can still affect interaction response time.

| Full source name / role | Live TID(s) | Creation and work | Placement relevance |
| --- | --- | --- | --- |
| `deniald` main | 1095 | Native event loop, input/Wayland dispatch and Flutter platform runner | Big default; current RR priority 1, uclamp minimum 512 |
| `volition-kms` | 1277 | [volition/mod.rs](../compositor/src/volition/mod.rs:301): DRM/KMS submission scheduler | Big default; current RR 1; current uclamp minimum 0 |
| `denial-priority-guard` | 1107 | [cpu_scheduling.rs](../compositor/src/bin/deniald/cpu_scheduling.rs:302): periodic containment of inherited priority | Background exception candidate |
| `denial-portal-ipc` | 1103 | [portal_ipc.rs](../compositor/src/bin/deniald/portal_ipc.rs:125): portal IPC server/theme publication | Dedicated service worker |
| `denial-control` | 1121 | [output_control.rs](../compositor/src/bin/deniald/output_control.rs:773): control socket listener | Dedicated service worker |
| `denial-control-client` | 5517 | [output_control.rs](../compositor/src/bin/deniald/output_control.rs:958): one connection handler per accepted client, max 32 | Dynamic lifetime; must classify every new instance |
| `denial-authentication` | 1122 | [authentication.rs](../compositor/src/bin/deniald/authentication.rs:757): PAM authentication off the event loop | Interactive service work; PAM adds platform-dependent behavior |
| `denial-audio` | 1148 | [system_controls.rs](../compositor/src/bin/deniald/system_controls.rs:316): PulseAudio control/subscriptions | Controls volume/device state; not the audio server's real-time sample-processing thread |
| `denial-brightness` | 1149 | [system_controls.rs](../compositor/src/bin/deniald/system_controls.rs:324): brightness providers, including optional DDC | Dedicated service worker; provider can create further helpers |
| `denial-session-power` | 1150 | [system_controls.rs](../compositor/src/bin/deniald/system_controls.rs:341): session/power requests | Dedicated service worker |
| `denial-notifications` | 1151 | [notification_server.rs](../compositor/src/bin/deniald/notification_server.rs:156): D-Bus notification server | Dedicated service worker, separate from rendering notifications |
| `denial-orientation` | 1155 | [orientation_sensor.rs](../compositor/src/bin/deniald/orientation_sensor.rs:60): sensor monitoring/reconnection | Dedicated service worker |
| `denial-screenshot-writer` | 1157 | [screenshot.rs](../compositor/src/bin/deniald/screenshot.rs:52): queued PNG encoding/file output | Background exception candidate; presence does not mean a capture was requested |
| `denial-screencopy` | 1120 | [screencopy.rs](../compositor/src/bin/deniald/wayland_frontend/screencopy.rs:182): owns a shared GLES renderer and performs requested copies/readback | Can create/use its own Mesa workers; recording has latency requirements |
| `denial-xembed-tray` | 1208 | [xembed_tray.rs](../compositor/src/bin/deniald/xembed_tray.rs:130): XEmbed tray protocol/capture work | Dedicated service worker |
| `denial-child-reaper` | 3800 | [system_command.rs](../compositor/src/bin/deniald/flutter_runtime/system_command.rs:811): created before first application launch; tracks child exit | Background exception candidate; may be replaced |
| `denial-clipboard-dnd` | Absent | [clipboard.rs](../compositor/src/bin/deniald/wayland_frontend/clipboard.rs:119): one bounded write worker per requested transfer, max 8 | Transient background/service exception |

All named native helpers above except Volition currently use SCHED_OTHER/nice 0.
The explicit normalization helper is already called by most sites. Orientation,
screenshot writer, screencopy and control-client creation do not call it directly;
Volition uses its promotion callback. Current normalization controls priority,
**not affinity**. Do not equate the priority guard's unregistered set with a
safe little-only set.

## Library-owned threads inside deniald

### Mesa: six GL/driver pairs, not one

| Queue / actual names | Live TID(s) | Source and purpose | Existing attributes / implications |
| --- | --- | --- | --- |
| `deniald:zfq0` | 1109 | `zink_screen.c:3621`, `zink_batch.c:644`: shared Zink submission queue | Ordinary, trial minimum 512; measured critical dependency |
| `deniald:gdrv0` | 1114, 1118, 1123, 1125, 1262, 1264 | `u_threaded_context.c:5594`: one Gallium command queue per threaded context | Ordinary; only 1262 was hinted |
| `deniald:gl0` | 1115, 1119, 1124, 1126, 1263, 1265 | `glthread.c:221`: one GL command queue per enabled GLthread context | Ordinary; only 1263 was hinted |
| `deniald:zcq0` | 1112 | `zink_screen.c:366`: pipeline-cache serialization/put queue | **Ordinary**, despite cache work; not recognized by a nice-19-only rule |
| `deniald:zcfq0` through `zcfq3` | 1113, 1116, 1117, 1136 | `zink_screen.c:3778`, `zink_program.c`: cache lookup, shader/program setup and compilation, including optimized background variants | **Ordinary; mixed dependencies.** Zink also waits on compilation/cache fences. Do not call this uniformly disposable background work |
| `deniald:disk$0` | 1111 | `util/disk_cache.c:90`: disk cache job pool, can expand up to four workers | SCHED_BATCH/nice 19; explicitly requests **full affinity**, overriding inherited mask |
| `denial:traceq0` | 1110 | `util/perf/u_trace.c:369`: GPU trace processing | SCHED_BATCH/nice 19; dedicated background candidate |

The repeated `gl0`/`gdrv0` names refer to different contexts; queue indexes restart
at zero. They are not unique identifiers. The prior probe established 1262/1263
as the active pair for the measured swipes. The ownership of every other pair by
specific native/Flutter resource contexts has **not** been established through
a creation trace. Keep all six pairs represented; do not match only the first
thread whose name ends in `gl0`.

Mesa's helper in `util/u_queue.c` creates pthreads through `u_thread_create`,
sets the optional full-affinity mask, applies nice 19 for MINIMUM_PRIORITY queues,
and names the thread. SCHED_BATCH is also requested by the creator for those
queues. Plain affinity inheritance alone therefore does not implement the
little-only disk-cache exception. Queue-level job roles can also be mixed.

Additional configuration-dependent Mesa sites include the Vulkan runtime's
software submission thread (`vulkan/runtime/vk_queue.c:803`), Fossilize database
list updater (`util/fossilize_db.c:485`), file-notifier helper
(`util/os_file_notify.c:201`) and Turnip debug breadcrumbs thread
(`freedreno/vulkan/tu_cs_breadcrumbs.cc:140`). No live TID has been conclusively
assigned to these sites. Their availability is not evidence that they are active.
Different GPUs/drivers have additional pools outside this Moto-specific catalog.

### Flutter and Dart

| Actual name | Live TID(s) | Creation / purpose | Placement relevance |
| --- | --- | --- | --- |
| `io.flutter.ui` | 1266 | Engine thread host; shell UI isolate/event processing | Big default; current RR 1, minimum 512 |
| `io.flutter.rast` | 1267 | Engine thread host; raster/rendering and caller of the measured Mesa fence path | Big default; current RR 1, minimum 512 |
| `io.flutter.io` | 1268 | Engine thread host; resource/IO manager | Engine declares `kBackground`; Denial callback exists, but resource readiness can affect frames |
| `io.worker.1` through `.4` | 1269–1272 | `runtime/dart_vm.cc:275`, `fml/concurrent_message_loop.cc`: shared Flutter/Skia concurrent executor | Includes image decoding and Skia jobs; not dedicated housekeeping threads |
| `dart:io EventHa` | 1273 | Dart `runtime/bin/eventhandler_linux.cc:406`: asynchronous IO/socket/timer event handling | Shared runtime infrastructure |
| `DartWorker` | 1275, 24425, 24506, 24694 | Dart `runtime/vm/thread_pool.cc:337`: dynamically created/reused workers | Isolate execution and runtime tasks, including GC; cannot assign role from this name alone |
| `Dart Profiler T` | 5088 | Dart profiler support in this profile/DevTools session | Profiling-only candidate; truncated name does not distinguish profiler subtypes |

The engine chooses 2–4 concurrent Flutter workers in the inspected implementation.
Counts elsewhere depend on engine configuration and runtime load. Flutter's
priority callback receives UI/display, raster, background and normal categories;
it does **not** constitute a registration callback for every Dart VM/Mesa thread.
Denial supplies the platform runner and leaves UI/raster engine-managed in
[host.rs](../compositor/flutter-engine/src/host.rs:609).

Dart's profiler has separately named interrupter and sample-block-processing
threads; both names truncate to `Dart Profiler T` in `/proc/comm`. The snapshot
does not prove which subtype is TID 5088. Other conditional Dart threads include
`dart:io Process.start` (child exit handling after Dart process creation) and
timeline-file recorder threads. No such additional name appeared here.

**Dart isolates are not dedicated OS threads.** `BackgroundWorker` wraps
`Isolate.spawn`; a debug name is an isolate label. Dart schedules isolate/runtime
work through thread pools. Permanently setting the affinity of whichever
`DartWorker` executes an FFI call would classify that reused OS worker, not
reliably classify the isolate's future work. Dart GC also submits concurrent
mark/sweep tasks to VM pools (`runtime/vm/heap/marker.cc`, `sweeper.cc`).

| Shell isolate / creation path | Observed in VM service | Purpose |
| --- | --- | --- |
| `main` | Yes | Flutter shell, using the UI runner |
| `denial-nvidia-worker` | Yes, even on this Adreno phone | [shell_worker.dart](../dart_shell/lib/src/services/shell_worker.dart:19): optional NVML sampling; returns unavailable results if library/device initialization fails |
| `denial-status-notifier-worker` | No | [status_notifier_service.dart](../dart_shell/lib/src/services/status_notifier_service.dart:44): persistent tray D-Bus backend when started |
| `denial-system-tray-icon-resolver` | No | [system_tray_module.dart](../dart_shell/lib/src/desktop/system_tray_module.dart:66): persistent icon lookup worker when used |
| `denia-launcher-desktop-$reason` | No | [home_grid_controller.dart](../dart_shell/lib/src/launcher/controllers/home_grid_controller.dart:327): transient desktop application discovery via `Isolate.run` |
| Unnamed notification icon lookup / bounded image read | No | [notification_media.dart](../dart_shell/lib/src/widgets/notification_media.dart:41): two transient `Isolate.run` creation paths |
| `vm-service` system isolate | Yes | Debug/profile service; not a separate process |

The isolate snapshot cannot assign a fixed OS TID to each background isolate.
The launcher/image paths may have completed before observation. Current shell
source is a capability catalog; the installed AOT bundle was reused and is not
claimed to contain every current dirty-checkout change.

### Other native libraries

| Actual name | Live TID(s) | Owner / role | Confidence |
| --- | --- | --- | --- |
| `async-io` | 1105 | async-io 2.6.0 reactor; `src/driver.rs:29` | Source-matched role |
| `zbus::Connectio` | 1106, 1152, 1154 | zbus 5.18.0 connection executors; `src/connection/builder.rs:733` | Role known; exact live connection-to-TID mapping not traced |
| `blocking-3195` | 24713 | blocking 1.6.2 dynamically sized worker pool; `src/lib.rs:326` | Role known; current submitted operation not established |
| `Shm dropping th` | 1210 | Smithay `src/wayland/shm/pool.rs:30`: lazy shared-memory pool disposer; moves munmap/close out of the main thread | Dedicated housekeeping candidate |
| `deniald` (additional thread) | 1207 | Creator unresolved; observed ordinary priority and sleeping in `do_sys_poll` | **Unknown. Do not classify as little-only from inactivity or inherited name** |

Smithay additionally creates an unnamed child-wait thread when Xwayland
disconnects (`src/xwayland/xserver.rs:389`). Xwayland was still active here; that
site does not establish the identity of TID 1207.

The native audio backend explicitly starts `pa_threaded_mainloop_start`
([audio.rs](../compositor/src/bin/deniald/system_controls/audio.rs:379)), which
can create another library thread when a PulseAudio connection succeeds. Its
live identity is not proven here. Do not simply assign it to the unknown TID.
libpulse and libasyncns were mapped. PAM modules, optional libddcutil, NVML,
libseat backend selection and alternate graphics drivers can add configured
library helpers or executable helpers. These are conditional integration
boundaries, not a claim that extra helpers were observed on this phone.

## Processes and their subprocesses

### Live descendant tree

```text
systemd (1)
└─ deniald (1095)                                      56 threads
   ├─ (sd-pam) (1102)                                   1 thread
   ├─ Xwayland (1108)                                   1 thread
   ├─ kitty (3801)                                     14 threads
   │  ├─ kitten __atexit__ (3837)                        9 threads
   │  ├─ bash (3839)                                    1 thread
   │  └─ kitten __watch_conf__ (3845)                    9 threads
   └─ denial-settings (5483)                           35 threads
```

`(sd-pam)` is systemd's PAM session helper associated with `PAMName=login`,
inherited in the launched service process tree. It is not a Denial rendering
subsystem, despite its current PPID. The service invokes deniald directly;
the normal PC `denial-session` wrapper is not present in this Moto ancestry.

Xwayland is spawned directly through Smithay from
[wayland_frontend/startup.rs](../compositor/src/bin/deniald/wayland_frontend/startup.rs:243).
The call's customization closure is currently empty. Its path does not use the
ordinary application-launch helper and needs a separate placement decision.
Smithay launches `Xwayland` and supplies its Wayland/X11 sockets; Xwayland itself
can create additional driver threads on other workloads/configurations.

Kitty and Settings are independent application workloads. The existing Settings
process is a separate Flutter GTK application, not Denial's embedded shell.
Its observed threads include GTK/GLib/D-Bus/fontconfig/dconf helpers, its own
Mesa queues and its own Flutter raster/IO/concurrent workers. Its current source
plugin registrant is empty, and no explicit Dart process/isolate spawn sites
were found in `settings_app`. No separate `io.flutter.ui` name was observed in
that process; do not invent an additional UI TID from the shell's topology.
The exact task names and IDs for every descendant are in the appendix.

Kitty's two `kitten` helper purposes were verified from their first subcommand
only; user command arguments and environments were not captured. Its shell has
its own user-manager scope, despite remaining a PPID descendant. Application
children can create arbitrary further applications, workers and services.

### All identified Denial process-launch paths

| Path | Processes it can create | Boundary to handle |
| --- | --- | --- |
| Native `launch_application` | Executable specified by a desktop entry / shell command, including Settings, terminal, opener and arbitrary user applications; all their subprocesses | [system_command.rs](../compositor/src/bin/deniald/flutter_runtime/system_command.rs:618) funnels native application launches through one command builder/reaper |
| Smithay Xwayland startup | `Xwayland` plus its library workers | Separate creation path, outside application command builder |
| Dart UI workspace setup | `/usr/bin/denialctl --json ui setup` | [ui_development.dart](../dart_shell/lib/src/state/ui_development.dart:42): Dart `Process.run` bypasses native pre-exec scheduling reset |
| `denialctl` development operations | Git and `denial-ui` tool processes | [denialctl.rs](../compositor/src/bin/denialctl.rs:696); conditional developer workflow, absent from snapshot |
| `denial-ui` | Pinned Flutter tool runtime; exec for attached commands or status/wait for finite commands, then the tool's own descendants | [denial_ui.rs](../compositor/src/bin/denial_ui.rs:757); external development workload |
| Session activation / D-Bus requests | User-manager and D-Bus activated services; not generally PPID descendants | [session_activation.rs](../compositor/src/bin/deniald/session_activation.rs): publishes environment, starts session target via D-Bus |
| PAM / optional provider libraries | Backend/configuration-dependent helpers | Not centrally spawned through `launch_application`; inspect installed provider before making strict claims |

Normal native application launch resets SCHED_OTHER/nice and the inherited signal
mask in `pre_exec`, but **does not restore CPU affinity**. The current code would
therefore leak a future big-only inherited affinity into launched applications
unless this boundary is extended. Changing process groups does not reset CPU
affinity. The Dart process and Xwayland paths need their own handling too.

The PC [denial-session](../packaging/arch/denial-session) script creates deniald
as its child and performs session cleanup after exit. It is an ancestor, not a
deniald-created helper. The Alpine wrapper additionally starts audio/polkit
session services under `dbus-run-session`; those are session siblings/ancestors
with their own lifecycle. Packaging/tool subprocesses are not compositor workers.

### Related services outside the descendant tree

The live Denial task cgroup is `/user.slice/user-0.slice/session-4.scope`.
`systemctl show denial-moto70.service` reports its service cgroup separately;
using that empty service cgroup would miss the process. Most native application
children share the session scope, so treating that entire scope as compositor
work would also misclassify applications.

| Live service/process | PID(s) / relationship | Meaning for inventory |
| --- | --- | --- |
| User systemd manager | 960 | Owner of activated session services, not a deniald child |
| User D-Bus broker launcher/broker | 1142 / 1146 | Session infrastructure |
| `droidloom.service` / `droidloom-wayland` | 1161, 12 threads in the process index | `graphical-session.target` Wants this service; it Wants `droidloom-applications.service` |
| `droidloom-applications` | 1361 | Activated companion service, PPID 960 |
| System `droidloomd` and Android | 1160 → unshare 1359 → Android init 1362 → Android services/apps | Separate system-service tree. Denial's session integration can involve it; do not recursively classify the Android system as compositor work |
| PipeWire / WirePlumber / PulseAudio compatibility server | 3723 / 3724 / 3725 | Independent audio services; their audio real-time threads are not Denial's volume-control worker |
| Desktop portal / GTK portal | 3812 / 3856 | User-manager services; D-Bus interaction does not make them deniald threads |
| Permission store / accessibility services | 3820 / 3882 / 3893; accessibility broker 3888 → 3890 | Independent services and subprocesses |
| `denial-portal` | Absent; `denial-portal.service` not installed on this phone | Repository provides a D-Bus-activated settings/theme portal backend with its own main and zbus/async helper threads |

The portal backend's test module spawns a portal frontend and `busctl`; those
are **test-only** sites, not production subprocesses. Systemd target dependency
metadata establishes configuration relationships, not proof of which historical
client first activated a service. The independently owned Android/service trees
are bounded here at their interfaces; they are not part of the 126-task Denial
descendant total.

## Findings to carry into implementation

1. The intended big-only workload default covers many more Mesa workers than the
   three in the trial. That is expected; six independent GL/driver pairs exist.
2. Existing background marking is incomplete for automatic exceptions: the Zink
   cache-put queue is ordinary priority, and compilation/cache-get workers have
   mixed uses. Conversely, ordinary priority is not evidence of unimportance.
3. Mesa's disk-cache pool explicitly resets affinity. A once-only startup mask
   needs additional exception handling and verification; inherited affinity does
   not remain authoritative against later library calls.
4. Denial has convenient native worker startup sites and a Flutter role callback.
   Several sites lack even explicit priority normalization; list each boundary
   deliberately rather than sweeping all unregistered tasks into little-only.
5. Flutter's concurrent pool and DartWorker pools are not cleanly separated by
   workload urgency. Keep unresolved/mixed threads in the accepted big default
   until their exception is justified. An isolate label alone cannot safely pin
   pooled OS workers across subsequent jobs.
6. Application, Xwayland, Dart process, and indirect service boundaries differ.
   An entire session cgroup or recursive process-tree big mask is not the intended
   compositor-only policy. Restore the independent application CPU domain at
   launch, before its own threads and subprocesses inherit it.
7. TID 1207's creator and the profiler subtype remain unresolved. Other queue
   roles are known, but precise EGL-context/connection/pool-job ownership was not
   captured. A future creation trace can associate new instances with their
   creator; an old thread's PPID cannot reconstruct that information.

No affinity, priority, uclamp, engine, driver or service settings changed during
this inventory. The previous three-worker uclamp trial remains a separate
experiment. All observed tasks below still allow CPUs **0–7**; none is currently
hard big-only or little-only. The proposed Moto split remains little 0–2 and
big 3–7, subject to effective allowed/online masks.

## Complete live task appendix

Generated from the second snapshot. Names are Linux `comm` values and can be
truncated to 15 bytes. `OTHER` = SCHED_OTHER, `RR` = SCHED_RR, `BATCH` =
SCHED_BATCH. Every row permits CPUs 0–7 and has uclamp maximum 1024.
Minimum values below are current hints, not hard CPU restrictions. CPU and wait
states in the raw snapshot describe the sampling instant, not role importance.

### PID 1095: deniald

PPID 1; 56 tasks; executable `/var/lib/moto70-denial/feedback-audit-897ea11dab8c/deniald`.

| TID | Observed name | Policy | Nice | RT priority | uclamp minimum |
| ---: | --- | --- | ---: | ---: | ---: |
| 1095 | `deniald` | RR | 0 | 1 | 512 |
| 1103 | `denial-portal-i` | OTHER | 0 | 0 | 0 |
| 1105 | `async-io` | OTHER | 0 | 0 | 0 |
| 1106 | `zbus::Connectio` | OTHER | 0 | 0 | 0 |
| 1107 | `denial-priority` | OTHER | 0 | 0 | 0 |
| 1109 | `deniald:zfq0` | OTHER | 0 | 0 | 512 |
| 1110 | `denial:traceq0` | BATCH | 19 | 0 | 0 |
| 1111 | `deniald:disk$0` | BATCH | 19 | 0 | 0 |
| 1112 | `deniald:zcq0` | OTHER | 0 | 0 | 0 |
| 1113 | `deniald:zcfq0` | OTHER | 0 | 0 | 0 |
| 1114 | `deniald:gdrv0` | OTHER | 0 | 0 | 0 |
| 1115 | `deniald:gl0` | OTHER | 0 | 0 | 0 |
| 1116 | `deniald:zcfq1` | OTHER | 0 | 0 | 0 |
| 1117 | `deniald:zcfq2` | OTHER | 0 | 0 | 0 |
| 1118 | `deniald:gdrv0` | OTHER | 0 | 0 | 0 |
| 1119 | `deniald:gl0` | OTHER | 0 | 0 | 0 |
| 1120 | `denial-screenco` | OTHER | 0 | 0 | 0 |
| 1121 | `denial-control` | OTHER | 0 | 0 | 0 |
| 1122 | `denial-authenti` | OTHER | 0 | 0 | 0 |
| 1123 | `deniald:gdrv0` | OTHER | 0 | 0 | 0 |
| 1124 | `deniald:gl0` | OTHER | 0 | 0 | 0 |
| 1125 | `deniald:gdrv0` | OTHER | 0 | 0 | 0 |
| 1126 | `deniald:gl0` | OTHER | 0 | 0 | 0 |
| 1136 | `deniald:zcfq3` | OTHER | 0 | 0 | 0 |
| 1148 | `denial-audio` | OTHER | 0 | 0 | 0 |
| 1149 | `denial-brightne` | OTHER | 0 | 0 | 0 |
| 1150 | `denial-session-` | OTHER | 0 | 0 | 0 |
| 1151 | `denial-notifica` | OTHER | 0 | 0 | 0 |
| 1152 | `zbus::Connectio` | OTHER | 0 | 0 | 0 |
| 1154 | `zbus::Connectio` | OTHER | 0 | 0 | 0 |
| 1155 | `denial-orientat` | OTHER | 0 | 0 | 0 |
| 1157 | `denial-screensh` | OTHER | 0 | 0 | 0 |
| 1207 | `deniald` | OTHER | 0 | 0 | 0 |
| 1208 | `denial-xembed-t` | OTHER | 0 | 0 | 0 |
| 1210 | `Shm dropping th` | OTHER | 0 | 0 | 0 |
| 1262 | `deniald:gdrv0` | OTHER | 0 | 0 | 512 |
| 1263 | `deniald:gl0` | OTHER | 0 | 0 | 512 |
| 1264 | `deniald:gdrv0` | OTHER | 0 | 0 | 0 |
| 1265 | `deniald:gl0` | OTHER | 0 | 0 | 0 |
| 1266 | `io.flutter.ui` | RR | 0 | 1 | 512 |
| 1267 | `io.flutter.rast` | RR | 0 | 1 | 512 |
| 1268 | `io.flutter.io` | OTHER | 0 | 0 | 0 |
| 1269 | `io.worker.1` | OTHER | 0 | 0 | 0 |
| 1270 | `io.worker.2` | OTHER | 0 | 0 | 0 |
| 1271 | `io.worker.3` | OTHER | 0 | 0 | 0 |
| 1272 | `io.worker.4` | OTHER | 0 | 0 | 0 |
| 1273 | `dart:io EventHa` | OTHER | 0 | 0 | 0 |
| 1275 | `DartWorker` | OTHER | 0 | 0 | 0 |
| 1277 | `volition-kms` | RR | 0 | 1 | 0 |
| 3800 | `denial-child-re` | OTHER | 0 | 0 | 0 |
| 5088 | `Dart Profiler T` | OTHER | 0 | 0 | 0 |
| 5517 | `denial-control-` | OTHER | 0 | 0 | 0 |
| 24425 | `DartWorker` | OTHER | 0 | 0 | 0 |
| 24506 | `DartWorker` | OTHER | 0 | 0 | 0 |
| 24694 | `DartWorker` | OTHER | 0 | 0 | 0 |
| 24713 | `blocking-3195` | OTHER | 0 | 0 | 0 |

### PID 1102: (sd-pam)

PPID 1095; 1 tasks; executable `/usr/lib/systemd/systemd-executor`.

| TID | Observed name | Policy | Nice | RT priority | uclamp minimum |
| ---: | --- | --- | ---: | ---: | ---: |
| 1102 | `(sd-pam)` | OTHER | 0 | 0 | 0 |

### PID 1108: Xwayland

PPID 1095; 1 tasks; executable `/usr/bin/Xwayland`.

| TID | Observed name | Policy | Nice | RT priority | uclamp minimum |
| ---: | --- | --- | ---: | ---: | ---: |
| 1108 | `Xwayland` | OTHER | 0 | 0 | 0 |

### PID 3801: kitty

PPID 1095; 14 tasks; executable `/usr/bin/kitty`.

| TID | Observed name | Policy | Nice | RT priority | uclamp minimum |
| ---: | --- | --- | ---: | ---: | ---: |
| 3801 | `kitty` | OTHER | 0 | 0 | 0 |
| 3818 | `kitty:disk$0` | BATCH | 19 | 0 | 0 |
| 3819 | `kitty:zfq0` | OTHER | 0 | 0 | 0 |
| 3823 | `kitty:traceq0` | BATCH | 19 | 0 | 0 |
| 3824 | `kitty:disk$0` | BATCH | 19 | 0 | 0 |
| 3825 | `kitty:zcq0` | OTHER | 0 | 0 | 0 |
| 3826 | `kitty:zcfq0` | OTHER | 0 | 0 | 0 |
| 3827 | `kitty:gdrv0` | OTHER | 0 | 0 | 0 |
| 3828 | `kitty:gl0` | OTHER | 0 | 0 | 0 |
| 3834 | `kitty:zcfq1` | OTHER | 0 | 0 | 0 |
| 3835 | `kitty:zcfq2` | OTHER | 0 | 0 | 0 |
| 3836 | `kitty:zcfq3` | OTHER | 0 | 0 | 0 |
| 3838 | `KittyChildMon` | OTHER | 0 | 0 | 0 |
| 3853 | `kitty:disk$1` | BATCH | 19 | 0 | 0 |

### PID 3837: kitten

PPID 3801; 9 tasks; executable `/usr/bin/kitten`.

| TID | Observed name | Policy | Nice | RT priority | uclamp minimum |
| ---: | --- | --- | ---: | ---: | ---: |
| 3837 | `kitten` | OTHER | 0 | 0 | 0 |
| 3860 | `kitten` | OTHER | 0 | 0 | 0 |
| 3861 | `kitten` | OTHER | 0 | 0 | 0 |
| 3863 | `kitten` | OTHER | 0 | 0 | 0 |
| 3864 | `kitten` | OTHER | 0 | 0 | 0 |
| 3865 | `kitten` | OTHER | 0 | 0 | 0 |
| 3870 | `kitten` | OTHER | 0 | 0 | 0 |
| 3871 | `kitten` | OTHER | 0 | 0 | 0 |
| 3876 | `kitten` | OTHER | 0 | 0 | 0 |

### PID 3839: bash

PPID 3801; 1 tasks; executable `/usr/bin/bash`.

| TID | Observed name | Policy | Nice | RT priority | uclamp minimum |
| ---: | --- | --- | ---: | ---: | ---: |
| 3839 | `bash` | OTHER | 0 | 0 | 0 |

### PID 3845: kitten

PPID 3801; 9 tasks; executable `/usr/bin/kitten`.

| TID | Observed name | Policy | Nice | RT priority | uclamp minimum |
| ---: | --- | --- | ---: | ---: | ---: |
| 3845 | `kitten` | OTHER | 0 | 0 | 0 |
| 3857 | `kitten` | OTHER | 0 | 0 | 0 |
| 3858 | `kitten` | OTHER | 0 | 0 | 0 |
| 3859 | `kitten` | OTHER | 0 | 0 | 0 |
| 3862 | `kitten` | OTHER | 0 | 0 | 0 |
| 3866 | `kitten` | OTHER | 0 | 0 | 0 |
| 3867 | `kitten` | OTHER | 0 | 0 | 0 |
| 3868 | `kitten` | OTHER | 0 | 0 | 0 |
| 3869 | `kitten` | OTHER | 0 | 0 | 0 |

### PID 5483: denial-settings

PPID 1095; 35 tasks; executable `/var/lib/moto70-denial/settings1/bundle/denial-settings`.

| TID | Observed name | Policy | Nice | RT priority | uclamp minimum |
| ---: | --- | --- | ---: | ---: | ---: |
| 5483 | `denial-settings` | OTHER | 0 | 0 | 0 |
| 5485 | `pool-spawner` | OTHER | 0 | 0 | 0 |
| 5486 | `gmain` | OTHER | 0 | 0 | 0 |
| 5487 | `gdbus` | OTHER | 0 | 0 | 0 |
| 5488 | `[pango] fontcon` | OTHER | 0 | 0 | 0 |
| 5490 | `dconf worker` | OTHER | 0 | 0 | 0 |
| 5491 | `denial-:disk$0` | BATCH | 19 | 0 | 0 |
| 5492 | `denial-se:zfq0` | OTHER | 0 | 0 | 0 |
| 5493 | `denial:traceq0` | BATCH | 19 | 0 | 0 |
| 5494 | `denial-:disk$0` | BATCH | 19 | 0 | 0 |
| 5495 | `denial-se:zcq0` | OTHER | 0 | 0 | 0 |
| 5496 | `denial-s:zcfq0` | OTHER | 0 | 0 | 0 |
| 5497 | `denial-s:gdrv0` | OTHER | 0 | 0 | 0 |
| 5498 | `denial-set:gl0` | OTHER | 0 | 0 | 0 |
| 5499 | `denial-s:gdrv0` | OTHER | 0 | 0 | 0 |
| 5500 | `denial-set:gl0` | OTHER | 0 | 0 | 0 |
| 5501 | `denial-s:gdrv0` | OTHER | 0 | 0 | 0 |
| 5502 | `denial-set:gl0` | OTHER | 0 | 0 | 0 |
| 5503 | `denial-s:gdrv0` | OTHER | 0 | 0 | 0 |
| 5504 | `denial-set:gl0` | OTHER | 0 | 0 | 0 |
| 5505 | `denial-s:gdrv0` | OTHER | 0 | 0 | 0 |
| 5506 | `denial-set:gl0` | OTHER | 0 | 0 | 0 |
| 5507 | `io.flutter.rast` | OTHER | 0 | 0 | 0 |
| 5508 | `io.flutter.io` | OTHER | 0 | 0 | 0 |
| 5509 | `io.worker.1` | OTHER | 0 | 0 | 0 |
| 5510 | `io.worker.2` | OTHER | 0 | 0 | 0 |
| 5511 | `io.worker.3` | OTHER | 0 | 0 | 0 |
| 5512 | `io.worker.4` | OTHER | 0 | 0 | 0 |
| 5513 | `dart:io EventHa` | OTHER | 0 | 0 | 0 |
| 5524 | `denial-s:zcfq1` | OTHER | 0 | 0 | 0 |
| 5525 | `denial-s:zcfq2` | OTHER | 0 | 0 | 0 |
| 5526 | `denial-s:zcfq3` | OTHER | 0 | 0 | 0 |
| 5527 | `denial-:disk$1` | BATCH | 19 | 0 | 0 |
| 5528 | `denial-:disk$2` | BATCH | 19 | 0 | 0 |
| 5529 | `denial-:disk$3` | BATCH | 19 | 0 | 0 |
