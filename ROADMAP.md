# Denial roadmap

Denial is a Flutter-native Wayland compositor. Its long-term goal is to ship a
smooth, game-ready, exceptionally polished desktop by default—and to let
users reshape that desktop directly in Flutter with immediate feedback.

This roadmap describes direction, not a release schedule or a promise of
specific dates. Priorities may change when real hardware, applications, or
security findings expose more important work.

## Product shape

Denial has three deliberate layers:

1. The Rust and Smithay compositor owns Wayland protocol state, native
   resources, input, outputs, DRM/KMS presentation, and system integration.
2. The Flutter shell owns the desktop's visual and interaction policy through
   a versioned compositor-to-shell contract.
3. Denial's reference shell provides the opinionated, complete desktop users
   receive by default, while its Dart source remains a first-class
   customization surface.

Flutter is part of the compositor's foundation. It is not an overlay and the
reference shell is not intended to become a collection of replacements for
unrelated Linux system services or applications.

## Long-term commitments

### Compositor foundation

- Correct behavior for the Wayland protocols required by modern native
  applications, desktop integration, and gaming.
- Reliable Xwayland, multi-output, hotplug, scaling, input, fullscreen,
  suspend and resume, portal, and session lifecycle behavior.
- Explicit failure and recovery paths instead of silent corruption or an
  unusable session.
- Clear compatibility levels based on hardware and driver configurations that
  have actually been tested.

### Flutter shell platform

- A stable, versioned contract between the native compositor and Flutter
  shell bundles.
- Bundle manifests and capability negotiation so compatibility is checked
  before a shell starts.
- A documented development workflow and an example alternative shell.
- A live development mode in which VSCodium and Flutter tooling can attach to
  the running desktop, report source errors, and hot reload Dart-owned
  behavior without ending the Wayland session.
- A short path from a live workspace to a validated optimized shell, with the
  packaged UI and a last-working custom build available for recovery.
- Migration rules for persistent configuration and protocol changes.
- Validation and a recovery path when a custom bundle is missing,
  incompatible, or unable to start.
- A clear trust boundary: user-provided Flutter bundles are trusted local code
  unless a future architecture explicitly provides isolation.

### Reference desktop

- Coherent workspace and window management, application launching, system
  surfaces, notifications, clipboard behavior, settings, session controls,
  and lock-screen behavior.
- Keyboard, pointer, and touch interaction that remain usable without
  requiring one specific input device.
- Adaptive layouts that can eventually serve both conventional PCs and
  touch-first systems without turning the reference shell into several
  unrelated desktops.
- Accessibility as a platform requirement rather than a cosmetic addition.

### Performance and efficiency

- Predictable frame pacing at high refresh rates and under real application
  and gaming workloads.
- Low input latency and correct presentation feedback.
- Reasonable power and idle behavior on desktop, laptop, and future tablet
  hardware.
- Performance claims backed by repeatable evidence.

### Distribution and trust

- Signed first-party Arch Linux packages for supported architectures.
- Pinned and documented source inputs for Denial's coupled Flutter Engine
  build.
- A source build path that remains usable without the first-party repository.
- Progressively stronger build isolation and reproducibility as the project
  and its user base grow.

## Now: harden the public alpha

The current priority is making the existing desktop dependable outside its
development machines:

- use reports from real installations to find correctness and compatibility
  problems;
- fix session-blocking failures before expanding the visible feature set;
- improve diagnostics, failure handling, and recovery;
- verify installation, upgrade, removal, and session startup behavior;
- record confirmed behavior across GPUs, drivers, displays, and input
  devices;
- improve Wayland and Xwayland compatibility where real applications expose
  gaps;
- continue frame-pacing, high-refresh, gaming, and power-behavior work; and
- keep the native compositor, shell bundle, and package versions coherent.

Denial 0.2.0 also establishes the first usable live-shell development
foundation:

- the optional `denial-ui-development` package carries a version-coupled JIT
  engine and scoped Flutter/Dart tooling;
- `denialctl ui setup` creates and prepares a matching editable checkout;
- VSCodium can hot reload saved Dart changes and use Flutter Inspector without
  receiving pause or breakpoint control over the desktop isolate;
- switching between the optimized AOT shell and the JIT shell keeps Wayland
  clients and the compositor session alive; and
- `denialctl ui restore` remains available independently of the Flutter UI.

This is an MVP, not the finished shell platform. Its immediate follow-up work
is to reduce development overhead, improve diagnostics, and validate the
workflow through normal package upgrades without weakening the native recovery
path.

## Next: establish the shell platform

Once the public-alpha foundation is sufficiently dependable:

- formalize the bundle manifest and compatibility rules;
- add compositor and shell capability negotiation;
- extend the live Flutter MVP with native source watching, explicit hot
  restart, optimized custom builds, activation health checks, and last-working
  rollback;
- define configuration migration and compatibility behavior;
- publish an example alternative Flutter shell;
- document the shell development and validation workflow;
- provide a recovery path for broken or incompatible bundles; and
- reduce assumptions that exist only because one reference shell currently
  consumes the platform.

The alternative-shell contract is not stable until the project explicitly
announces it as stable. Compatibility may break during the public alpha when
that is necessary to reach a sound long-term design.

## Later: expand the platform

Longer-term work may include:

- first-party ARM64 builds;
- touch-first and tablet hardware support;
- broader GPU and driver qualification;
- a general per-output rendering fallback for layouts that cannot use the
  shared atlas path;
- deeper accessibility integration;
- variable refresh rate, color management, and HDR where the architecture and
  upstream protocols make them appropriate;
- stronger independent verification and reproducibility of release builds;
  and
- packaging maintained by additional distributions or communities.

These are directions, not commitments to a particular order.

## Definition of 1.0

Denial 1.0 should mean:

- the native compositor and Flutter shell contract is versioned and stable;
- incompatible shell bundles fail safely and recovery is documented;
- the supported hardware, drivers, protocols, and known limitations are
  stated clearly;
- installation, updates, session startup, lock, suspend, and recovery are
  dependable on supported systems;
- common native Wayland and Xwayland applications behave correctly;
- the reference shell is usable through its supported input methods; and
- releases follow the documented signing and validation process.

It does not mean that every desktop feature, distribution, device, or hardware
configuration is supported.

## Non-goals

Denial does not currently aim to:

- become a Linux distribution or package manager;
- replace NetworkManager, BlueZ, PipeWire, logind, or other established system
  services;
- build a Denial-specific browser, terminal, file manager, or application
  suite merely for completeness;
- operate a marketplace for third-party shells or plugins;
- introduce cloud accounts, telemetry, or mandatory online services;
- reserve functionality for sponsors;
- give sponsors control over technical decisions;
- officially package every Linux distribution; or
- treat arbitrary custom shell bundles as sandboxed or untrusted code.

## Direction and sponsorship

Doctor Logix maintains Denial's product and technical direction. User reports
and technical evidence can change priorities, but receiving sponsorship does
not transfer roadmap control. Pull requests are not accepted during alpha;
the temporary policy and accepted feedback channels are documented in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

Sponsorship supports open development, build and release infrastructure, test
hardware, compatibility work, and the time required to maintain Denial. The
software and its public development remain available on the same terms
regardless of sponsorship.
