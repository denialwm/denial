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
  src,
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
  dartShell = callPackage ./dart-shell.nix {
    src = sourceFor [
      "dart_shell"
      "protocol"
    ];
    sourceLockHash = builtins.hashFile "sha256" (src.origSrc + "/dart_shell/pubspec.lock");
    # The shell's manifest version is source metadata. Keep it independent of
    # the final package identity so packaging-only changes do not rebuild AOT.
    version = "0.0.0";
  };
  settingsApp = callPackage ./settings-app.nix {
    src = sourceFor [
      "dart_shell"
      "protocol"
      "settings_app"
    ];
    sourceLockHash = builtins.hashFile "sha256" (src.origSrc + "/settings_app/pubspec.lock");
    version = "0.0.0";
  };
  packageSrc = sourceFor [
    "README.md"
    "LICENSE"
    "LICENSES/CC-BY-SA-4.0.txt"
    "LICENSES/GPL-3.0-only.txt"
    "dart_shell/assets/cursors/BIBATA_MODERN_ICE.md"
    "dart_shell/assets/fonts/OFL.txt"
    "dart_shell/assets/fonts/README.md"
    "dart_shell/assets/wallpapers/ATTRIBUTION.md"
    "docs/man"
    "packaging/arch/denial-portal.service"
    "packaging/arch/denial-portals.conf"
    "packaging/arch/denial-session"
    "packaging/arch/denial.desktop"
    "packaging/arch/denial.portal"
    "packaging/arch/dev.denial.Settings.desktop"
    "packaging/arch/org.freedesktop.impl.portal.desktop.denial.service"
    "packaging/arch/outputs.conf"
    "packaging/arch/session.conf"
    "packaging/arch/xdg-desktop-portal-wlr-Denial"
    "packaging/denial-session.target"
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
    install -m755 ${settingsApp}/bin/denial-settings $out/bin/denial-settings
    ln --symbolic ../lib/denial/settings/denial-settings \
      $out/bin/.denial-settings-wrapped
    substituteInPlace $out/bin/denial-settings \
      --replace-fail '${settingsApp}/bin/.denial-settings-wrapped' \
      "$out/bin/.denial-settings-wrapped"

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
    install -Dm644 ${packageSrc}/dart_shell/assets/wallpapers/ATTRIBUTION.md \
      $out/share/doc/denial/WALLPAPERS.md
    install -Dm644 ${packageSrc}/dart_shell/assets/cursors/BIBATA_MODERN_ICE.md \
      $out/share/doc/denial/CURSORS.md
    install -Dm644 ${packageSrc}/dart_shell/assets/fonts/README.md \
      $out/share/doc/denial/FONTS.md
    install -Dm644 ${packageSrc}/LICENSE $out/share/licenses/denial/LICENSE
    install -Dm644 ${packageSrc}/LICENSES/CC-BY-SA-4.0.txt \
      $out/share/licenses/denial/CC-BY-SA-4.0.txt
    install -Dm644 ${packageSrc}/LICENSES/GPL-3.0-only.txt \
      $out/share/licenses/denial/GPL-3.0-only.txt
    install -Dm644 ${packageSrc}/dart_shell/assets/fonts/OFL.txt \
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
    test -x $out/bin/.denial-settings-wrapped
    grep --fixed-strings 'GIO_EXTRA_MODULES' $out/bin/denial-settings
    grep --fixed-strings 'GDK_PIXBUF_MODULE_FILE' $out/bin/denial-settings
    grep --fixed-strings 'XDG_DATA_DIRS' $out/bin/denial-settings
    grep --fixed-strings "$out/bin/.denial-settings-wrapped" \
      $out/bin/denial-settings
    ! grep --fixed-strings '$out/bin/.denial-settings-wrapped' \
      $out/bin/denial-settings
    ! grep --fixed-strings '${settingsApp}' $out/bin/denial-settings
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
    inherit compositor dartShell settingsApp;
    inherit buildIdentity sourceRevision;
    providedSessions = [ "denial" ];
    tests.path-contract = callPackage ./tests/path-contract.nix {
      package = finalAttrs.finalPackage;
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
