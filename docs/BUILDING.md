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

## Building with your local engine

During development, the Flutter engine is built from the two fork trees as
they are on disk, uncommitted changes included, and the build cache is kept:
only what changed is rebuilt.

| To | Run |
| --- | --- |
| Prepare only the current host's release engine | [Host release engine only](#host-release-engine-only) |
| Build everything: engine, shell, Settings, compositor | `tools/denial-pc build` |
| Build the engine and the shell only | `tools/denial-pc bundle` |
| The same, then reload the shell in the running session | `tools/denial-pc refresh` |
| Deploy everything to a lab host | `tools/denial-lab-deploy USER@HOST` |
| Try an engine change for one login | `tools/denial-pc engine-test-build`, then `engine-test-check` and `engine-test-arm` |

Nothing needs to be committed, locked or checked out first, and no other
source tree is needed. Each build says which trees it used; `+…` is a hash of
their uncommitted changes:

```text
Using the local Flutter and Skia trees as they are on disk:
  Flutter 48e0f675…+40df9477… at /mnt/exty/denial-flutter-fork-3.44.7
  Skia    5b495e3e… at /mnt/exty/denial-skia-fork-3.44.7
```

Not for development:

- `tools/denial-flutter-engine build`, `refresh-metadata` and `verify` use the
  commits pinned in `prebuilt/flutter-engine/SOURCE_LOCK.json`. They are for
  CI and releases.
- The Flutter shell tests (`tools/denial-pc test` and `flutter-test`) run on
  a debug engine from those pinned commits, and need the forks clean at them.
  While the forks are ahead of the lock, test with `sdk-test`, `plugin-check`
  and `compositor-test`.
- Never make a lock-pinned copy of the forks to get around either. A push
  carries everything local, so the complete local combination must be
  validated before pushing, not built implicitly for an engine-only request.

Before pushing, commit in the forks, advance the lock to their HEADs, and run
`tools/denial-flutter-engine refresh-metadata` once
([Pinned Flutter generation](#pinned-flutter-generation)).

### Host release engine only

A local engine update or session-restart preparation defaults to **the
current host's native RELEASE engine only**. Reuse a completed matching
engine and necessary compiler prerequisites rather than rebuilding them.
ARM/cross outputs, debug/profile, development-engine tests, shell/Settings,
compositor, full application/distribution and plugin-kit builds are separate
scopes, not engine prerequisites. `denial-pc build`, `bundle`, and `refresh`,
and `denial-flutter-engine prepare-app-build` prepare broader targets and
must not be used for this request.

On the current x86-64 workstation, the minimal incremental engine command
from the repository root is:

```sh
cache="${DENIAL_FLUTTER_ENGINE_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/denial/flutter-engine}"
flutter="${DENIAL_FLUTTER_SOURCE_ROOT:-/mnt/exty/denial-flutter-fork-3.44.7}"
jobs="$(nproc)"; jobs="$((jobs > 4 ? jobs - 4 : 1))"
flock "$cache/build.lock" env \
  PATH="$flutter/engine/src/flutter/third_party/depot_tools:$PATH" \
  DEPOT_TOOLS_UPDATE=0 \
  /usr/bin/ninja -C "$cache/build/out/denial_host_release" \
  -j "$jobs" libflutter_engine.so
```

This selects only the engine target and its actual dependencies. It does not
assemble, install, or activate an application bundle. Use `-n` with Ninja for
a lightweight readiness check when the engine already exists; a matching
`no work to do` result needs no compilation. Coordinate the shared cache
lock with other builds. The command is for this native x86-64 host, not an
instruction to also build ARM; a native ARM host uses its own architecture
mapping from `tools/lib/denial-architecture.sh`.

Before reuse, check the ELF architecture, `args.gn` host/target CPU and
release runtime modes, local SHA-256, and canonical Flutter/Skia source
state, including uncommitted changes. Check graph provenance with
`denial_engine_output_root` from `tools/lib/denial-local-engine.sh`; it must
resolve to the selected canonical Flutter tree's `engine/src`. If the graph
is missing, points elsewhere, or needs new configuration, first run
`tools/denial-flutter-engine prepare-graph`. That generates only the native
release graph, without an engine or application build. Do not switch to
the lock-pinned `build`/`verify` path for a development engine. If a required
host compiler artifact is absent, select its specific release target;
do not rebuild completed compilers or add cross/debug/profile targets.

**Engine ready does not mean gallery/bundle compatible or active.** A shell,
Settings app or selected plugin bundle built against another engine may
still be incompatible. Report its actual next step separately; do not make
extra builds implicit or assume restarting alone fixes it. Reuse existing
safe staging and never truncate an engine mapped by any running process.
Installation/activation must preserve previous versions and rollback backups.
For authorized test-device deployments, follow the
[no automatic rollback policy](../AGENTS.md#test-device-deployment-failures-no-automatic-rollback),
including when service activation fails: retain the candidate and diagnostic
evidence, report installed/selected/running state separately, and ask the Doctor
before switching back. Local workstation activation still waits at the standard
user-owned session checkpoint. This command neither authorizes a restart/logout
nor arms an isolated engine test.

Plugin-kit preparation is a separate scope, not an engine readiness gate.
For an explicitly requested kit, `prepare-denial-plugin-kit --provenance
development` verifies the canonical native release graph without building it,
and records actual fork revisions, dirty-input hashes and compiler inventory.
Its default `locked-release` mode still requires the source lock and committed
engine checksum. Never change the source lock, spoof metadata, or create a
pinned source projection to prepare a development kit. See
[plugin build-input provenance](PLUGIN_DEVELOPMENT.md#build-input-provenance).

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

Normal builds include Xwayland. To compile and run a Wayland-only compositor,
set the same switch for the build and session commands:

```sh
DENIAL_PC_XWAYLAND=0 tools/denial-pc build
DENIAL_PC_XWAYLAND=0 tools/denial-pc session
```

Xwayland is a default Cargo feature. The environment switch builds the
compositor with `--no-default-features --features flutter`, so Smithay's
Xwayland implementation and `x11rb` are absent from the resolved build graph.
A normal binary can instead disable only server startup for one invocation
with `deniald --no-xwayland`.

Validate the Dart-only plugin SDK without building a Flutter development engine:

```sh
tools/denial-pc sdk-test
```

This checks formatting, analysis, and SDK tests with the pinned Dart toolchain.
It is also included in `tools/denial-pc test` and branch validation.

The Dart suite focuses on wire compatibility, authentication, power actions,
persistence, plugin composition/build/activation, and native geometry authority.
Widget appearance, layout, animation, and per-feature smoke tests are omitted.

Check the Flutter-facing SDK and first-party plugins without building a
development engine:

```sh
tools/denial-pc plugin-check
```

This resolves each package's locked dependencies and checks formatting and static
analysis. The normal release bundle build compiles their shell integration.
It is also included in `tools/denial-pc test` and branch validation.

The default composition selects the built-in top bar. Taskbar is a development
dependency for alternative-composition validation, resolved from the locked
[`denialwm/denial-plugins`](https://github.com/denialwm/denial-plugins)
collection at `plugins/denial_taskbar`. Pub records its exact Git commit in
`dart_shell/pubspec.lock`; no adjacent checkout is required. UI development
snapshots and Nix sources vendor
that package into `plugins/denial_taskbar` so their offline builds remain
self-contained. The flake pins the same collection commit as an explicit input.

Run only the lock-matched Flutter shell tests, optionally forwarding a test
path or other `flutter test` arguments:

```sh
tools/denial-pc flutter-test
tools/denial-pc flutter-test test/platform/denial_wire_test.dart
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

- Flutter `3.47.5`;
- the exact Denial Flutter and Skia fork commits in
  `prebuilt/flutter-engine/SOURCE_LOCK.json`;
- upstream Flutter compatibility revision
  `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`;
- Dart `3.13.4`;
- engine artifact revision `af7e796e161ae0bb1ff0758c71a7105418bd9ded`;
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

During development the canonical trees are used as they are on disk
([Building with your local engine](#building-with-your-local-engine)). The
engine built from them is checked against its own checksum
(`libflutter_engine.so.local.sha256`) rather than the committed one. One GN
output serves every build; a build from another tree regenerates it first.

The lock's exact Flutter and Skia commits are the immutable authority for CI
and release builds. Before pushing, commit in the forks and advance the lock
to their HEADs, so that what is pushed is what was tested. CI never inherits
a developer checkout; it validates or provisions a detached projection of the
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

For CI and releases there are two deliberately separate commands:

```sh
# Build or reuse the locked engine; an unchanged lock is an exact cache hit.
tools/denial-flutter-engine build

# Run exactly once after deliberately advancing SOURCE_LOCK.json.
tools/denial-flutter-engine refresh-metadata

# Refresh package declarations from verified lock-matched release inputs.
tools/refresh-denial-engine-manifests
tools/refresh-denial-engine-manifests --check
```

`refresh-metadata` regenerates the release mode's tracked `args.gn` and
canonical checksum, incrementally rebuilds invalidated release targets,
populates the new revision-keyed cache entry, and stages the verified release
engine below `prebuilt/`. Debug and profile modes are included only with the
separately requested `DENIAL_FLUTTER_ENGINE_DEVELOPMENT_MODES=1` scope.
Do not invoke the routine `build` command and manually fix successive mode
checksum failures during a lock advance.

The manifest helper derives source, GN, header, engine and build-ID hashes,
then updates both package manifests and their PKGBUILD manifest checksums.
It requires clean canonical forks at the lock and a checksum-verified native
release engine. The paused legacy UI-development package records its retained
debug/profile engines' actual source identities separately; a release-only
refresh does not rebuild them or claim they match the new source lock.

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
- Xwayland, unless building with `DENIAL_PC_XWAYLAND=0`;
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

Build the two required runtime packages and the optional Plugin Manager package
with:

```sh
tools/denial-pc arch-package
```

This produces `denial-flutter-engine`, `denial`, and
`denial-plugin-manager` below:

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

Live Flutter UI editing remains split into another optional package. Debug
and profile engines are excluded from the routine build and release path. The
legacy package can only be refreshed after an explicitly requested engine
build with `DENIAL_FLUTTER_ENGINE_DEVELOPMENT_MODES=1`; then create and
validate it with the repository's Rust task:

```sh
cargo xtask ui-development-package
```

The resulting legacy `denial-ui-development` archive is written beside the
release packages. It contains the coupled JIT engine, optimized AOT profile
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

## Debian, Fedora, and openSUSE package adapters

Build both native package families from one compiled and ABI-gated payload:

```sh
tools/denial-pc native-packages
```

`debian-package` and `fedora-package` build either release family
independently. Build the openSUSE adapter separately with:

```sh
tools/denial-pc opensuse-package
```

The shared staging pass rejects any ELF input requiring a glibc version newer
than 2.39, the Ubuntu 24.04 baseline, and records deterministic file
inventories and hashes. Every adapter disables package-time ELF rewriting,
extracts its finished archives, and requires every installed payload byte and
mode to match that shared tree. Target distributions are required for clean
installation and graphical-session validation, not for compilation or package
assembly. The builder needs `dpkg-deb` for `.deb` output and `rpmbuild`, `rpm`,
`rpm2cpio`, and `bsdtar` for RPM output. Finished packages are written below
`$XDG_CACHE_HOME/denial/pc-build/packages/` by default; openSUSE RPMs use its
`opensuse/` child because their dependency metadata intentionally differs from
the Fedora RPMs with the same payload version.

## Local session

Install or remove the development display-manager entry with:

```sh
tools/denial-pc install-session
tools/denial-pc remove-session
```

The packaged session is separate from this development entry. Do not replace
or restart a running compositor implicitly; activate a newly built session
only at an explicit test checkpoint.
