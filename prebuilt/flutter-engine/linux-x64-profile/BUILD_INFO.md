# Flutter Engine — Linux x64 profile

`libflutter_engine.so` is Denial's pinned raw Flutter Embedder library for
Flutter's standard performance-profiling mode. It runs an optimized AOT
application while retaining the authenticated loopback Dart VM service used
by Flutter DevTools. It is not a JIT or checked-mode runtime.

- Flutter: `3.44.7`
- Flutter source revision:
  `84fc5cbb223bc12f83d65b647ff8a56caf779ffd`
- Coupled engine artifact revision:
  `69c8c61792f04cc809dfef0c910414fb9afc06cd`
- Dart: `3.12.2`
- Dart source revision:
  `d684a576a6aa954ae107a03b2b4e1d61c3bebe93`
- Skia revision: `e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465`
- Engine patches: `patches/flutter-engine/3.44.7/`
- Runtime mode: Flutter `profile`, Dart `profile`
- Native optimization: enabled (`is_debug = false`, LTO enabled)
- Target: Linux x86-64

The current profile artifact includes patch 0007's rotating-atlas surface
cache. Its 144 Hz NVIDIA timing comparison, driver trace, unit-test results,
and coupled release artifact are recorded in
`patches/flutter-engine/3.44.7/VALIDATION.md`.

## Rebuild

Start from the same clean, pinned gclient checkout used for Denial's release
engine, apply the ordered engine patch series, and build from `engine/src`:

```sh
./flutter/tools/gn \
  --runtime-mode=profile \
  --target-dir=denial_host_profile
/usr/bin/ninja -C out/denial_host_profile -j 16 libflutter_engine.so
```

The generated `args.gn` must match this directory's tracked copy. Verify that
the library reports AOT mode and exports
`FlutterEngineGetProcAddresses`,
`FlutterEngineRunsAOTCompiledDartCode`, and
`DenialFlutterEngineScheduleFrameForExternalTextures`. Then verify its
recorded SHA-256 before packaging it.

## Licensing

Flutter Engine is BSD 3-Clause. The coupled Flutter and third-party license
texts are tracked in `../linux-x64-release/` and are included by the
development package that ships this profiling engine.
