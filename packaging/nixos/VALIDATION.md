# NixOS source package and module validation

Validated on 2026-09-18. This record covers the first-party Nix source build,
module integration, package contracts, and non-visual runtime health. Visual
validation remains user-owned and was not performed.

## Test system

- Host: dedicated unattended validation machine `192.168.1.18`
- Distribution: NixOS 26.05.7443.70cc4559b10a
- Kernel: Linux 7.1.8
- Architecture: `x86_64-linux`
- Session: GDM Wayland session with systemd/logind autologin
- Display hardware: AMD-driven internal eDP panel; NVIDIA PRIME/offload device

The host imports `denial.nixosModules.default` and uses the package from
Denial's locked flake input. GDM selection and autologin remain explicit host
policy rather than module policy.

## Source build and checks

The following completed successfully from the repository staging tree:

```sh
nix flake check --no-build --print-build-logs
nix flake check --print-build-logs --cores 10
tools/denial-nix verify-locks
sudo nixos-rebuild switch --cores 10
```

The initial source build compiled Denial's locked Flutter engine in 7,221
Ninja steps, then built the Dart shell, Settings, and Rust workspace. No Denial
release binary was downloaded or repackaged. Later validation reused those
content-addressed engine and Flutter outputs.

The Rust package runs its release-profile checks instead of disabling them.
All 241 runnable workspace tests passed. The one ignored test is the existing
isolated-bundle ABI test, whose own diagnostic directs maintainers to
`tools/denial-pc engine-test-check`.

The Nix checks additionally covered:

- exact agreement between both application `pubspec.lock` files and their
  generated Nix JSON, plus the locked Flutter tool input;
- agreement between `SOURCE_LOCK.json`, the engine revision, and every
  non-placeholder fixed-output hash in `nix/flutter-engine-lock.json`;
- enabled and disabled PolicyKit-agent and DDC/I2C module configurations;
- the absolute Zenity wlr-portal chooser command;
- installed launcher, desktop, D-Bus, portal, and systemd path contracts;
- Home Manager-style output-config symlinks, persistence of live writable
  state, and reset when declarative input changes;
- preservation of the Settings GTK launcher environment;
- absence of `/usr/bin/denial*` integration paths and
  `flutter-engine-toolchain` from the complete runtime closure;
- preservation of Denial's runtime EGL, PAM, PulseAudio, and DDC library
  search paths after Nix ELF fixup.

Branch validation now evaluates all flake outputs and builds the lock and
module checks on a GitHub-hosted Nix runner. The full source package remains a
deliberate local/self-hosted build because it includes the custom Flutter
engine.

## Resource and closure measurements

This 2026-09-18 validation predated the public Denial Cachix integration, so
its first system build exhausted the test host's 48 GiB thin root volume while
materializing the engine source, build, and system closures. Its existing
NixOS logical volume was extended online to 64 GiB. This is why the
installation guide still recommends at least 64 GiB of free builder working
space for a cache miss instead of describing the build only as “substantial.”

The composed package occupies approximately 105 MiB itself. Replacing the
Settings engine library's synthetic toolchain RUNPATH with direct runtime
library paths reduced the installed runtime closure from approximately
1.08 GiB to 596.0 MiB. The standalone Settings closure is 346.9 MiB, and
neither it nor the composed closure retains `flutter-engine-toolchain`.

## Installed-path and configuration contracts

`denial-session` resolves its own installed prefix and exports exact
package-relative compositor, control-client, Settings, Flutter-bundle, and
packaged-default paths. No `/usr/bin` compatibility links are required.

The final Settings launcher is the original Nix GTK wrapper retargeted to the
composed package. It retains `GIO_EXTRA_MODULES`,
`GDK_PIXBUF_MODULE_FILE`, and GSettings schema paths through
`XDG_DATA_DIRS`.

An ordinary writable `$XDG_CONFIG_HOME/denial/outputs.conf` remains direct
mutable state for backward compatibility. A symlink or read-only file is a
declarative source copied to `$XDG_STATE_HOME/denial/outputs.conf`; Denial may
write the state without mutating the source. State survives launches while
the source is unchanged and is refreshed when that source changes. When no
per-user source exists, `/etc/denial/outputs.conf` follows the same model, so
later NixOS rebuilds propagate.

Unreleased packages use a source-derived `0.0.0+git.*` or `0.0.0+src.*`
package version and compile the corresponding `nix.git.*` or `nix.src.*`
build identity into the binaries. `deniald --version` therefore identifies
the exact candidate instead of reporting only `development`; no semver
release file is synthesized, preserving the tag-only release-version policy.

## Runtime activation

After `nixos-rebuild switch`, the Denial session was restarted through GDM as
required for the agent-managed `.18` host. A new `deniald` process ran from
the activated source package, and its mapped Flutter engine came from that
same package prefix.

Post-activation checks confirmed:

- GDM, `deniald`, `denial-session.target`, `denial-portal.service`, and the
  default `denial-polkit-agent.service` were active;
- no system or user units were failed;
- `hardware.i2c.enable` was active and the session user had the resulting
  I2C device-access integration;
- the generated wlr portal configuration contained the absolute Nix-store
  Zenity chooser rather than an empty or packaged-but-bypassed config;
- the portal and control sockets were listening;
- `denial-session --check` resolved package-local binaries and Flutter assets;
- transient `MissingAuthorization` backing-store retries occurred during the
  GDM KMS handoff; they stopped immediately after startup, and the delayed log
  contained no panic or further compositor error.

Rendered output and interactive screen sharing were not triggered or judged
by the agent.
