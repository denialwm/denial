# Denial build trust

Denial publishes only claims supported by its current evidence. The first
public alpha prioritizes ordinary signed installation and transparent build
ownership. Complete offline closure and independent reproducibility remain
later goals. The project does not treat a CI badge, package signature, or
maintainer-owned builder as proof that a binary is safe.

## Current status

As of 2026-07-25:

- the x86-64 source-built Flutter Engine and split Pacman package prototype
  have passed source reconstruction, tests, package transactions, and
  real-hardware validation;
- no production Denial package repository exists;
- the permanent release identity
  `AE4108FA5E91E26BE0EE331E0F5B3AD16E023091` is backed up and its signing
  subkey is installed in the GitHub `release-signing` environment;
- the signed-tag, GitHub Release, and Pages workflow is staged but has not
  been publicly run;
- no Stage 1 development or disposable-key package is presented as a public
  release;
- complete offline dependency closure and package reproducibility remain
  Stage 2 and Stage 3 work;
- the dedicated x86-64 host, locked runner account, and manually armed
  one-job GitHub registration have passed local and live registration tests;
- AArch64 is not yet a supported release architecture.

The detailed evidence is in
[the package validation report](packaging/arch/VALIDATION.md). The remaining
work and release gates are in
[the publishing design](packaging/arch/PUBLISHING.md).

## Builder disclosure

The initial x86-64 release builder is a dedicated CachyOS laptop owned and
operated by the Denial maintainer. CachyOS is the host; a recreated clean Arch
environment must become the Stage 2 package build authority. The machine
accepts only manually triggered, trusted `main` or future signed-tag jobs. It
never executes pull-request or fork code.

Machine ownership is disclosed rather than presented as an assurance. The
builder is one trust domain, so two builds on that machine can demonstrate
determinism but not independent reproduction.

For the public alpha, the builder must:

- run as a dedicated unprivileged account;
- receive no production signing key;
- be registered as an ephemeral one-job GitHub runner;
- retain no credentials or writable build environment after the job;
- accept only a manually dispatched reviewed version tag;
- run the compositor and Flutter tests before packaging;
- publish the exact source revision, host package inventory, logs, manifests,
  `.BUILDINFO`, and artifact hashes.

Stage 2 and Stage 3 additionally require recreated clean Arch environments,
declared dependency acquisition, network-disabled compilation, and
reproducibility work. The public alpha states plainly that it has not reached
those gates.

The implemented host uses a locked `denial-builder` account, a checksum-pinned
official runner, a static hardened systemd service, and an ephemeral
repository-scoped registration. It stores neither a GitHub PAT nor a signing
key. See [the builder runbook](packaging/arch/BUILDER.md).

## What each proof means

| Evidence | Establishes | Does not establish |
|---|---|---|
| OpenPGP package signature | Denial approved these exact bytes | The bytes match public source |
| GitHub artifact attestation | A public workflow associated a digest with a repository, revision, and event | The self-hosted machine was uncompromised |
| Clean offline build | Compilation used the declared local closure rather than fetching ambient inputs | The builder was honest |
| Same-builder double build | The inputs appear deterministic in fresh local environments | Independent agreement |
| Independent byte-identical rebuild | Another trust domain produced the same bytes from the published inputs | That the reviewed source has no vulnerability |

No individual item replaces the others.

## Public-alpha release evidence

Every public-alpha release publishes:

- a signed, immutable source tag;
- literal package metadata;
- the package `.BUILDINFO`;
- the source revision, runner disclosure, compiler and Flutter versions, host
  package inventory, test logs, Namcap output, and artifact hashes;
- detached OpenPGP signatures for packages and repository databases;
- a signed complete SHA-256 manifest;
- the full public key and fingerprint;
- explicit non-claims for offline closure, reproducibility, independent
  rebuilding, SBOMs, and AArch64.

Stage 2 and Stage 3 later add immutable source/tool closures, generated
`.SRCINFO`, normalized compiler and linker manifests, SBOMs, attestations,
debug information, and reproducibility results that distinguish same-builder
from independent verification.

The signing identity is separate from the builder. Package files are immutable:
an already published `pkgver-pkgrel` is never silently replaced.

## Independent verification

The eventual independent verification path is:

```sh
git verify-tag vX.Y.Z
git checkout vX.Y.Z
cd packaging/arch
makerepropkg /path/to/denial-X.Y.Z-1-x86_64.pkg.tar.zst
```

This command is not yet a public-alpha claim: the current PKGBUILD consumes
cache-backed build outputs. It becomes a release gate only after Stage 2
replaces those inputs with a complete immutable closure.

Until an external rebuilder exists, Denial will report:

```text
same-builder reproducible: yes|no
independently reproduced:  yes|no
```

It will never call two builds performed by the owner-operated machine
“independent.”

## Workflow policy

The public GitHub workflows are part of the reviewable build instructions:

- no `pull_request` trigger targets a Denial-owned runner;
- manual builder qualification runs only from `main`;
- release jobs require a clean signed `vMAJOR.MINOR.PATCH` tag contained in
  public `main`;
- workflow permissions default to read-only;
- build jobs have no signing or repository-publication secret;
- a separate `release-signing` environment receives only the secret subkey;
- publication re-verifies the signed tree without any secret key and publishes
  a draft GitHub Release only after Pages deployment succeeds.

`tools/denial-release` implements the machine and source audits used by those
workflows. Passing a development source audit is necessary but is not
authorization to publish; only the manual signed-tag release path can do so.
