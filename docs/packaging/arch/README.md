# Arch Linux packaging

Build Denial and create the two Pacman packages from the current working tree:

```sh
tools/denial-pc arch-package
```

The packages are written below
`$XDG_CACHE_HOME/denial/pc-build/packages/` by default:

- `denial-flutter-engine` owns the pinned engine, ICU data, generation
  manifest, build metadata, and Flutter licenses;
- `denial` owns the compositor, AOT application, Flutter assets, session
  launcher, portals, and machine configuration.

Install both in one transaction, with the engine package first:

```sh
sudo pacman -U \
  /path/to/denial-flutter-engine-3.44.7.denial1-1-x86_64.pkg.tar.zst \
  /path/to/denial-*.pkg.tar.zst
```

The `denial` package requires the exact virtual capability
`denial-flutter-engine-abi=3.44.7.denial1`. A routine Denial rebuild can
therefore reuse this engine package, while a Flutter-generation change must
produce a new compatible pair.

Development packages use a VCS-derived version. The public release workflow
accepts only a clean signed `vMAJOR.MINOR.PATCH` tag matching both project
version files and emits `pkgrel=1`.

Pacman owns the compositor, Flutter bundle, Wayland session, and portal
configuration. `/etc/denial/outputs.conf` is the administrator-controlled
output template. On first launch, `denial-session` copies it to
`$XDG_CONFIG_HOME/denial/outputs.conf` (or
`$HOME/.config/denial/outputs.conf`) with user-only permissions. Denial and
display-control clients such as `nwg-displays` persist changes to that
per-user file through Denial's atomic output-control transaction.

`/etc/denial/session.conf` remains machine configuration. Both files below
`/etc/denial/` are package backup files and survive upgrades. An explicit
`DENIAL_OUTPUT_CONFIG` override must name a readable regular file in a
directory writable by the session user; this is required for persistent
display changes. The package launcher selects the desktop shell by default.
Set `DENIA_SHELL_PROFILE=mobile` in `session.conf` only for an explicit
mobile-shell development session.

Run `denial-session --check` from an existing desktop for an installation and
hardware preflight. It initializes the per-user output configuration when it
does not exist. To start Denial, log out, choose **Denial** in the display
manager, and sign in.

## First-party repository

The staged public-alpha workflow publishes a signed x86-64 repository at:

```text
https://denialwm.github.io/denial/x86_64
```

It remains dormant until public visibility, Pages enablement, and the first
signed version tag are complete. The exact user setup is in
[INSTALL.md](INSTALL.md). The operator key boundary, backup, tag-signing,
rotation, and revocation procedure is in [SIGNING.md](SIGNING.md).

The completed local package validation is recorded in
[VALIDATION.md](VALIDATION.md). The public-alpha contract and later hardening
stages are defined in [PUBLISHING.md](PUBLISHING.md). Every trusted push to
`main` can produce the unsigned, independently checked candidate documented in
[MAIN_VALIDATION.md](MAIN_VALIDATION.md).
