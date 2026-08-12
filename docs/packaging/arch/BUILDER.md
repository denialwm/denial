# Owner-operated x86-64 builder

This is the initial no-cost Denial builder: one dedicated laptop, one trusted
job at a time, and no automatic pull-request execution. The machine is useful
build capacity, not an independent trust domain.

## Current status

As of 2026-07-25, the host at the operator's private SSH target
`192.168.1.18` is provisioned and has passed both the local qualification
scan and a live GitHub registration test. The test runner was then stopped,
its writable instance was removed, and its repository registration was
deleted. No runner waits online between jobs.

The machine actually has:

- CachyOS, an Arch-compatible x86-64 host;
- an AMD Ryzen AI 9 HX 370 with 12 cores and 24 threads;
- 30 GiB physical RAM and 30 GiB zram;
- a 512 GB NVMe drive with approximately 439 GiB currently free;
- Btrfs storage below `/srv`;
- synchronized time and an NVMe health log with no media errors.

The host operating system is not the future release build authority. Stage 2
must build in a recreated clean Arch environment with declared inputs. This
machine authorizes only x86-64 candidates; cross-compiling AArch64 here does
not create native AArch64 release evidence.

## Runner architecture

The versioned implementation is in
[`packaging/arch/runner`](../../../packaging/arch/runner/README.md), operated through
`tools/denial-builder`.

The installed boundary is:

- a locked `denial-builder` system account with `/usr/bin/nologin`;
- no supplementary groups and no noninteractive sudo access;
- root-owned runner parents and a fresh, user-writable `current` instance;
- GitHub Actions runner `2.336.0`, downloaded from the official release and
  verified against SHA-256
  `04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d`;
- a static systemd service that cannot be enabled at boot;
- an ephemeral, repository-scoped registration with the extra label
  `denial-builder`;
- a service sandbox with no capabilities, no privilege escalation, no host
  home-directory access, a read-only host filesystem, private devices and
  temporary storage, one disposable writable runner directory, and one
  credential-free persistent build-cache root;
- automatic deletion of the writable instance when the one job exits.

The production package-signing key must never be copied to this laptop.
Builds produce unsigned candidates, hashes, and evidence. Signing and
publication are separate operations.

The machine does not store a GitHub PAT. `tools/denial-builder arm` requests a
short-lived repository registration token through the operator workstation's
authenticated `gh` session, passes it over SSH, and starts one runner. The
runner's generated credentials disappear with the writable instance.

## Trigger policy

Jobs accepted by this machine are deliberately narrow:

- owner-pushed `dev` and trusted `main` pushes, or explicit manual dispatch,
  during branch validation;
- manual dispatch for builder qualification;
- never `pull_request`, `pull_request_target`, or fork code;
- never a job whose workflow revision has not been reviewed by the operator.

The repository currently enforces read-only default `GITHUB_TOKEN`
permissions, forbids Actions from approving pull requests, and requires every
referenced action to use a full commit SHA. The qualification workflow uses no
external action.

The repository is public. Repository rules, environment protection, action
pinning, and organization account security remain operator controls to review
whenever the release workflow or maintainer set changes. The ephemeral runner
boundary does not replace those controls.

## Host prerequisites

The host is fully updated and currently provides:

```text
actionlint
base-devel
devtools
git
jq
libarchive
zstd
gnupg
namcap
diffoscope
bubblewrap
binutils
dpkg
patchelf
pax-utils
clang
lld
ninja
cmake
pkgconf
rustup
rpm-tools
shellcheck
nvme-cli
```

These host packages qualify the builder and produce trusted-branch
candidates. The `main` candidate supplies the exact compiled payloads later
promoted into public-beta packages. They are not the Stage 2 dependency
closure.
Compositor and Flutter build dependencies ultimately belong in the recreated
clean environment, not in undocumented ambient host state.

Do not add `NOPASSWD: ALL`. A future clean-chroot build may need a narrowly
scoped root-owned helper, but that helper does not exist yet and must be
reviewed independently.

## Operation

Install or update the pinned host configuration:

```sh
tools/denial-builder install
```

The installer creates `/srv/denial-builder/cache` for the locked builder
account and confines the service so this credential-free cache root is its
only persistent writable state outside the disposable runner. Verified
Flutter artifacts, Cargo/Pub dependencies, Rust targets, and compatible engine
build outputs may survive jobs. Each ephemeral job resolves Flutter and Skia
from the exact commits in `SOURCE_LOCK.json`, validating any retained detached
projection before use; no cached source checkout is editable or authoritative.
A matching verified artifact entry skips the engine build entirely.

Audit the machine as the unprivileged runner account:

```sh
tools/denial-builder doctor
```

Once `.github/workflows/builder-qualification.yml` exists on remote `main`,
arm one runner, dispatch the workflow, and watch it to completion:

```sh
tools/denial-builder qualify
```

Every trusted push starts the branch-validation workflow. Development work is
proven first:

```sh
tools/denial-builder arm
git push origin dev
```

After that exact `dev` tree is green, arm a new one-job runner immediately
before merging it into `main`. The hosted authorization gate checks the merge,
then the runner performs a fresh production build from `main`.

Either branch build can also be dispatched and watched manually:

```sh
tools/denial-builder validate-dev
tools/denial-builder validate
```

Its unsigned artifact and independent verification boundary are documented in
[`BRANCH_VALIDATION.md`](BRANCH_VALIDATION.md).

Only after the `main` production candidate has passed may a version be chosen
and signed. The public-beta release controller is:

```sh
tools/denial-builder release v0.2.0
```

It refuses a missing tag, missing release-signing environment secret, or a
fingerprint mismatch. It does not arm or use this machine: the hosted release
workflow promotes the retained exact-commit `main` payload, then signs and
publishes it without compilation.

The lower-level lifecycle commands are:

```sh
tools/denial-builder arm
tools/denial-builder status
tools/denial-builder logs
tools/denial-builder cancel
```

`cancel` is the recovery path for an armed runner that has not completed its
one job. It stops the listener, erases the local instance, resets the unit
state, and deletes Denial runner registrations from this repository.

The arm helper requires the fresh listener to establish an authenticated
GitHub broker session before it returns. The controller then prefers GitHub's
REST status to report that exact registration online. GitHub has a documented
[false-offline runner status bug][runner-false-offline], so after the normal
status wait it may continue only when all three local checks agree: the exact
fresh registration still exists, the broker session was established, and the
confined service remains active. A 250-minute controller timeout covers the
four-hour workflow limit while preventing a dispatched workflow from waiting
indefinitely if the status inconsistency masks a real scheduling failure.

From a clean checkout, the qualification workflow executes:

```sh
tools/denial-release source-audit
tools/denial-release doctor --ci
```

It checks the exact source revision, committed manifests and hashes, host
capacity, required tools, architecture, event, ref, and GitHub runner context,
then builds or verifies the locked Flutter Engine cache. It does not sign,
attest, or publish a package.

## Recurring release gate

Run `tools/denial-builder qualify` after any material builder or workflow
change. Run `tools/denial-builder validate-dev` for an explicit candidate
build, or `tools/denial-builder validate` for an explicit `main` production
candidate build. Both validation commands arm a fresh runner. A failed
production candidate is repaired and proven on `dev` before another merge.

Neither command authorizes publication. `tools/denial-builder release` still
requires a clean signed version tag contained in `main` and the protected
signing environment, but it consumes only the retained successful `main`
candidate and never invokes the builder. Stage 2 and Stage 3 harden that same
release channel later; they are not prerequisites for the explicitly limited
alpha.

[runner-false-offline]: https://github.com/actions/runner/issues/3892
