# Fedora package adapter

Build the Fedora x86-64 runtime packages with:

```sh
tools/denial-pc fedora-package
```

The RPM spec consumes the same GLIBC 2.39-gated staging tree as the Debian
adapter. ELF stripping, debug splitting, build-id links, and post-build binary
rewrites are disabled. The builder extracts both RPMs and proves that every
installed payload byte and mode matches the shared tree.
Outputs are written below `$XDG_CACHE_HOME/denial/pc-build/packages/` by
default.

The two required packages are `denial-flutter-engine` and `denial`. Clean
Fedora installation, reinstall, configuration preservation, and a real GDM
session are recorded in [VALIDATION.md](VALIDATION.md).

Signed releases attach both RPMs and adjacent `.sig` files to the GitHub
Release. Import `denial-repo-key.asc`, then verify each download with
`gpg --verify PACKAGE.sig PACKAGE` before installation. This is currently a
signed direct-download lane, not a DNF repository or an embedded RPM-signature
claim.
