# Flutter Engine — Linux x64 release

`libflutter_engine.so` is Denial's optimized raw Flutter Embedder library. The
official Linux artifact is a GTK embedding library, so Denial builds and
packages this raw AOT embedder target directly.

The generated library is ignored by Git. This directory tracks its expected
checksum, GN configuration, upstream compatibility revisions, and licenses.

## Source identity

[`SOURCE_LOCK.json`](../SOURCE_LOCK.json) is the sole source-of-truth for
engine source:

- Denial Flutter fork:
  `38724af712979f95c4fdc264148fa032e8ca223f`
- Denial Skia fork:
  `0ee042f542b3e79f5ac49115387718c6bb3d7d34`
- Upstream Flutter compatibility base:
  `84fc5cbb223bc12f83d65b647ff8a56caf779ffd` (Flutter `3.44.7`)
- Engine artifact revision:
  `69c8c61792f04cc809dfef0c910414fb9afc06cd`
- Engine content hash:
  `66c98ad6cba21e2c9b2062123a41d5a8edb2fe70`
- Dart:
  `d684a576a6aa954ae107a03b2b4e1d61c3bebe93` (Dart SDK `3.12.2`)

The Flutter fork’s DEPS file pins the Skia fork commit. Engine, framework, and
Flutter-tool changes all live as normal commits in those forks; the Denial
repository does not carry or reconstruct a downstream patch series.

## Build and cache behavior

Use:

```sh
tools/denial-flutter-engine build
```

The tool hashes the complete source lock, every mode’s `args.gn`, and expected
artifact checksum. A valid exact hit performs no source synchronization,
configuration, compilation, or linking. On a miss, it updates one persistent
fork checkout and retains `out/denial_host_{release,debug,profile}`, so GN and
Ninja perform an incremental rebuild rather than recreating the engine.
Flutter derives `concurrent_toolchain_jobs` from host capacity; the builder
normalizes only that field to the committed value and regenerates the graph
before comparing the complete arguments, keeping x86-64 builders identical.
After Flutter strips each library, the builder canonicalizes its GNU build ID
to the SHA-1 of the shipped ELF with that note zeroed. This removes build-ID
drift caused solely by discarded debug metadata while preserving a
content-derived identifier and the strict full-file SHA-256 gate.

The equivalent direct release commands are:

```sh
./flutter/tools/gn \
  --runtime-mode=release \
  --target-dir=denial_host_release
/usr/bin/ninja -C out/denial_host_release libflutter_engine.so
```

Generated arguments must match `args.gn`, and the output must match
`libflutter_engine.so.sha256`. It must export
`FlutterEngineGetProcAddresses` and
`DenialFlutterEngineScheduleFrameForExternalTextures`.

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
