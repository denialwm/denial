A Flutter-native Wayland compositor.

Denial begins with a belief: origin does not have to dictate purpose.

Flutter was created to build application interfaces. Here, it is given a
different life. It owns the desktop scene itself: the shell, its motion, and
the composition of Wayland applications. Flutter is not an overlay placed on
top of another compositor. It is part of the compositor's foundation.

That is the architecture. It is also the meaning of the name.

## Repository workflow

Trusted development lands on `dev` first. Arm the ephemeral builder before
pushing so `.github/workflows/branch-validation.yml` can build, package, and
independently verify that exact commit. Do not repair pipeline failures
directly on `main`; fix and prove them on `dev`, then promote the green commit
to `main` through a pull request. Signed public releases remain restricted to
separately signed version tags. The verified `vMAJOR.MINOR.PATCH` tag is the
sole source of every release package version and filename; Flutter generation
identifiers remain compatibility metadata, not release names.

## Graphical session control

Never log out, terminate, restart, or otherwise stop the user's graphical
session on the user's behalf. In particular, do not terminate a login session,
stop its user-session targets, kill the compositor to force an exit, reboot, or
power off the machine. When testing requires a fresh Denial session, tell the
user that a restart is required and wait for the user to log off and return to
SDDM themselves. Continue only after the user confirms that they have logged
back in. Perform session-control actions only when the user explicitly asks
for that exact action.

## Why Denial

**Denial** is an English word. The name contains **Denia**, followed by one
last letter.

It is a quiet reference to Denia from *Wuthering Waves*. Her story never gives
a simple answer to what she originally was, and that uncertainty is important.
What is clear is that others treated her as an asset: something selected,
shaped, and assigned a purpose that was not her own. She was meant to remain a
vessel. Instead, by observing people and learning to live among them, she grew
a heart and gained the ability to choose what she would become.

# PC development build

Denial builds two versioned parts: the Rust compositor in `compositor/` and
the embedded Flutter shell bundle in `dart_shell/`. `tools/denial-pc` keeps
downloaded toolchains and native build output outside the checkout by default.

All `tools/denial-pc` commands must run outside the sandbox as required by
`AGENTS.md`.

Bootstrap the pinned official Flutter SDK and Rust dependencies:

```sh
tools/denial-pc bootstrap
```

Then inspect prerequisites, build and test:

```sh
tools/denial-pc doctor
tools/denial-pc build
tools/denial-pc test
```

The compositor binary is written to
`$XDG_CACHE_HOME/denial/pc-build/rust/release/deniald` by default. The Flutter
bundle is written to `dart_shell/build/linux/x64/release/bundle`.
`tools/denial-pc` builds its AOT assets directly with the official Flutter
tool and packages the locally rebuilt raw embedder library; normal builds do
not use a third-party platform runner or a C++ Linux runner.

The bootstrap pins Flutter `3.44.7` at
`84fc5cbb223bc12f83d65b647ff8a56caf779ffd`, coupled to Dart `3.12.2` and
engine artifact `69c8c61792f04cc809dfef0c910414fb9afc06cd`. Cargo resolves the
exact crate and Smithay revisions in `compositor/Cargo.lock`. The pinned
upstream-derived `libflutter_engine.so` is generated locally and ignored by
Git. Its expected checksum, source/build metadata, and licenses live in
`prebuilt/flutter-engine/linux-x64-release/`. Rebuild it using that
directory's `BUILD_INFO.md` before creating a bundle. It applies the versioned
engine series in `patches/flutter-engine/3.44.7/`: six coupled OpenGL
stencil/dynamic-MSAA correctness patches, one rotating-atlas surface-cache
fix, and four autonomous-texture damage, raster, and scheduling fixes. The
separate, compatible SDK series in
`patches/flutter/` remains part of bootstrap: it raises touch resampling from
60 Hz to 120 Hz and permits explicit VM-service attachment to Denial's raw
embedder project without a generated platform runner.

Denial-owned Flutter and Skia commits and mail patches use
`Doctor Logix <doctor.logix@gmail.com>`. Set that identity locally in source
forks and temporary repositories; never rely on the host's global Git config.
The release source audit enforces the committed patch headers.

For direct engine builds, put `flutter/third_party/depot_tools` on `PATH` for
`vpython3`, but invoke `/usr/bin/ninja` explicitly to bypass its Python wrapper.

The Flutter embedder ABI is committed as generated Rust in
`compositor/flutter-engine/src/sys.rs`, stamped with the coupled revisions from
`prebuilt/flutter-engine/linux-x64-release/{ENGINE_REVISION,FLUTTER_REVISION}`.

Normal builds do not run `bindgen` and do not require Clang/libclang. During a
controlled Flutter engine upgrade, regenerate the committed ABI bindings with:

```sh
tools/generate-flutter-embedder-bindings
tools/generate-flutter-embedder-bindings --check
```

The generator downloads `embedder.h` from the pinned official Flutter
monorepo commit, runs the separately locked binding tool, and records both
revisions plus the source header's SHA-256 in `sys.rs`. Set
`DENIAL_FLUTTER_EMBEDDER_HEADER` to use an explicit local header instead.

For separate caches, set `DENIAL_PC_DEPENDENCY_ROOT`,
`DENIAL_PC_BUILD_ROOT`, or `DENIAL_PC_RUST_TARGET`. A first bootstrap requires
network access; subsequent builds reuse the cache.

The host needs a Rust toolchain compatible with the repository-level
`rust-toolchain.toml`,
`pkg-config`, Xwayland, and the development libraries required by Smithay's
DRM, GBM/EGL, libinput, libseat and udev backends. Only binding regeneration
needs Clang/libclang.

Install or remove the local SDDM entry with:

```sh
tools/denial-pc install-session
tools/denial-pc remove-session
```
