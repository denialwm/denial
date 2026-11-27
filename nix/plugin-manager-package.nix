{
  lib,
  stdenvNoCC,
  settingsApp,
  compositor,
  denialFlutter,
  gitMinimal,
  coreutils,
  pluginBuildKit,
  packageSrc,
  version,
}:

let
  # Beside the command: Settings, which links the manager, and the command
  # itself find their build kit, Dart, denialctl and git through it.
  installationMetadata = builtins.toJSON {
    schema = 1;
    buildKit = "${pluginBuildKit}";
    denialctl = "${compositor}/bin/denialctl";
    dart = "${denialFlutter.dart}/bin/dart";
    path = [
      "${gitMinimal}/bin"
      "${coreutils}/bin"
    ];
  };
in
stdenvNoCC.mkDerivation {
  pname = "denial-plugin-manager";
  inherit version;
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -d $out/bin $out/lib/denial $out/lib/denial-plugins
    # A copy, not a link: the command reads the metadata beside its real
    # path.
    install -m755 ${settingsApp}/lib/denial-plugins/denial-plugins \
      $out/lib/denial-plugins/denial-plugins
    printf '%s\n' ${lib.escapeShellArg installationMetadata} \
      > $out/lib/denial-plugins/denial-plugins.installation.json
    ln -s ../lib/denial-plugins/denial-plugins $out/bin/denial-plugins
    ln -s ${pluginBuildKit} $out/lib/denial/plugin-build-kit

    install -Dm644 ${packageSrc}/docs/PLUGIN_DEVELOPMENT.md \
      $out/share/doc/denial-plugin-manager/PLUGIN_DEVELOPMENT.md
    install -Dm644 ${packageSrc}/LICENSE \
      $out/share/licenses/denial-plugin-manager/LICENSE
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    test -x $out/bin/denial-plugins
    $out/bin/denial-plugins --help > help.txt
    grep --fixed-strings 'denial-plugins apply' help.txt
    test -f $out/lib/denial/plugin-build-kit/kit.json
    test -f $out/lib/denial/plugin-build-kit/runtime/packages/denial_plugin_discovery/discover.dart
    test ! -e $out/lib/denial/plugin-build-kit/flutter/bin/cache/dart-sdk
    grep --fixed-strings '"dartVersion"' \
      $out/lib/denial/plugin-build-kit/kit.json
    grep --fixed-strings '"dartConstraint"' \
      $out/lib/denial/plugin-build-kit/kit.json
  '';

  meta = {
    description = "Plugin development and composition tools for Denial";
    homepage = "https://github.com/denialwm/denial";
    license = lib.licenses.gpl3Plus;
    mainProgram = "denial-plugins";
    platforms = [ "x86_64-linux" ];
  };
}
