# Changelog

This file records user-visible changes to Denial. Denial is still a public
alpha: native APIs, the Flutter shell contract, configuration, and package
boundaries may change before 1.0.

## [Unreleased]

### Added

- Backdrop blur now has a configurable minimum effective window-opacity
  threshold, including an unconditional no-blur path for fully invisible
  windows.

### Changed

- High-rate external-texture frames now preserve precise rotating-atlas
  damage, reuse cached layer-diff metadata for only the dirty textures, and
  avoid redundant Ganesh flushes when cached texture bindings need no GL work.
- Output ticks use maintained per-output window membership, and output-control
  snapshots are rebuilt only after state changes.
- The guided Arch setup now stops after trusting the release key and adding
  the signed repository. Package installation remains an explicit
  `sudo pacman -Syu denial` command.
- Signed tags now provide package and user-visible runtime versions without a
  predictive Cargo, Dart, PKGBUILD, manual-page, or changelog version bump.
- `dev` candidates are never published. After an exact validated merge,
  `main` independently builds the production candidate; a later signed tag
  versions and publishes those exact compiled payloads without rebuilding.

### Fixed

- Fully opaque client content no longer requests backdrop blur merely because
  its shadow, rounded corners, or antialiased border carries alpha.
- Complex Flutter damage regions no longer collapse touching L-shaped output
  repairs into a full-atlas repaint.
- Failed local tag-signing attempts now reliably erase the decrypted recovery
  kit and temporary keyring after function scope unwinds.
- Arch packages now disable host-default debug-package rewriting explicitly,
  keeping tag-promoted payloads independent of the build host.

## [0.2.1] - 2026-07-29

### Added

- The optional UI development package now includes and enables the
  version-matched browser DevTools frontend for Flutter Inspector and
  performance profiling.

### Changed

- The native compositor plus Flutter's display and raster threads now request
  minimum-priority `SCHED_RR` only under a non-fatal realtime envelope, with
  RTKit-backed high-priority normal scheduling as the fallback. Realtime
  overruns demote Denial instead of terminating the graphical session;
  background workers and launched applications remain ordinary tasks.
- Signed release tags now directly version the Denial, Flutter Engine, and UI
  development archives. The engine's Flutter ABI remains separate metadata,
  and a Pacman epoch safely migrates from its former Flutter-numbered package.

### Fixed

- Powering off the final output now moves Flutter into its standard hidden
  lifecycle and cancels stale frame authorization. The shell stops producing
  invisible frames while Wayland applications remain alive for wake.

## [0.2.0] - 2026-07-27

### Added

- `denialctl`, a native compositor status, control, and recovery client which
  remains usable when the Flutter shell cannot render.
- A Developer page in Settings and a versioned native protocol for selecting,
  preparing, starting, inspecting, and restoring Flutter shell runtimes.
- In-process switching between the official optimized AOT shell and a JIT
  development shell without ending the Wayland session or its applications.
- The optional `denial-ui-development` package with a pinned JIT engine,
  curated Flutter and Dart tooling, locked shell dependencies, editor
  configuration, source metadata, and licenses.
- `denialctl ui setup`, which creates a version-matched editable Git checkout,
  prepares it with the packaged toolchain, selects it, and enters live
  development.
- VSCodium hot reload on save and Flutter Inspector support for the running
  desktop shell.
- `denial-session --start-locked` for autologin and direct-start setups which
  need Denial's native security gate closed before Flutter presents its first
  frame.
- A repository-owned guided installer which verifies the complete signing-key
  fingerprint, rejects conflicting Pacman configuration, and installs Denial
  through a normal full-system upgrade.

### Changed

- Denial's supported editor attachment is deliberately non-pausing. It keeps
  hot reload and Inspector functionality without granting DAP breakpoint,
  pause, stepping, or expression-evaluation control over the desktop isolate.
- Output configuration and runtime state now remain available through the
  native control path independently of Flutter Settings.
- Every login starts from the official optimized shell; live development must
  be enabled explicitly.
- The desktop shell is now the fail-safe default. The mobile shell is selected
  only by an exact, explicit `DENIA_SHELL_PROFILE=mobile` request.
- Normal display-manager sessions start unlocked after the display manager has
  authenticated the user; unattended startup can opt into Denial's own initial
  lock instead of imposing a duplicate password prompt on every login.
- Main-branch and signed-release validation now build, inspect, and retain the
  optional development package alongside the two required runtime packages.
- The packaged Flutter tool snapshot is built in a cleared, fixed environment
  and verified by checksum, preventing host locale, identity, and XDG settings
  from changing the development toolchain artifact.
- The packaged Flutter command-line tool now uses a deterministic AOT image
  and pinned `dartaotruntime`, removing host-specific warmed-JIT heap state
  while reducing its uncompressed payload.
- The Flutter tool snapshot now targets Dart's generic x86-64 CPU profile so
  development packages do not vary with builder-specific instruction sets.
- Flutter's optional package-map version metadata is now normalized to the
  pinned SDK version, so fresh and previously initialized toolchains produce
  the same development snapshot.
- The repository-level Rust toolchain pin now applies consistently to both the
  compositor and `cargo xtask`, including hardened builders with no default
  Rustup toolchain.
- Main validation now binds the exact verified push SHA to a local `main`
  branch so development packages record a cloneable source ref without
  weakening detached release-tag validation.
- Trusted `dev` pushes now run the complete production-shaped build, package,
  artifact, and independent-verification lane before promotion to `main`.
  Installable `dev` candidates use package release `0` and are excluded from
  the signed-tag publication path.
- Builder qualification now exercises Bubblewrap's private-network namespace
  before accepting work, and the runner permits the capability-free
  `AF_NETLINK` access required to initialize that isolated namespace.
- The alpha contribution policy now explicitly defers pull requests until
  Denial exits alpha while continuing to welcome issue reports and technical
  feedback.

### Safety and recovery

- Failed JIT preparation or startup falls back to the packaged optimized
  shell.
- `denialctl ui restore` provides a native recovery path from a terminal or
  virtual console.
- VM-service discovery remains authenticated, loopback-only, unadvertised over
  mDNS, and stored in a user-private runtime file.

### Known limitations

- Denial and `denial-ui-development` remain Arch Linux x86-64 public-alpha
  packages.
- Live development consumes substantially more storage, memory, and CPU than
  the optimized shell.
- Native file watching, one-click optimized custom builds, last-working custom
  rollback, and a stable third-party shell compatibility contract are not yet
  implemented.
- A custom Flutter shell and direct VM-service access are trusted local-user
  capabilities, not a sandbox for untrusted code.

[Unreleased]: https://github.com/denialwm/denial/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/denialwm/denial/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/denialwm/denial/compare/v0.1.0...v0.2.0
