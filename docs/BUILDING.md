# Building Denial

Denial currently supports an x86-64 PC development build. It builds two
versioned components:

- the Rust compositor and native control client in `compositor/`;
- the embedded Flutter shell bundle in `dart_shell/`.

Downloaded toolchains and native build output live outside the checkout by
default. A first bootstrap needs network access; later development builds
reuse the pinned cache.

## Quick start

Bootstrap the pinned Flutter SDK and Rust dependencies:

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

Set `DENIAL_PC_DEPENDENCY_ROOT`, `DENIAL_PC_BUILD_ROOT`, or
`DENIAL_PC_RUST_TARGET` to place the corresponding caches elsewhere.

## Pinned Flutter generation

The current development generation couples:

- Flutter `3.44.7`;
- Flutter revision `84fc5cbb223bc12f83d65b647ff8a56caf779ffd`;
- Dart `3.12.2`;
- engine artifact revision `69c8c61792f04cc809dfef0c910414fb9afc06cd`;
- the ordered engine series in `patches/flutter-engine/3.44.7/`;
- the ordered framework and Flutter-tool patches in `patches/flutter/`;
- the generated Rust embedder ABI in
  `compositor/flutter-engine/src/sys.rs`.

Normal builds consume a locally rebuilt engine staged as
`prebuilt/flutter-engine/linux-x64-release/libflutter_engine.so`. The library
is ignored by Git; its expected checksum, source revisions, build arguments,
licenses, and rebuild instructions remain tracked beside it in
[`BUILD_INFO.md`](../prebuilt/flutter-engine/linux-x64-release/BUILD_INFO.md).
Routine Dart and Rust builds do not rebuild the engine or run `bindgen`.
Set `DENIAL_PC_ENGINE_SOURCE` to consume the same checksum-pinned engine from
an explicit external path, as the ephemeral release builder does. Arch
packaging uses the verified copy in the assembled bundle, so the engine
package and Denial package always derive from the same checked input.

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
- Xwayland;
- the development libraries used by Smithay's DRM, GBM/EGL, libinput,
  libseat, udev, and libxkbcommon backends.

Only binding regeneration needs Clang and libclang. Run
`tools/denial-pc doctor` for the authoritative check on the current host.

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
unsigned candidate when the ephemeral runner is armed. `dev` uses package
release `0`; clean signed version tags use the separate signing and Pages
publication path. Stage 2 later adds offline input closure. See the
[branch validation boundary](packaging/arch/BRANCH_VALIDATION.md).

Live Flutter UI editing is deliberately split into a third, optional package.
After the pinned debug engine described in
[`BUILD_INFO.md`](../prebuilt/flutter-engine/linux-x64-debug/BUILD_INFO.md) has
been rebuilt and staged, create and validate it with the repository's Rust
task:

```sh
cargo xtask ui-development-package
```

The resulting `denial-ui-development` archive is written beside the two
required packages. It contains the coupled, native-optimized JIT engine, the
curated Dart and Flutter runtime needed for shell assembly and editor attach,
locked dependency sources needed by Denial's shell, a version-matched editable
source snapshot and revision metadata, and the native `denial-ui` client. Its
isolated validation prepares the real packaged shell with networking disabled.
An engine binary change requires one Denial session restart; normal Dart hot
reload does not.
The validator reports the compressed and installed sizes and enforces explicit
budgets so accidental package growth fails before publication. See
[Live Flutter UI development](UI_DEVELOPMENT.md).

## Local session

Install or remove the development SDDM entry with:

```sh
tools/denial-pc install-session
tools/denial-pc remove-session
```

The packaged session is separate from this development entry. Do not replace
or restart a running compositor implicitly; activate a newly built session
only at an explicit test checkpoint.
