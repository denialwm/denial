# Alpine Linux 3.24 runtime validation

This records a development runtime validation on Alpine Linux 3.24.  It is not
a claim that Denial currently publishes a first-party APK repository.  The
test deliberately uses Alpine's musl userspace and OpenRC/elogind session model
with Denial's distribution-neutral x86-64 glibc payload.

## Installation provenance

- official `alpine-minirootfs-3.24.1-x86_64.tar.gz`, released 2026-06-13;
- SHA-256
  `41f73e3cf5fa919b8aa5ca6b30dc48f0da2720776d7423e2a7748211456fe081`;
- detached signature verified with Alpine's official release key fingerprint
  `0482 D840 22F5 2DF1 C4E7 CD43 293A CD09 07D9 495A`;
- Alpine Linux 3.24.1 packages and Linux LTS `6.18.44-r0`;
- isolated 32 GiB thin LV `/dev/denial_lab/alpine324`, ext4 UUID
  `0889c2f0-ab36-481e-89cd-773232663dc4`.

The test root remains isolated from the host installations.  A shared Limine
installation loads copies of Alpine's kernel and initramfs from the Denial lab
boot partition.

## Boot boundary

Limine URI fragments are **BLAKE2b-512**, not SHA-512.  Both algorithms happen
to print 128 hexadecimal characters, so visual length is not a useful check.
Generate each suffix with:

```sh
b2sum -l 512 FILE
```

Immediately before every reboot, recompute the staged kernel and initramfs
values independently and compare them byte-for-byte with `limine.conf`.  The
validated artifacts used these BLAKE2b-512 values:

```text
vmlinuz   b7d8ebc63d86dd381444d3d1a7129d55cac06be97edff62e434c8e3cada5f6ccdee642bdf220717bbffdba1add9c73b3f2a917346e80626049d7b3e9a8b38028
initramfs 989f644646222d4e6e2389e686bc33ed847ac6070f9baa668e5675debb03d48b982a644044ab45444510875737e2fa1fcc83ed067cd00eda6b3fefe28c0badd7
```

Using SHA-512 produces Limine's `hash for URI does not match!` failure before
Linux starts.  This rule is also recorded in the repository's `AGENTS.md`
because it applies to every shared Denial lab entry, not only Alpine.

Alpine's initramfs must include `dm-thin-pool.ko` and
`/usr/sbin/thin_check`; the latter comes from `thin-provisioning-tools` and was
added through a dedicated mkinitfs feature.  Without it, activation stops
before mounting root.

The kernel command line uses the persistent mapper path:

```text
root=/dev/mapper/denial_lab-alpine324 rootfstype=ext4 rw quiet reboot=efi
```

Although `nlplug-findfs` locates the ext4 UUID correctly, passing the transient
`/dev/dm-N` name it observed to BusyBox mount raced device-mapper enumeration.
That appeared as a missing `/dev/dm-9` on successive boots.  The stable mapper
path avoids encoding an enumeration result while retaining the UUID in the
filesystem metadata and installation record.

## Session model

OpenRC starts eudev, D-Bus, elogind, seatd, NetworkManager, and greetd.  Greetd
establishes the PAM/elogind session on VT 7 and launches
`denial-alpine-session`.  That wrapper owns a standalone `dbus-run-session`,
starts PipeWire, WirePlumber, the PulseAudio compatibility server, and the
polkit-gnome authentication agent from Alpine's `/usr/lib/polkit-gnome`
installation path, then executes the normal packaged `denial-session`
launcher.  The agent is held until Denial publishes its Wayland socket; GTK
cannot initialize the agent before a display exists.  Startup output is
retained in `~/.local/state/denial/alpine-session.log`, including failures that
greetd would otherwise leave only on its VT.

Greetd creates `/run/greetd.run` after attempting `initial_session`.  The
marker deliberately survives a service restart for the rest of that boot, so
an ordinary `rc-service greetd restart` falls back to agreety instead of
autologging in again.  Validation restarts that specifically need a fresh
one-shot Denial session must stop greetd, remove that volatile marker, and then
start greetd.  This is a test-host operation, not package installation policy;
the marker disappears naturally when `/run` is recreated at boot.

`denial-session` finds no active systemd user manager and therefore selects
its already-supported `launcher process` lifecycle.  No Alpine distribution
branch was added to the compositor or launcher.  The package's one-shot
`denial-runtime-dirs` OpenRC service creates `/tmp/.X11-unix` as root with mode
1777 before rootless Xwayland starts.

The login user must be authorized for the `seat` group.  The package does not
guess which local accounts should receive direct device access.

## Password-hash boundary

Alpine's musl `crypt` and its `pam_unix` stack do not verify the `$y$`
yescrypt hash copied from the CachyOS account used to provision this lab.
That made a correct password appear incorrect in Denial's lock screen even
though the account was enabled and PAM was connected.  Running Alpine's own
`passwd` for the account generated the configured `$6$` SHA-512 hash; unlock
then succeeded with the same password.  Installers must create or update
passwords through Alpine's native account tools rather than copying a shadow
hash from a glibc distribution.

## glibc payload on musl

Alpine's official `gcompat` package provides the glibc loader and common ABI
surface, but the validated Flutter/Dart runtime exposed two narrower gaps:

1. Flutter refers to glibc's `__res_init`, while musl exposes the equivalent
   `res_init` entry point and gcompat 1.1.0 does not bridge that spelling.
2. Dart's stack-headroom check assumes substantially larger stacks than musl's
   defaults.  The main isolate aborted before the first Flutter frame, and
   newly created worker threads would have inherited the same small default.

The Alpine adapter builds two small, source-owned shared objects.  One bridges
`__res_init` to musl's `res_init`.  A constructor in the other touches a 1 MiB
main-thread reserve and sets the default pthread stack size to 8 MiB before
Dart initializes.  They are installed below `/usr/lib/denial/alpine` and added
only to `deniald`'s `DT_NEEDED` list with a private runtime search path.
Applications launched by Denial do not inherit an `LD_PRELOAD` workaround.

## Native Kitty package split

Alpine packages Kitty's executable, Wayland backend, and X11 backend
separately.  The base `kitty` package installs `kitty.desktop`, so application
discovery succeeds even though that package alone cannot create a window.  A
native Wayland validation install must select `kitty-wayland`, which pulls the
base package and supplies `/usr/lib/kitty/kitty/glfw-wayland.so` in the same APK
transaction.  Kitty remains a validation client rather than a Denial runtime
dependency.

## Font package contract

The minimal Alpine rootfs contains Fontconfig but no installed font files.
Denial bundles JetBrains Mono only for specialized system-bar typography;
ordinary shell text is deliberately resolved through the host's Fontconfig
catalog.  With an empty catalog, the lock screen and shell therefore had no
usable default face.

Alpine APKBUILD metadata has no weak `Recommends` tier.  The `denial` APK
therefore requires all three official packages:

- `font-noto` for Latin UI text;
- `font-noto-cjk` for Denial's supported Simplified Chinese locale and the
  `Noto Sans CJK SC` fallback family; and
- `font-noto-emoji` for color emoji and status glyph fallback.

An `apk add --simulate` transaction on the validation host proved that adding
the Denial and exact-matching engine APKs selects those packages, plus Noto's
common, math, and symbols dependencies, without a separate font command.
Fonts must not be copied into `/usr/share/fonts` or downloaded ad hoc during
installation.

## Validated runtime

The physical `.18` hybrid-graphics host reached a direct Denial session with:

- an active PAM/elogind `seat0` session on VT 7;
- AMD Radeon 890M atomic KMS driving the internal `1920x1200` panel at
  `144.004 Hz`;
- Impeller OpenGL ES and Denial's four-buffer native-fence atlas;
- a live `deniald` process, control socket, `wayland-1`, and rootless Xwayland;
- `denial-session --check` passing compositor, control client, Flutter bundle,
  output configuration, DRM/render device, desktop profile, Impeller, and
  Xwayland checks;
- package-owned Noto Latin, Simplified Chinese, and color-emoji resolution;
- successful lock-screen authentication after Alpine-native password hashing;
- native Wayland Kitty 0.47.0 with Alpine's `kitty-wayland` backend, including
  user-configured background opacity;
- activation of `xdg-desktop-portal`, its GTK backend, and its wlr backend,
  exposing 21 desktop portal interfaces;
- a live polkit-gnome authentication agent attached after Denial published its
  Wayland socket;
- NetworkManager Wi-Fi, DNS, and SSH connectivity; and
- PipeWire, WirePlumber, Pulse compatibility, an analog sink/source, and
  RTKit-backed compositor/display/raster priority elevation.

The resulting Alpine desktop is captured in
[the Alpine 3.24 screenshot](../../assets/screenshots/alpine-3.24.png).

Package installation, upgrade, configuration preservation, native Wayland
launch, portal activation, fonts, audio, networking, and lock/unlock are
proven. Branch CI now builds in a checksum-pinned Alpine minirootfs on the
CachyOS runner, retains the adapted payload, and verifies the APK extraction
independently. Signed-tag promotion repackages that payload without compiling
it, and publication exercises Alpine's dependency solver before attaching the
OpenPGP-signed direct downloads.

A clean-image repeat, an explicit X11 client round trip, portal screencast
completion, and a native RSA-signed APKINDEX remain. The current first-party
lane is therefore a signed direct-download public beta, not an Alpine package
repository.
