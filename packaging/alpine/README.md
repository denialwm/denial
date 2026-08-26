# Alpine Linux package adapter

Alpine 3.24 is runtime-tested on x86-64. Denial's release pipeline publishes
the `denial` and `denial-flutter-engine` APKs as direct GitHub Release
downloads with adjacent OpenPGP signatures. A native RSA-signed APK repository
is not published yet. This adapter consumes the same staged glibc payload as
the Debian and Fedora adapters and makes the Alpine-specific musl compatibility
boundary explicit.

The supported entry point is:

```sh
tools/denial-pc alpine-package
```

On the CachyOS Actions runner, `tools/package-denial-apk` verifies the pinned
Alpine 3.24.1 minirootfs checksum, enters it through rootless Bubblewrap,
installs the declared build tools, and runs `abuild` with networking disabled
during package assembly. The adapter:

- uses Alpine's `gcompat` only for the Denial process and its Flutter engine;
- packages a resolver-symbol bridge for Flutter and a Dart thread-stack
  compatibility constructor, both loaded through `deniald`'s ELF metadata
  rather than inherited `LD_PRELOAD` state;
- installs and enables a one-shot OpenRC runtime-directory service without
  restarting the active session, plus a standalone user-D-Bus wrapper whose
  polkit agent waits for Denial's Wayland socket before starting; and
- declares `font-noto`, `font-noto-cjk`, and `font-noto-emoji` as hard runtime
  dependencies.

The font dependencies are intentional.  Denial ships JetBrains Mono for its
specialized system-bar typography, but ordinary shell text comes from
Fontconfig.  Alpine's minimal installation has no default system font and APK
has no weak `Recommends` tier.  Installing the eventual `denial` APK must
therefore install Latin, Simplified Chinese, and emoji coverage in the same
transaction; users must not need a separate font command or an ad-hoc font
download.

Branch validation retains both the unsigned APKs and a separately hashed
Alpine-adapted payload. Signed-tag promotion consumes that prepared payload,
runs only `abuild rootpkg` under the repository's no-compilation guard, adds
the tag-derived runtime version, and proves that the compiled files did not
change. A separate hosted job uses `apk-tools` to validate metadata and solve
the complete Alpine 3.24 dependency transaction before publication.

Clean installation, upgrade/config preservation, and the graphical-session
matrix are recorded in [VALIDATION.md](VALIDATION.md).

Alpine splits Kitty's display backends out of its base package.  Installing
`kitty` alone exposes its desktop entry but cannot open a window; use
`kitty-wayland` when selecting Kitty as a native Wayland validation client.
Kitty is not a Denial runtime dependency, so the compositor package does not
install a terminal emulator or choose one for the user.
