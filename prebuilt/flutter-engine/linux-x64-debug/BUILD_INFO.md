# Flutter Engine — Linux x64 debug/JIT

`libflutter_engine.so` is the pinned debug/JIT counterpart to Denial's release
Flutter Embedder library. It exists specifically for live shell development:
the compositor loads this engine together with a Dart kernel bundle, exposes
the authenticated VM service only on loopback, and can then be attached to by
Flutter tooling.

The generated library is ignored by Git. This directory records the exact
source identity, build configuration, expected checksum, and rebuild recipe
used by the `denial-ui-development` package.

- Flutter: `3.44.7`
- Flutter source revision: `84fc5cbb223bc12f83d65b647ff8a56caf779ffd`
  (see `FLUTTER_REVISION`)
- Coupled engine artifact revision:
  `69c8c61792f04cc809dfef0c910414fb9afc06cd` (see `ENGINE_REVISION`)
- Engine content hash: `7076f47b1d1a3a0edfd8837b17dc15be6abab661`
- Dart source revision: `d684a576a6aa954ae107a03b2b4e1d61c3bebe93`
  (Dart SDK `3.12.2`)
- Skia base revision: `e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465`
- Public Flutter review branch:
  [`denialwm/flutter@5498828ee023a05ae2c6677a1dee3eae7007eebc`](https://github.com/denialwm/flutter/commit/5498828ee023a05ae2c6677a1dee3eae7007eebc)
- Public Skia review branch:
  [`denialwm/skia@5097a648e9bbb1d4a7fdf06a2a6d7bef3c9dd414`](https://github.com/denialwm/skia/commit/5097a648e9bbb1d4a7fdf06a2a6d7bef3c9dd414)
- Engine patches: the ordered release series under
  `patches/flutter-engine/3.44.7/`
- Runtime mode: Flutter `debug`, Dart `develop`
- Native optimization: enabled (`is_debug = false`, LTO enabled)
- Target: Linux x86-64
- GN configuration: `args.gn`, copied verbatim from the build output
- Integrity: `libflutter_engine.so.sha256`

The reference binary was built in an isolated source view whose modified
Flutter and Skia files match the two public review commits above. It exports
both Flutter's standard embedder proc table and Denial's versioned external
texture scheduling extension.

## Rebuild

Start from a clean gclient checkout coupled to `FLUTTER_REVISION`, apply the
ordered engine patch series, and build from the engine source root:

```sh
cd /path/to/flutter-gclient-root
for patch_file in <repo>/patches/flutter-engine/3.44.7/*.patch; do
  git apply --check "$patch_file"
  git apply "$patch_file"
done
cd engine/src
./flutter/tools/gn \
  --runtime-mode=debug \
  --target-dir=denial_host_debug
/usr/bin/ninja -C out/denial_host_debug -j 32 libflutter_engine.so
```

The generated `out/denial_host_debug/args.gn` must match the tracked
`args.gn`. Flutter's `debug` runtime mode selects the JIT-capable Dart
`develop` runtime; it does not require an unoptimized native engine. In
particular, verify `is_debug = false`, `enable_lto = true`,
`flutter_runtime_mode = "debug"`, and `dart_runtime_mode = "develop"`.
Verify that `FlutterEngineRunsAOTCompiledDartCode()` returns false and that
`FlutterEngineGetProcAddresses`,
`FlutterEngineRunsAOTCompiledDartCode`, and
`DenialFlutterEngineScheduleFrameForExternalTextures` are exported. Copy the
library to this directory and run:

```sh
sha256sum --check --strict libflutter_engine.so.sha256
```

Do not update the reference checksum for an unexplained mismatch. Flutter,
Dart, engine, Skia, framework patch, and embedder revisions are a coupled
toolchain and must be upgraded together.

## Licensing

Flutter Engine is BSD 3-Clause and its bundled third-party components retain
their respective licenses. The development package ships the same
`LICENSE.flutter` and `LICENSE.third_party` material recorded for Denial's
release engine, together with the pinned Dart SDK license.
