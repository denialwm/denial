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
  `af53fe6dc91e13ea1d2da9103d7d88fc202dd052`
- Denial Skia fork:
  `5097a648e9bbb1d4a7fdf06a2a6d7bef3c9dd414`
- Upstream Flutter compatibility base:
  `84fc5cbb223bc12f83d65b647ff8a56caf779ffd` (Flutter `3.44.7`)
- Engine artifact revision:
  `69c8c61792f04cc809dfef0c910414fb9afc06cd`
- Engine content hash:
  `f4cde4ea83f811f4031367a0ee30332f3ec1b53a`
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
