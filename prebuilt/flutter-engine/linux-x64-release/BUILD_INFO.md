# Flutter Engine — Linux x64 release

`libflutter_engine.so` is Denial's optimized raw Flutter Embedder library. The
official Linux artifact is a GTK embedding library, so Denial builds and
packages this raw AOT embedder target directly.

The generated library is ignored by Git. This directory tracks its expected
checksum, GN configuration, upstream compatibility revisions, and licenses.

## Source identity

[`SOURCE_LOCK.json`](../SOURCE_LOCK.json) is the sole source-of-truth for
the engine source of CI and release builds. The generated `args.gn` records the corresponding Flutter,
Skia, Dart and content identities; `ENGINE_REVISION` and `FLUTTER_REVISION`
record the coupled upstream ABI revisions without duplicating mutable lock
values in this document.

The Flutter fork’s DEPS file pins the Skia fork commit. Engine, framework, and
Flutter-tool changes all live as normal commits in those forks; the Denial
repository does not carry or reconstruct a downstream patch series.

## Build and cache behavior

During development, `tools/denial-pc build` builds this engine from the local
fork trees as they are on disk, uncommitted changes included, and records its
checksum in `libflutter_engine.so.local.sha256`
([Building with your local engine](../../../docs/BUILDING.md#building-with-your-local-engine)).

CI and release builds use the locked engine:

```sh
tools/denial-flutter-engine build
```

The tool hashes the complete source lock, the release mode's `args.gn`, and its
expected artifact checksum. A valid exact hit performs no source
synchronization, configuration, compilation, or linking. On a miss, it updates
one persistent fork checkout and retains `out/denial_host_release`, so GN and
Ninja perform an incremental rebuild rather than recreating the engine.
Flutter derives `concurrent_toolchain_jobs` from host capacity; the builder
normalizes only that field to the committed value and regenerates the graph
before comparing the complete arguments, keeping x86-64 builders identical.
After Flutter strips each library, the builder canonicalizes its GNU build ID
to the SHA-1 of the shipped ELF with that note zeroed. This removes build-ID
drift caused solely by discarded debug metadata while preserving a
content-derived identifier and the strict full-file SHA-256 gate.

Debug and profile engines are excluded from routine builds. They are available
only through the explicit `DENIAL_FLUTTER_ENGINE_DEVELOPMENT_MODES=1`
development path.

The equivalent direct release commands are:

```sh
./flutter/tools/gn \
  --runtime-mode=release \
  --enable-fontconfig \
  --target-dir=denial_host_release
/usr/bin/ninja -C out/denial_host_release libflutter_engine.so
```

Generated arguments must match `args.gn`, and the output must match
`libflutter_engine.so.sha256`. It must export
`FlutterEngineGetProcAddresses`,
`DenialFlutterEngineRequestFrameForExternalTextures`, and
`DenialFlutterEngineScheduleFrameForExternalTextures`.

Linux builds enable Flutter's Fontconfig backend. The shipped engine therefore
requires `libfontconfig.so.1` and discovers fonts through the host's Fontconfig
configuration instead of assuming they live below `/usr/share/fonts`.

The standard Rust ABI remains generated from the pristine official embedder
header at the upstream compatibility revision:

```sh
tools/generate-flutter-embedder-bindings
tools/generate-flutter-embedder-bindings --check
```

Denial's versioned extension is loaded and typed separately in
`compositor/flutter-engine/src/lib.rs`.

## Licensing

Flutter Engine is BSD 3-Clause; binary redistribution is permitted.
`LICENSE.flutter` is the Flutter license and `LICENSE.third_party` is the
cumulative third-party license material. Ship both with every engine package.
