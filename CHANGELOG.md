# Changelog

This file records user-visible changes to Denial. Denial is still a public
alpha: native APIs, the Flutter shell contract, configuration, and package
boundaries may change before 1.0.

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
- Main-branch and signed-release validation now build, inspect, and retain the
  optional development package alongside the two required runtime packages.
- The packaged Flutter tool snapshot is built in a cleared, fixed environment
  and verified by checksum, preventing host locale, identity, and XDG settings
  from changing the development toolchain artifact.
- The repository-level Rust toolchain pin now applies consistently to both the
  compositor and `cargo xtask`, including hardened builders with no default
  Rustup toolchain.
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

[0.2.0]: https://github.com/denialwm/denial/compare/v0.1.0...v0.2.0
