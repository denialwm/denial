{
  lib,
  rustPlatform,
  runCommand,
  pkg-config,
  fontconfig,
  glib,
  libxkbcommon,
  polkit,
  vulkan-loader,
  wayland,
  denialAppsSrc ? null,
  gpuiTouchSrc ? null,
  version ? "0.0.0+unknown",
}:

assert lib.assertMsg (denialAppsSrc != null && gpuiTouchSrc != null) ''
  Settings and the Polkit agent are built from the denial-apps and gpui-touch
  commits that settings/SOURCE_LOCK.json names. Supply denialAppsSrc and gpuiTouchSrc when
  using this expression directly.
'';
let
  # denial-apps finds gpui-touch beside itself.
  source = runCommand "source" { } ''
    mkdir $out
    cp -R ${denialAppsSrc} $out/denial-apps
    cp -R ${gpuiTouchSrc} $out/gpui-touch
  '';
  # Loaded with dlopen rather than recorded as ELF dependencies.
  runtimeLibraryPath = lib.makeLibraryPath [
    fontconfig
    libxkbcommon
    vulkan-loader
    wayland
  ];
in
rustPlatform.buildRustPackage {
  pname = "denial-settings";
  inherit version;
  src = source;
  # Settings is a Cargo workspace of its own in denial-apps, with its own lock;
  # the Polkit agent and the plugin manager, which Settings links, are its
  # other members.
  sourceRoot = "source/denial-apps/apps/settings";
  cargoBuildFlags = [
    "-p"
    "settings"
    "-p"
    "polkit"
    "-p"
    "denial-plugins"
  ];
  cargoTestFlags = [
    "-p"
    "settings"
    "-p"
    "polkit"
    "-p"
    "denial-plugins"
  ];
  # The workspace's own Cargo configuration builds into the denial-apps
  # checkout's shared target, outside the part of the source made writable.
  CARGO_TARGET_DIR = "target";

  cargoLock = {
    lockFile = denialAppsSrc + "/apps/settings/Cargo.lock";
    # GPUI's git dependencies, each at the commit the lock names.
    allowBuiltinFetchGit = true;
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    fontconfig
    glib
    libxkbcommon
    polkit
    wayland
  ];

  postInstall = ''
    install -d $out/lib/denial-apps
    mv $out/bin/settings $out/lib/denial-apps/
    mv $out/bin/polkit $out/lib/denial-apps/
    # The plugin manager command goes into its own package.
    install -d $out/lib/denial-plugins
    mv $out/bin/denial-plugins $out/lib/denial-plugins/
    ln --symbolic ../lib/denial-apps/settings $out/bin/denial-settings
    ln --symbolic ../lib/denial-apps/polkit $out/bin/denial-polkit-agent
    install -Dm644 org.denialwm.Settings.png \
      $out/share/icons/hicolor/512x512/apps/org.denialwm.Settings.png
    install -Dm644 ../../LICENSE.md ../../README.md \
      --target-directory=$out/share/licenses/denial/settings
    install -Dm644 ../../LICENSES/Apache-2.0.txt ../../LICENSES/CC-BY-SA-4.0.txt \
      ../../LICENSES/GPL-3.0-only.txt \
      --target-directory=$out/share/licenses/denial/settings/LICENSES
    test -x $out/lib/denial-apps/settings
    test -x $out/lib/denial-apps/polkit
    test -x $out/lib/denial-plugins/denial-plugins
  '';

  postFixup = ''
    patchelf --add-rpath ${runtimeLibraryPath} $out/lib/denial-apps/settings
    patchelf --add-rpath ${runtimeLibraryPath} $out/lib/denial-apps/polkit
  '';

  meta = {
    description = "Settings, Welcome, the Polkit agent and the plugin manager for Denial";
    homepage = "https://github.com/denialwm/denial-apps";
    license = with lib.licenses; [
      gpl3Plus
      asl20
      cc-by-sa-40
    ];
    platforms = [ "x86_64-linux" ];
  };
}
