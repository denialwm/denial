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

Bootstrap the pinned Flutter eLinux/SDK revisions and Rust dependencies:

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
bundle remains at `dart_shell/build/elinux/x64/release/bundle`, as required by
the Flutter eLinux tool.

The bootstrap pins flutter-elinux
`d13ebc3c7b4dca316073b5755823c0252b4895cc` and Flutter SDK
`17025dd88227cd9532c33fa78f5250d548d87e9a`. Cargo resolves the exact crate and
Smithay revisions in `compositor/Cargo.lock`. The Flutter embedder ABI header
used by `bindgen` is retained under `third_party/flutter_embedder/`.

For separate caches, set `DENIAL_PC_DEPENDENCY_ROOT`,
`DENIAL_PC_BUILD_ROOT`, or `DENIAL_PC_RUST_TARGET`. A first bootstrap requires
network access; subsequent builds reuse the cache.

The host needs a Rust toolchain compatible with `compositor/rust-toolchain.toml`,
Clang/libclang for `bindgen`, `pkg-config`, Xwayland, and the development
libraries required by Smithay's DRM, GBM/EGL, libinput, libseat and udev
backends.

Install or remove the local SDDM entry with:

```sh
tools/denial-pc install-session
tools/denial-pc remove-session
```