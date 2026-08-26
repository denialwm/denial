<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/branding/denial-dark.svg">
    <img alt="Denial" src="assets/branding/denial.svg" width="768">
  </picture>
</h1>

<p align="center"><strong>A Flutter-native Wayland compositor.</strong></p>

Denial begins with a belief: origin does not have to dictate purpose.

Flutter was created to build application interfaces. Here, it is given a
different life. It owns the desktop scene itself: the shell, its motion, and
the composition of Wayland applications. Flutter is not an overlay placed on
top of another compositor. It is part of the compositor's foundation.

That is the architecture. It is also the meaning of the name.

![The Denial desktop with its settings, system bar, terminal, clock, and audio visualizer](assets/screenshots/desktop.png)

## Flutter at the compositor layer

A conventional Flutter desktop application receives a window from an existing
compositor. Denial goes one layer deeper: `deniald` embeds the Flutter Engine
directly through its native Embedder API, and the Dart shell runs AOT-compiled
inside the compositor process. It is not a Wayland client and does not need
another compositor beneath it.

Rust and Flutter have separate responsibilities:

- Rust, built on Smithay, owns Wayland protocol state, client buffers, input
  devices, focus and grabs, output configuration, DRM/KMS presentation, and
  native resource lifetimes.
- Flutter owns the visible desktop policy: shell layout, windows, system
  surfaces, settings, motion, gestures, and the regions that participate in
  shell interaction.

Wayland client buffers remain native resources. Denial imports their contents
as external textures and places them in the same Flutter scene as the shell
UI. Flutter renders that scene into a desktop-wide GBM atlas; each connected
display scans its own region directly through KMS, without a second compositor
pass over the completed frame.

```text
Wayland clients ──> Rust / Smithay ──> external textures ──> Flutter scene
       input <──── native routing <──── shell hit regions <──────┘
                                                               │
Displays <────────────── DRM / KMS <────────────── shared GBM atlas
```

### Impeller at desktop scale

Denial renders with Flutter's **Impeller** backend by default. That sentence
hides the interesting part: Impeller was designed to render an application
inside a window, while Denial asks it to render the entire desktop into
compositor-owned, rotating GBM framebuffers. Denial's locked Flutter fork
integrates Impeller's GLES path directly with the shared KMS atlas, including
exact embedder FBO presentation, no-target frame handling, preserved partial
damage, native fences, and external-texture lifetime.

This is not a Flutter app using Impeller inside another compositor. Impeller
is part of the compositor's own frame path, from the Dart scene to scanout.
Skia/Ganesh remains in the same engine generation as a compatibility fallback
and can be selected explicitly with `--flutter-renderer skia` or the packaged
`DENIA_FLUTTER_RENDERER=skia` session override.

The native compositor, embedded Flutter shell, and standalone Flutter Settings
client are built as separate runtime parts.
The current shell lives in `dart_shell/` and is loaded with its AOT library,
assets, ICU data, and pinned engine generation as one runtime bundle. Their
platform bridge carries immutable scene state and bounded commands without
giving Dart ownership of file descriptors, Wayland objects, EGL images, or
KMS buffers.

Settings lives in `settings_app/` as a normal Wayland process and communicates
with `deniald` over its versioned Unix control socket. Its rendering workload
is isolated from the compositor's Flutter engine, while Rust remains the sole
authority for persistent and hardware state.

This bundle boundary is also the path toward alternative Flutter shells. As
the compatibility contract stabilizes, a compatible user-provided bundle will
be able to replace Denial's reference shell without replacing the native
compositor beneath it.

## Why Denial

**Denial** is an English word. The name contains **Denia**, followed by one
last letter.

It is a quiet reference to Denia from *Wuthering Waves*. Her story never gives
a simple answer to what she originally was, and that uncertainty is important.
What is clear is that others treated her as an asset: something selected,
shaped, and assigned a purpose that was not her own. She was meant to remain a
vessel. Instead, by observing people and learning to live among them, she grew
a heart and gained the ability to choose what she would become.

Her story reflects Denial's central idea: what something was made to be does
not have to determine what it can become.

## Project status

Denial is a public beta in active development. The supported PC architectures
are x86-64 and ARM64 (AArch64), and the native APIs, Flutter bundle contract,
configuration, and wire protocol may still change before 1.0. The compositor
already runs as a complete Wayland session with Xwayland, multi-output
presentation, native input routing, direct screenshots, and portal-based
screen sharing. Denial's appearance setting also drives one semantic light or
dark shell theme and the standard desktop `color-scheme` and `accent-color`
portal preferences, so portal-aware Wayland applications follow Denial's
committed brightness and resolved custom or wallpaper-derived accent.

## Supported architectures

| Architecture | Working | Binaries available |
| --- | :---: | :---: |
| x86-64 | ✅ | ✅ |
| ARM64 (AArch64) | ✅ | ❌ |

ARM64 is fully supported, but first-party ARM64 binaries are not published
yet. Build Denial from source with an architecture-matched Flutter engine and
shell bundle; see the [build guide](docs/BUILDING.md).

## Supported distros

| Distro | Working | Binaries available |
| --- | :---: | :---: |
| Arch Linux | ✅ | ✅ |
| CachyOS | ✅ | ✅ |
| Omarchy 4.0 | ✅ | ✅ |
| Debian 13 (trixie) | ✅ | ✅ |
| Ubuntu 24.04 LTS (noble) | ✅ | ✅ |
| Fedora 44 | ✅ | ✅ |
| Alpine Linux 3.24 | ✅ | ✅ |
| NixOS | ✅ | ❌ |
| Void Linux | ✅ | ❌ |

The binary column refers to the current first-party x86-64 package set. Omarchy
uses the signed Arch-compatible Pacman packages and is validated with Denial as
its native compositor and desktop session; Omarchy's Hyprland-specific
Quickshell is not part of that compatibility claim. Alpine packages are signed
direct GitHub Release downloads; a native APK repository is not published yet.
NixOS and Void Linux have been tested successfully, but do not have first-party
binary packages yet.

## Live Flutter shell development

The optional `denial-ui-development` binary package is currently available
only through the Pacman repository. It turns the reference shell into an
editable Flutter workspace. `denialctl ui setup` creates the
matching source checkout and starts a JIT shell; opening its `dart_shell` directory in
VSCodium enables hot reload on save and the packaged browser DevTools for
Flutter Inspector and performance profiling while Wayland applications keep
running.

Install it separately when this workflow is wanted:

```sh
sudo pacman -S denial-ui-development
denialctl ui setup
```

The supported editor debug-adapter connection is deliberately non-pausing. It
does not grant breakpoint, pause, stepping, or expression-evaluation control
over the desktop isolate. Browser DevTools connects through the broader VM
service and should be used carefully because pausing the root isolate pauses
the interactive desktop. A native `denialctl ui restore` command returns to
the packaged optimized shell even when edited Flutter code cannot present a
usable Settings window.

## Install

Denial provides signed first-party x86-64 repositories for Arch Linux and
CachyOS, Debian 13, Ubuntu 24.04 LTS, and Fedora 44. Review the
[repository setup script](install.sh), then run:

```sh
sh -c 'if ! command -v curl >/dev/null 2>&1; then echo "Error: curl is not available." >&2; exit 1; fi; curl -fsSL https://install.denialwm.org | sh'
```

It verifies the complete release-key fingerprint, rejects conflicting package
manager configuration, and adds the matching signed repository. It does not
install packages. When setup completes, use only the command for the current
distribution.

**Arch Linux or CachyOS**

```sh
sudo pacman -Syu denial
```

**Debian 13 or Ubuntu 24.04**

```sh
sudo apt update && sudo apt install denial
```

**Fedora 44**

```sh
sudo dnf install denial
```

The package manager pulls in the matching `denial-flutter-engine` package.
The setup script shows its complete plan and asks for confirmation before using
`sudo`.

ARM64 is fully supported from source, but the first-party repositories do not
publish ARM64 packages yet. See [Build Denial](docs/BUILDING.md).

Impeller is the default renderer. If a driver-specific issue requires the
Skia/Ganesh fallback, set `DENIA_FLUTTER_RENDERER=skia` in
`/etc/denial/session.conf` and restart the Denial session.

See the [complete installation guide](docs/INSTALL.md) for per-distribution
trust paths, updates, removal, and manual Pacman setup.

## Documentation

- [Install Denial](docs/INSTALL.md)
- [Arch repository details](docs/packaging/arch/INSTALL.md)
- [Build Denial](docs/BUILDING.md)
- [Session startup and locking](docs/SESSION_STARTUP.md)
- [Control and recover Denial with `denialctl`](docs/DENIALCTL.md)
- [Live Flutter UI development](docs/UI_DEVELOPMENT.md)
- [Architecture](docs/architecture.md)
- [Screenshots and screen sharing](docs/SCREEN_CAPTURE.md)
- [Changelog](CHANGELOG.md)
- [Roadmap](ROADMAP.md)
- [Security policy](SECURITY.md)
- [Beta contribution policy](CONTRIBUTING.md)
- [Complete documentation index](docs/README.md)

## Made through dialogue

Denial was conceived, architected, directed, and tested by its human creator,
Doctor Logix, and developed in continuous collaboration with OpenAI Codex. Its
initial implementation was generated through that collaboration rather than
written manually by its creator.

The project's purpose, architecture, design principles, and final technical
decisions came from the human side. Codex investigated the codebase, proposed
solutions, implemented features, analyzed failures, and refined the system
through an ongoing dialogue. Every result was evaluated against real hardware
and redirected whenever it failed to match the intended design or performance
expectations.

This is part of Denial’s origin, not a disclaimer hidden in a footnote.

Authorship is more than typing source code. Denial exists because a person
decided what should exist, defined how it should work, recognized when the
implementation was wrong, and kept directing the process until the idea became
a functioning system.

## License

Denial's original source code is licensed under
[GPL-3.0-or-later](LICENSE). Bundled third-party components and media retain
their own licenses and attribution notices.
