# Flutter Engine — Linux x64 profile

`libflutter_engine.so` is Denial's optimized AOT profiling engine. It retains
the authenticated loopback VM service required by Flutter DevTools without
using a debug or JIT runtime.

## Source identity

The authoritative source input is
[`SOURCE_LOCK.json`](../SOURCE_LOCK.json):

- Denial Flutter fork:
  `38724af712979f95c4fdc264148fa032e8ca223f`
- Denial Skia fork:
  `0ee042f542b3e79f5ac49115387718c6bb3d7d34`
- Upstream Flutter compatibility base:
  `84fc5cbb223bc12f83d65b647ff8a56caf779ffd` (Flutter `3.44.7`)
- Engine artifact revision:
  `69c8c61792f04cc809dfef0c910414fb9afc06cd`
- Dart: `3.12.2`

All Denial changes are normal fork commits. The relevant performance and
hardware results are retained in the
[engine validation report](../../../docs/flutter-engine/3.44.7/VALIDATION.md).

## Build

Use the revision-keyed incremental builder:

```sh
tools/denial-flutter-engine build
```

The equivalent direct engine commands are:

```sh
./flutter/tools/gn \
  --runtime-mode=profile \
  --target-dir=denial_host_profile
/usr/bin/ninja -C out/denial_host_profile libflutter_engine.so
```

Generated arguments must match `args.gn`; the result must match
`libflutter_engine.so.sha256`, report AOT mode, and export
`FlutterEngineGetProcAddresses`, `FlutterEngineRunsAOTCompiledDartCode`, and
`DenialFlutterEngineScheduleFrameForExternalTextures`.
Before checksum verification, the builder canonicalizes the stripped
library's GNU build ID from the shipped ELF content. Full-file SHA-256
verification therefore remains exact across independent build paths.

## Licensing

Flutter Engine is BSD 3-Clause. The coupled Flutter and third-party licenses
are recorded in `../linux-x64-release/` and included by the development
package.
