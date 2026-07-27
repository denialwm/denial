# Arch Linux packaging

Build Denial and create the two required Pacman packages from the current
working tree:

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

Live Flutter UI editing is provided separately so normal installations do not
carry a development toolchain. Build the optional package with:

```sh
cargo xtask ui-development-package
```

This writes `denial-ui-development` to the same package directory. Install it
only after the matching required pair:

```sh
sudo pacman -U \
  /path/to/denial-ui-development-*.pkg.tar.zst
```

The optional package requires the exact
`denial-flutter-engine-abi=3.44.7.denial1` generation and contains the pinned
JIT engine, Dart and Flutter tools, Denial's locked UI dependency sources, a
version-matched editable source snapshot and revision metadata, native
`denial-ui` client, metadata, and licenses. Its build and validation workflow
is documented in [UI development](../../UI_DEVELOPMENT.md).

Development packages use a VCS-derived version. The public release workflow
accepts only a clean signed `vMAJOR.MINOR.PATCH` tag matching both project
version files and emits `pkgrel=1`.

Pacman owns the compositor, native control client, Flutter bundle, Wayland
session, and portal configuration. `/etc/denial/outputs.conf` is the
administrator-controlled output template. On first launch, `denial-session`
copies it to `$XDG_CONFIG_HOME/denial/outputs.conf` (or
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
manager, and sign in. Once the session is running, use `denialctl status` for
a native compositor and Flutter UI health summary.

The packaged display-manager entry starts unlocked because that path already
authenticated the user. Direct or autologin startup must opt into the native
startup lock with `denial-session --start-locked`; the complete policy and
launcher examples are documented in
[Session startup and locking](../../SESSION_STARTUP.md).

## First-party repository

The public-alpha workflow publishes a signed x86-64 repository at:

```text
https://denialwm.github.io/denial/x86_64
```

The repository is active. Each release contains the two required runtime
packages and, beginning with Denial 0.2.0, the optional
`denial-ui-development` package. The exact user setup is in
[INSTALL.md](INSTALL.md). The operator key boundary, backup, tag-signing,
rotation, and revocation procedure is in [SIGNING.md](SIGNING.md).

The completed local package validation is recorded in
[VALIDATION.md](VALIDATION.md). The public-alpha contract and later hardening
stages are defined in [PUBLISHING.md](PUBLISHING.md). Every trusted push to
`dev` or `main` can produce the unsigned, independently checked candidate
documented in [BRANCH_VALIDATION.md](BRANCH_VALIDATION.md).
