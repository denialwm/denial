# Main-branch production-candidate validation

Every push to remote `main` runs
`.github/workflows/main-validation.yml`. The workflow is also available through
manual dispatch.

The lane produces an unsigned production candidate, not a public release. Its
purpose is to prove that the exact committed source can pass Denial's complete
x86-64 build and package path before a version tag is created.

## Build boundary

The owner-operated x86-64 runner:

1. checks out the exact pushed commit into a fresh ephemeral workspace;
2. verifies and consumes the root-owned pinned Flutter Engine artifact
   installed separately on the builder host;
3. audits committed inputs and qualifies the builder;
4. bootstraps the pinned Flutter and Rust toolchains;
5. builds the Flutter integration bundle;
6. runs the Rust and Flutter test suites;
7. builds and internally validates the engine and Denial packages;
8. records package metadata, host inputs, checksums, toolchain versions, and
   build logs;
9. uploads one seven-day candidate artifact.

A separate GitHub-hosted Arch job downloads that artifact and independently
checks its source identity, checksums, architecture, package set, package
ownership metadata, engine ABI dependency, and required runtime payloads.

The artifact is named:

```text
denial-main-validated-candidate-RUN_ID
```

Its provenance explicitly records:

```text
artifact_class=main-production-candidate
publication_authorized=false
signature_status=unsigned
```

## Running the push lane

The self-hosted runner is ephemeral and must be armed immediately before a
trusted push:

```sh
tools/denial-builder install
tools/denial-builder arm
git push --force-with-lease origin main
```

`install` verifies the ignored local `libflutter_engine.so` against the
tracked checksum and places it under
`/srv/denial-builder/artifacts/flutter-engine/3.44.7.denial1/` as a root-owned,
read-only build input. Routine runner instances can read but cannot replace
it. Update that host artifact only as part of a controlled Flutter generation
change.

After the workflow finishes, remove any remaining runner registration with:

```sh
tools/denial-builder cancel
```

The workflow can also be run manually with:

```sh
tools/denial-builder validate
```

## Release boundary

A successful candidate validates the source and package construction path. It
does not authorize publication and never receives a signing secret.

Production signing remains exclusive to `.github/workflows/release.yml`. That
workflow accepts only a clean signed `vMAJOR.MINOR.PATCH` tag contained in
`main`, signs in the protected `release-signing` environment, independently
verifies the signed repository, and publishes only after all release gates
pass.
