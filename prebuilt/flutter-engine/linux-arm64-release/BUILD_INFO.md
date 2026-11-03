# Flutter Engine — Linux arm64 release

`libflutter_engine.so` is Denial's raw Flutter Embedder library for 64-bit
ARM Linux, cross-built on an x86-64 builder from the same locked sources as
the [x64 release](../linux-x64-release/BUILD_INFO.md). The generated library
is ignored by Git; this directory tracks its expected checksum and GN
configuration. The upstream revisions and licenses are the x64 release's.

The builder compiles it with Flutter's own clang and arm64 Debian sysroot:

```sh
DENIAL_TARGET_ARCH=aarch64 tools/denial-flutter-engine build
```

Its output directory is `out/denial_linux_arm64_release`, beside the x64
`out/denial_host_release` whose Dart and asset compilers build the
applications. Release builds of the applications compile their AOT code with
that directory's `clang_x64/gen_snapshot`; the plugin build kit ships its
arm64 `gen_snapshot`, `impellerc` and `font-subset`.
