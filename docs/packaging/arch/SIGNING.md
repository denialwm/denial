# Denial release-signing identity

Denial uses one dedicated OpenPGP identity for release tags, Arch packages,
Pacman databases, and signed checksum manifests.

```text
UID:         Doctor Logix (Denial Repository Signing) <doctor.logix@gmail.com>
Fingerprint: AE4108FA5E91E26BE0EE331E0F5B3AD16E023091
Signing subkey:
             0B0565B0240D83C6BBE558236BE21CAACDD0CCB7
```

The Ed25519 primary key is certification-only and initially expires after
five years. Its Ed25519 signing subkey initially expires after one year. The
primary fingerprint is the stable public identity; signing subkeys can be
renewed or rotated without asking users to trust a different primary key.

## Key separation

The generated recovery kit contains:

- the public key;
- the encrypted primary and signing secret keys;
- a signing-subkey-only export;
- GnuPG's automatic revocation certificate;
- the signing-key passphrase;
- fingerprints, metadata, and checked SHA-256 values.

The full kit is compressed and encrypted again with AES-256. Its encrypted
archive is stored on the separate `/mnt/exty` NVMe. The outer archive
passphrase and signing-key passphrase are stored in a mode-`0600` recovery
file on the system drive. These two files are necessary together.

GitHub receives only:

- `DENIAL_RELEASE_SIGNING_KEY`, the encrypted secret-subkey export;
- `DENIAL_RELEASE_SIGNING_PASSPHRASE`, inside the `release-signing`
  environment;
- `DENIAL_RELEASE_SIGNING_FINGERPRINT`, a non-secret repository variable.

The builder laptop receives none of them. The hosted signing job imports the
subkey into a temporary keyring and erases that keyring after use.

## Operator commands

Inspect the public key and GitHub configuration:

```sh
tools/denial-release-key status
```

Verify the encrypted recovery archive without retaining a decrypted copy:

```sh
tools/denial-release-key verify-backup \
  /mnt/exty/denial-release-key-backups/denial-release-key-AE4108FA5E91E26BE0EE331E0F5B3AD16E023091.tar.zst.gpg \
  /home/logix/.local/share/denial-release-key/recovery.conf
```

From the reviewed clean root, create one signed tag at clean local `main`:

```sh
tools/denial-release-key sign-tag \
  v0.1.0 \
  /mnt/exty/denial-release-key-backups/denial-release-key-AE4108FA5E91E26BE0EE331E0F5B3AD16E023091.tar.zst.gpg \
  /home/logix/.local/share/denial-release-key/recovery.conf
```

The command temporarily decrypts the archive, imports only the signing
subkey, signs and verifies the local tag, and erases the temporary material.
It deliberately does not push. Review the tag before:

```sh
git push origin v0.1.0
tools/denial-builder release v0.1.0
```

## Before first publication

The current second-NVMe backup protects against failure of the system drive;
it is not an offline backup because both NVMe devices are normally attached
to one computer. Before the first public release:

1. copy the encrypted archive to separate removable or offline storage;
2. copy the recovery values into a password manager or another separately
   protected location;
3. verify that offline copy with `verify-backup`;
4. confirm the tracked public key and GitHub variable have the same complete
   fingerprint;
5. confirm the GitHub environment contains no primary secret key;
6. document who can authorize environment use once the repository is public.

Do not commit either recovery file, private-key export, or decrypted archive.

## Rotation and revocation

Renew or replace the signing subkey before it expires, publish the updated
public key, and test it through the private repository path before using it.
The stable primary fingerprint should change only if the primary key is
compromised or permanently lost.

If the signing subkey may be compromised:

1. stop all releases and disable the `release-signing` environment;
2. remove its GitHub secrets;
3. use the offline primary key to revoke the subkey and create a replacement;
4. publish the updated public key and a clearly dated incident notice;
5. do not re-enable publication until fresh clients reject the revoked
   signature and accept the replacement.

If the primary key may be compromised, use the stored revocation certificate,
publish a new identity through every available channel, and require users to
verify the new full fingerprint manually.
