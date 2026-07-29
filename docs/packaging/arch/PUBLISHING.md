# Denial Arch packaging and repository design

> Status: Stage 1, the private pipeline rehearsal, the resource and structure
> review, and the clean repository root completed on 2026-07-25. Denial 0.1.0
> activated the signed public-alpha repository on 2026-07-26. Every trusted
> `main` push can produce an unsigned, independently checked candidate when the
> ephemeral runner is armed; clean signed tags use the separate release,
> signing, verification, and Pages path. Denial 0.2.0 extends that path with
> the optional, version-coupled `denial-ui-development` package. Stage 2 and
> Stage 3 remain later hardening work rather than prerequisites for an honest
> alpha.

This document defines both the intended production packaging model for Denial
and the gates used to reach it. It supersedes the earlier monolithic
runtime-archive proposal.

Denial's own Pacman repository publishes normal signed binary packages.
Flutter is maintained as a separate, slowly changing generation; routine
Denial releases reuse that generation and do not rebuild Flutter Engine. The
public alpha discloses that its owner-operated builder is not independently
reproducible. Later stages progressively close and reproduce every build
input.

The long-term package model has four roles:

```text
denial-flutter-toolchain ──builds──▶ denial ──requires──▶ denial-flutter-engine
                                         ▲                     ▲
                                         │                     │ same ABI
denial-ui-development (optional) ─requires┘─────────────────────┘
```

Compilation happens in package builders, never during `pacman -S`, an install
hook, or first launch. The public alpha uses the validated two-package runtime
split, `denial-flutter-engine` plus `denial`, and publishes
`denial-ui-development` separately for users who want live Flutter shell
editing. The build-only `denial-flutter-toolchain` arrives in Stage 2.

## Delivery stages

The build and distribution system is introduced in four deliberate stages:

| Stage | Purpose | Dependency control | Distribution |
|---|---|---|---|
| 1. Prototype build | Prove the source build and package split | Pinned top-level revisions, but online acquisition and existing caches are allowed | Local `pacman -U` testing only |
| 1.5. Signed public alpha | Give early users ordinary Pacman install and update semantics with explicit limits | Stage 1 inputs plus a clean signed version tag, locked package set, release evidence, and a separate signing job | Signed x86_64 first-party repository |
| 2. Pinned build | Make the build repeatable and reviewable | All effective inputs are fixed, declared, and checked | Clean-chroot and testing repository |
| 3. Secured build | Harden releases after adoption justifies the cost | Offline closure, reproducibility, independent comparison, SBOM, audit, and recovery exercises | Hardened public repository |

“Unsecured prototype” describes the absence of stronger supply-chain
assurances. It does not permit intentionally unsafe code or skipped source
review. Arbitrary Stage 1 outputs and the disposable-key rehearsal remain
private. A public-alpha artifact is a distinct output: it must come from the
reviewed manual tag workflow, pass the documented tests, carry the permanent
Denial signature, and state every missing assurance next to the download.

Each stage keeps the package boundaries and generation model needed by the
next stage. The prototype is therefore useful implementation work, not a
throwaway build script.

Architectures advance through the gates independently:

```text
x86_64:  Stage 1 ──▶ Public alpha ──▶ Stage 2 ──▶ Stage 3
aarch64:                     Stage 1 ──▶ Stage 2 ──▶ Stage 3
```

The first active lane is x86_64. The public repository advertises only that
lane. AArch64 work starts later and follows its own gates; adding it does not
require rebuilding or redesigning x86_64.

## Public-alpha release contract

The initial public repository deliberately makes a smaller, testable promise:

- every release is manually dispatched from a clean `vMAJOR.MINOR.PATCH`
  tag signed by the Denial release identity;
- the tag commit must be contained in public `main`;
- the owner-operated x86_64 builder receives no signing secret and never runs
  pull-request or fork code;
- the existing compositor and Flutter test suites run before packaging;
- exactly one compatible `denial` and `denial-flutter-engine` pair, plus the
  optional version-matched `denial-ui-development` package when present in the
  release contract, is handed to a separate GitHub-hosted signing job;
- packages, Pacman databases, and the complete checksum manifest are signed;
- the signed repository is re-verified without a secret key before one Pages
  artifact is deployed;
- the same package set and evidence are retained on a draft GitHub Release,
  which is published only after Pages deployment succeeds;
- package filenames are immutable and installation uses Pacman's normal
  signature enforcement.

Every release page and repository manifest also states what this does not
prove: there is no complete offline dependency closure, byte-for-byte
reproducibility claim, independent builder, generated SBOM, or AArch64
support yet. Signatures prove that Denial authorized exact bytes; they do not
prove that those bytes were independently reconstructed from source.

## Stage 3 hardened-release goals

The release system must provide:

- source-built `libflutter_engine.so`, `libapp.so`, `deniald`, and
  `denialctl`;
- immutable and independently verifiable source provenance;
- compilation without network access after inputs have been acquired;
- exact coupling between Flutter, Dart, the engine, AOT output, and the Rust
  embedder bindings;
- separate signed packages for every architecture advertised by the
  repository, beginning with `x86_64` and later adding `aarch64`;
- rare Flutter-generation releases and inexpensive routine Denial releases;
- clean-chroot builds with reproducibility checks;
- atomic, signed Pacman repository publication;
- enough metadata to reproduce or investigate any published binary.

The build does not need to bootstrap every compiler from source. Pinned,
signed compilers and build utilities are a normal trust boundary, just as
Arch packages use existing Rust, Clang, Dart, GN, and Ninja packages to build
new binaries. The important guarantee is that every shipped Denial runtime
artifact is compiled from declared source and that every build input is
identified.

## Package architecture

Stage 1 implements the `denial-flutter-engine` and `denial` runtime split. It
uses the locally bootstrapped pinned Flutter SDK to build the application. The
public-alpha channel additionally carries the optional
`denial-ui-development` package. The immutable
`denial-flutter-toolchain` package and the combined split-package base are
introduced in Stage 2, after the engine source build is proven.

### `denial-flutter-engine`

This is the small runtime portion of a Denial Flutter generation. It contains:

```text
/usr/lib/denial/flutter/lib/libflutter_engine.so
/usr/lib/denial/flutter/data/icudtl.dat
/usr/share/denial/flutter-engine/manifest.json
/usr/share/licenses/denial-flutter-engine/LICENSE.flutter
/usr/share/licenses/denial-flutter-engine/LICENSE.third_party
```

The engine binary is rebuilt only when the locked Flutter/Skia source,
configuration, a relevant security fix, or a target ABI changes. Each signed
Denial tag packages the verified binary under that tag's version, so a release
never replaces an older archive identity. The package must not expose itself
as a general system Flutter Engine: Denial makes stronger compatibility
assumptions than the public C symbol names alone express.

### `denial-flutter-toolchain`

This is a build-only package from the same Flutter generation. It supplies the
matching:

- the locked Denial Flutter framework;
- Dart SDK and frontend tools;
- target `gen_snapshot`;
- Flutter assembly targets;
- engine metadata needed to produce compatible AOT output;
- a helper that materializes a writable toolchain copy below `$srcdir`.

Flutter tooling historically expects parts of its SDK cache to be writable.
The installed package must remain immutable. A Denial build therefore copies
or reflinks the packaged toolchain seed into its build directory and operates
only on that private copy.

The first implementation may package a complete pre-populated toolchain seed.
It can be reduced to the exact AOT inputs later, provided the reduced form is
still reproducible and works offline.

Ordinary users do not need this package at runtime. It is a `makedepends` of
the source-built `denial` package and can be removed after the package build.
Publishing it makes the build environment available to users and independent
rebuilders instead of keeping an undocumented CI-only toolchain.

### `denial`

This is the user-facing package. It contains:

```text
/usr/bin/deniald
/usr/bin/denialctl
/usr/bin/denial-session
/usr/share/man/man1/denialctl.1.gz
/usr/lib/denial/flutter/lib/libapp.so
/usr/lib/denial/flutter/data/flutter_assets/
/usr/share/wayland-sessions/denial.desktop
/usr/share/xdg-desktop-portal/denial-portals.conf
/etc/denial/
/etc/xdg/xdg-desktop-portal-wlr/Denial
/usr/share/licenses/denial/
```

It depends on the exact compatible virtual engine generation and uses the
matching toolchain generation at build time. Routine Denial releases rebuild
only the Rust compositor and control client, Dart AOT application, assets,
tests, and package.

The package retains `backup=()` entries for administrator-owned configuration.
Normal installation does not require a `.install` script beyond actions that
cannot be expressed through ordinary package ownership.

### `denial-ui-development`

This is an optional, user-facing development package for live editing and
profile-mode analysis of the Flutter shell. It contains the matching
JIT-capable and optimized AOT profile engines, a curated Flutter and Dart
runtime, the fork-built Flutter tool snapshot, matching browser DevTools assets,
locked shell dependency sources, the native `denial-ui` client, a
version-matched source snapshot, and the editor configuration exercised by
Denial.

It requires a bounded Denial version range and the exact
`denial-flutter-engine-abi` generation. Its isolated package validation
prepares Denial's real JIT shell with network access disabled and verifies the
engine, tool, source, permissions, licenses, and size budgets. Initial
`denialctl ui setup` uses GitHub to create a normal editable checkout at the
recorded source revision; compilation does not occur inside a Pacman hook.

The package is not a sandbox. A custom Flutter shell and direct VM-service
access are trusted local-user capabilities. The packaged editor debug-adapter
connection remains non-pausing, but browser DevTools uses the broader
VM-service interface for Inspector and performance profiling. Pausing the root
isolate through DevTools also pauses the interactive desktop.

### Split package base

`denial-flutter-engine` and `denial-flutter-toolchain` should be produced by
one source PKGBUILD with a package base such as `denial-flutter`. One checkout,
one source closure, and one engine build then produce both packages with an
identical generation.

Debug-symbol publication may be produced from the same build. The production
runtime should be stripped, while matching unstripped symbols remain available
for crash analysis. The JIT engine shipped by `denial-ui-development` is a
runtime-mode artifact, not a substitute for separate native debug symbols.

## Flutter generation and compatibility

Denial uses a named Flutter generation rather than treating
`libflutter_engine.so` as an interchangeable library. The current virtual
compatibility capability is:

```text
3.44.7.denial1
```

Its human-readable generation identifier is:

```text
flutter-3.44.7-engine-69c8c617-denial-r1
```

The first generation records at least:

```text
Flutter version:             3.44.7
Flutter source revision:     84fc5cbb223bc12f83d65b647ff8a56caf779ffd
Engine artifact revision:    69c8c61792f04cc809dfef0c910414fb9afc06cd
Dart source revision:        d684a576a6aa954ae107a03b2b4e1d61c3bebe93
Skia upstream revision:      e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465
Flutter fork revision:       af53fe6dc91e13ea1d2da9103d7d88fc202dd052
Skia fork revision:          5097a648e9bbb1d4a7fdf06a2a6d7bef3c9dd414
Fork source lock:             prebuilt/flutter-engine/SOURCE_LOCK.json
Embedder header checksum:    recorded in compositor/flutter-engine/src/sys.rs
```

Every change to a Flutter, Dart, or Skia revision, either fork history, engine
or framework/tool behavior, an AOT compiler input, embedder header, or
compatibility-relevant GN configuration creates a new checksummed engine
artifact identity. The next signed Denial tag gives that artifact a fresh
package version automatically. Increment the virtual ABI only when Denial and
the engine are no longer runtime-compatible; reserve `pkgrel` for a
packaging-only correction to one tagged release.

The runtime package takes its release identity from the tag while advertising
the versioned virtual capability separately:

```bash
pkgver="${DENIAL_PACKAGE_VERSION}"
epoch=1
_flutter_generation=3.44.7.denial1

provides=("denial-flutter-engine-abi=${_flutter_generation}")
```

The build-only package advertises the matching AOT generation:

```bash
provides=("denial-flutter-aot-generation=${_flutter_generation}")
```

The Denial package declares:

```bash
_flutter_generation=3.44.7.denial1

depends+=(
  denial-flutter-engine
  "denial-flutter-engine-abi=${_flutter_generation}"
  rtkit
)
makedepends+=(
  denial-flutter-toolchain
  "denial-flutter-aot-generation=${_flutter_generation}"
)
```

Versioned virtual capabilities couple the actual Flutter generation without
also coupling a packaging-only `pkgrel`. The unversioned concrete dependencies
ensure that Pacman selects Denial's packages, while their virtual capabilities
enforce the compatible generation.

`deniald --version` should print the Denial version and Git revision together
with the expected Flutter generation. At startup, Denial should read
`manifest.json` and reject a mismatched generation or embedder-header hash
with a precise error. A binary checksum may be recorded as additional
integrity evidence, but the generation identifier is the compatibility
contract.

The manifest installed by `denial-flutter-engine` should contain:

- schema version;
- package version and release;
- Flutter, engine, Dart, and Skia revisions;
- Flutter and Skia fork repositories and exact commits;
- the immutable source-lock hash;
- embedder-header SHA-256;
- target architecture;
- normalized GN arguments;
- source-closure identifier and SHA-256;
- compiler and linker versions;
- hashes of `libflutter_engine.so` and `icudtl.dat`;
- `SOURCE_DATE_EPOCH`;
- license-manifest or SBOM location.

## Release cadence

Flutter and Denial deliberately have separate cadences.

Routine development looks like:

```text
Flutter generation 3.44.7.denial1
├── Denial 0.1.0
├── Denial 0.2.0
├── Denial 0.3.0
└── Denial 0.4.0
```

All four Denial releases may reuse the same verified engine binary. Each
signed tag still emits a uniquely versioned runtime archive alongside its new
`libapp.so` and `deniald`; routine releases do not compile Flutter Engine
again.

A planned production Flutter upgrade happens only after the new generation
has passed fork-commit review, offline builds, reproducibility checks, and
hardware validation. Once both architecture lanes are supported, it looks
like:

```text
Flutter generation 3.45.x.denial1
├── engine/toolchain build for x86_64
├── engine/toolchain build for aarch64
├── Denial rebuild for each supported architecture
└── one atomic repository promotion
```

One or two scheduled Flutter upgrades per year is a reasonable policy.
Unscheduled releases remain possible for:

- a relevant Flutter, Dart, Skia, ICU, or toolchain security issue;
- a system-library ABI or SONAME transition;
- a correctness bug in the Denial engine fork;
- an architecture-specific engine failure;
- a required embedder ABI change.

The repository must monitor these conditions instead of assuming that a
calendar pin is safe indefinitely.

## Flutter and Skia fork provenance

Flutter checks out Skia as a separate Git dependency. Denial modifies both
histories, so one Flutter fork cannot honestly contain the complete source
delta. The paired public Flutter and Skia forks are the development and CI
sources of truth. The exact release inputs are the immutable commits in
`prebuilt/flutter-engine/SOURCE_LOCK.json`:

- Flutter: [`denialwm/flutter`](https://github.com/denialwm/flutter),
  branch `denial/3.44.7-r1`, currently
  `af53fe6dc91e13ea1d2da9103d7d88fc202dd052`;
- Skia: [`denialwm/skia`](https://github.com/denialwm/skia),
  branch `denial/3.44.7-r1`, currently
  `5097a648e9bbb1d4a7fdf06a2a6d7bef3c9dd414`.

The engine portions of these histories were independently verified on
2026-07-25; the three Flutter framework/tool commits were migrated and tested
on 2026-07-29. The branches are movable review references. Build and release
inputs use the immutable commit IDs above, never an unpinned branch name.

The
[engine validation report](../../flutter-engine/3.44.7/VALIDATION.md)
records the historical reconstruction, exact fork-tree comparison,
x86_64 source build, artifact comparison, and engine unit-test results.

```text
upstream flutter/flutter                 upstream google/skia
          │                                       │
          ▼                                       ▼
Denial Flutter branch                     Denial Skia branch
  - fourteen logical commits                - two logical commits
          │                                       │
          ▼                                       ▼
immutable Flutter commit                 immutable Skia commit
          └──────────┬────────────────────────────┘
                     ▼
         immutable SOURCE_LOCK.json
                     ▼
        verified incremental engine build
```

The branches start at their exact upstream revisions:

```text
flutter/flutter @ 84fc5cbb223bc12f83d65b647ff8a56caf779ffd
└── denial/3.44.7-r1
    ├── Query embedder FBO capabilities
    ├── Enable stencil for GL surfaces
    ├── Wrap texture-backed FBOs for GLES DMSAA loads
    ├── Describe XRGB scanout textures as RGB8
    ├── Preserve partial damage for reused layer trees
    ├── Damage only marked external textures
    ├── Decouple autonomous damage from the raster clip
    ├── Schedule batched external-texture frames
    ├── Cache rotating embedder GL surfaces
    ├── Pin the Denial Skia fork
    ├── Format the rotating surface cache
    ├── Tune pointer resampling for 120 Hz shells
    ├── Allow explicit attach for raw embedder projects
    └── Keep Denial attach sessions non-pausing

google/skia @ e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465
└── denial/3.44.7-r1
    ├── Fix DMSAA lifetime and stencil continuity on wrapped GL FBOs
    └── Use highp coordinates for partial DMSAA loads
```

Keep one reviewable change in each commit. Commit messages must describe the
problem, Denial's dependency on the behavior, validation evidence, and any
corresponding upstream issue or pull request.

Do not let Flutter or Skia inherit an unrelated machine-wide identity. Before
creating Denial-owned commits, configure both fork checkouts explicitly:

```sh
git -C /path/to/flutter-fork config --local user.name 'Doctor Logix'
git -C /path/to/flutter-fork config --local user.email 'doctor.logix@gmail.com'
git -C /path/to/skia-fork config --local user.name 'Doctor Logix'
git -C /path/to/skia-fork config --local user.email 'doctor.logix@gmail.com'
```

This configuration affects only new commits. If a commit already has the
wrong author, amend or rebase it before publishing the review branch.

For every generation, update `SOURCE_LOCK.json` with exact Flutter, Skia, and
bootstrap depot_tools commits. Flutter DEPS must select the locked Skia
repository and commit. `tools/denial-release source-audit` verifies that the
engine and UI manifests agree with this lock and rejects a downstream patch
directory.

`tools/denial-flutter-engine build` is the canonical source-to-artifact path.
It verifies the locked checkout, compares generated GN arguments with the
committed configuration, and verifies all three engine checksums. An unchanged
lock is an artifact-cache hit; a changed lock retains the checkout and Ninja
outputs for an incremental rebuild.

For an upgrade, rebase the logical commits and review semantic drift with
`git range-diff`:

```sh
git range-diff \
  old-upstream..denial/3.44.7 \
  new-upstream..denial/3.45.x
```

Run the same review independently for the paired Skia branch.

Keep old release source locks immutable. Generally useful fixes should be
proposed upstream so accepted changes can disappear naturally from future
Denial fork branches.

## Offline source closure

An offline build is feasible once all inputs have been acquired. Network
access is allowed only in an explicit source-preparation job; it is prohibited
when compiling release packages.

The common source closure contains:

- the exact Flutter monorepo revision;
- all Git repositories selected by Flutter `DEPS`;
- exact Dart, Skia, ICU, Vulkan, and other third-party sources;
- the immutable Denial Flutter and Skia fork commits;
- locked Rust crate sources required by the Flutter/engine build;
- locked Dart and Pub sources required to construct the framework and
  toolchain;
- the embedder header and binding-generation metadata;
- all license files and a generated license inventory;
- the closure manifest and its schema.

Architecture-specific tool-input closures contain any pinned host or target
artifacts that the Flutter build normally obtains through CIPD or SDK cache
population. Every CIPD instance ID and checksum must be present in the common
manifest. These are declared build tools, not undocumented runtime blobs.
Every redistributed tool input must pass a license review. An input that
cannot legally be mirrored must instead come from an allowed package
dependency or be built from redistributable source.

A suggested release layout is:

```text
denial-flutter-source-3.44.7.denial1.tar.zst
denial-flutter-source-3.44.7.denial1.tar.zst.sig
denial-flutter-tools-3.44.7.denial1-x86_64.tar.zst
denial-flutter-tools-3.44.7.denial1-x86_64.tar.zst.sig
denial-flutter-tools-3.44.7.denial1-aarch64.tar.zst
denial-flutter-tools-3.44.7.denial1-aarch64.tar.zst.sig
denial-flutter-3.44.7.denial1-manifest.json
denial-flutter-3.44.7.denial1-manifest.json.sig
```

The source PKGBUILD declares the common closure in `source=()` and the tool
inputs in `source_x86_64=()` and `source_aarch64=()`, with SHA-256 values for
every archive. Detached signatures are also declared as sources and verified
against explicit `validpgpkeys`. A signature does not replace the package
checksum; both are kept.

### Source-closure preparation

A future `tools/prepare-flutter-source-closure` command runs online in a
controlled environment and must:

1. verify the locked Flutter and Skia commits and Denial generation manifest;
2. fetch the exact upstream Flutter revision;
3. resolve `DEPS` without floating branches;
4. pin and disable `depot_tools` self-update;
5. fetch every referenced Git and CIPD object;
6. verify every revision and instance ID;
7. fetch locked Cargo and Pub sources;
8. remove build outputs, caches not required for offline use, and credentials;
9. normalize archive ownership, order, permissions, and timestamps;
10. generate the license inventory and SBOM;
11. create and hash the common and architecture-specific archives;
12. rehydrate them in a fresh network-disabled environment;
13. complete an engine/toolchain build before signing the closure.

Some Flutter scripts derive version data with `git rev-parse`. The closure must
either retain minimal local repository metadata or modify those scripts to read
the immutable generation manifest. A package build must never infer release
identity from an arbitrary checkout state.

The first source acquisition necessarily needs network access. Subsequent
compilation is offline when the signed source archives and dependency packages
are present in `SRCDEST` and the Pacman cache.

### Build-environment closure

Source archives alone do not reproduce a build on a rolling distribution. A
generation also records the complete clean-chroot environment:

- architecture and base-image or chroot snapshot identifier;
- every Pacman build dependency and exact installed version;
- Rust, Clang, LLD, Dart, GN, Ninja, Python, and system-library versions;
- `/etc/makepkg.conf` build flags;
- locale and other output-affecting environment values;
- container image digest when a container is used.

The release builder seeds a local Pacman cache or signed build repository with
those packages before its network is disabled. `.BUILDINFO` is published with
the resulting package. Long-term reproduction may use an Arch Linux Archive
snapshot or a retained Denial build-environment image, but the image digest
does not replace the package-level input manifest.

## Source-built Flutter package base

The production `denial-flutter` PKGBUILD is conceptually:

```bash
pkgbase=denial-flutter
pkgname=(
  denial-flutter-engine
  denial-flutter-toolchain
)
pkgver=3.44.7.denial1
pkgrel=1
arch=(x86_64 aarch64)

source=(
  "denial-flutter-source-${pkgver}.tar.zst::https://.../"
)
source_x86_64=(
  "denial-flutter-tools-${pkgver}-x86_64.tar.zst::https://.../"
)
source_aarch64=(
  "denial-flutter-tools-${pkgver}-aarch64.tar.zst::https://.../"
)

prepare() {
  # Verify the closure manifest.
  # Verify the locked Flutter and Skia source trees.
  # Configure Cargo and Pub to use only vendored sources.
}

build() {
  # Select explicit GN and AOT settings from CARCH.
  # Build libflutter_engine.so and the matching AOT tools.
  # Record the normalized GN arguments and artifact hashes.
}

check() {
  # Verify source identity, engine exports, bindings, architecture, tests,
  # licenses, manifests, and absence of undeclared network inputs.
}

package_denial-flutter-engine() {
  provides=("denial-flutter-engine-abi=${pkgver}")
  # Install only runtime engine files, metadata, and licenses.
}

package_denial-flutter-toolchain() {
  provides=("denial-flutter-aot-generation=${pkgver}")
  # Install the immutable AOT toolchain seed and materialization helper.
}
```

`prepare()` and `build()` run with the network unavailable. Commands such as
the following are forbidden there:

- `git fetch`, `git clone`, or access to a remote Git URL;
- `curl`, `wget`, or an implicit HTTP client;
- online `gclient sync` or CIPD resolution;
- Flutter cache downloads;
- online `cargo fetch`;
- online `dart pub get`.

The permitted equivalents consume the unpacked closure:

```sh
export DEPOT_TOOLS_UPDATE=0
export PUB_CACHE="$srcdir/pub-cache"

cargo build --frozen --offline
dart pub get --offline
```

The build should be executed inside an isolated network namespace so an
undeclared fetch fails immediately rather than succeeding from CI's ambient
network.

## Routine Denial source package

The stable Denial PKGBUILD builds from an immutable `vX.Y.Z` source tag. Its
source archive or companion vendor archive contains the locked Cargo and Pub
dependencies needed for an offline build.

The conceptual recipe is:

```bash
pkgname=denial
pkgver="${DENIAL_PACKAGE_VERSION:?verified tag version is required}"
pkgrel=1
arch=(x86_64 aarch64)

_flutter_generation=3.44.7.denial1

depends=(
  denial-flutter-engine
  "denial-flutter-engine-abi=${_flutter_generation}"
  rtkit
  # Other direct runtime dependencies.
)
makedepends=(
  denial-flutter-toolchain
  "denial-flutter-aot-generation=${_flutter_generation}"
  cargo
  # Other direct build dependencies.
)

prepare() {
  # Materialize the immutable toolchain below $srcdir.
  # Configure Cargo and Pub for vendored, offline resolution.
}

build() {
  # Build libapp.so for the CARCH-specific Flutter target.
  # Build deniald with cargo --frozen --offline.
}

check() {
  # Run Dart, Rust, ABI, manifest, and non-hardware smoke tests.
}

package() {
  # Install deniald, libapp.so, assets, sessions, configuration, and licenses.
  # Do not install libflutter_engine.so or icudtl.dat; the engine package owns them.
}
```

The verified release tag is the sole input to PKGBUILD `pkgver` and generated
runtime version output. Cargo and Dart retain `0.0.0` only because their
unpublished source manifests require a version field; they are not release
inputs. Reject a dirty worktree. Set `SOURCE_DATE_EPOCH` from the release-tag
commit timestamp.

No compilation belongs in `post_install()` or another Pacman transaction
hook. Installation only verifies signatures, resolves dependencies, and
extracts package-owned files.

### Metadata and dependency policy

The stable PKGBUILD must:

- materialize `pkgver` from the verified signed tag and use `pkgrel=1`;
- declare the immutable Denial source and vendor closure in `source=()`;
- use checksums for every source and signatures where available;
- package only files produced below `$srcdir` and `$pkgdir`;
- accept release identity only from the tag-verifying release controller and
  reject unrelated environment overrides or externally injected binaries;
- generate `.SRCINFO` from the final tag-derived metadata;
- reset `pkgrel` to `1` for each new Denial version and increment it only for
  packaging changes;
- install a project-level `LICENSE` under
  `/usr/share/licenses/denial/`;
- use normal stripping and publish matching debug information;
- preserve administrator configuration through `backup=()`;
- expose `deniald --version` with the Denial and Flutter generation details.

Audit direct runtime dependencies instead of relying on transitive packages.
The current package specifically needs these corrections:

- use `bluez` rather than `bluez-utils` for Bluetooth support because Denial
  communicates with BlueZ over D-Bus and does not invoke its command-line
  utilities;
- remove `brightnessctl` unless Denial begins invoking it;
- declare `libpulse` directly because the compositor dynamically loads
  `libpulse.so.0`;
- keep PulseAudio-compatible servers such as `pipewire-pulse` as optional
  runtime choices rather than substitutes for the client library dependency.

`tools/denial-pc arch-package` remains useful for local development snapshots.
Snapshot versions may include a Git revision and `.dirty`, but no dirty or
environment-injected package is eligible for signing or repository
publication.

## Architecture matrix

Flutter, Rust, and Pacman use different names for the same CPU families:

| Layer | x86-64 | ARM64 |
|---|---|---|
| Pacman `CARCH` | `x86_64` | `aarch64` |
| Flutter architecture | `x64` | `arm64` |
| Flutter target | `linux-x64` | `linux-arm64` |
| Rust target triple | `x86_64-unknown-linux-gnu` | `aarch64-unknown-linux-gnu` |
| Package suffix | `x86_64.pkg.tar.zst` | `aarch64.pkg.tar.zst` |

The PKGBUILDs use one explicit mapping:

```bash
case "$CARCH" in
  x86_64)
    _flutter_arch=x64
    _flutter_target=linux-x64
    _rust_target=x86_64-unknown-linux-gnu
    _engine_out=denial_linux_x64_release
    _engine_gn_args=(
      --runtime-mode=release
      "--target-dir=${_engine_out}"
    )
    ;;
  aarch64)
    _flutter_arch=arm64
    _flutter_target=linux-arm64
    _rust_target=aarch64-unknown-linux-gnu
    _engine_out=denial_linux_arm64_release
    _engine_gn_args=(
      --linux
      --linux-cpu=arm64
      --runtime-mode=release
      "--target-dir=${_engine_out}"
    )
    ;;
  *)
    error "unsupported architecture: $CARCH"
    return 1
    ;;
esac
```

The AOT target follows the same mapping:

```text
x86_64:
  -dTargetPlatform=linux-x64
  release_bundle_linux-x64_assets

aarch64:
  -dTargetPlatform=linux-arm64
  release_bundle_linux-arm64_assets
```

`libflutter_engine.so`, `libapp.so`, and `deniald` are native code and must be
built separately for each architecture. Flutter assets may be identical, but
they are still packaged with and validated against the corresponding native
artifacts.

### Builder policy

The release authority should use:

- a clean native Arch x86-64 builder;
- a clean native AArch64 builder using an Arch-compatible AArch64 userspace;
- real x86-64 and ARM64 hardware for compositor smoke tests.

The initial x86-64 authority is a dedicated, maintainer-owned Arch Linux
laptop. Ownership is disclosed and is not presented as an independent trust
domain. It accepts only explicitly armed trusted-`main` jobs and manually
dispatched signed-tag release jobs. It never runs pull-request or fork code,
contains no production signing key, and registers as an ephemeral one-job
runner. The public operating contract and bring-up procedure are recorded in
[BUILDER.md](BUILDER.md).

Two clean builds on that laptop test determinism but are reported as
same-builder reproduction. Only a byte-identical result from infrastructure
outside the maintainer's control is reported as independent reproduction.

Flutter supports cross-building its Linux ARM64 engine from an x86-64 host,
and Rust can target `aarch64-unknown-linux-gnu`. A complete Denial cross-build
also needs an AArch64 sysroot and matching target development libraries for
EGL, GBM, libinput, libseat, udev, libxkbcommon, and other Smithay
dependencies. Cross-builds are useful for early CI, but native builders are
the preferred signed-release authority.

Generic AArch64 packages target the baseline architecture and must not use
`-mcpu=native` or a device-specific `--arm-tune`. Vendor kernels, Mesa forks,
firmware, or device enablement belong in separate repositories or packages;
they must not be hidden inside the generic Denial package.

For each package, validation must confirm that all ELF artifacts match
`CARCH`. An x86-64 engine with an AArch64 `libapp.so`, or the reverse, must
fail before packaging.

## Build and validation requirements

### Source and offline checks

Every build must:

1. verify source hashes and available signatures;
2. verify the generation manifest and exact fork source lock;
3. verify that Flutter DEPS resolves the locked Skia fork commit;
4. use only locked Cargo and Pub dependencies;
5. run the package compilation phase with the network namespace disabled;
6. fail if a tool attempts to modify an installed system package;
7. record the complete package `.BUILDINFO`.

### Flutter and ABI checks

The engine build must:

- compare generated `args.gn` with the reviewed generation configuration;
- export `FlutterEngineGetProcAddresses` and all other required embedder
  symbols;
- regenerate the Rust bindings only during a controlled generation update;
- run `tools/generate-flutter-embedder-bindings --check`;
- confirm the embedder-header checksum and recorded revisions;
- verify that the AOT toolchain and runtime engine identify the same Dart and
  engine generation;
- build and retain matching debug information;
- generate the third-party license inventory.

The same committed Rust bindings will probably serve both Linux x86-64 and
AArch64 because both use an LP64 ABI, but this is a tested property, not an
assumption. Layout and symbol tests must run for both targets.

### Package checks

Every resulting package must be checked with:

- `namcap` against the PKGBUILD and package;
- `readelf` or equivalent architecture and dynamic-dependency inspection;
- RPATH and RUNPATH inspection;
- direct shared-library dependency auditing;
- file ownership, permissions, and collision checks;
- installation and upgrade in a disposable Pacman root;
- dependency resolution against the staged repository;
- an uninstall check confirming that no unowned generated files remain.

The production package should follow normal Arch stripping and debug-package
conventions instead of retaining all symbols through `options=('!strip')`.
If Flutter's build performs its own stripping, the unstripped output and build
IDs must be captured explicitly.

### Reproducibility

For every architecture advertised as a hardened release lane:

1. build the same source package twice in fresh environments;
2. compare the package and principal ELF artifacts;
3. investigate differences with `diffoscope`;
4. normalize timestamps through `SOURCE_DATE_EPOCH`;
5. preserve compiler, linker, GN, and source-closure identifiers;
6. publish reproducibility status with the release.

`makerepropkg` or an equivalent clean two-build comparison should be part of
the release gate.

### Hardware checks

Chroot tests cannot validate a compositor. Before hardened promotion,
exercise at least:

- session startup and shutdown;
- DRM/KMS output discovery and modesetting;
- GBM/EGL renderer creation;
- Flutter scene rendering;
- Wayland client composition;
- Xwayland startup;
- input and seat handling;
- external textures and partial damage;
- dynamic-MSAA and stencil behavior maintained by the engine fork.

Run the relevant subset on real x86-64 and ARM64 GPU hardware. QEMU can verify
userspace execution but cannot replace real display and driver tests.

## Release pipelines

### Flutter-generation release

This heavy pipeline runs rarely:

1. approve the new generation manifest;
2. tag the tested Flutter and Skia forks;
3. update and review the immutable fork source lock;
4. create the signed offline source closure;
5. build `denial-flutter-engine` and `denial-flutter-toolchain` for every
   architecture in this promotion without network access;
6. run static, unit, ABI, license, and reproducibility checks;
7. run real-hardware rendering tests;
8. rebuild Denial for the new generation on every architecture in this
   promotion;
9. verify dependency resolution in a staged repository;
10. sign every package and source artifact;
11. publish the entire compatible set atomically.

An engine generation is never promoted alone when the currently published
Denial package requires a different generation.

### Routine Denial release

This is the normal, inexpensive path:

1. create and sign a clean `vX.Y.Z` tag;
2. verify that the tag alone supplies all package and runtime versions;
3. use the already published matching Flutter toolchain;
4. build `libapp.so` and `deniald` offline for each released architecture;
5. run tests, package checks, and available hardware smoke tests;
6. build twice for reproducibility;
7. sign the packages;
8. stage every affected architecture repository;
9. publish each database only after all package files it references are
   available.

The Flutter Engine binary is not rebuilt in this pipeline. Its checksum-pinned
runtime archive is emitted with the same tag-derived package version as the
rest of the release set.

Architecture lanes may be promoted independently. A routine x86_64 release
does not wait for an AArch64 builder unless the release explicitly changes a
cross-architecture compatibility contract.

### Emergency release

A security or ABI event may bypass the planned Flutter calendar, but not the
release gates. Produce a new Flutter generation, rebuild Denial, and promote
the compatible set atomically. Never silently replace an already published
`pkgver-pkgrel` file.

## Signing policy

Use one dedicated OpenPGP identity for Denial releases. Its primary
fingerprint remains the stable user-facing identity while signing subkeys can
be renewed or revoked:

- make the primary key certification-only;
- use a dedicated, expiring release-signing subkey;
- never commit private key material;
- give the GitHub `release-signing` environment only the secret-subkey export
  and its passphrase, never the primary secret key;
- keep an encrypted full recovery archive separately from its recovery
  passphrase, keep another offline copy, and verify it periodically;
- publish the public key and full fingerprint through multiple trusted
  channels;
- document key rotation and revocation;
- sign release tags, packages, repository databases, and checksum manifests.
  Stage 3 later adds signed source closures and SBOM material.

The public-alpha workflow builds unsigned packages on the owner-operated
runner, transfers them by digest, and signs them in the isolated hosted job.
Equivalent manual package signing is:

```sh
gpg --local-user "$KEY_FINGERPRINT" \
  --detach-sign denial-0.2.0-1-x86_64.pkg.tar.zst
```

Create and sign each architecture's database only after its package set is
complete:

```sh
repo-add \
  --sign \
  --key "$KEY_FINGERPRINT" \
  --include-sigs \
  --prevent-downgrade \
  public/x86_64/denial.db.tar.zst \
  'public/x86_64/denial-flutter-engine-1:0.2.1-1-x86_64.pkg.tar.zst' \
  public/x86_64/denial-0.2.1-1-x86_64.pkg.tar.zst \
  public/x86_64/denial-ui-development-0.2.1-1-x86_64.pkg.tar.zst
```

Stage 2 adds `denial-flutter-toolchain` to the same compatible set.

When updating an existing database, also pass `--verify`. Matching `.sig`
files beside packages allow `repo-add --include-sigs` to embed signatures in
the database metadata.

## Repository layout and publication

The public-alpha repository is one static HTTPS tree:

```text
public/
├── denial-repo-key.asc
├── install.sh
├── x86_64/
│   ├── denial.db
│   ├── denial.db.sig
│   ├── denial.db.tar.zst
│   ├── denial.db.tar.zst.sig
│   ├── denial.files
│   ├── denial.files.sig
│   ├── denial-flutter-engine-1:0.2.1-1-x86_64.pkg.tar.zst
│   ├── denial-0.2.1-1-x86_64.pkg.tar.zst
│   └── denial-ui-development-0.2.1-1-x86_64.pkg.tar.zst
```

Every package also has a detached `.sig`. The abbreviated tree omits those
repeated entries. The release job copies the repository-owned `install.sh`
from the exact tagged source, requires its embedded fingerprint to match the
active release key, and includes it in the signed `SHA256SUMS` manifest.
`install.denialwm.org` serves that file through the project-controlled
Cloudflare route. Stage 2 adds the toolchain package; AArch64 adds a sibling
directory only after its own build and hardware lane exists.

Package filenames are immutable. GitHub Releases retain the complete package
set and signed evidence for each tag. Pages presents the current Pacman view;
manual rollback can use an earlier release until automated rollback retention
is implemented.

Publication order is:

1. build a fresh staging tree;
2. copy all package files and detached signatures;
3. construct and sign databases from that exact staged set;
4. verify that every database entry resolves to an existing signed package;
5. upload the release assets to a draft GitHub Release;
6. deploy the complete tree as one Pages artifact;
7. publish the draft release only after Pages succeeds.

If atomic directory promotion is unavailable, upload immutable package files
first and repository databases last. Clients must never observe a database
that references a package which is not yet available.

GitHub Pages is sufficient at Denial's initial scale. The source repository
must be public before GitHub Free will serve it. Pages deployment
archives cannot contain symbolic or hard links, while `repo-add` commonly
creates aliases such as `denial.db` and `denial.files` as symlinks. Materialize
these aliases and their signatures as ordinary files before creating the
Pages artifact.

The first implementation replaces the whole current tree on every release.
Monitor the Pages site-size and bandwidth limits; migrate package storage if
real adoption approaches them.

## Client configuration

Users first obtain the public key and verify its complete fingerprint through
an independently published channel:

```sh
curl -O https://denialwm.github.io/denial/denial-repo-key.asc
gpg --show-keys --with-fingerprint denial-repo-key.asc
sudo pacman-key --add denial-repo-key.asc
sudo pacman-key --lsign-key AE4108FA5E91E26BE0EE331E0F5B3AD16E023091
```

They then add:

```ini
[denial]
SigLevel = Required TrustedOnly
Server = https://denialwm.github.io/denial/$arch
```

Installation and upgrades remain ordinary Pacman transactions:

```sh
sudo pacman -Syu denial
```

Pacman substitutes `$arch`; the public alpha currently serves only `x86_64`.
Do not instruct users to use `TrustAll`, `SigLevel = Optional`, or
`SigLevel = Never`.

A later `denial-keyring` bootstrap package may install the repository keyring,
trusted fingerprints, and revoked-key list. Its initial acquisition still
requires independent fingerprint verification.

## Relationship to the AUR and official Arch

The first-party repository is the primary release channel and is not blocked
on official Arch adoption. Its package name is simply `denial`, because users
receive an ordinary source-built binary package from Denial's signed
repository.

If a GitHub runtime archive or equivalent prebuilt artifact is offered through
the AUR, that recipe must be named `denial-bin`. A future AUR source recipe may
use `denial` and depend on the source-built Flutter-generation packages, but
it should be submitted only after the offline build is reliable for ordinary
users.

Official Arch currently targets x86-64. The first-party AArch64 package is
therefore maintained by Denial or an Arch Linux ARM-compatible downstream; it
is not a prerequisite for official Arch inclusion.

Official adoption remains a maintainer and project-maturity decision, not a
technical requirement for this design. The same source closures, PKGBUILDs,
reproducibility evidence, and fork provenance would make later adoption much
less burdensome.

## Current implementation gap

The repository has not yet implemented the complete production design:

- the complete source delta of the working prebuilt engine has been recovered,
  including `DenialFlutterEngineScheduleFrameForExternalTextures`, separated
  into logical commits, and published on the paired `denialwm/flutter` and
  `denialwm/skia` branches; the exact commits are locked directly and their
  promoted engine passes the x86_64 source build, engine unit tests, and
  real-hardware validation;
- the two Stage 1 PKGBUILDs are `x86_64`-only and package artifacts produced
  by the cache-backed prototype build rather than compiling their complete
  source closure inside `build()`;
- development builds still use VCS-derived package versions, while the
  public-alpha path accepts only a clean `vMAJOR.MINOR.PATCH` tag, derives all
  release versions from it, and fixes `pkgrel=1`;
- the project-level GPL-3.0-or-later grant now exists, while a generated
  third-party license inventory remains pending;
- the prototype `denial` package retains production symbols with
  `options=('!strip')`;
- `tools/denial-pc` hardcodes the x64 Flutter target, bundle path, ICU path,
  and ignored local engine staging path;
- the validated source-built engine still uses the legacy working-tree
  handoff under `prebuilt/flutter-engine/linux-x64-release/`;
- there is no `denial-flutter` split package base;
- there is no offline source-closure generator;
- Cargo and Pub inputs are not yet exported as release closures;
- the private disposable-key signing rehearsal passed;
- the permanent primary fingerprint is
  `AE4108FA5E91E26BE0EE331E0F5B3AD16E023091`; its encrypted full recovery
  archive and separate recovery values passed a fresh restore verification,
  and GitHub holds only the signing-subkey export in the `release-signing`
  environment;
- the permanent-key, signed-package, signed-database, GitHub Release, and
  Pages workflow is staged but cannot publish while the repository is private
  and no reviewed signed release tag exists;
- hardened atomic multi-architecture publication, offline closure, and
  independent reproduction remain unimplemented.

The `prebuilt/` handoff remains an ignored working-tree staging location for a
local engine rebuild. Tracked checksums and metadata identify the validated
reference build. CI instead supplies checksum-verified artifacts from the
revision-keyed builder cache through explicit package inputs. Retire the local
handoff after the Stage 2 toolchain/source packages build and package the
engine directly.

## Staged implementation plan

### Stage 1 — prototype build

Goal: prove on x86_64 that the fork-built Flutter Engine, Dart AOT bundle, Rust
compositor, and Pacman package split can be built and installed as one working
system.

The prototype may use the network, the existing Flutter checkout, and
pre-populated development caches. Its top-level Flutter and Rust revisions
remain pinned, but it makes no claim yet that all transitive inputs are
captured or that another machine can reproduce the result.

Completed checkpoint, 2026-07-25: items 1 through 9 are complete. The
published Flutter and Skia histories were reconstructed exactly, built through
all 3,893 engine actions, matched the former bootstrap engine's complete
dynamic export and ELF section tables, passed all 642 tests in the three
complete engine suites, and ran cleanly in Denial on dual-output x86_64 GPU
hardware. The
[validation report](../../flutter-engine/3.44.7/VALIDATION.md) records the
evidence and explains the source-built library's 29 differing bytes.
The [package validation report](VALIDATION.md) records the two-package build,
exact generation dependency, artifact identity, Pacman install/upgrade/remove
tests, and proof that a second Denial package release reused the unchanged
engine package. It also records the successful live login from `/usr/bin` and
`/usr/lib/denial`. Signed generation tags remain a provenance-hardening step
for the transition into Stage 2.

It was implemented and validated in this order:

1. Recover the complete engine delta from the known working local checkout,
   currently `/mnt/exty/denial-flutter-engine-3.44.7`.
2. Separate that delta into reviewable commits on the paired Flutter and Skia
   forks, including the custom external-texture scheduling API and its
   export-list change.
3. Pin both reviewed fork commits in `SOURCE_LOCK.json` and prove Flutter DEPS
   resolves the exact Skia fork commit.
4. Build the x86_64 engine from that locked source using the current online
   `gclient` workflow and persistent incremental caches.
5. Compare its symbols and behavior with the validated bootstrap reference;
   investigate any difference before using it as the prototype runtime.
6. Build the Dart shell bundle with the pinned Flutter SDK and build
   `deniald` from `compositor/Cargo.lock`.
7. Create minimal x86_64 packages for `denial-flutter-engine` and `denial`.
   Keep their file ownership and exact generation dependency compatible with
   the final model.
8. Install both with `pacman -U` in a disposable test system and test session
   startup, Flutter rendering, Wayland clients, upgrade, and removal.
9. Build a second Denial revision while reusing the same engine package, to
   prove that routine releases do not rebuild Flutter Engine.

Stage 1 explicitly excludes:

- public repository publication or user-facing release claims;
- a packaged immutable Flutter AOT toolchain;
- complete dependency closure and network-disabled builds;
- production signing, reproducibility, SBOM, and release-key operations;
- AArch64 packages.

Stage 1 passes when:

- the exact locked fork commits contain every required engine source change;
- the source-built engine provides all symbols Denial loads and renders the
  tested scene correctly;
- no undocumented working-tree delta is needed;
- the two packages install, run, upgrade, and uninstall locally;
- a routine Denial rebuild consumes the existing engine package.

Every condition above passed on 2026-07-25. Stage 1 artifacts remain local
prototype outputs and inherit all exclusions listed above.

A private CI rehearsal signed Stage 1 packages with an expiring key whose
identity explicitly says `NOT FOR PRODUCTION`, constructed signed Pacman
databases, independently verified them, and uploaded them as one-day
workflow artifacts. That result proves the mechanics only and is never a
user-facing release.

### Stage 1.5 — signed public alpha

Goal: make the validated x86-64 packages installable and updatable through
ordinary Pacman while describing the owner-operated build boundary precisely.

Denial 0.1.0 completed the initial publication path on 2026-07-26. The same
gates apply to every later release:

1. review a clean release commit and its resource, attribution, documentation,
   package, and workflow changes;
2. validate the exact commit through the unsigned `dev` candidate lane and
   promote it unchanged to `main`;
3. choose the version, then create and push a signed
   `vMAJOR.MINOR.PATCH` tag on that validated commit now contained in `main`;
4. manually run `.github/workflows/release.yml` for that tag;
5. verify the Pages repository and GitHub Release produced by the workflow;
6. install or upgrade through `pacman -Syu` on a real Arch system; and
7. retain the package, database, signature, checksum, and build evidence.

The workflow itself:

- rebuilds and tests only on the ephemeral owner-operated x86-64 runner;
- transfers unsigned packages and evidence to a GitHub-hosted signing job;
- signs exactly one `denial`, one compatible `denial-flutter-engine`, and,
  beginning with 0.2.0, one optional version-matched
  `denial-ui-development`;
- creates and verifies signed `denial.db` and `denial.files` databases;
- materializes every Pages alias as a regular file;
- re-verifies the complete signed tree in a job with no secret key;
- creates a draft GitHub prerelease, deploys the Pages artifact, and publishes
  the prerelease only after the deployment succeeds.

Stage 1.5 explicitly does not claim:

- a clean-chroot or network-disabled compilation;
- a complete immutable dependency closure;
- byte-for-byte package reproducibility;
- an independent build;
- generated SBOM or attestation coverage;
- AArch64 support.

Stage 1.5 passes for each release when a fresh or existing x86-64 Arch system
rejects altered content, accepts the published key and signed databases,
installs or upgrades `denial`, and launches a working session. Denial 0.2.0 is
also the first signed-upgrade and optional-development-package exercise. These
are release integrity and usability claims, not independent source-to-binary
proof.

### Stage 2 — pinned build

Goal: turn the working prototype into a repeatable, dependency-fixed build
that can be reviewed and exercised in clean infrastructure.

Implement it in this order:

1. Define the Flutter generation manifest and compatibility identifier.
2. Keep `SOURCE_LOCK.json`, Flutter DEPS, and the paired fork revisions
   mechanically checked for exact agreement.
3. Record every effective Flutter, engine, Dart, Skia, `depot_tools`, CIPD,
   Cargo, and Pub input by immutable revision or content hash.
4. Export or cache the exact locked Rust and Dart dependencies required by
   the build; eliminate floating resolution and undocumented ambient-cache
   dependencies.
5. Create the `denial-flutter` split PKGBUILD that produces
   `denial-flutter-engine` and `denial-flutter-toolchain`.
6. Make the Denial PKGBUILD consume the matching toolchain and engine
   generations, with literal release versions and explicit source checksums.
7. Build and test the packages in fresh clean chroots from empty caches.
   Network access may acquire declared sources, but compilation may not
   discover floating or undeclared inputs.
8. Audit package ownership, direct runtime dependencies, licenses, debug
   information, ELF architecture, RPATH, and uninstall behavior.
9. Exercise signed packages in a private `[denial-testing]` repository. A
   testing key is not the production release identity.

Stage 2 passes when:

- the manifest identifies all inputs that affect shipped artifacts;
- no dependency is selected by a moving branch, tag, URL, or unlocked solver;
- a manifest, source-lock, or checked-out revision mismatch fails the build;
- clean builders can repeatedly produce functional packages without relying
  on a developer's undocumented caches;
- install, upgrade, downgrade, and removal work through the testing
  repository.

### Stage 3 — hardened production build

Goal: close the remaining supply-chain and operational gaps once real use
justifies that engineering cost, without changing the user-facing repository.

Implement it in this order:

1. Add `tools/prepare-flutter-source-closure` and produce signed,
   content-addressed common and architecture-specific closures.
2. Build both PKGBUILDs in fresh chroots with networking disabled during
   `prepare()` and `build()`.
3. Run independent two-build reproducibility comparisons and investigate all
   unexplained differences.
4. Generate license inventories, SBOMs, build metadata, ABI checks, and
   matching debug information.
5. Complete real-hardware compositor validation for the architecture being
   promoted.
6. Rotate or harden the existing production signing identity as needed and
   complete fingerprint verification, rotation, and revocation exercises.
7. Sign closures, manifests, packages, and repository databases.
8. Implement staged verification, atomic publication, rollback retention, and
   recovery tests.
9. Promote x86_64 when its gate is complete. Start and promote AArch64 through
   the same three stages independently.

## Stage 3 hardening definition of done

An architecture is ready for hardened-release status when:

- both PKGBUILDs build for it in fresh chroots with networking disabled;
- all sources and tool inputs are immutable, hashed, and signed;
- no runtime binary is copied from a working-tree artifact staging directory;
- the Flutter and Skia checkouts exactly match the immutable commits and DEPS
  relationship recorded by the source lock;
- engine, toolchain, app, bindings, and manifests share one generation;
- its packages pass ELF and dependency checks;
- real hardware renders the Denial scene and Wayland clients on that target;
- two independent builds reproduce the published packages or have documented
  and understood differences;
- package and database signatures verify from a fresh Pacman root;
- a staged install, upgrade, downgrade, and removal all succeed;
- publication cannot expose a database before all referenced package files;
- the previous compatible release remains available for recovery.

The project may describe an architecture as a hardened, independently
reproducible release lane only after that architecture independently satisfies
this definition. Public-alpha architecture support remains governed by its
smaller contract above.

## References

- [Denial repository installation](INSTALL.md)
- [Denial release-signing operations](SIGNING.md)
- [Flutter source repository](https://github.com/flutter/flutter)
- [Compiling the Flutter engine](https://github.com/flutter/flutter/blob/master/docs/engine/contributing/Compiling-the-engine.md)
- [Flutter supported deployment platforms](https://docs.flutter.dev/reference/supported-platforms)
- [Creating Arch packages](https://wiki.archlinux.org/title/Creating_packages)
- [PKGBUILD manual](https://man.archlinux.org/man/PKGBUILD.5.en)
- [Clean-chroot builds](https://wiki.archlinux.org/title/DeveloperWiki:Building_in_a_clean_chroot)
- [Reproducible builds](https://wiki.archlinux.org/title/Reproducible_builds)
- [makepkg manual](https://man.archlinux.org/man/makepkg.8)
- [pkgctl build manual](https://man.archlinux.org/man/pkgctl-build.1)
- [makerepropkg manual](https://man.archlinux.org/man/makerepropkg.1.en)
- [repo-add manual](https://man.archlinux.org/man/repo-add.8)
- [pacman.conf manual](https://man.archlinux.org/man/pacman.conf.5.en)
- [GitHub Pages custom workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
- [GitHub deployment environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
