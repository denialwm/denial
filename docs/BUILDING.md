# Building Denial

Denial supports PC source builds on x86-64 and ARM64 (AArch64). It builds three
runtime components:

- the Rust compositor and native control client in `compositor/`;
- the embedded Flutter shell bundle in `dart_shell/`;
- the standalone Flutter Settings Wayland application in `settings_app/`.

Downloaded toolchains and native build output live outside the checkout by
default. A first bootstrap needs network access; later development builds
reuse the pinned cache.

The turnkey helper and paths below document the current x86-64 reference build.
An ARM64 build uses the same locked Denial, Flutter, and Skia sources with an
architecture-matched Flutter engine and shell bundle; do not reuse the x86-64
engine artifacts on ARM64. First-party ARM64 packages are not published yet.

## Quick start

Validate or provision the pinned Flutter SDK and fetch Rust dependencies:

```sh
tools/denial-pc bootstrap
```

Inspect the host, build, and run the test suites:

```sh
tools/denial-pc doctor
tools/denial-pc build
tools/denial-pc test
```

The release compositor is written to:

```text
$XDG_CACHE_HOME/denial/pc-build/rust/release/deniald
```

The matching native control and recovery client is written to:

```text
$XDG_CACHE_HOME/denial/pc-build/rust/release/denialctl
```

The Flutter bundle is written to:

```text
dart_shell/build/linux/x64/release/bundle
```

The Settings application bundle is written to:

```text
settings_app/build/linux/x64/release/bundle
```

Build only that client with `tools/denial-pc settings`.

Set `DENIAL_PC_DEPENDENCY_ROOT`, `DENIAL_PC_BUILD_ROOT`, or
`DENIAL_PC_RUST_TARGET` to place the corresponding caches elsewhere.

## Pinned Flutter generation

The current development generation couples:

- Flutter `3.44.7`;
- the exact Denial Flutter and Skia fork commits in
  `prebuilt/flutter-engine/SOURCE_LOCK.json`;
- upstream Flutter compatibility revision
  `84fc5cbb223bc12f83d65b647ff8a56caf779ffd`;
- Dart `3.12.2`;
- engine artifact revision `69c8c61792f04cc809dfef0c910414fb9afc06cd`;
- the generated Rust embedder ABI in
  `compositor/flutter-engine/src/sys.rs`.

All downstream Flutter, engine, and Skia changes are commits in the locked
forks. The repository does not reconstruct them from patches.

### Engine source workflow

Local engine development has exactly two editable roots:

```text
/mnt/exty/denial-flutter-fork-3.44.7
/mnt/exty/denial-skia-fork-3.44.7
```

The Flutter tree's `engine/src/flutter/third_party/skia` resolves to the
second root. Edit, format, test, and commit engine source only in those trees.
Set `DENIAL_FLUTTER_SOURCE_ROOT` and `DENIAL_SKIA_SOURCE_ROOT` together to
relocate them. Local GN and Ninja output lives below
`$DENIAL_FLUTTER_ENGINE_CACHE_ROOT/build`; no second local Flutter or Skia
source tree belongs in that cache. An isolated builder without the canonical
pair may retain a detached, lock-pinned source projection. Never patch or
commit such a projection; tooling may replace it.

The lock's exact Flutter and Skia commits are the immutable authority for one
build. Canonical working-tree changes do not enter a build until they are
committed and the lock is deliberately advanced. CI never inherits a
developer checkout; it validates or provisions a detached projection of the
lock. Only verified artifacts, dependencies, compatible build outputs, and
locked projections may be reused across jobs.

Normal builds consume a locally rebuilt engine staged as
`prebuilt/flutter-engine/linux-x64-release/libflutter_engine.so`. The library
is ignored by Git; its expected checksum, source revisions, build arguments,
licenses, and rebuild instructions remain tracked beside it in
[`BUILD_INFO.md`](../prebuilt/flutter-engine/linux-x64-release/BUILD_INFO.md).
`tools/denial-flutter-engine build` reuses an exact artifact cache hit without
running GN or Ninja. When the source lock or GN arguments change, it retains
compatible mode-specific Ninja outputs for an incremental rebuild. Any
cache-managed source checkout remains build-only. Its only host normalization
fixes Flutter's generated toolchain-job count to the committed value before
regenerating and comparing the complete GN graph. Routine Dart and Rust builds
do not run `bindgen`. Arch packaging uses the verified output selected by that
tool, so the engine package and Denial package always derive from the same
checked input.

There are two deliberately separate commands:

```sh
# Routine build or deployment; unchanged engines are an exact cache hit.
tools/denial-flutter-engine build

# Run exactly once after deliberately advancing SOURCE_LOCK.json.
tools/denial-flutter-engine refresh-metadata
```

`refresh-metadata` regenerates every mode's tracked `args.gn` and canonical
checksum in one transaction, incrementally rebuilds invalidated targets,
populates the new revision-keyed cache entry, and stages all verified engines
below `prebuilt/`. Do not invoke the routine `build` command and manually fix
successive release, debug, and profile checksum failures during a lock advance.

During a controlled engine upgrade, regenerate and check the committed
bindings with:

```sh
tools/generate-flutter-embedder-bindings
tools/generate-flutter-embedder-bindings --check
```

## Host requirements

The host needs:

- the Rust toolchain selected by the repository-level `rust-toolchain.toml`;
- `pkg-config`;
- RealtimeKit (`rtkit`) for the compositor's unprivileged high-priority
  scheduling fallback;
- Xwayland;
- the Fontconfig development files used by the Linux engine's system-font
  backend;
- the development libraries used by Smithay's DRM, GBM/EGL, libinput,
  libseat, udev, and libxkbcommon backends.

Only binding regeneration needs Clang and libclang. Run
`tools/denial-pc doctor` for the authoritative check on the current host.
Denial uses lowest-priority `SCHED_RR` only when the inherited host limits let
it keep a non-fatal realtime guard. Otherwise RTKit gives the compositor,
Flutter display, and Flutter raster threads a negative nice value without
changing them to a realtime policy. Denial remains usable with ordinary CPU
scheduling when neither grant is available.

## Local Arch package prototype

Build the two required Stage 1 packages with:

```sh
tools/denial-pc arch-package
```

This produces `denial-flutter-engine` and `denial` below:

```text
$XDG_CACHE_HOME/denial/pc-build/packages/
```

These are development snapshots, not public releases. They currently rely on
the prepared development cache and do not claim offline dependency closure or
reproducibility. See:

- [Arch package instructions](packaging/arch/README.md);
- [package validation evidence](packaging/arch/VALIDATION.md);
- [build trust model](BUILD_TRUST.md);
- [production packaging design](packaging/arch/PUBLISHING.md).

The dedicated x86-64 host and its manually armed one-job GitHub runner are
documented in the [builder runbook](packaging/arch/BUILDER.md). Every trusted
push to `dev` or `main` can build and independently verify an installable,
unsigned candidate when the ephemeral runner is armed. `dev` produces a
non-releasable development candidate; `main` independently produces the
production candidate. Both use package release `0`. Only after `main` is
green is a version chosen: the signed-tag workflow promotes those exact
compiled payloads to tag-derived package metadata, signs them, and publishes
them without compiling again. Stage 2 later adds offline input closure. See the
[branch validation boundary](packaging/arch/BRANCH_VALIDATION.md).

Live Flutter UI editing is deliberately split into a third, optional package.
After the pinned debug and profile engines described under
`prebuilt/flutter-engine/` have been rebuilt and staged, create and validate
it with the repository's Rust task:

```sh
cargo xtask ui-development-package
```

The resulting `denial-ui-development` archive is written beside the two
required packages. It contains the coupled JIT engine, optimized AOT profile
engine, curated Dart and Flutter runtime needed for shell assembly and editor
attach, matching browser DevTools assets needed for Inspector and performance
profiling, locked dependency sources needed by Denial's shell, a
version-matched editable source snapshot and revision metadata, and the native
`denial-ui` client. Its isolated validation prepares the real packaged shell
with networking disabled.
An engine binary change requires one Denial session restart; normal Dart hot
reload does not.

The validator reports the compressed and installed sizes and enforces explicit
budgets so accidental package growth fails before publication. See
[Live Flutter UI development](UI_DEVELOPMENT.md).

## Debian and Fedora package adapters

Build both native package families from one compiled and ABI-gated payload:

```sh
tools/denial-pc native-packages
```

`debian-package` and `fedora-package` build either family independently. The
shared staging pass rejects any ELF input requiring a glibc version newer than
2.39, the Ubuntu 24.04 baseline, and records deterministic file inventories
and hashes. Both adapters disable package-time ELF rewriting, extract their
finished archives, and require every installed payload byte and mode to match
that shared tree. Target distributions are required for clean installation
and graphical-session validation, not for compilation or package assembly.
The builder needs `dpkg-deb` for `.deb` output and `rpmbuild`, `rpm`,
`rpm2cpio`, and `bsdtar` for RPM output. Finished packages are written below
`$XDG_CACHE_HOME/denial/pc-build/packages/` by default.

## Local session

Install or remove the development display-manager entry with:

```sh
tools/denial-pc install-session
tools/denial-pc remove-session
```

The packaged session is separate from this development entry. Do not replace
or restart a running compositor implicitly; activate a newly built session
only at an explicit test checkpoint.
