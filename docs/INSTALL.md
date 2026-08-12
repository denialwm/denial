# Install Denial

Denial publishes signed first-party x86-64 repositories for Arch Linux and
CachyOS, Debian 13 (trixie), Ubuntu 24.04 LTS (noble), and Fedora 44. NixOS
26.05 and Void Linux are runtime-tested but do not have first-party binary
packages yet. Every repository uses the permanent release-key fingerprint:

```text
AE4108FA5E91E26BE0EE331E0F5B3AD16E023091
```

ARM64 (AArch64) is fully supported, but first-party ARM64 binaries are not
published yet. ARM64 users should follow the [source build guide](BUILDING.md).

Review the repository-owned [`install.sh`](../install.sh), then run:

```sh
sh -c 'if ! command -v curl >/dev/null 2>&1; then echo "Error: curl is not available." >&2; exit 1; fi; curl -fsSL https://install.denialwm.org | sh'
```

The setup script detects the supported distribution, downloads the public
key, derives and pins its complete fingerprint, rejects conflicting existing
configuration, and configures the native package manager. It asks before
using `sudo` and does not install Denial or any other package.

After repository setup, install Denial explicitly. Use only the command for
the current distribution.

### Arch Linux or CachyOS

```sh
sudo pacman -Syu denial
```

### Debian 13 or Ubuntu 24.04

```sh
sudo apt update && sudo apt install denial
```

### Fedora 44

```sh
sudo dnf install denial
```

The package manager installs the exactly compatible
`denial-flutter-engine` package as a dependency. The optional
`denial-ui-development` binary package is currently published only through
the Pacman repository.

## Repository trust paths

The guided setup installs these exact configurations:

- Arch Linux and CachyOS: `https://denialwm.github.io/denial/$arch`, with
  package and Pacman database signatures required through Pacman's trusted
  keyring;
- Debian 13: `https://denialwm.github.io/denial/apt`, suite `trixie`, component
  `main`, with `/etc/apt/keyrings/denial.asc` as `Signed-By`;
- Ubuntu 24.04: the same APT root, suite `noble`, component `main`, and the same
  scoped keyring;
- Fedora 44: `https://denialwm.github.io/denial/rpm/fedora/$releasever/$basearch`,
  with both `gpgcheck=1` for embedded RPM signatures and `repo_gpgcheck=1` for
  signed repository metadata.

APT authenticates the signed `InRelease`/`Release.gpg` metadata before using
its package checksums. DNF authenticates `repomd.xml` and the embedded OpenPGP
signature in each RPM header. Adjacent detached signatures and the signed
top-level `SHA256SUMS` remain available for direct-download verification.

## Updates and removal

Use the native package manager's normal full update path:

```sh
# Arch Linux or CachyOS
sudo pacman -Syu

# Debian or Ubuntu
sudo apt update && sudo apt upgrade

# Fedora
sudo dnf upgrade
```

Remove Denial with `sudo pacman -Rns denial`, `sudo apt remove denial`, or
`sudo dnf remove denial`. Removing the package does not remove the repository
configuration or release key.

The [Arch-specific guide](packaging/arch/INSTALL.md) documents manual Pacman
keyring setup, configuration inspection, the optional development package,
and session validation in more detail.

## Release trust

Public-beta packages are built on Denial's owner-operated x86-64 runner and
signed in a separate GitHub-hosted job. The tag workflow promotes the retained
`main` payload without compiling it again, creates all three repository
formats, and a secret-free publication job exercises APT and DNF clients
against the exact signed snapshot before deployment. This proves release
authorization and repository integrity, not offline closure, reproducibility,
independent rebuilding, SBOM coverage, or AArch64 binary packages. See
[Build trust](BUILD_TRUST.md) for the exact claims.
