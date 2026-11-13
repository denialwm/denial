# Changelog

This file records user-visible changes to Denial. Denial is currently a public
beta: native APIs, the Flutter shell contract, configuration, and package
boundaries may change before 1.0.

## [Unreleased]

### Added

- An app size apart from the shell's (`apps.scale`, 1 to 3). Apps opened
  after a change draw that many times larger than the screen's scale, at full
  sharpness; X11 apps follow through their DPI. The shell and Droidloom keep
  the screen's scale, and so do clients that make layer surfaces, such as
  panels.
- Packages for ARM64 (AArch64). The Pacman, APT and DNF repositories carry
  `denial`, `denial-flutter-engine` and `denial-plugin-manager` for ARM64
  beside x86-64, and each machine downloads only its own architecture. The
  setup script configures ARM64 machines, Arch Linux ARM included. Alpine
  packages stay x86-64.
- A phone running the mobile shell keeps working as a phone when a monitor is
  plugged in: the monitor runs the desktop shell beside it. Apps open on the
  screen they were started from. A recents card's monitor button, or opening
  the app from the monitor's launcher, moves an app to the monitor; dropping
  a window on the phone's screen, or opening it from the phone, brings it
  back. With the monitor in use the power button turns off only the phone,
  each screen dims on its own, and unplugging moves the monitor's windows to
  the phone until it returns. The monitor has its own roundness
  (`appearance.monitorCornerRadiusScale`) and its own wallpaper, placed and
  zoomed apart from the phone's (`outputZooms` in the wallpaper file). See
  [docs/PHONE_AND_MONITOR.md](docs/PHONE_AND_MONITOR.md).
- Color management. Output buffers are 10-bit where the display planes allow
  it, and each display gets the desktop converted from sRGB to its own gamut,
  read from its EDID. `denialctl color correction off` and `on` compare a
  display with and without it. Screenshots and screen capture stay sRGB.
- `denialctl color lut load FILE.cube` grades the whole desktop with a 3D LUT,
  and `denialctl color app APP_ID lut load FILE.cube` grades one app's
  windows. Display color settings are saved and applied again at the next
  start.
- HDR on displays whose EDID offers PQ. `denialctl color hdr OUTPUT on`
  switches the output to BT.2100 with SDR content at a chosen white (203 cd/m²
  by default), and HDR windows keep the display's headroom. `srgb` is for
  displays that ignore BT.2020 and show PQ with sRGB primaries.
- Apps can describe their colors through `wp_color_management_v1` and
  `wp_color_representation_v1`; Denial converts tagged windows into the
  desktop's colors.
- A color tuning panel, opened with Super+Alt+P or `denialctl color tune`,
  grades the desktop or a tapped app live: lift, gamma and gain wheels and
  exposure, contrast, saturation, vibrance, warmth and tint sliders, over a
  base look from `~/.local/share/denial/luts`. It has built-in looks (Warm,
  Cool, Logix, Matte, Film, Night and Mono), shows the target ungraded while
  Before is held, and saves on release.
- Mouse & touchpad settings can switch mouse acceleration off, which gives
  libinput's flat pointer profile.
- `zwp_input_timestamps_v1`: clients get libinput's microsecond time for each
  key, pointer and touch event.
- `denial_keyboard_inset_v1` lets an app follow the on-screen keyboard's
  height as it opens, closes and is dragged, and lay itself out around the
  keys instead of being moved above them.
- Input deck: a touch display can become a full-screen keyboard and touchpad
  for the desktop shown on another display.
- Remote desktops, virtual machines and other apps that ask for it through
  `zwp_keyboard_shortcuts_inhibit_v1` can now receive Super and Denial's other
  shortcuts while they have focus. Denial asks first: Allow once, Always allow,
  Decline once or Never allow. The pointer release shortcut (Super+Escape by default), VT
  switching, the emergency exit and the volume and brightness keys stay with
  Denial, and the release shortcut gives the shortcuts back until the app is
  focused again.
- Settings has a Permissions page. It lists the apps that asked for Denial's
  keyboard shortcuts and sets each to Ask, Always allow or Never allow,
  effective at once.
- `denial-portal` now implements `org.freedesktop.impl.portal.Access`, so
  portal permission questions, such as camera access for sandboxed apps,
  appear in Denial's own dialog.
- Notifications stay until they are closed, are grouped, and open their app
  on tap. A notification alerts once; an update alerts again only when its
  summary, body or image changed.
- The mobile keyboard is rewritten. Each touch goes to the key whose area
  holds it, gaps and edges included, and a strip above the keys suggests
  words. Space or punctuation corrects a mistyped word and the next Backspace
  takes the correction back; a long press on a vowel offers its accents, and a
  double tap on Shift locks capitals. English is built in; another language
  turns on when `denial/dictionaries/<language>.words.gz` is installed in a
  data directory.
- The mobile lock screen asks for a six-digit PIN; a PIN of 4 to 12 digits set
  earlier keeps working until it is changed. Fingerprint unlock needs that PIN,
  shows scan feedback and retries at once after a rejected scan. The SIM PIN is
  asked on the lock screen's own keypad, the newest notifications show there
  and swipe away, and a double tap turns the screen off. An account with no
  password, PIN or fingerprint still locks, and opens with a swipe.
- Always-on display for the mobile shell, on panels that keep showing their
  last frame while the output is off. `/etc/denial/ambient-display.json` names
  the output; the locked phone then shows the time, the date, the wallpaper's
  subject and the fingerprint mark on black, and the clock moves on each
  minute.
- With Phonewave's optional `wallpaper-depth` program installed, the lock
  screen draws its clock behind the wallpaper's subject. The mask is made in
  the background when the wallpaper picker closes and kept for that file.
- The mobile shell moves as one app deck: opening, switching, recents and
  going home follow the finger and settle with its speed, and apps open from
  their icon. The volume indicator, quick settings tiles, toggles and sliders
  move like liquid.
- On the mobile shell, Power plus Volume Down takes a screenshot.
- The shade has a Screen recording tile when Phonewave's `screen-record` is
  installed, and the shell's clocks can show 24-hour time.
- The mobile home screen keeps its own layout for portrait and for landscape,
  and in landscape its cells shrink to fit and the keyboard gets taller rows.
- On the mobile shell an app that asks for full screen gets the whole screen
  and the status bar steps aside; a swipe down from the top edge still opens
  the shade.
- Wallpapers can be zoomed in, from 1 to 4 times, about their alignment point.

### Changed

- Output views are composed from retained slices by default.
- Client buffers are released as soon as the last frame that sampled them is
  done. Denial follows upstream Smithay instead of a fork.
- An idle Denial wakes far less often. deniald, the polkit agent, the X11 tray,
  the lock check and the input device scans wait for events instead of
  polling, and shell telemetry and the thread priority guard sleep while the
  outputs are off.
- While any screen is lit, Denial holds Wi-Fi power save off on drivers that
  offer `power_save_allowed`, so a reply after a quiet gap no longer waits for
  the chip to wake. Power save comes back once every screen is dark.
- Minimized mobile windows pause, and on the mobile shell every app stays
  suspended while the session is locked.
- On the mobile shell the power button only turns the screen off and on.
- Auto-rotation follows Phonewave's `steinerd` (`org.steinerd.Sensors1`)
  instead of iio-sensor-proxy.
- Do not disturb, lock-screen previews, waking the screen for notifications,
  keyboard vibration and fingerprint unlock are keys in the settings
  document; the separate notification-policy file is gone. On a phone,
  `idleLockEnabled` turns locking on or off and `screenOffLockDelaySeconds`
  sets how long a dark screen stays unlocked.
- In landscape the mobile shade shows notifications and quick settings side
  by side, each one and a half phones wide, with quick tiles one and a half
  times as tall. Recents is the same row of cards as in portrait, overlapping,
  newer over older, so a swipe crosses them faster. The card in the middle
  follows the finger while newer cards travel faster and older ones slower
  and smaller, so the stack moves as it scrolls.
- A notification in the mobile shade or on the lock screen swipes away
  toward the start edge only.
- The mobile home screen starts with one page; empty pages after the last
  icon no longer count.
- A phone or tablet in landscape, or any tablet, locks with the mobile lock
  screen and its PIN pad. The desktop lock screen is for desktop view and a
  second screen. In landscape the PIN pad stays up in the last third, beside
  a larger clock and the notifications, and the fingerprint works until a
  PIN is being typed.

### Removed

- The Skia renderer. Denial engines are Impeller-only Slimpeller builds, and
  deniald no longer accepts `--flutter-renderer`; `denial-app` no longer
  accepts `--renderer`.

### Fixed

- Qt and other Xlib apps under Xwayland are scaled: Denial also sets
  `Xft.dpi` in the X resources, which they read instead of XSETTINGS.
- A quick flick in mobile recents reaches the next card however short it
  is; it no longer springs back unless the finger slows before release.
- An app opening from its icon lets the icon go before it is twice its size,
  on a tablet as on a phone, not several times larger.
- Plugin Manager no longer reports a job as interrupted while its worker is
  still starting.
- On a large mobile screen the first row of home icons opens again: the
  closed status bar no longer takes touches below its own height.
- Logging in to Denial from LightDM no longer drops back to the greeter with
  "libseat did not activate the current TTY session". Display managers that
  start the session before logind activates it are now waited for, also with
  libseat 0.8 (#185).
- Returning to full brightness, and quitting Denial, restore the display's
  original gamma LUT instead of leaving the output dimmed (#176).
- When the session ends, Denial gives the systemd user manager back the
  environment it replaced, so a later Plasma login no longer waits about two
  minutes on the portal (#152).
- A monitor that disconnects while it sleeps no longer disconnects every
  Wayland client, Xwayland included, with "Invalid binding of wl_output".
- A client that renders faster than the display no longer stalls on buffers
  Denial held; Denial keeps only its newest frame.
- Coming back from another VT no longer logs "could not acquire Flutter
  embedder backing store ... MissingAuthorization".
- An output no longer stays black after a frame ends without presenting.
- When a shell bundle refresh fails, Denial starts the shell again.
- Presentation times stay in order on drivers that repeat the previous
  completion timestamp, such as msm.
- With Fcitx, a modifier released after the input method dropped its grab no
  longer stays held.
- The Plugin Manager runs with the Dart SDK it was built with, not whichever
  Dart comes first on `PATH`.
- Android apps under Droidloom no longer show a notification twice after it
  times out.
- Started through UWSM, Denial finds its logind session: `loginctl
  lock-session` locks it, logind sees whether it is locked, and it no longer
  retries the lookup every two seconds.

## [0.5.1] - 2026-10-11

Everything since 0.2.6. Releases 0.3.0 through 0.5.1 each published this
section as it stood at their tag.

### Added

- Denial can now compose its Flutter shell from typed built-in and external
  plugins. The optional `denial-plugin-manager` package provides the graphical
  manager, CLI, version-matched compiler kit, validated Apply/recovery flow,
  and Git-based installation without publishing Denial SDKs on pub.dev.
- After a Denial update, your plugins now come back on their own. Denial keeps
  them and their settings, rebuilds them for the new release in the
  background while its standard desktop runs, and switches back at a quiet
  moment without a logout. One notification follows the rebuild; if it cannot
  finish, it explains why and offers Try again, Check for updates, and Open
  Plugins, and it waits for a network connection when downloads are needed.
- Plugins now discovers the public `denialwm/denial-plugins` collection by
  default. Its first entry is the independently installable Windows-style
  Taskbar; catalog discovery never installs or enables a plugin automatically.
- Mouse & touchpad settings can now tune the scrolling layout's continuous
  three-finger swipe speed independently from two-finger content scrolling.
- Workspace transitions can now move horizontally or vertically, and
  four-finger workspace gestures work on either axis.
- Systemd-managed Denial sessions now launch standard XDG desktop autostart
  entries after the compositor and its discovered display endpoints are ready.
- Settings can configure environment variables for applications launched by
  Denial, globally or for a selected desktop application. Rust validates and
  atomically persists rules keyed by standard desktop-file IDs; variables can
  be set, set to an empty string, or removed without changing the compositor
  or systemd activation environment. Shortcut Application targets preserve the
  same identity and receive the selected application's rules.
- End-to-end fractional display scaling now keeps Flutter, native Wayland clients, and Xwayland sharp and consistently sized.
- `Super+Shift+S` now opens a compositor-native region screenshot workflow with direct Wayland screencopy support.
- Shortcuts can now toggle the focused window's always-on-top state in both
  stacking and managed layouts.
- Settings now runs as a built-in local Flutter application that can be launched from the desktop and mobile home surfaces.
- Mobile mode now has a dedicated wallpaper browser with preview, drag positioning, fine alignment controls, and per-display targeting.
- Simplified Chinese localization and a live language selector are now available throughout the shell and Settings.
- Appearance settings now include live wallpaper selection and physical cursor-size controls.
- The desktop system bar now hosts StatusNotifier/AppIndicator items and
  legacy XEmbed tray icons, including menus and pointer actions.
- Alpine Linux 3.24 is now a supported x86-64 package target, with native APK
  packages, OpenRC session integration, installation documentation, and a
  no-compile release-promotion path.

### Changed

- The reference desktop, top bar, launcher, and clock are first-party plugins
  built against the extracted `denial_sdk` and `denial_flutter_sdk` contracts.
  Release validation now builds and verifies the separate Plugin Manager for
  Pacman, APT, DNF, Alpine direct downloads, and Nix.
- Denial environment variables now prefer the consistent `DENIAL_*` prefix
  while accepting every existing `DENIA_*` spelling as a compatibility alias.
- Clipboard history now provides searchable text, image and file cards, drag-to-drop actions, privacy states, and accessible controls.
- KMS and rendering devices can now be selected independently, with automatic display-owned scanout allocation for split-GPU hardware.
- Flutter frame delivery now uses stricter backpressure, preserved logical damage, kernel presentation timing, and safer multi-output buffer ownership.
- The shell keyboard now routes text editing and native key actions correctly between local Flutter surfaces and Wayland clients.
- Window content rendering now cleanly separates embedded Flutter applications from compositor-supplied Wayland textures.
- Distribution guidance now documents a reusable packaging boundary and an initial Debian delivery plan.
- Branch and release validation now build and independently verify Alpine APK
  payloads in a pinned Alpine minirootfs on the CachyOS runner.

### Fixed

- KMS-only compositor builds now keep shared hotplug and Wayland behavior
  available without the Flutter shell, and scheduler setup supports musl's
  extended `sched_param` layout.
- Installed sessions now detect VMware `vmwgfx` render devices and select
  Mesa's KMS software renderer before GBM/EGL initialization, avoiding an
  immediate compositor abort when accelerated EGL is unavailable.
- Switching to a workspace with no focus history now activates a visible
  window, so focused-window shortcuts work before the first pointer click.
- Scrolling layouts now retain each workspace's active viewport, column order,
  and resized widths when workspace or output membership is reconciled.
- Direct-boot diagnostic sessions now detect unbound primary planes and start
  without requiring a predecessor framebuffer. `DENIAL_NO_PREDECESSOR=1`
  remains available to force that path on unusual DRM implementations.
- UI workspace setup now honors `DENIAL_CONTROL_TOOL` and
  `DENIAL_DEVELOPMENT_TOOL`, allowing installations outside `/usr/bin` to use
  the shell's built-in setup action.
- Delayed display edges can no longer replay stale frame ticks or supersede a ready Flutter frame before presentation.
- Mobile edge panels, status text, wallpaper queries, and local-application home-grid persistence now behave consistently across compact layouts.
- Denial now keeps the Wayland session alive when every DRM output disconnects
  and rebuilds the display state when an output returns.
- Physical keyboard lock LEDs now follow the compositor's XKB state.
- Overview transitions now interpolate window layout geometry without making
  frames and shadows jump to their destination before the animation finishes.

## [0.2.6] - 2026-08-07

### Added

- A compositor-integrated Impeller GLES path for Flutter's desktop-wide GBM
  atlas, including exact embedder FBO presentation, preserved partial damage,
  backdrop-filter support, native synchronization, and external-texture
  lifetime.
- Backdrop blur now has a configurable minimum effective window-opacity
  threshold, including an unconditional no-blur path for fully invisible
  windows.

### Changed

- Impeller is now Denial's default Flutter renderer. The retained Skia/Ganesh
  path remains available through `--flutter-renderer skia` or the packaged
  `DENIA_FLUTTER_RENDERER=skia` session override.
- High-rate external-texture frames now preserve precise rotating-atlas
  damage, reuse cached layer-diff metadata for only the dirty textures, and
  avoid redundant Ganesh flushes when cached texture bindings need no GL work.
- Output ticks use maintained per-output window membership, and output-control
  snapshots are rebuilt only after state changes.
- The guided Arch setup now stops after trusting the release key and adding
  the signed repository. Package installation remains an explicit
  `sudo pacman -Syu denial` command.
- Signed tags now provide package and user-visible runtime versions without a
  predictive Cargo, Dart, PKGBUILD, manual-page, or changelog version bump.
- `dev` candidates are never published. After an exact validated merge,
  `main` independently builds the production candidate; a later signed tag
  versions and publishes those exact compiled payloads without rebuilding.

### Fixed

- Managed X11 toplevels now always receive Denial's frame, rounded corners,
  and shadow, preventing decoration-free Xwayland windows from corrupting
  Impeller backdrop blur and shadow damage when minimized.
- Retained window-frame layers now include their shadow outset in partial
  repaint damage instead of clipping repair to the window's layout bounds.
- Denial now clears non-primary DRM planes inherited from the display manager
  before its first compositor frame, preventing a stale hardware cursor or
  overlay image from remaining latched above the Flutter desktop.
- Retained builder checkouts now run Flutter revision-transition hooks with
  the pinned depot_tools environment instead of depending on a host-global
  `vpython3` command.
- DPMS wake now absorbs transient connector disconnects while monitors retrain
  their links, preserving Wayland outputs and client windows across display
  power cycles.
- Fully opaque client content no longer requests backdrop blur merely because
  its shadow, rounded corners, or antialiased border carries alpha.
- Complex Flutter damage regions no longer collapse touching L-shaped output
  repairs into a full-atlas repaint.
- Failed local tag-signing attempts now reliably erase the decrypted recovery
  kit and temporary keyring after function scope unwinds.
- Arch packages now disable host-default debug-package rewriting explicitly,
  keeping tag-promoted payloads independent of the build host.

## [0.2.1] - 2026-07-29

### Added

- The optional UI development package now includes and enables the
  version-matched browser DevTools frontend for Flutter Inspector and
  performance profiling.

### Changed

- The native compositor plus Flutter's display and raster threads now request
  minimum-priority `SCHED_RR` only under a non-fatal realtime envelope, with
  RTKit-backed high-priority normal scheduling as the fallback. Realtime
  overruns demote Denial instead of terminating the graphical session;
  background workers and launched applications remain ordinary tasks.
- Signed release tags now directly version the Denial, Flutter Engine, and UI
  development archives. The engine's Flutter ABI remains separate metadata,
  and a Pacman epoch safely migrates from its former Flutter-numbered package.

### Fixed

- Powering off the final output now moves Flutter into its standard hidden
  lifecycle and cancels stale frame authorization. The shell stops producing
  invisible frames while Wayland applications remain alive for wake.

## [0.2.0] - 2026-07-27

### Added

- `denialctl`, a native compositor status, control, and recovery client which
  remains usable when the Flutter shell cannot render.
- A Developer page in Settings and a versioned native protocol for selecting,
  preparing, starting, inspecting, and restoring Flutter shell runtimes.
- In-process switching between the official optimized AOT shell and a JIT
  development shell without ending the Wayland session or its applications.
- The optional `denial-ui-development` package with a pinned JIT engine,
  curated Flutter and Dart tooling, locked shell dependencies, editor
  configuration, source metadata, and licenses.
- `denialctl ui setup`, which creates a version-matched editable Git checkout,
  prepares it with the packaged toolchain, selects it, and enters live
  development.
- VSCodium hot reload on save and Flutter Inspector support for the running
  desktop shell.
- `denial-session --start-locked` for autologin and direct-start setups which
  need Denial's native security gate closed before Flutter presents its first
  frame.
- A repository-owned guided installer which verifies the complete signing-key
  fingerprint, rejects conflicting Pacman configuration, and installs Denial
  through a normal full-system upgrade.

### Changed

- Denial's supported editor attachment is deliberately non-pausing. It keeps
  hot reload and Inspector functionality without granting DAP breakpoint,
  pause, stepping, or expression-evaluation control over the desktop isolate.
- Output configuration and runtime state now remain available through the
  native control path independently of Flutter Settings.
- Every login starts from the official optimized shell; live development must
  be enabled explicitly.
- The desktop shell is now the fail-safe default. The mobile shell is selected
  only by an exact, explicit `DENIA_SHELL_PROFILE=mobile` request.
- Normal display-manager sessions start unlocked after the display manager has
  authenticated the user; unattended startup can opt into Denial's own initial
  lock instead of imposing a duplicate password prompt on every login.
- Main-branch and signed-release validation now build, inspect, and retain the
  optional development package alongside the two required runtime packages.
- The packaged Flutter tool snapshot is built in a cleared, fixed environment
  and verified by checksum, preventing host locale, identity, and XDG settings
  from changing the development toolchain artifact.
- The packaged Flutter command-line tool now uses a deterministic AOT image
  and pinned `dartaotruntime`, removing host-specific warmed-JIT heap state
  while reducing its uncompressed payload.
- The Flutter tool snapshot now targets Dart's generic x86-64 CPU profile so
  development packages do not vary with builder-specific instruction sets.
- Flutter's optional package-map version metadata is now normalized to the
  pinned SDK version, so fresh and previously initialized toolchains produce
  the same development snapshot.
- The repository-level Rust toolchain pin now applies consistently to both the
  compositor and `cargo xtask`, including hardened builders with no default
  Rustup toolchain.
- Main validation now binds the exact verified push SHA to a local `main`
  branch so development packages record a cloneable source ref without
  weakening detached release-tag validation.
- Trusted `dev` pushes now run the complete production-shaped build, package,
  artifact, and independent-verification lane before promotion to `main`.
  Installable `dev` candidates use package release `0` and are excluded from
  the signed-tag publication path.
- Builder qualification now exercises Bubblewrap's private-network namespace
  before accepting work, and the runner permits the capability-free
  `AF_NETLINK` access required to initialize that isolated namespace.
- The alpha contribution policy now explicitly defers pull requests until
  Denial exits alpha while continuing to welcome issue reports and technical
  feedback.

### Safety and recovery

- Failed JIT preparation or startup falls back to the packaged optimized
  shell.
- `denialctl ui restore` provides a native recovery path from a terminal or
  virtual console.
- VM-service discovery remains authenticated, loopback-only, unadvertised over
  mDNS, and stored in a user-private runtime file.

### Known limitations

- Denial and `denial-ui-development` remain Arch Linux x86-64 public-alpha
  packages.
- Live development consumes substantially more storage, memory, and CPU than
  the optimized shell.
- Native file watching, one-click optimized custom builds, last-working custom
  rollback, and a stable third-party shell compatibility contract are not yet
  implemented.
- A custom Flutter shell and direct VM-service access are trusted local-user
  capabilities, not a sandbox for untrusted code.

[Unreleased]: https://github.com/denialwm/denial/compare/v0.2.6...HEAD
[0.2.6]: https://github.com/denialwm/denial/compare/v0.2.1...v0.2.6
[0.2.1]: https://github.com/denialwm/denial/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/denialwm/denial/compare/v0.1.0...v0.2.0
