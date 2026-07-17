# PC development build

Denial keeps project-owned source in the repository and reproducible changes
to external dependencies in `patches/`. Pinned Aquamarine,
`hyprland-protocols`, `udis86`, `flutter-elinux`, and Flutter SDK checkouts live
outside the repository, by default below
`$XDG_CACHE_HOME/denial/pc-dependencies/` (or `$HOME/.cache` when
`XDG_CACHE_HOME` is unset).

Bootstrap the exact revisions and apply Denial's patches once:

```sh
tools/denial-pc bootstrap
```

Then inspect the local prerequisites and build:

```sh
tools/denial-pc doctor
tools/denial-pc build
```

The bootstrap pins Aquamarine `06669631175b4db2383b94e7f8c13f45a9d28757`,
`hyprland-protocols` `3a5c2bda1c1a4e55cc1330c782547695a93f05b2`,
`udis86` `5336633af70f3917760a6d441ff02d93477b0c86`,
`flutter-elinux` `d13ebc3c7b4dca316073b5755823c0252b4895cc`,
and Flutter `17025dd88227cd9532c33fa78f5250d548d87e9a`. Builds reject other revisions
and unexpected tracked changes so an accidental local dependency edit cannot
silently become part of Denial.

Native build output lives outside the checkout, by default below
`$XDG_CACHE_HOME/denial/pc-build/`. The Flutter application bundle remains in
`dart_shell/build/`, as required by the Flutter tool. Its eLinux project is an
architecture-neutral bundle manifest; Denial does not build or install a
second runner or embedder library. `tools/denial-pc` requests x64 artifacts for
the PC compositor, while device builds select the matching Flutter engine
architecture. A first bootstrap and build require network access; subsequent
builds reuse the cache.
The host still needs CMake, Ninja, a C/C++ toolchain, `pkg-config`, and the
development libraries required by the compositor and its integrated Flutter
embedder.

For an intentionally separate dependency cache, set
`DENIAL_PC_DEPENDENCY_ROOT` before invoking the tool. The lower-level
`DENIAL_AQUAMARINE_SOURCE` and `DENIAL_FLUTTER_ELINUX` overrides remain
available for controlled experiments, but the same pinned revisions and patch
checks still apply. Set `DENIAL_PC_BUILD_ROOT` to relocate native build output.
