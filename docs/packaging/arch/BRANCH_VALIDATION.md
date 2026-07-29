# Trusted-branch candidate validation

Every trusted push to remote `dev` or `main` runs
`.github/workflows/branch-validation.yml`. Pull requests and forks never
trigger the owner-operated builder.

`dev` is the first complete integration gate. It runs the same x86-64 build,
test, package, artifact, and independent-verification path as `main` before
changes are promoted. Its three packages are installable for testing, but use
package release `0` and are explicitly ineligible for release signing or
publication.

`main` is an unchanged-promotion gate on a GitHub-hosted runner. It accepts
only a two-parent merge whose tree is exactly its validated `dev` parent,
whose first parent is the previous `main`, and whose `dev` commit has a
successful build plus independent-verification run. It does not compile the
same tree a second time. A public release is rebuilt from a separately signed
version tag by the release workflow.

## Build boundary

The owner-operated x86-64 runner:

1. checks out the exact pushed commit as a local `dev` or `main` branch in a
   fresh ephemeral workspace, allowing the development package to record both
   that verified revision and its cloneable upstream branch;
2. builds or reuses optimized, profile, and JIT Flutter Engine artifacts from
   the exact locked Denial Flutter and Skia fork commits;
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

The development artifact is named:

```text
denial-dev-validated-candidate-RUN_ID
```

Their policy fields are:

| Branch | Artifact class | Package release | Release signing |
| --- | --- | ---: | --- |
| `dev` | `development-test-candidate` | `0` | Ineligible |

It records `publication_authorized=false`,
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

`install` creates the credential-free persistent engine cache under
`/srv/denial-builder/cache/flutter-engine`. The workflow populates it from the
committed fork source lock. Exact hits are checksum-verified no-ops; source or
GN changes reuse the retained checkout and Ninja object graph.

Wait for the `dev` workflow and its independent verifier to pass. Test its
downloadable package-release-`0` artifact when the change warrants a live
session check. Only then promote the same commit from `dev` to `main` using a
merge commit, never squash or rebase. The `main` push needs no self-hosted
runner; its hosted provenance gate rejects any tree change or missing
successful `dev` validation. Do not repair a failed promotion directly on
`main`; fix it on `dev`, prove it there, and promote it again.

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
`main`, uses that verified tag as the sole `pkgver` source for every archive,
signs in the protected `release-signing` environment, independently verifies
the signed repository, and publishes only after all release gates pass.
