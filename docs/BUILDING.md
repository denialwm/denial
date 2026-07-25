# Building Denial

Denial currently supports an x86-64 PC development build. It builds two
versioned components:

- the Rust compositor in `compositor/`;
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
- the framework patch in `patches/flutter/`;
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

- the Rust toolchain selected by `compositor/rust-toolchain.toml`;
- `pkg-config`;
- Xwayland;
- the development libraries used by Smithay's DRM, GBM/EGL, libinput,
  libseat, udev, and libxkbcommon backends.

Only binding regeneration needs Clang and libclang. Run
`tools/denial-pc doctor` for the authoritative check on the current host.

## Local Arch package prototype

Build the two local Stage 1 packages with:

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
push to `main` can build and independently verify an unsigned production
candidate when the ephemeral runner is armed. The first public alpha remains
gated on public repository controls, Pages enablement, and a signed version
tag. Stage 2 later adds offline input closure. See the
[main validation boundary](packaging/arch/MAIN_VALIDATION.md).

## Local session

Install or remove the development SDDM entry with:

```sh
tools/denial-pc install-session
tools/denial-pc remove-session
```

The packaged session is separate from this development entry. Do not replace
or restart a running compositor implicitly; activate a newly built session
only at an explicit test checkpoint.
