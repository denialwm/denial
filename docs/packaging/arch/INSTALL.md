# Install Denial from its Arch repository

> The repository becomes live with Denial's first announced public-alpha
> release. Until then, the URL below may return `404`.

The first-party repository currently supports Arch Linux on `x86_64`. It
contains two packages:

- `denial`, the compositor, Flutter application, session, and configuration;
- `denial-flutter-engine`, the matching pinned Flutter runtime.

Pacman installs and upgrades them together.

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
requires trusted signatures for both packages and repository databases.

## 3. Install Denial

Refresh all repositories, perform the normal system upgrade, and install
Denial:

```sh
sudo pacman -Syu denial
```

Inspect the selected package source and version if desired:

```sh
pacman -Si denial denial-flutter-engine
```

Then log out, choose **Denial** in the display manager, and sign in. From an
existing graphical session, `denial-session --check` performs an installation
and hardware preflight without starting the compositor.

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

Pacman preserves administrator-modified backup files according to its normal
`.pacsave` behavior. Remove the `[denial]` block from `/etc/pacman.conf` if the
repository is no longer wanted.

## Release trust

Public-alpha packages are built on Denial's owner-operated x86-64 runner and
signed in a separate GitHub-hosted job. The signature proves that Denial
authorized the exact package bytes. It does not yet prove an offline build,
byte-for-byte reproducibility, independent rebuilding, SBOM coverage, or
AArch64 support. See [Build trust](../../BUILD_TRUST.md) for the precise
claims and non-claims.
