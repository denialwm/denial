{
  lib,
  stdenvNoCC,
  callPackage,
  makeWrapper,
  patchelf,
  coreutils,
  ddcutil,
  libglvnd,
  libpulseaudio,
  pam,
  systemd,
  xwayland,
  gnused,
  util-linux,
  denialFlutter,
  src,
  runCommand,
  yq-go,
  taskbarSrc ? null,
  version ? "0.0.0+unknown",
  buildIdentity ? "nix.unknown",
  sourceRevision ? "unknown",
}:

let
  sourceFor =
    roots:
    lib.fileset.toSource {
      root = src.origSrc;
      fileset = lib.fileset.intersection (lib.fileset.fromSource src) (
        lib.fileset.unions (map (root: src.origSrc + "/${root}") roots)
      );
    };
  compositor = callPackage ./compositor.nix {
    src = sourceFor [
      "compositor"
      "packaging/arch/denial-portals.conf"
      "packaging/arch/denial.portal"
      "protocol"
    ];
    inherit version buildIdentity;
  };
  # Vendor the development dependency from the locked multi-package collection.
  uiSourceFor =
    roots:
    assert lib.assertMsg (taskbarSrc != null) ''
      The development workspace requires plugins/denial_taskbar from the locked
      denial-plugins collection. Supply taskbarSrc when using this expression directly.
    '';
    runCommand "source" { nativeBuildInputs = [ yq-go ]; } ''
      mkdir -p $out/plugins
      cp -R ${sourceFor roots}/. $out/
      cp -R ${
        lib.cleanSourceWith {
          src = taskbarSrc;
          filter =
            path: type:
            !(
              type == "directory"
              && builtins.elem (baseNameOf (toString path)) [
                ".git"
                ".dart_tool"
                "build"
              ]
            );
        }
      } $out/plugins/denial_taskbar
      chmod -R u+w $out
      if [ -f "$out/dart_shell/pubspec.yaml" ]; then
        yq -i '.dev_dependencies.denial_taskbar = {"path": "../plugins/denial_taskbar"}' \
          "$out/dart_shell/pubspec.yaml"
        yq -i '.packages.denial_taskbar.source = "path" |
          .packages.denial_taskbar.description = {"path": "../plugins/denial_taskbar", "relative": true}' \
          "$out/dart_shell/pubspec.lock"
      fi
    '';
  dartShell = callPackage ./dart-shell.nix {
    src = uiSourceFor [
      "dart_shell"
      "packages/denial_sdk"
      "packages/denial_flutter_sdk"
      "plugins/denial_top_bar"
      "plugins/denial_desktop"
      "plugins/denial_launcher"
      "plugins/denial_clock"
      "plugins/denial_pets"
      "protocol"
    ];
    sourceLockHash = builtins.hashFile "sha256" (src.origSrc + "/dart_shell/pubspec.lock");
    # The shell's manifest version is source metadata. Keep it independent of
    # the final package identity so packaging-only changes do not rebuild AOT.
    version = "0.0.0";
  };
  nativeApp = callPackage ./native-app.nix {
    src = sourceFor [ "native_app" "compositor" ];
  };
  polkitApp = callPackage ./polkit-app.nix {
    inherit nativeApp;
    src = sourceFor [
      "polkit_app"
      "packages/denial_sdk"
      "packages/denial_flutter_sdk"
      "protocol/generated/dart"
    ];
    sourceLockHash = builtins.hashFile "sha256" (src.origSrc + "/polkit_app/pubspec.lock");
    version = "0.0.0";
  };
  settingsApp = callPackage ./settings-app.nix {
    inherit nativeApp;
    src = uiSourceFor [
      "dart_shell"
      "packages/denial_sdk"
      "packages/denial_flutter_sdk"
      "plugins/denial_top_bar"
      "plugins/denial_desktop"
      "plugins/denial_launcher"
      "plugins/denial_clock"
      "plugins/denial_pets"
      "protocol"
      "settings_app"
    ];
    sourceLockHash = builtins.hashFile "sha256" (src.origSrc + "/settings_app/pubspec.lock");
    version = "0.0.0";
  };
  pluginManagerApp = callPackage ./plugin-manager-app.nix {
    inherit pluginManagerBackend nativeApp;
    src = sourceFor [
      "plugin_manager_app"
      "packages/denial_sdk"
      "packages/denial_flutter_sdk"
      "protocol/generated/dart"
    ];
    sourceLockHash = builtins.hashFile "sha256" (src.origSrc + "/plugin_manager_app/pubspec.lock");
    version = "0.0.0";
  };
  pluginManagerBackend = callPackage ./plugin-manager-backend.nix {
    inherit pluginBuildKit compositor;
    src = sourceFor [
      "packages/denial_plugin_manager"
      "packages/denial_sdk"
    ];
    sourceLockHash = builtins.hashFile "sha256" (
      src.origSrc + "/packages/denial_plugin_manager/pubspec.lock"
    );
  };
  pluginBuildKit = callPackage ./plugin-build-kit.nix {
    src = sourceFor [
      "dart_shell"
      "packages/denial_sdk"
      "packages/denial_flutter_sdk"
      "plugins/denial_top_bar"
      "plugins/denial_desktop"
      "plugins/denial_launcher"
      "plugins/denial_clock"
      "plugins/denial_pets"
      "plugins/builtins.yaml"
      "protocol/generated/dart"
      "compositor/src/lib.rs"
      "prebuilt/flutter-engine"
      "LICENSE"
      "tools/prepare-denial-plugin-kit"
    ];
    inherit sourceRevision;
  };
  packageSrc = sourceFor [
    "README.md"
    "LICENSE"
    "LICENSES/CC-BY-SA-4.0.txt"
    "LICENSES/GPL-3.0-only.txt"
    "packages/denial_flutter_sdk/assets/cursors/BIBATA_MODERN_ICE.md"
    "packages/denial_flutter_sdk/assets/fonts/OFL.txt"
    "packages/denial_flutter_sdk/assets/fonts/README.md"
    "packages/denial_flutter_sdk/assets/wallpapers/ATTRIBUTION.md"
    "docs/man"
    "docs/PLUGIN_DEVELOPMENT.md"
    "packaging/arch/denial-portal.service"
    "packaging/arch/denial-portals.conf"
    "packaging/arch/denial-session"
    "packaging/arch/denial.desktop"
    "packaging/arch/denial.portal"
    "packaging/arch/dev.denial.Settings.desktop"
    "packaging/dev.denial.PluginManager.desktop"
    "packaging/dev.denial.Welcome.desktop"
    "packaging/arch/org.freedesktop.impl.portal.desktop.denial.service"
    "packaging/arch/outputs.conf"
    "packaging/arch/session.conf"
    "packaging/arch/xdg-desktop-portal-wlr-Denial"
    "packaging/denial-session.target"
    "packaging/denial-polkit-agent.service"
    "packaging/denial-suspend-mode"
  ];
  runtimeLibraryPath = lib.makeLibraryPath [
    libglvnd
    pam
    libpulseaudio
    ddcutil
  ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "denial";
  inherit version;
  src = packageSrc;

  dontUnpack = true;
  nativeBuildInputs = [
    makeWrapper
    patchelf
  ];

  installPhase = ''
    runHook preInstall

    install -Dm755 ${compositor}/bin/deniald $out/bin/deniald
    install -Dm755 ${compositor}/bin/denialctl $out/bin/denialctl
    install -Dm755 ${compositor}/bin/denial-portal $out/bin/denial-portal
    install -Dm755 ${packageSrc}/packaging/arch/denial-session $out/bin/denial-session
    patchShebangs $out/bin/denial-session

    install -d $out/lib/denial/flutter
    cp --recursive ${dartShell}/. $out/lib/denial/flutter/

    install -d $out/lib/denial/settings
    cp --recursive ${settingsApp}/app/denial-settings/. $out/lib/denial/settings/
    ln --symbolic ../lib/denial/settings/denial-settings $out/bin/denial-settings

    install -d $out/lib/denial/polkit
    cp -R ${polkitApp}/app/denial-polkit-dialog/. $out/lib/denial/polkit/
    mv $out/lib/denial/polkit/denial-polkit-dialog $out/lib/denial/polkit/denial-app
    makeWrapper ${compositor}/bin/denial-polkit-agent $out/bin/denial-polkit-agent \
      --add-flags "--runner $out/lib/denial/polkit/denial-app --bundle $out/lib/denial/polkit --engine $out/lib/denial/polkit/lib/libflutter_engine.so"
    install -Dm644 ${packageSrc}/packaging/denial-polkit-agent.service \
      $out/lib/systemd/user/denial-polkit-agent.service
    substituteInPlace $out/lib/systemd/user/denial-polkit-agent.service \
      --replace-fail '/usr/bin/denial-polkit-agent' "$out/bin/denial-polkit-agent"

    install -m644 ${pluginBuildKit}/runtime/.denial-ui-source.json \
      $out/lib/denial/flutter/.denial-ui-source.json

    install -Dm644 ${packageSrc}/packaging/denial-session.target \
      $out/lib/systemd/user/denial-session.target
    install -Dm644 ${packageSrc}/packaging/arch/denial-portal.service \
      $out/lib/systemd/user/denial-portal.service
    substituteInPlace $out/lib/systemd/user/denial-portal.service \
      --replace-fail 'ExecStart=/usr/bin/denial-portal' "ExecStart=$out/bin/denial-portal"

    install -Dm755 ${packageSrc}/packaging/denial-suspend-mode \
      $out/lib/systemd/system-sleep/denial-suspend-mode
    substituteInPlace $out/lib/systemd/system-sleep/denial-suspend-mode \
      --replace-fail '#!/bin/sh' '#!${stdenvNoCC.shell}' \
      --replace-fail "sed 's/\\[//g; s/\\]//g'" "${gnused}/bin/sed 's/\\[//g; s/\\]//g'" \
      --replace-fail 'command -v loginctl' 'test -x ${systemd}/bin/loginctl' \
      --replace-fail 'loginctl list-sessions' '${systemd}/bin/loginctl list-sessions' \
      --replace-fail 'loginctl show-session' '${systemd}/bin/loginctl show-session' \
      --replace-fail 'loginctl show-user' '${systemd}/bin/loginctl show-user' \
      --replace-fail 'logger -t denial-suspend-mode' '${util-linux}/bin/logger -t denial-suspend-mode'

    install -Dm644 ${packageSrc}/packaging/arch/denial.desktop \
      $out/share/wayland-sessions/denial.desktop
    substituteInPlace $out/share/wayland-sessions/denial.desktop \
      --replace-fail '/usr/bin/denial-session' "$out/bin/denial-session"

    install -Dm644 ${packageSrc}/packaging/arch/dev.denial.Settings.desktop \
      $out/share/applications/dev.denial.Settings.desktop
    substituteInPlace $out/share/applications/dev.denial.Settings.desktop \
      --replace-fail '/usr/bin/denial-settings' "$out/bin/denial-settings"
    install -Dm644 ${packageSrc}/packaging/dev.denial.Welcome.desktop \
      $out/share/applications/dev.denial.Welcome.desktop
    substituteInPlace $out/share/applications/dev.denial.Welcome.desktop \
      --replace-fail '/usr/bin/denial-settings' "$out/bin/denial-settings"

    install -Dm644 ${packageSrc}/packaging/arch/denial-portals.conf \
      $out/share/xdg-desktop-portal/denial-portals.conf
    install -Dm644 ${packageSrc}/packaging/arch/denial.portal \
      $out/share/xdg-desktop-portal/portals/denial.portal
    install -Dm644 \
      ${packageSrc}/packaging/arch/org.freedesktop.impl.portal.desktop.denial.service \
      $out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.denial.service
    substituteInPlace \
      $out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.denial.service \
      --replace-fail '/usr/bin/denial-portal' "$out/bin/denial-portal"

    install -Dm644 ${packageSrc}/packaging/arch/xdg-desktop-portal-wlr-Denial \
      $out/etc/xdg/xdg-desktop-portal-wlr/Denial
    install -Dm644 ${packageSrc}/packaging/arch/session.conf \
      $out/etc/denial/session.conf
    install -Dm644 ${packageSrc}/packaging/arch/outputs.conf \
      $out/etc/denial/outputs.conf

    install -Dm644 ${packageSrc}/README.md $out/share/doc/denial/README.md
    install -d $out/share/denial
    printf '%s\n' '${buildIdentity}' >$out/share/denial/build-identity
    printf '%s\n' '${sourceRevision}' >$out/share/denial/source-revision
    for manual in denialctl deniald denial-session denial-portal; do
      install -Dm644 ${packageSrc}/docs/man/$manual.1 $out/share/man/man1/$manual.1
    done
    install -Dm644 ${packageSrc}/packages/denial_flutter_sdk/assets/wallpapers/ATTRIBUTION.md \
      $out/share/doc/denial/WALLPAPERS.md
    install -Dm644 ${packageSrc}/packages/denial_flutter_sdk/assets/cursors/BIBATA_MODERN_ICE.md \
      $out/share/doc/denial/CURSORS.md
    install -Dm644 ${packageSrc}/packages/denial_flutter_sdk/assets/fonts/README.md \
      $out/share/doc/denial/FONTS.md
    install -Dm644 ${packageSrc}/LICENSE $out/share/licenses/denial/LICENSE
    install -Dm644 ${packageSrc}/LICENSES/CC-BY-SA-4.0.txt \
      $out/share/licenses/denial/CC-BY-SA-4.0.txt
    install -Dm644 ${packageSrc}/LICENSES/GPL-3.0-only.txt \
      $out/share/licenses/denial/GPL-3.0-only.txt
    install -Dm644 ${packageSrc}/packages/denial_flutter_sdk/assets/fonts/OFL.txt \
      $out/share/licenses/denial/OFL-1.1.txt

    wrapProgram $out/bin/denial-session \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          systemd
          xwayland
        ]
      }

    runHook postInstall
  '';

  # The compositor loads these libraries with dlopen, so the normal ELF
  # dependency scanner cannot retain them while fixing up this composed output.
  postFixup = ''
    patchelf --add-rpath ${runtimeLibraryPath} $out/bin/deniald
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test -x $out/bin/deniald
    test -x $out/bin/denialctl
    test -x $out/bin/denial-portal
    test -x $out/bin/denial-settings
    test -x $out/bin/denial-polkit-agent
    test -x $out/lib/denial/polkit/denial-app
    test "$(readlink $out/bin/denial-settings)" = ../lib/denial/settings/denial-settings
    ! grep --binary-files=text --recursive --fixed-strings \
      'flutter-engine-toolchain-' $out/lib/denial/settings
    test -x $out/bin/denial-session
    test -f $out/lib/denial/flutter/data/icudtl.dat
    test -f $out/lib/denial/flutter/lib/libapp.so
    test -f $out/lib/denial/flutter/lib/libflutter_engine.so
    test -f $out/share/wayland-sessions/denial.desktop
    test -f $out/lib/systemd/user/denial-session.target
    grep --fixed-strings '${buildIdentity}' $out/share/denial/build-identity
    grep --fixed-strings '${sourceRevision}' $out/share/denial/source-revision
    ! grep --recursive --fixed-strings '/usr/bin/denial' \
      $out/share/wayland-sessions \
      $out/share/applications \
      $out/share/dbus-1/services \
      $out/lib/systemd/user
    grep --fixed-strings "Exec=$out/bin/denial-session" \
      $out/share/wayland-sessions/denial.desktop
    grep --fixed-strings "ExecStart=$out/bin/denial-portal" \
      $out/lib/systemd/user/denial-portal.service
    case "$(patchelf --print-rpath $out/bin/deniald)" in
      *${lib.getLib libglvnd}/lib*) ;;
      *)
        echo "deniald is missing its libglvnd runtime search path" >&2
        exit 1
        ;;
    esac
    runHook postInstallCheck
  '';

  passthru = {
    inherit
      compositor
      dartShell
      settingsApp
      nativeApp
      polkitApp
      pluginManagerApp
      pluginManagerBackend
      pluginBuildKit
      ;
    inherit buildIdentity sourceRevision;
    pluginManager = callPackage ./plugin-manager-package.nix {
      denial = finalAttrs.finalPackage;
      inherit
        denialFlutter
        pluginManagerApp
        pluginManagerBackend
        pluginBuildKit
        packageSrc
        version
        ;
    };
    providedSessions = [ "denial" ];
    tests.path-contract = callPackage ./tests/path-contract.nix {
      package = finalAttrs.finalPackage;
      pluginManager = finalAttrs.finalPackage.pluginManager;
    };
  };

  meta = {
    description = "Flutter-native Wayland compositor and desktop shell";
    homepage = "https://github.com/denialwm/denial";
    license = with lib.licenses; [
      gpl3Plus
      gpl3Only
      cc-by-sa-40
      ofl
    ];
    mainProgram = "denial-session";
    platforms = [ "x86_64-linux" ];
  };
})
