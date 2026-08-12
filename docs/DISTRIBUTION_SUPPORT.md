# Distribution support

Denial targets Linux rather than one distribution. Arch Linux, CachyOS,
Fedora 44, Debian 13, NixOS 26.05, Void Linux, and Ubuntu 24.04 LTS have
completed runtime validation.

## Architecture support

| Architecture | Working | Binaries available |
| --- | :---: | :---: |
| x86-64 | ✅ | ✅ |
| ARM64 (AArch64) | ✅ | ❌ |

Both architectures are fully supported. The first-party repository and
release pipeline currently publish binaries only for x86-64; ARM64 users build
the same compositor, Flutter engine, and shell from source.

| Distro | Working | Binaries available |
| --- | :---: | :---: |
| Arch Linux | ✅ | ✅ |
| CachyOS | ✅ | ✅ |
| Debian 13 (trixie) | ✅ | ✅ |
| Ubuntu 24.04 LTS (noble) | ✅ | ✅ |
| Fedora 44 | ✅ | ✅ |
| NixOS 26.05 | ✅ | ❌ |
| Void Linux | ✅ | ❌ |

Debian-family and Fedora package adapters consume one byte-identical runtime
staging tree. Signed APT repositories serve Debian 13 and Ubuntu 24.04, and a
signed DNF repository serves Fedora 44; the same packages are retained as
direct GitHub Release downloads. Arch Linux and CachyOS use the signed Pacman
repository. NixOS and Void native adapters remain deferred. The packaging
boundary remains reusable for other distributions.

The first real GDM port and the compatibility requirements it exposed are
recorded in the [Fedora 44 validation](../packaging/fedora/VALIDATION.md).
The older userspace and NVIDIA driver behavior exercised by the next port are
recorded in the [Debian 13 validation](../packaging/debian/VALIDATION.md).
The immutable paths, symlinked desktop entries, and system font discovery
exercised by the third port are recorded in the
[NixOS 26.05 validation](../packaging/nixos/VALIDATION.md).
The runit, elogind, and user-D-Bus lifecycle exercised by the fourth port is
recorded in the [Void Linux validation](../packaging/void/VALIDATION.md).
The Ubuntu desktop stack and hybrid-graphics topology exercised by the fifth
port are recorded in the
[Ubuntu 24.04 LTS validation](../packaging/ubuntu/VALIDATION.md).

## Current limitations

- First-party packages and the public release CI lane are currently x86-64
  only. This is a binary-delivery limitation, not a Denial runtime support
  limitation; ARM64 is fully supported from source.
- The Rust compositor is built against the builder's host libraries. The
  current first-party x86-64 binary requires glibc 2.39, so it cannot run on Debian 12;
  Debian 13 can load it, but a future rolling-distribution build could raise
  that requirement again. The Flutter engine itself currently requires glibc
  2.18 and Fontconfig for distribution-native system-font discovery.
- Denial pins Rust 1.95, newer than Debian 13's packaged Rust compiler. A
  Debian builder must provision the pinned toolchain, while the resulting
  runtime package must not depend on a Rust installation.
- The graphical session requires a logind-compatible seat and session API and
  a user D-Bus. Denial always publishes its discovered Wayland, X11, and
  control endpoints to D-Bus activation. When a systemd user manager owns its
  standard bus name, Denial additionally publishes there and manages the
  packaged graphical-session target; otherwise its launcher process owns the
  compositor lifecycle directly. This supports elogind-based systems without
  making UWSM or systemd a runtime requirement.
- Native DDC brightness loads libddcutil ABI 5 and resolves both display
  metadata and VCP setter APIs by symbol capability. Newer releases publish a
  DRM connector directly. With the stable metadata API in libddcutil 2.2.0,
  Denial correlates the reported I2C bus with DRM sysfs and accepts an EDID
  fallback only when it is unambiguous. The setter similarly supports the
  verification-free entry point added in libddcutil 2.2.6 and the
  ABI-compatible legacy entry point. Debian 13 provides ABI 5; Debian 12
  provides ABI 4, so brightness control would be unavailable there even after
  a native compositor rebuild. Fedora packages the ABI library as
  `libddcutil`, separately from the `ddcutil` command, so its packaging adapter
  recommends its `libddcutil.so.5` capability directly rather than relying on
  the diagnostic command to provide it.
- Hardware must expose atomic KMS, GBM/EGL, hardware GLES 3.0 or newer, and a
  renderable format/modifier shared with every active primary plane. This may
  exclude older GPUs and simple virtual-machine display devices independently
  of distribution.

## Native package delivery

One version-neutral x86-64 build supplies the locked Flutter engine and Denial
payload. The shared staging pass enforces the oldest supported ABI baseline,
currently glibc 2.39 from Ubuntu 24.04, before thin adapters add Debian or RPM
metadata. Package assembly does not require booting the target distribution.
The adapters preserve compiled bytes and independently compare every extracted
file and mode with the staging manifest.

The packages install a complete usable compositor: binaries and Flutter
bundle, session launcher and Wayland session entry, default configuration,
portal routing, licenses, and declared runtime dependencies. Essential session
components belong in `Depends`/`Requires`; integrations whose absence only
removes a shell feature belong in `Recommends` or `Suggests`.

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
