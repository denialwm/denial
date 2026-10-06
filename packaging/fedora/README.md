# Fedora package adapter

The Fedora spec is a **source build**: `%build` runs the canonical
`tools/denial-pc` pipeline inside the build chroot (lock-pinned Denial
Flutter fork bootstrap, gn/ninja engine artifacts, Flutter AOT shell and
settings bundles, Cargo release build of the compositor) and installs the
payload trees staged by `tools/stage-denial-runtime` from the tagged Git
source snapshot (`Source0`).

The raw Flutter engine is compiled in the chroot from the lock-pinned fork
sources (`tools/denial-flutter-engine build`, gn/ninja against the engine's
Debian sysroot) and shipped by the `denial-flutter-engine` subpackage; its
generation is pinned by SHA-256 in the source tree, and no external engine
package is required at build time.

## Building with lc (Local-Copr)

Single stage against one local repository (e.g. under `/tmp`):

```sh
lc init --repo /tmp/denial-lc/repo

# The build needs network: %build bootstraps the lock-pinned Flutter and
# Skia forks and toolchains, compiles the engine from the fork sources in
# the chroot, then builds the compositor and the shell bundles.
lc build --source <dir with denial.spec + Source0 tarball> \
    --torepo /tmp/denial-lc/repo --enable-network
```

`lc build` produces both `denial` and its `denial-flutter-engine`
subpackage from the one spec.

The mock chroot needs the host's `mock` (user mode works; note that
setuid `userhelper` must actually gain privileges — under a `NoNewPrivs`
sandbox it silently fails with exit 6). Build dependencies are declared in
the spec (Rust toolchain compatible with `rust-toolchain.toml`, git, ninja,
Python, pkg-config, libinput/libseat/libudev/GBM/GL/EGL development
libraries).

## Building the staged-binary lane

The staged-binary lane remains available for release tooling:

```sh
tools/denial-pc fedora-package
```

It consumes the GLIBC 2.39-gated staging tree shared with the Debian
adapter and runs `rpmbuild` with the payload roots injected as `--define`s
(`denial_payload`, `engine_payload`, ...). Outputs are written below
`$XDG_CACHE_HOME/denial/pc-build/packages/` by default.

The two required packages are `denial-flutter-engine` and `denial`. Clean
Fedora installation, reinstall, configuration preservation, and a real GDM
session are recorded in [VALIDATION.md](VALIDATION.md).

Signed releases attach both RPMs and adjacent `.sig` files to the GitHub
Release. Import `denial-repo-key.asc`, then verify each download with
`gpg --verify PACKAGE.sig PACKAGE` before installation. This is currently a
signed direct-download lane, not a DNF repository or an embedded RPM-signature
claim.
