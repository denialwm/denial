# Flutter Engine — Linux x64 debug/JIT

`libflutter_engine.so` is the JIT-capable engine used by
`denial-ui-development` for live shell development, hot reload, the Flutter
Inspector, and an authenticated loopback VM service. Native engine code
remains optimized; only the Dart runtime mode is `develop`.

## Source identity

The authoritative source input is
[`SOURCE_LOCK.json`](../SOURCE_LOCK.json):

- Denial Flutter fork:
  `ce225d5bd9c635ce8cf233f6f3a0877f27a98254`
- Denial Skia fork:
  `0ee042f542b3e79f5ac49115387718c6bb3d7d34`
- Upstream Flutter compatibility base:
  `84fc5cbb223bc12f83d65b647ff8a56caf779ffd` (Flutter `3.44.7`)
- Engine artifact revision:
  `69c8c61792f04cc809dfef0c910414fb9afc06cd`
- Dart: `3.12.2`

All Denial changes are commits in the two forks. No downstream patch series is
applied during bootstrap or engine builds.

## Build

The canonical incremental builder is:

```sh
tools/denial-flutter-engine build
```

It checks out the exact locked commits, verifies that Flutter DEPS resolves the
locked Skia fork, compares generated GN arguments with `args.gn`, and verifies
the resulting library against `libflutter_engine.so.sha256`. Exact cache hits
skip synchronization, GN, Ninja, and linking. Source changes retain
`out/denial_host_debug`, allowing Ninja to rebuild only invalidated targets.
The builder canonicalizes the stripped library's GNU build ID from its shipped
content before applying the strict SHA-256 check, so discarded debug metadata
cannot make otherwise identical artifacts differ between build paths.

The equivalent direct engine commands are:

```sh
./flutter/tools/gn \
  --runtime-mode=debug \
  --enable-fontconfig \
  --target-dir=denial_host_debug
/usr/bin/ninja -C out/denial_host_debug libflutter_engine.so
```

The engine must report JIT mode and export `FlutterEngineGetProcAddresses`,
`FlutterEngineRunsAOTCompiledDartCode`, and
`DenialFlutterEngineScheduleFrameForExternalTextures`.

Linux builds enable Flutter's Fontconfig backend. The shipped engine therefore
requires `libfontconfig.so.1` and discovers fonts through the host's Fontconfig
configuration instead of assuming they live below `/usr/share/fonts`.

## Licensing

Flutter Engine is BSD 3-Clause and bundled third-party components retain their
licenses. The development package includes the release engine’s Flutter and
third-party license material together with the pinned Dart SDK license.
