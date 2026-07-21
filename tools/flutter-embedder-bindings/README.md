# Flutter Embedder Rust binding generator

This separately locked maintenance tool converts Flutter's C Embedder API into
the Rust bindings committed at `compositor/flutter-engine/src/sys.rs`.
Ordinary Denial builds never compile this tool and therefore do not require
Clang, libclang, or `bindgen`.

Run the repository wrapper during a controlled Flutter engine upgrade:

```sh
tools/generate-flutter-embedder-bindings
tools/generate-flutter-embedder-bindings --check
```

The wrapper reads the coupled artifact revision from
`prebuilt/flutter-engine/elinux-x64-release/ENGINE_REVISION` and the source
commit from `FLUTTER_REVISION`. It downloads that commit's
`engine/src/flutter/shell/platform/embedder/embedder.h` from the official
Flutter monorepo, generates bindings with the exact `bindgen` dependency
locked in this directory, and stamps both revisions and the header SHA-256
into the output.

To generate from an already available engine checkout or downloaded header,
set `DENIAL_FLUTTER_EMBEDDER_HEADER` to its exact `embedder.h` path. The pinned
engine and Flutter revisions remain authoritative and are still recorded in
the output.
