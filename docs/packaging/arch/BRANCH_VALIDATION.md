# Trusted-branch candidate validation

Every trusted push to remote `dev` or `main` runs
`.github/workflows/branch-validation.yml`. Pull requests and forks never
trigger the owner-operated builder.

`dev` is the first complete integration gate. It builds, tests, packages, and
independently verifies an installable development candidate. That candidate
uses package release `0` and is explicitly ineligible for signing or
publication. Its build policy may intentionally diverge from production in
the future, for example by enabling additional diagnostics.

`main` has two gates. A GitHub-hosted authorization job first accepts only a
two-parent merge whose tree is exactly its validated `dev` parent, whose
first parent is the previous `main`, and whose `dev` commit has a successful
push validation. The owner-operated runner then independently performs the
production build from that exact `main` commit, with release-mode Flutter AOT
and Rust artifacts. A separate hosted job verifies the resulting unsigned
production candidate.

The version is deliberately still undecided at this point. Only after the
production candidate is green may a maintainer choose and sign a
`vMAJOR.MINOR.PATCH` tag on that exact commit. The tag workflow downloads the
retained `main` candidate, changes only tag-derived package metadata, installs
the tag-derived runtime version file, proves that every compiled payload is
unchanged, and then signs and publishes it. It performs no compilation.

## Build boundary

For either trusted branch, the owner-operated x86-64 runner:

1. checks out the exact pushed commit in a fresh ephemeral workspace;
2. builds or reuses optimized, profile, and JIT Flutter Engine artifacts from
   the exact locked Denial Flutter and Skia fork commits;
3. audits committed inputs and qualifies the builder;
4. bootstraps the pinned Flutter and Rust toolchains;
5. builds the Flutter integration bundle;
6. runs the Rust and Flutter test suites;
7. builds and internally validates the two required runtime packages as Arch,
   Debian, RPM, and Alpine archives, plus the optional Arch UI-development
   package;
8. records package metadata, host inputs, checksums, toolchain versions, and
   build logs; and
9. uploads the unsigned candidate artifact.

A separate GitHub-hosted Arch job downloads that artifact and independently
checks its source identity, checksums, all nine archives, package ownership
metadata, engine ABI dependencies, version bounds, and required runtime and
development payloads. The candidate also contains separately hashed neutral
and Alpine-adapted staging trees, so the verifier compares every APK file and
mode with the exact post-`gcompat`/`patchelf` payload.

The CachyOS host does not need to boot Alpine. `tools/package-denial-apk`
verifies a pinned official Alpine 3.24.1 minirootfs, enters it through rootless
Bubblewrap, installs declared build dependencies, then disables networking
while `abuild` compiles the two small musl bridges and assembles the APKs.

The artifacts are named:

```text
denial-dev-validated-candidate-RUN_ID
denial-main-validated-candidate-RUN_ID
```

Their policy fields are:

| Branch | Artifact class | Build policy | Package release | Signing |
| --- | --- | --- | ---: | --- |
| `dev` | `development-test-candidate` | Development | `0` | Ineligible |
| `main` | `production-release-candidate` | Production | `0` | Eligible only after signed-tag promotion |

Both record `publication_authorized=false`,
`signature_status=unsigned`, and the exact source and workflow identity.
Only `main` records `release_signing_eligible=true`. The release workflow
refuses a `dev` artifact even when it was built from an identical source tree.

## Development and main flow

The self-hosted runner is ephemeral. Arm one job immediately before each
trusted branch push:

```sh
tools/denial-builder install

tools/denial-builder arm
git push origin dev

# After dev is green, arm a new one-job runner immediately before merging.
tools/denial-builder arm
# Merge the exact validated dev tree into main without squashing or rebasing.
```

`install` creates the credential-free persistent engine cache under
`/srv/denial-builder/cache/flutter-engine`. The workflow populates it from the
committed fork source lock. The runner validates or provisions an exact,
detached Flutter/Skia projection; it never inherits an editable source
checkout. Exact artifact hits are checksum-verified no-ops, while compatible
build outputs and locked projections may still be reused.

Test the downloadable development artifact when a change warrants a live
session check. Do not repair a failed `main` production build directly on
`main`; fix it on `dev`, prove the fix there, and promote it again.

Either branch can also be built and watched through the controller. Both
commands arm a fresh one-job runner:

```sh
tools/denial-builder validate-dev
tools/denial-builder validate
```

After a workflow finishes, remove any unexpected remaining registration with:

```sh
tools/denial-builder cancel
```

## Release boundary

Do not choose a public version merely to obtain a production build. A green
`main` production candidate is the versionless release decision point.

After choosing and pushing a clean signed tag on that exact commit, run:

```sh
tools/denial-builder release vMAJOR.MINOR.PATCH
```

This controller does not arm the builder. `.github/workflows/release.yml`
resolves the successful exact-commit `main` push run, promotes its retained
payloads to tag-derived `pkgver`/`pkgrel` metadata, verifies payload identity,
signs in the protected `release-signing` environment, independently verifies
the signed repository and direct APK downloads, and publishes only after every
release gate passes. Alpine promotion consumes the already adapted payload and
runs only `abuild rootpkg` under the no-compilation guard; no bridge or Denial
binary is rebuilt.
