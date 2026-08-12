# Install Denial from its Arch repository

The first-party repository currently supports Arch Linux on `x86_64`. It
contains three packages:

- `denial`, the compositor, Flutter application, session, and configuration;
- `denial-flutter-engine`, the matching pinned Flutter runtime; and
- `denial-ui-development`, an optional version-coupled live Flutter
  development environment.

Installing `denial` pulls in the required engine automatically. The
development package is installed only when requested.

## Guided repository setup

Review the repository-owned [`install.sh`](../../../install.sh), then run:

```sh
curl -fsSL https://install.denialwm.org | sh
```

The installer downloads the public key from the published Denial repository,
derives its full fingerprint locally, and refuses to continue unless it equals
`AE4108FA5E91E26BE0EE331E0F5B3AD16E023091`. It also rejects an existing
`[denial]` section unless its signature policy and server exactly match the
configuration below. After showing its plan and receiving confirmation, it
uses `sudo` only to trust the verified key and add the repository when
necessary. It deliberately does not install packages. When setup completes,
install Denial explicitly:

```sh
sudo pacman -Syu denial
```

Pacman installs the matching `denial-flutter-engine` package as a required
dependency.

The following sections document the same process for users who prefer to
perform every step manually.

## 1. Import the Denial release key

The permanent primary fingerprint is:

```text
AE4108FA5E91E26BE0EE331E0F5B3AD16E023091
```

Download the public key into a temporary directory, derive its full
fingerprint locally, and require an exact match before changing Pacman's
keyring:

```sh
key_fingerprint='AE4108FA5E91E26BE0EE331E0F5B3AD16E023091'
key_tmp="$(mktemp -d)"
trap 'rm -rf -- "$key_tmp"' EXIT

curl \
  --proto '=https' \
  --tlsv1.2 \
  --fail \
  --silent \
  --show-error \
  --location \
  --output "$key_tmp/denial-repo-key.asc" \
  https://denialwm.github.io/denial/denial-repo-key.asc

downloaded_fingerprint="$(
  gpg \
    --batch \
    --show-keys \
    --with-colons \
    --fingerprint \
    "$key_tmp/denial-repo-key.asc" \
    | awk -F: '$1 == "fpr" { print toupper($10); exit }'
)"
test "$downloaded_fingerprint" = "$key_fingerprint"

gpg --show-keys --with-fingerprint "$key_tmp/denial-repo-key.asc"
sudo pacman-key --add "$key_tmp/denial-repo-key.asc"
sudo pacman-key --lsign-key "$key_fingerprint"
```

If a newly installed Arch system has no initialized Pacman keyring, run
`sudo pacman-key --init` and `sudo pacman-key --populate archlinux` first.

The full fingerprint is also printed in the tagged GitHub Release, the signed
repository metadata, and
[`packaging/arch/denial-repo-key.asc`](../../../packaging/arch/denial-repo-key.asc).
Do not substitute a short key ID.

## 2. Add the repository

Open Pacman's configuration:

```sh
sudoedit /etc/pacman.conf
```

Add this block after the official Arch repositories:

```ini
[denial]
SigLevel = Required TrustedOnly
Server = https://denialwm.github.io/denial/$arch
```

Do not use `TrustAll`, `Optional`, or `Never`. The configuration above
requires trusted signatures for every package and repository database.

## 3. Install Denial

Refresh all repositories, perform the normal system upgrade, and install
Denial:

```sh
sudo pacman -Syu denial
```

Inspect the selected package source and version if desired:

```sh
pacman -Si denial denial-flutter-engine denial-ui-development
```

Then log out, choose **Denial** in the display manager, and sign in. From an
existing graphical session, `denial-session --check` performs an installation
and hardware preflight without starting the compositor. Inside a running
Denial session, `denialctl status` verifies the native control connection and
reports the compositor, output, and Flutter UI state.

Denial renders through its compositor-integrated Impeller GLES backend by
default. If a GPU-driver issue requires the retained Skia/Ganesh fallback, add
`DENIA_FLUTTER_RENDERER=skia` to `/etc/denial/session.conf` and restart the
Denial session. Removing the override returns to Impeller.

The standard display-manager entry starts unlocked because the display manager
has already authenticated the user. An autologin or other direct boot path
which does not authenticate first should launch
`denial-session --start-locked`. See
[Session startup and locking](../../SESSION_STARTUP.md) for the exact session and
greetd forms and the supported launcher modes.

## Optional live Flutter development

Install the development environment only when you want to edit Denial's
Flutter shell:

```sh
sudo pacman -S denial-ui-development
denialctl ui setup
```

The setup command creates a version-matched editable checkout in `~/DenialUI`,
prepares it with the packaged toolchain, and enters live development. Open
`~/DenialUI/dart_shell` in VSCodium and run **Attach to Denial live UI** for
hot reload on save, Flutter Inspector, and browser DevTools performance
profiling. Return to the packaged optimized shell at any time with:

```sh
denialctl ui restore
```

See [Live Flutter UI development](../../UI_DEVELOPMENT.md) for the runtime,
security, and recovery model.

## Updates

Denial uses the normal Arch upgrade path:

```sh
sudo pacman -Syu
```

Pacman verifies the database and package signatures before installing an
update. Flutter Engine updates are separate and less frequent; the `denial`
package requires the exact compatible engine ABI.

## Removal

Remove the compositor and its now-unused dependencies with:

```sh
sudo pacman -Rns denial
```

If `denial-ui-development` is installed, remove it in the same transaction:

```sh
sudo pacman -Rns denial-ui-development denial
```

Pacman preserves administrator-modified backup files according to its normal
`.pacsave` behavior. Remove the `[denial]` block from `/etc/pacman.conf` if the
repository is no longer wanted. An editable `~/DenialUI` checkout is user
data and is not removed by Pacman.

## Release trust

Public-alpha packages are built on Denial's owner-operated x86-64 runner and
signed in a separate GitHub-hosted job. The signature proves that Denial
authorized the exact package bytes. It does not yet prove an offline build,
byte-for-byte reproducibility, independent rebuilding, SBOM coverage, or
AArch64 support. See [Build trust](../../BUILD_TRUST.md) for the precise
claims and non-claims.
