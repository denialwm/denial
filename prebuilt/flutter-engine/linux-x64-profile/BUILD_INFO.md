# Flutter Engine — Linux x64 profile

`libflutter_engine.so` is Denial's optimized AOT profiling engine. It retains
the authenticated loopback VM service required by Flutter DevTools without
using a debug or JIT runtime.

## Source identity

The authoritative source input is
[`SOURCE_LOCK.json`](../SOURCE_LOCK.json). Generated `args.gn` and the adjacent
revision files record the derived build and ABI identities without duplicating
mutable lock values in this document.

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
  --enable-fontconfig \
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

Linux builds enable Flutter's Fontconfig backend. The shipped engine therefore
requires `libfontconfig.so.1` and discovers fonts through the host's Fontconfig
configuration instead of assuming they live below `/usr/share/fonts`.

## Licensing

Flutter Engine is BSD 3-Clause. The coupled Flutter and third-party licenses
are recorded in `../linux-x64-release/` and included by the development
package.
