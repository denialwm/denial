{
  lib,
  stdenvNoCC,
  pluginManagerBackend,
  pluginBuildKit,
  packageSrc,
  version,
}:

stdenvNoCC.mkDerivation {
  pname = "denial-plugin-manager";
  inherit version;
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -d $out/bin $out/lib/denial
    ln -s ${pluginManagerBackend}/bin/denial-plugins $out/bin/denial-plugins
    ln -s ${pluginManagerBackend}/bin/denial-plugins.installation.json \
      $out/bin/denial-plugins.installation.json
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
    test -f $out/lib/denial/plugin-build-kit/kit.json
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
