# Distribution support

Denial targets Linux rather than one distribution. Debian is the first port
because it has been requested most often; the packaging boundary should remain
reusable for other distributions.

## Current limitations

- The Flutter engine, Dart bundle, packages, and CI are currently x86-64 only.
- The Rust compositor is built against the builder's host libraries. The
  current Arch-built binary requires glibc 2.39, so it cannot run on Debian 12;
  Debian 13 can load it, but a future rolling-distribution build could raise
  that requirement again. The Flutter engine itself currently requires only
  glibc 2.18.
- Denial pins Rust 1.95, newer than Debian 13's packaged Rust compiler. A
  Debian builder must provision the pinned toolchain, while the resulting
  runtime package must not depend on a Rust installation.
- The supported graphical-session launcher requires UWSM and systemd/logind.
  UWSM is available for Debian 13 through backports rather than the base stable
  suite, so an ordinary stable installation cannot yet satisfy this path from
  its default repositories alone.
- Native DDC brightness loads libddcutil ABI 5. Debian 13 provides it; Debian
  12 provides ABI 4, so brightness control would be unavailable there even
  after a native compositor rebuild.
- Hardware must expose atomic KMS, GBM/EGL, hardware GLES 3.0 or newer, and a
  renderable format/modifier shared with every active primary plane. This may
  exclude older GPUs and simple virtual-machine display devices independently
  of distribution.

## Debian delivery plan

Use a dedicated Debian development and build machine, with the oldest Debian
release we intend to support as its ABI baseline. Initially this should be
Debian 13 unless Debian 12 is deliberately added to scope.

That machine will build native Debian packages for the locked Flutter engine
and Denial payload. The packages must install a complete usable compositor:
the binaries and Flutter bundle, session launcher and Wayland session entry,
default configuration, portal routing, licenses, and declared runtime
dependencies. Essential session components belong in `Depends`; integrations
whose absence only removes a shell feature belong in `Recommends` or
`Suggests`. UWSM must either be supplied by the same repository or cease to be
a mandatory session dependency before the package can claim installation from
an unmodified Debian stable system.

Validation must start from a clean Debian installation and cover package
installation, display-manager login, logind/libseat handoff, Wayland and X11
applications, lock and unlock, logout, audio, networking, power controls, and
portal screenshot and screencast. Package validation must also inspect ELF
dependencies and reject a glibc requirement newer than the declared Debian
baseline.

## Extensible packaging boundary

The compositor must not branch on distribution names. Follow these rules:

- discover native dependencies through `pkg-config`, stable SONAMEs, D-Bus
  interfaces, and explicit minimum versions;
- use build-time switches only for genuinely optional compiled integrations,
  not to identify a distribution;
- derive installed binary, library, data, session, and manual paths from a
  configurable prefix and `DESTDIR`; a compiled data-root constant may be used
  when it also has standard runtime fallbacks;
- prefer runtime capability detection for optional services and degrade the
  affected feature without preventing compositor startup;
- keep one distribution-neutral payload inventory, with small adapters below
  `packaging/<distribution>/` mapping capabilities to package names and policy;
- build each binary on its oldest supported ABI baseline, then test that exact
  payload on every newer supported release.

This keeps Debian work focused now without turning Debian assumptions into the
next port's limitations.
