# Debian package adapter

Build the Debian 13 and Ubuntu 24.04-compatible x86-64 runtime packages with:

```sh
tools/denial-pc debian-package
```

The adapter consumes the shared, GLIBC 2.39-gated runtime staging tree. It
does not compile on or inspect the target distribution. `dpkg-deb` only adds
Debian control metadata; the builder extracts both resulting packages and
proves that every installed payload byte and mode matches the shared tree.
Outputs are written below `$XDG_CACHE_HOME/denial/pc-build/packages/` by
default.

The two required packages are `denial-flutter-engine` and `denial`. Clean
Debian package installation, reinstall, configuration preservation, and a
real GDM session are recorded in [VALIDATION.md](VALIDATION.md).

Signed releases attach both `.deb` files and adjacent `.sig` files to the
GitHub Release. Import `denial-repo-key.asc`, then verify each download with
`gpg --verify PACKAGE.sig PACKAGE` before installation. This is currently a
signed direct-download lane, not an APT repository.
