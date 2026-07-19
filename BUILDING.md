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

The real session owns DRM and must be started from the login manager or an
otherwise inactive text VT. `Ctrl+Alt+Backspace` is the compositor-level
graceful escape path.
