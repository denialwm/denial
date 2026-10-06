# Denial one-job GitHub runner

These files define the owner-operated x86-64 runner host. They intentionally
separate reusable host installation from per-job GitHub registration.

## Files

- `runner.env` pins the official runner archive, URL, and SHA-256.
- `install-host` creates the locked account, installs the root-owned runner
  release, creates the persistent engine build cache, installs the systemd
  unit and helpers, and validates the unit.
- `denial-actions-runner-arm` creates a fresh writable instance, registers it
  for one repository job, and starts the static service.
- `denial-actions-runner-cleanup` removes only the fixed disposable instance.
- `denial-actions-runner.service` confines the unprivileged listener and
  guarantees cleanup after exit. Its startup probe must successfully create
  the same private Bubblewrap network namespace used by package validation
  before the GitHub listener is allowed to start.

Use these files through `tools/denial-builder`; do not run the remote helpers
manually during normal operation.

## Credential model

No long-lived GitHub credential is installed on the builder. The operator
workstation requests a repository registration token, sends it over SSH on
standard input, and discards it. GitHub runner credentials exist only inside
`/srv/denial-builder/runner/current`, which is deleted after the job.

The package-signing key is outside this design entirely.

`ProtectProc=invisible` prevents the runner from inspecting processes owned by
other users. Standard read-only `/proc` system information remains available
because the qualification check and native build tools use CPU and memory
topology data.

The service admits `AF_NETLINK` because Bubblewrap uses `NETLINK_ROUTE` to
initialize loopback after `--unshare-net`. This does not restore host-network
access to the package sandbox: the child still runs in its own network
namespace, and the runner service retains an empty capability set.

When a job exits, the service first erases every credential-bearing file from
its disposable instance. If systemd still holds the empty instance root as a
temporary bind mount, the operator-side cleanup removes that directory after
the service namespace has disappeared.

The runner writes ordinary build caches only below
`/srv/denial-builder/cache`. The unprivileged account can also ask the
root-owned Nix daemon to realize immutable paths in `/nix/store`, but it is not
a trusted Nix user and cannot change daemon settings or post-build hooks. The
installer configures only Denial's public Cachix substituter and signing key.
The Cachix write token exists only in the disposable Actions environment and
an explicit list of validated Denial paths is uploaded; credentials are never
stored in either persistent cache.

Engine entries are addressed by the committed source lock, GN arguments, and
expected checksums; every reuse verifies the engine bytes before packaging.

## Updating the runner

Runner auto-update is disabled so the executable used for a job remains the
reviewed release. To update it:

1. review the official `actions/runner` release;
2. update all four values in `runner.env`, including the checksum published on
   the release page;
3. run `tools/denial-builder install`;
4. run `tools/denial-builder doctor`;
5. perform an `arm`, `status`, and `cancel` lifecycle test before dispatching a
   real job.

An existing release directory with a mismatched source record is rejected
rather than silently overwritten.

## Scope

This service protects the host from an ordinary trusted build job. It is not
the Stage 2 clean build boundary and does not make a maintainer-owned machine
independent. Offline compilation, fixed package inputs, clean Arch chroots,
double builds, signing, attestation, and independent reproduction are separate
release gates.
