# Denial feature completion plan

Status: active — F1–F4 complete; F5 next

This file is the source of truth for the next Denial product goal. The goal is
complete only when every feature and acceptance criterion below is implemented,
tested, documented, and validated without regressing Denial's event-driven idle
behavior.

## Product outcome

Turn the current shell into a complete daily-driver desktop without weakening
the architecture that now makes `deniald` effectively disappear at idle.
Controls must represent real system state, security-sensitive behavior must be
native-owned, and unsupported capabilities must be shown honestly rather than
simulated locally.

## Current baseline

- Notifications already have a native freedesktop D-Bus server, bounded wire
  representation, replacement/expiry handling, and Dart state. The visible
  banner is text-only and non-interactive; history, real DND, images, actions,
  and dismissal UI are unfinished.
- Brightness, default-output volume, application audio, power profiles,
  screenshots, the OSK, and the desktop Bluetooth dashboard have real backends.
- The quick-settings Wi-Fi, Bluetooth, DND, and rotation tiles currently mutate
  local Dart state; they are not authoritative system controls.
- The lock layer blocks normal shell interaction but unlocks by gesture and has
  no PAM-backed identity check.
- Hyprland already supplies Wayland/X11 clipboard and drag-and-drop behavior.
  Denial does not yet provide clipboard history.
- There is no Denial system-tray host, MPRIS surface, power/session menu, polkit
  agent, or declared desktop-portal integration.

## Non-negotiable engineering rules

- Do not restart, reload, replace, signal, or terminate the running compositor
  or Flutter engine while implementing this plan. Runtime activation waits for
  a user-initiated checkpoint.
- Builds leave two logical CPU cores free. Compute jobs as
  `max(1, nproc - 2)`; on the current 16-thread host use `-j14`.
- Batch work so each coherent checkpoint normally incurs one compilation.
- Run every `tools/denial-pc` command outside the sandbox as required by
  `AGENTS.md`, but never invoke its restart or reload operations under this
  plan.
- Embedded Dart must never call `Process.run` or `Process.start`.
- Latency-sensitive and frequently used controls use a persistent native bridge,
  persistent D-Bus connection, or an existing managed IPC service—never a CLI
  command per interaction.
- Prefer signal-driven state. Poll only where the platform exposes no event
  source, document why, and use the slowest interval consistent with correct
  UX.
- Do not add periodic frame production, render-path environment reads, or work
  to `RuntimeOutput.cpp` unless a feature strictly requires it and measurement
  justifies it.
- All lists, payloads, images, histories, retries, and queues are bounded.
- Native code owns PAM conversations, credentials, privileged requests,
  compositor state, Wayland selections, and unsafe handles. Dart owns visual
  policy and high-level user intent.
- Unsupported hardware or unavailable services produce a disabled or hidden
  control with a useful explanation. They must never look enabled because of a
  local placeholder boolean.

## Cross-feature UI and quality contract

Every delivered surface must:

- work with mouse, touch, and keyboard where the interaction makes sense;
- have deterministic focus traversal, Escape/back behavior, tooltips, and
  semantic labels;
- respect safe areas, text scaling, reduced-motion settings, and Denial's
  existing visual tokens;
- provide explicit loading, unavailable, permission-required, and error states;
- avoid unbounded `Column` children for dynamic content; use lazy bounded lists;
- isolate expensive images or animations behind repaint boundaries;
- keep Riverpod state immutable and dispose subscriptions, timers, D-Bus
  clients, and native callbacks deterministically;
- include unit tests for state/policy, widget tests for critical interactions,
  and native or wire tests for every new protocol boundary.

## Delivery order

| Phase | Feature | Why this order |
| --- | --- | --- |
| F1 | Notifications 1.0 | Most backend work exists; delivers an immediately visible complete feature without touching rendering |
| F2 | Authoritative connectivity controls | Removes misleading local-only Wi-Fi and Bluetooth state |
| F3 | Secure lock and authentication | Converts the current screen shield into an authenticated lock |
| F4 | Session and power actions | Reuses the secure prompt and system-service foundation from F3 |
| F5 | Desktop portals and polkit | Restores expected application integration and privilege prompts |
| F6 | System tray | Adds the persistent application affordances many desktop apps require |
| F7 | MPRIS media controls | Adds event-driven media state to the shade and lock screen |
| F8 | Authoritative rotation lock | Completes the final placeholder quick-setting tile |
| F9 | Clipboard history | Builds a privacy-conscious shell feature over the compositor's existing selection support |
| F10 | Integrated acceptance and documentation | Proves the features coexist without idle or interaction regressions |

## F1 — Notifications 1.0

### Required behavior

- [x] Keep the native `org.freedesktop.Notifications` service as the sole
      notification owner and add focused native tests for registration,
      replacement, expiry, close reasons, malformed hints, bounded images, and
      action invocation.
- [x] Advertise only capabilities that work end-to-end. Advertise `actions`
      once interactive actions ship; keep sound/persistence capability claims
      aligned with the actual implementation.
- [x] Replace the banner-wide `IgnorePointer` behavior with precise interactive
      hit regions while allowing input outside cards to pass through.
- [x] Support default activation, explicit action buttons, dismiss, and correct
      `ActionInvoked`/`NotificationClosed` signals.
- [x] Render application icons, static image hints, urgency, body text,
      progress, replacement updates, and resident/transient behavior safely.
- [x] Bound visible banners and queue overflow deterministically so a burst
      cannot cover the desktop or create an unbounded widget tree.
- [x] Add a notification center to the system shade with active notifications,
      bounded session history, unread state, per-item dismissal, and clear-all.
- [x] Implement real DND policy. DND suppresses ordinary banners and sounds but
      retains history; critical notifications follow an explicit bypass policy.
- [x] Make the Silent/DND tile authoritative and persist its policy state.
- [x] Add lock-screen privacy modes: hidden, application-only, and full preview.
      The default must not expose notification body text while locked.
- [x] Honor `suppress-sound`; if notification sound is implemented, route it
      through a persistent managed audio path rather than spawning a player.
- [x] Provide keyboard focus, screen-reader live-region semantics, reduced
      motion, and adaptive banner/center layout.

### Acceptance

- Notification replacement never duplicates a card or history entry.
- A burst beyond the visible limit remains bounded and ordered.
- Default and named actions reach the originating application exactly once.
- Dismiss and expiry emit the correct freedesktop close reason.
- DND, locked privacy, actions, images, progress, and clear-all have automated
  coverage.
- With no notifications arriving, the feature creates no periodic work.

### F1 checkpoint evidence — 2026-07-17

- Native integration: five focused GTest cases cover D-Bus registration,
  capability honesty, replacement, expiry and close reasons 1–4, native
  capacity eviction, malformed hints, bounded images/actions/strings, and
  exactly-once actions. The suite exits cleanly in 121 ms.
- Dart/UI: notification policy, lifecycle, burst bounds, DND/critical bypass,
  lock privacy, transient/history behavior, persistence, actions, precise input
  regions, adaptive center controls, raw/static images, progress, clear-all,
  enlarged text, and animated-remnant bounds have automated coverage.
- Desktop Notification Center and the application-volume mixer share one
  monitor-aware centering primitive. A dual-output widget regression verifies
  that dialogs center inside `DisplayLayout.mainOutput`, never in the gap or
  midpoint of the complete Flutter output atlas.
- Sound remains deliberately unimplemented and unadvertised. Consequently no
  notification sound path exists that could ignore `suppress-sound`; a future
  sound implementation must use the managed persistent audio path.
- Static image files are read off the UI isolate with a 4 MiB compressed-byte
  limit and a 512 px decode target; notification/app icon files are capped at
  8 MiB. Native raw image payloads remain capped at 512 KiB.
- `flutter-elinux analyze` and the complete 91-test Dart suite passed before
  the final edge-case additions; the focused final F1 widget tests and native
  suite also pass.
- Production artifact: `/home/logix/.cache/denial/pc-build/hyprland/deniald`,
  built with `DENIAL_BUILD_JOBS=14`. No compositor or Flutter restart/reload
  was performed.

## F2 — Authoritative connectivity controls

### Wi-Fi

- [x] Add a persistent NetworkManager D-Bus service with signal-driven radio,
      connectivity, active-connection, access-point, and strength state.
- [x] Replace the local Wi-Fi boolean with authoritative state and distinguish
      disabled, disconnected, connecting, limited, captive, and online states.
- [x] Provide scan, connect, disconnect, forget, and radio enable/disable.
- [x] Support secured networks through a focused credential prompt; never log,
      persist in Riverpod state, or echo secrets after submission.
- [x] Show saved/current networks first, deduplicate access points by network
      identity, and bound scan results.
- [x] Disable the surface honestly when NetworkManager is unavailable.

### Bluetooth

- [x] Replace the quick-settings Bluetooth boolean with the existing BlueZ
      provider's real powered/connected state.
- [x] Make the tile toggle the real adapter and expose a detail surface for
      scan, pair, trust, connect, disconnect, and remove.
- [x] Reuse one BlueZ model between the shade and desktop dashboard so the two
      surfaces cannot disagree.
- [x] Handle agent requests, pairing errors, adapter loss, and service restarts
      without blocking the Flutter isolate.

### Acceptance

- Tiles always converge to service state after an optimistic interaction.
- External NetworkManager or BlueZ changes appear without reopening the shade.
- Failed authentication or service loss returns to a truthful recoverable UI.
- Idle radios generate no shell polling or render loop.

### F2 checkpoint evidence — 2026-07-17

- NetworkManager and BlueZ each use one persistent system-bus connection,
  service-owner recovery, coalesced service signals, immutable snapshots, and
  no polling or command-line utilities. Equivalent snapshots are suppressed.
- Wi-Fi exposes bounded scan results, saved/current ordering, access-point
  deduplication, radio/scan/connect/disconnect/forget, explicit connectivity
  states, permission gating, and a local one-shot credential field that is
  cleared before the request is dispatched.
- Bluetooth exposes bounded adapter/device state, power/discovery,
  pair/trust/connect/disconnect/remove, and a sender-validated BlueZ Agent1
  endpoint. Pairing conversations are limited to one request with a 60-second
  timeout; PIN/passkey text is passed directly and never stored in Riverpod.
- The shade and desktop dashboard now consume the same BlueZ provider. Local
  Wi-Fi and Bluetooth quick-setting booleans were removed. Detail surfaces are
  adaptive, lazy, reduced-motion aware, and keyboard/mouse/touch accessible.
- Lock activation synchronously destroys managed transient surfaces, including
  credential prompts, and mobile now hosts those surfaces through the same
  interaction registry as desktop.
- `flutter-elinux analyze` reports no issues. The focused six-file F2 suite
  passes all 15 service, controller, protocol, permission, service-loss,
  credential-lifetime, bounds, and widget tests with concurrency capped at 14.
- No production build, compositor reload, or session restart was performed for
  this phase; live hardware activation remains for a user-requested checkpoint.

## F3 — Secure lock and authentication

### Required behavior

- [x] Replace the gesture-only unlock decision with a native-owned PAM
      authentication boundary. A configured PAM stack may provide password,
      fingerprint, or other system authentication without separate secret
      handling in Dart.
- [x] Keep the compositor's input router authoritative: while locked, clients
      cannot receive keyboard, pointer, touch, clipboard, drag-and-drop, or
      shell-command input that bypasses the lock surface.
- [x] Replace file polling as the primary lock command path with persistent
      native IPC. Compatibility files may remain as an event-triggered adapter
      during migration, not as the security authority.
- [x] Add an accessible password/conversation UI with secure obscuring,
      keyboard and OSK support, retry/error feedback, cancellation, and a clear
      busy state.
- [x] Never log credentials or retain them beyond a single authentication
      attempt. Native buffers are cleared after use and attempts are rate
      limited.
- [x] Lock every output atomically and define behavior for outputs added while
      locked.
- [x] Hide or redact notifications, tray menus, clipboard history, media
      metadata, screenshots, and application surfaces according to lock policy.
- [x] Preserve the current polished lock animation, power information, reduced
      motion, and input accessibility.

### Acceptance

- A swipe or UI-only state mutation cannot unlock the session.
- Correct PAM authentication unlocks once; failure leaves the compositor
  securely locked and usable for another attempt.
- Lock state survives shell UI reconstruction without exposing client input.
- Automated tests cover conversation state, cancellation, retries, secret
  lifetime policy, multi-output lock policy, and native/Dart disagreement.

### F3 checkpoint evidence — 2026-07-17

- Lock ownership now lives in a process-lifetime native controller. Flutter
  reconstructs from that state and cannot clear it. The only successful unlock
  transition is the current, uncancelled PAM result; stale, duplicated, late,
  and UI-only responses fail closed.
- The PAM conversation runs on one sleeping worker, supports the configured
  system stack's password/fingerprint/other modules, uses strict 4 KiB packets,
  move-only scrubbed response buffers, a 120-second conversation bound, and
  exponential 750 ms–30 s retry delays without compositor-thread blocking.
- Native lock checks now precede keybindings and compositor event listeners for
  keyboard, pointer, wheel, touch, stylus, tablet-pad, swipe, and pinch input.
  Lock entry releases client focus, grabs, constraints, held inputs, active
  gestures, and drag-and-drop. A missing or reconstructed Flutter isolate still
  consumes all client-bound input.
- Wayland/XWayland clipboard receives, primary selection, DnD, screencopy,
  client-window commands, notification actions, shortcuts, and system-control
  messages are denied while locked. Existing notification privacy policy and
  the opaque multi-output lock scene keep application and shell content hidden.
- `hyprctl denial-lock lock|status` is the documented primary native IPC path;
  it intentionally exposes no unlock command. Compatibility files are watched
  only as a one-way lock adapter and mirror native secure state.
- `Super+L` now dispatches `session:lock` directly to the process-lifetime
  authentication controller. The consuming bind bypasses client shortcut
  inhibitors, remains allowed during compositor-owned shell surfaces, and
  launches no shell, `hyprctl`, or helper process.
- The adaptive PAM UI supports hardware keyboard and a focusable built-in OSK,
  obscured/visible conversations, busy/info/error/cancel/retry states, text
  scaling, tooltips, semantics, reduced motion, and one authentication pane
  while every active or newly added output remains covered.
- `flutter-elinux analyze` reports no issues. Eleven focused Dart protocol,
  controller, disagreement, swipe, credential-lifetime, and multi-output tests
  pass. Five focused native protocol/controller tests pass in 30 ms.
- Secure-boundary key ownership is balanced before the lock UI changes and the
  eventual hardware release remains quarantined ahead of plugins/keybindings.
  This prevents the Enter used for PAM submission from sticking or leaking
  into the newly focused client. Four native regressions cover boundary flush,
  duplicate downs, delivery failure, and keyboard removal.
- Unlock keeps the existing application scene mounted from authentication
  success through final lock-overlay removal. Existing desktop windows remain
  continuously visible and their one-shot entrance reveals cannot replay; a
  widget regression preserves the same reveal state across the full boundary.
- Production artifact:
  `/home/logix/.cache/denial/pc-build/hyprland/deniald`, linked with `libpam` and
  built with 14 jobs. No compositor/Flutter reload, restart, signal, or runtime
  activation was performed.

## F4 — Session and power actions

### Required behavior

- [x] Add a cohesive power/session surface for lock, logout, suspend,
      hibernate when supported, reboot, and power off.
- [x] Use persistent logind/system-bus APIs and native compositor IPC. Do not
      shell out to `systemctl`, `loginctl`, or arbitrary commands.
- [x] Query capability and authorization state before enabling each action.
- [x] Respect logind inhibitors and present actionable failures or blocked
      reasons.
- [x] Require deliberate confirmation for destructive actions while keeping
      lock and suspend fast.
- [x] Ensure logout asks the compositor to end the session cleanly without
      conflating it with an engine reload.
- [x] Make the surface accessible from both desktop and touch shell policies.

### Acceptance

- Unsupported or unauthorized actions cannot appear successful.
- Duplicate taps produce at most one system request.
- Confirmation, cancellation, inhibition, permission, and service-loss paths
  have automated coverage.

### F4 checkpoint evidence — 2026-07-17

- One persistent system-bus client owns logind state for the process lifetime.
  It reads `Can*` authorization/capability values and bounded inhibitors,
  follows service and manager signals, coalesces concurrent refreshes, and
  performs a fresh authoritative read immediately before every system action.
  It creates no periodic idle work and never invokes a CLI utility.
- Lock uses the native PAM-backed F3 boundary. Logout uses a bounded native
  platform message posted onto the compositor event loop and calls
  `CCompositor::stopCompositor()`, reaching deniald's normal runtime shutdown
  and compositor cleanup path rather than reloading the Flutter engine.
- The monitor-aware power surface is reachable from the desktop dashboard and
  the touch/system-shade footer. It provides mouse, touch, Enter/Space,
  semantics, tooltips, reduced-motion behavior, bounded scrolling, explicit
  loading/error/service-loss states, blocker reasons, authorization labels,
  and confirmation for logout, restart, and power off.
- State and widget coverage proves duplicate coalescing, confirmation and
  cancellation, inhibitors, denied/challenge capabilities, sanitized failures,
  service loss, local lock availability, and enlarged-text layout. The complete
  131-test Dart suite passes and `flutter-elinux analyze` reports no issues.
- Production artifact:
  `/home/logix/.cache/denial/pc-build/hyprland/deniald`, built with 14 jobs
  together with the fixed 320 ms desktop-window entrance and transient-popup
  animation suppression. No compositor/Flutter reload, restart, signal, or
  runtime activation was performed.

## F5 — Desktop portals and polkit

### Desktop portals

- [ ] Declare and install a Denial portal configuration that selects compatible
      backends for file chooser, open URI, notifications, screenshots,
      screencast, settings, and global shortcuts where supported.
- [ ] Validate browser screen sharing, Flatpak permission flows, screenshots,
      file selection, and URI opening under the Denial session identity.
- [ ] Keep compositor-owned capture and permission decisions native; reuse
      Hyprland-compatible portal behavior where it remains correct.
- [ ] Document required portal packages and make missing backends diagnosable.

### Polkit

- [ ] Register one persistent polkit authentication agent for the graphical
      session.
- [ ] Reuse the secure native authentication boundary from F3 and present a
      Denial-styled prompt containing verified action, vendor, identity, and
      cancellation information.
- [ ] Serialize or explicitly queue simultaneous requests with strict bounds;
      a vanished requester cancels its prompt.
- [ ] Never expose secrets to logs, unrelated providers, or stale callbacks.

### Acceptance

- Portal and polkit registration are deterministic and observable.
- Screen sharing, a representative Flatpak file chooser, and a representative
  privileged action complete through their standard desktop APIs.
- Cancellation and missing-service paths do not leave a modal shell layer.

## F6 — System tray

### Required behavior

- [ ] Implement or integrate a persistent StatusNotifierWatcher/host for the
      graphical session without taking ownership from another active watcher.
- [ ] Model item identity, status, title, tooltip, icon/theme pixmaps, attention
      state, activation, secondary activation, scrolling, and removal.
- [ ] Support DBusMenu actions with bounded menu depth/item count and update
      signals.
- [ ] Provide adaptive panel placement, overflow, keyboard navigation,
      semantics, and touch-sized targets.
- [ ] Isolate malformed or disappearing items so one application cannot break
      the tray.

### Acceptance

- Items can appear, update, activate, open menus, request attention, and vanish
  without stale UI.
- Large or malformed icons and menus remain bounded.
- With no items, the host creates no periodic UI work.

## F7 — MPRIS media controls

### Required behavior

- [ ] Discover MPRIS players through persistent session-bus ownership signals.
- [ ] Model playback status, identity, metadata, capabilities, position,
      volume, loop, shuffle, and player disappearance without polling where
      MPRIS signals suffice.
- [ ] Provide play/pause, previous, next, seek, and player selection only when
      the player advertises support.
- [ ] Render bounded, cached artwork safely with a fallback icon.
- [ ] Add a compact shade card and privacy-aware lock-screen media surface.
- [ ] Define deterministic policy for multiple players and recently active
      players.

### Acceptance

- External player changes update the UI without reopening it.
- Unsupported controls are disabled rather than attempted.
- Player churn, malformed metadata, artwork failure, and multiple-player policy
  have automated coverage.

## F8 — Authoritative rotation lock

### Required behavior

- [ ] Replace the local rotation boolean with actual auto-rotation policy and
      output-transform state owned by native code.
- [ ] Subscribe to a persistent orientation source such as
      `iio-sensor-proxy` where available; do not poll a CLI utility.
- [ ] Apply transforms through the compositor bridge while preserving touch,
      pointer, Flutter scene, screenshot, and window coordinate mapping.
- [ ] Bind policy to the intended rotatable output; non-rotatable desktop
      outputs remain unaffected.
- [ ] Disable or hide the tile when no sensor or rotatable output exists.

### Acceptance

- Locked orientation remains stable across sensor events.
- Unlocked orientation applies one coherent display/input transition.
- Missing sensor, output removal, and rapid orientation changes remain bounded
  and tested.

## F9 — Clipboard history

### Required behavior

- [ ] Add a native clipboard-history owner over the existing Wayland/X11
      selection machinery; do not scrape clipboard content from embedded Dart.
- [ ] Start with bounded in-memory session history. Do not persist clipboard
      contents to disk by default.
- [ ] Support safe text and image MIME types with per-item, total-byte, and
      item-count limits; reject malformed or oversized data.
- [ ] Deduplicate consecutive content and preserve enough source data for a
      selected entry to become the active clipboard after the original client
      exits.
- [ ] Provide search, copy/activate, pin for the current session, delete,
      clear-all, and pause-history controls.
- [ ] Suppress history capture and UI while locked; clearing history must also
      release retained native selection data.
- [ ] Preserve normal clipboard, primary selection, X11 interoperability, and
      drag-and-drop semantics.

### Acceptance

- Copy/paste continues to work between Wayland and X11 applications with
  history enabled, paused, and cleared.
- Oversized, unsupported, rapidly changing, and source-exit cases remain
  bounded.
- Sensitive state never appears on the lock screen or in persistent storage.

## F10 — Integrated acceptance and documentation

- [ ] Add a feature matrix to user documentation describing available,
      unavailable, and hardware-dependent behavior.
- [ ] Document every required service, D-Bus name, portal backend, PAM service,
      configuration file, and failure diagnostic.
- [ ] Ensure generated wire code and protocol documentation are updated
      together for every new channel or payload.
- [ ] Run Dart formatting, analysis, unit/widget tests, native formatting,
      native tests, protocol golden tests, and production builds.
- [ ] Keep builds at `nproc - 2` jobs and record each checkpoint artifact.
- [ ] Perform no compositor or Flutter restart during implementation. Accumulate
      runtime checks for a later user-initiated validation window.
- [ ] At that later checkpoint, verify notifications, lock/authentication,
      power actions, Wi-Fi, Bluetooth, portals, polkit, tray, MPRIS, rotation,
      clipboard, multi-monitor behavior, idle CPU, memory, file descriptors,
      logs, and failure recovery.

## Goal completion criteria

This goal is complete only when:

1. Every checkbox in F1–F10 is satisfied or replaced by an equally strict,
   documented implementation agreed with the project creator.
2. No quick-setting control is backed by placeholder local state.
3. Security-sensitive features have native ownership and negative-path tests.
4. All dynamic collections and external payloads have explicit bounds.
5. Static analysis and all relevant automated tests pass.
6. Production artifacts build while leaving two CPU cores free.
7. No implementation step restarts or reloads the active session.
8. A later user-authorized runtime checkpoint demonstrates that the completed
   feature set preserves Denial's responsiveness and near-zero idle behavior.
