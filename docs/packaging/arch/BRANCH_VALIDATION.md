# Trusted-branch candidate validation

Every trusted push to remote `dev` or `main` runs
`.github/workflows/branch-validation.yml`. Pull requests and forks never
trigger the owner-operated builder.

`dev` is the first complete integration gate. It runs the same x86-64 build,
test, package, artifact, and independent-verification path as `main` before
changes are promoted. Its three packages are installable for testing, but use
package release `0` and are explicitly ineligible for release signing or
publication.

`main` is the production-candidate gate. It repeats the proven path with
package release `1`, but its artifact also remains unsigned and unpublished.
A public release is always rebuilt from a separately signed version tag by the
release workflow.

## Build boundary

The owner-operated x86-64 runner:

1. checks out the exact pushed commit as a local `dev` or `main` branch in a
   fresh ephemeral workspace, allowing the development package to record both
   that verified revision and its cloneable upstream branch;
2. verifies and consumes the root-owned pinned optimized and JIT Flutter
   Engine artifacts installed separately on the builder host;
3. audits committed inputs and qualifies the builder;
4. bootstraps the pinned Flutter and Rust toolchains;
5. builds the Flutter integration bundle;
6. runs the Rust and Flutter test suites;
7. builds and internally validates the two required runtime packages and the
   optional UI-development package;
8. records package metadata, host inputs, checksums, toolchain versions, and
   build logs;
9. uploads one seven-day candidate artifact.

A separate GitHub-hosted Arch job downloads that artifact and independently
checks its source identity, checksums, architecture, three-package set, package
ownership metadata, engine ABI dependencies, version bounds, and required
runtime and development payloads.

Artifacts are named:

```text
denial-dev-validated-candidate-RUN_ID
denial-main-validated-candidate-RUN_ID
```

Their policy fields are:

| Branch | Artifact class | Package release | Release signing |
| --- | --- | ---: | --- |
| `dev` | `development-test-candidate` | `0` | Ineligible |
| `main` | `main-production-candidate` | `1` | Ineligible |

Both record `publication_authorized=false`,
`release_signing_eligible=false`, and `signature_status=unsigned`.

Any byte sequence can technically be signed outside this project. Denial's
enforced boundary is that the release workflow never consumes a branch
artifact: it accepts only a signed version tag, verifies that tag against
`main`, and rebuilds the packages under a separate artifact name before the
protected signing job can start.

## Development and promotion flow

The self-hosted runner is ephemeral. Arm it immediately before pushing trusted
development work:

```sh
tools/denial-builder install
tools/denial-builder arm
git push origin dev
```

`install` verifies the ignored local optimized and JIT
`libflutter_engine.so` files against their tracked checksums. It places them
under `/srv/denial-builder/artifacts/flutter-engine/3.44.7.denial1/` and its
`debug/` subdirectory as root-owned, read-only build inputs. Routine runner
instances can read but cannot replace them. Update either host artifact only
as part of a controlled Flutter generation change.

Wait for the `dev` workflow and its independent verifier to pass. Test its
downloadable package-release-`0` artifact when the change warrants a live
session check. Only then promote the same commit from `dev` to `main`.

Arm a fresh runner immediately before merging the promotion pull request so
the resulting `main` push repeats the gate. Do not repair a failed production
candidate directly on `main`; fix it on `dev`, prove it there, and promote it
again.

After either workflow finishes, remove any remaining runner registration with:

```sh
tools/denial-builder cancel
```

Either branch can also be validated manually:

```sh
tools/denial-builder validate-dev
tools/denial-builder validate
```

## Release boundary

A successful branch candidate validates the source and package construction
path. It does not authorize publication and never receives a signing secret.

Production signing remains exclusive to `.github/workflows/release.yml`. That
workflow accepts only a clean signed `vMAJOR.MINOR.PATCH` tag contained in
`main`, signs in the protected `release-signing` environment, independently
verifies the signed repository, and publishes only after all release gates
pass.
