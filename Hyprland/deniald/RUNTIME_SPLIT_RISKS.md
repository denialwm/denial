# Runtime split risk ledger

This file tracks behavior-sensitive changes made while splitting `CRuntime` by
responsibility. It is intentionally operational: each entry names the invariant,
likely failure symptoms, and the evidence required before the change is treated
as safe. Keep it until the split has survived extended real-session testing.

## Non-negotiable invariants

- Flutter engine shutdown precedes destruction of callbacks, plugins, external
  textures, EGL objects, controllers, and main-loop dispatch state.
- Platform-message channel names have independent owned storage; registering one
  handler must never overwrite another handler.
- Platform messages whose data outlives an engine callback own their bytes.
- Wayland buffers and EGL images remain alive through the last GPU consumer and
  are released on the required thread.
- Output buffers only move through valid `FREE -> PREPARING -> READY -> SUBMITTED
  -> SCANNING` transitions, except an intentional scanout repeat.
- Flutter vsync batons are answered once and only from a physical output pulse.
- Flutter raster callbacks never synchronously wait for work that can only run on
  that same raster callback path.
- Input routing always consumes one immutable, verified layout snapshot.
- Audio, brightness, input, and power controls never spawn a CLI process from
  embedded Dart.
- No render-loop path reads mutable process environment state.

## Responsibility map

- `Runtime.cpp`: construction, startup/shutdown, and main-loop dispatch.
- `RuntimeBridge.cpp`: wire envelopes, verified request dispatch, and the
  ordered platform-channel ingress.
- `RuntimeSnapshots.cpp`: immutable window/display snapshot construction and
  FlatBuffer serialization.
- `RuntimeWindows.cpp`: compositor window observation, placement, cursor state,
  semantic shell/window actions, and request execution.
- `RuntimeShortcuts.cpp`: shortcut policy and orchestration across the native
  controllers, Flutter shell, and focused compositor window.
- `RuntimeControls.cpp`: notifications, audio, brightness, haptics, OSK,
  keyboard injection, and native system-command handling.
- `RuntimeFlutter.cpp`: Flutter/EGL host lifetime, engine restart, task queue,
  and non-presentation embedder callbacks.
- `RuntimeInput.cpp`: immutable-layout hit testing, coordinate mapping, and
  Flutter pointer/touch/keyboard delivery.
- `RuntimeOutput.cpp`: display layout, output state machines, KMS targets,
  damage, synchronization, screen copy, and presentation callbacks.
- `RuntimeOutputState.hpp`: allocation-free, constexpr output-buffer transition
  contract shared by production code and focused tests.
- `RuntimeSurfaces.cpp`: client buffer import, external textures, generations,
  sampled-buffer lifetime, and texture callbacks.
- `RuntimeInternal.hpp`: single definitions for shared constants and small
  implementation-only helpers.
- `RuntimeFlutterState.hpp`: private Flutter/EGL state shared by implementation
  units without exposing it through the public runtime interface.

## Runtime pulse map

```text
                                  Flutter engine
                                tasks | frames/vsync
                                      v
Wayland input -> RuntimeInput -> CRuntime -> RuntimeOutput -> physical outputs
                                      |
client buffers -> RuntimeSurfaces ----+----> external Flutter textures
                                      |
platform wire -> RuntimeBridge -------+----> RuntimeSnapshots
                                           RuntimeWindows
                                           RuntimeShortcuts
                                           RuntimeControls
```

`CRuntime` remains the sole owner and synchronization boundary. The split gives
each flow a visible home without inserting a facade, queue, allocation, or
thread hop between these chambers.

## Risk register

### R-001: Translation-unit split changes helper visibility

- Change: Move existing `CRuntime` member definitions and their private helpers
  into responsibility-focused `.cpp` files.
- Risk: A helper may be duplicated with subtly different behavior, initialized
  in a different order, or lose compile-time feature guards.
- Symptoms: link errors, diagnostics-only build failures, different fallback
  selection, or behavior that changes only after engine reload.
- Guard: Move each helper with its sole consumer; shared helpers get one declared
  internal API instead of copied implementations. Preserve feature guards and
  constants byte-for-byte during the first split.
- Evidence: Release build, diagnostics build where available, native suite, and
  source searches proving one definition per helper.

### R-002: Platform bridge and native control extraction

- Change: Isolate wire dispatch, platform channels, notifications, audio,
  brightness, haptics, OSK, and system commands from rendering.
- Risk: handler lifetime or callback ownership can outlive `CRuntime` or the
  Flutter engine; message ordering can change.
- Symptoms: mouse layout unavailable, applications not launching, controls
  becoming inert, duplicate replies, or teardown crashes.
- Guard: Keep channel registration and unregistration paired with engine
  lifetime. Copy callback payloads before dispatch. Preserve main-thread hops.
- Evidence: channel-isolation regression test, wire tests, runtime mouse/app
  launch test, audio/brightness shortcut test, and clean logout/reload.

### R-003: Flutter host lifecycle extraction

- Change: Isolate engine creation, task scheduling, callbacks, restart, and EGL
  context ownership.
- Risk: callbacks race shutdown, task timers retain a dead host, or contexts and
  textures are destroyed in the wrong order.
- Symptoms: compositor hang or crash during reload/logout, blinking display,
  missing input after restart, or `systemd-coredump` consuming a CPU core.
- Guard: Make stop idempotent; disconnect handlers and timers before destroying
  the host; drain or invalidate callbacks before EGL teardown.
- Evidence: repeated engine reload, logout/login, idle shutdown, and native tests.

### R-004: Surface import and external-texture extraction

- Change: Isolate dma-buf import, EGLImage caches, generation queues, texture
  notifications, and sampled-buffer holds.
- Risk: early buffer release, stale texture callbacks, unbounded queues, or GL
  destruction on the wrong thread.
- Symptoms: corrupted or frozen windows, client disconnects, memory growth,
  intermittent GL errors, or crashes during rapid window close.
- Guard: Preserve generation monotonicity, queue bounds, stable texture IDs,
  raster-thread retirement, and sampled lifetime holds.
- Evidence: window churn, video playback, rapid resize/close, memory observation,
  and presentation feedback checks.

### R-005: Output pipeline and presentation extraction

- Change: Isolate display layout, per-output state, shared atlas, fallback copy,
  fences, damage history, and page-flip scheduling.
- Risk: invalid state transitions, circular waits, reused scanning buffers,
  dropped damage, or cross-monitor coordinate errors.
- Symptoms: compositor freeze while audio continues, one frozen monitor, flicker,
  stale frames, high CPU, or a crash during high load/hotplug.
- Guard: Preserve the state machine and thread boundaries before optimizing it.
  Add assertions around ownership transitions and keep fallback presentation
  available.
- Evidence: multi-monitor runtime test, high-CPU stress, mixed refresh test,
  hotplug/reload, full native suite, and clean coredump/journal inspection.

### R-006: Explicit output-buffer transition contract

- Change: Replace scattered live-state assignments with named events validated
  against one transition table. Destruction remains an explicit unconditional
  reset after every frame reference and callback has been cleared.
- Risk: An event may encode an incorrect expected state, or diagnostics could
  accidentally turn a recoverable bookkeeping mismatch into a compositor
  stall.
- Symptoms: `invalid output target transition` in the journal, a target pool
  that remains saturated, frozen scanout, or repeated KMS commit failures.
- Guard: Invalid events are logged in production but retain the historical
  destination assignment so diagnostics cannot stop ownership progress. The
  contract has compile-time sequence tests and introduces no allocation,
  locking, or environment lookup.
- Behavior fix: A rejected repeated shared-atlas commit now remains
  `SCANNING`; the previous code marked the buffer `FREE` even though the prior
  scanout may still own it. A cancelled direct target also returns to `FREE`
  even if its monitor output disappeared before swapchain rollback.
- Evidence: `denial_runtime_output_state_test`, full native suite, runtime
  multi-monitor exercise, and journal search for transition violations.

### R-007: Bridge responsibility split

- Change: Divide the former bridge translation unit into wire, snapshots,
  windows, shortcuts, and native-control units while retaining one `CRuntime`
  owner and the original method bodies.
- Risk: Moving anonymous helpers or direct type dependencies may silently bind
  a different overload, change a feature guard, or omit a callback from the
  executable.
- Symptoms: link failure, missing window snapshots, inert shortcuts or sliders,
  notification/OSK failures, or platform messages accepted without dispatch.
- Guard: Preserve every method exactly once, keep the shared wire sequence and
  channel ownership on `CRuntime`, give each unit direct includes, and avoid a
  new facade, allocation, queue, or thread hop.
- Evidence: source and linked-symbol set comparison, Release build, all native
  tests, mouse/app/dual-monitor exercise, controls and shortcuts exercise, and
  notification/OSK smoke tests where available.

## Optimization decisions

- Keep `RuntimeOutput.cpp` as one translation unit. Denial explicitly builds
  with `-fno-lto`; splitting its tightly coupled frame scheduling, fence, and
  KMS call graph further would remove useful inlining opportunities across the
  hottest boundary.
- Output transition validation adds one predictable comparison only when a
  target changes ownership. State and event tables are `constexpr`; the normal
  path allocates nothing and performs no logging, locking, or system calls.
- The responsibility split adds no polymorphic dispatch or heap-owned facade
  to rendering. Existing `CRuntime` members remain directly accessible to the
  implementation units, preserving the render-path data layout and teardown
  order.

## Checkpoints

| Checkpoint | Scope | Build/tests | Runtime evidence | Status |
| --- | --- | --- | --- | --- |
| C0 | Baseline before runtime split | `deniald` built; 209/209 tests | Mouse and app launch recovered in prior session | Passed |
| C1 | Responsibility-focused source split | Release `deniald` linked; 209/209 tests passed | Pending | Build passed |
| C2 | Ownership boundaries and hot-path audit | Release `deniald` linked; 210/210 tests passed; formatter, source, and generated-object audits clean | Pending; running process predates this artifact | Build passed |
| C3 | Bridge responsibility split | Release `deniald` linked; 210/210 tests passed; source, format, object, and linked-symbol audits clean | Exact artifact restarted successfully; working flawlessly with near-zero idle CPU | Initial runtime passed |

### C2 evidence

- Built `deniald` and `check` with `-j14` on a 16-thread host, leaving two
  logical cores free.
- Added `denial_runtime_output_state_test`; all 210 discovered tests passed.
- The original named `CRuntime` behavior set is preserved. The private
  `SFlutterRuntime` constructor moved from an inline definition to its owning
  implementation unit; the only new behavior method reports invalid output
  transitions.
- `clang-format --dry-run --Werror` passes for every split runtime source and
  header, and `git diff --check` is clean.
- Source searches find no Dart `Process.run`/`Process.start`, native environment
  reads, or live output-state assignments outside the transition helper. The
  sole direct `FREE` assignment is the documented teardown reset.
- Generated-object inspection finds no calls to a transition wrapper in
  `RuntimeOutput.o` or `RuntimeFlutter.o`; only the exceptional invalid-state
  reporter remains out of line.

### C3 evidence

- Built `deniald` and `check` with `-j14` on a 16-thread host. The first pass
  exposed one missing direct `Monitor.hpp` include in the extracted snapshot
  unit; the corrective pass rebuilt only that unit, linked, and ran the suite.
- All 210 discovered tests passed, including the wire protocol, output-state,
  text-input, JSON-channel, and native-message-handler tests.
- All 47 methods moved out of the former bridge unit have an identical linked
  symbol set to the still-running pre-C3 binary. Across the complete runtime,
  the only added symbols are the intentional transition reporter and the
  private `SFlutterRuntime` constructor that was formerly emitted inline.
- `RuntimeOutput.o` remains 287,064 bytes of text and exports no
  `transitionOutputTarget` wrapper. Splitting the bridge did not touch the hot
  output implementation.
- Every split runtime source and header passes `clang-format --dry-run
  --Werror`; `git diff --check` is clean. Source searches find no forbidden Dart
  process launch, native environment read, or untracked live output-state
  assignment. The flattened Flutter sources retain their BSD notices.
- Checkpoint executable SHA-256:
  `7f28a3419abce3d2d0cc721748a376df48ebecdc2605c40feb6ef7c08d0ed2b4`.
- The process started on 2026-07-17 at 00:28:56 was verified through
  `/proc/975000/exe` to have that exact hash. The user reported a flawless
  session and near-zero idle CPU after restart.

## Completion audit

| Requirement | Authoritative evidence | Status |
| --- | --- | --- |
| Split `Runtime.cpp` by responsibility | The original 6,677-line unit is now a 229-line lifecycle/dispatch unit; wire ingress, snapshots, windows, shortcuts, native controls, Flutter, input, output, surfaces, and private shared state have distinct files listed in `Hyprland/CMakeLists.txt`. | Proven |
| Preserve the runtime contract | Every original named `CRuntime` behavior remains; the 47-method bridge contract is linked-symbol-identical to the pre-C3 binary. The private Flutter-state constructor emission and new invalid-transition reporter are explicitly accounted for. | Proven statically |
| Keep hot paths optimized | Output scheduling remains in one `-fno-lto` translation unit; generated objects contain no transition-wrapper calls; no facade allocation, virtual hop, environment read, or process launch was introduced. | Proven statically |
| Track risky changes | R-001 through R-007 document invariants, symptoms, guards, and required runtime evidence in this ledger. | Proven |
| Production build quality | All split sources and headers pass the project formatter, `git diff --check` is clean, Release `deniald` links, and all 210 tests pass. | Proven statically |
| Leave two CPU cores free | Every checkpoint build used `-j14` on a 16-thread host. | Proven |
| Real-session behavior | The exact C3 artifact restarted successfully and was reported flawless with near-zero idle CPU. Longer stress, hotplug, reload, and journal observation remain useful soak evidence. | Initial pass |

## Build policy

All checkpoint builds leave two logical CPU cores free. Use
`jobs = max(1, nproc - 2)` and batch changes so a checkpoint does not repeatedly
recompile the compositor while it is in active use.
