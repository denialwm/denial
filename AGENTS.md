A Flutter-native Wayland compositor.

Denial begins with a belief: origin does not have to dictate purpose.

Flutter was created to build application interfaces. Here, it is given a
different life. It owns the desktop scene itself: the shell, its motion, and
the composition of Wayland applications. Flutter is not an overlay placed on
top of another compositor. It is part of the compositor's foundation.

That is the architecture. It is also the meaning of the name.

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
bundle remains at the legacy-compatible
`dart_shell/build/elinux/x64/release/bundle` path. `tools/denial-pc` builds its
AOT assets directly with the official Flutter tool and packages the committed
raw embedder library; normal builds do not use `flutter-elinux` or a C++ Linux
runner.

The bootstrap pins Flutter `3.44.7` at
`84fc5cbb223bc12f83d65b647ff8a56caf779ffd`, coupled to Dart `3.12.2` and
engine artifact `69c8c61792f04cc809dfef0c910414fb9afc06cd`. Cargo resolves the
exact crate and Smithay revisions in `compositor/Cargo.lock`. The clean
upstream release `libflutter_engine.so`, its checksum, source/build metadata,
and licenses live in `prebuilt/flutter-engine/elinux-x64-release/`. The current
engine baseline applies none of the historical patches in
`patches/flutter-engine/`; those remain available for measured, selective
porting if the upstream baseline regresses performance. The separate,
compatible Flutter framework patch in `patches/flutter/` remains part of SDK
bootstrap and raises touch resampling from 60 Hz to 120 Hz.

The Flutter embedder ABI is committed as generated Rust in
`compositor/flutter-engine/src/sys.rs`, stamped with the coupled revisions from
`prebuilt/flutter-engine/elinux-x64-release/{ENGINE_REVISION,FLUTTER_REVISION}`.

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

The host needs a Rust toolchain compatible with `compositor/rust-toolchain.toml`,
`pkg-config`, Xwayland, and the development libraries required by Smithay's
DRM, GBM/EGL, libinput, libseat and udev backends. Only binding regeneration
needs Clang/libclang.

Install or remove the local SDDM entry with:

```sh
tools/denial-pc install-session
tools/denial-pc remove-session
```
