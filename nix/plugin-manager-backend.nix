{
  lib,
  buildDartApplication,
  denialFlutter,
  gitMinimal,
  coreutils,
  src,
  sourceLockHash,
  pluginBuildKit,
  compositor,
}:
let
  pubspecLock = lib.importJSON ./plugin_manager_backend-pubspec-lock.json;
  installationMetadata = builtins.toJSON {
    schema = 1;
    buildKit = "${pluginBuildKit}";
    denialctl = "${compositor}/bin/denialctl";
  };
in
assert lib.assertMsg (pubspecLock.source_sha256 == sourceLockHash) ''
  packages/denial_plugin_manager/pubspec.lock changed without regenerating its Nix lock;
  run `tools/denial-nix refresh-pub-locks`
'';
(buildDartApplication.override { dart = denialFlutter.dart; }) {
  pname = "denial-plugins";
  version = "0.0.0";
  inherit src pubspecLock;
  sourceRoot = "source/packages/denial_plugin_manager";
  dartEntryPoints."bin/denial-plugins" = "bin/denial_plugins.dart";
  extraWrapProgramArgs = "--prefix PATH : ${
    lib.makeBinPath [
      denialFlutter.dart
      gitMinimal
      coreutils
    ]
  }";
  preFixup = ''
    installDenialPluginMetadata() {
      printf '%s\n' ${lib.escapeShellArg installationMetadata} \
        > $out/bin/denial-plugins.installation.json
    }
    # The Dart fixup hook wraps every existing bin/* entry. Add metadata after
    # that hook so it stays beside the executable without being treated as one.
    postFixupHooks+=(installDenialPluginMetadata)
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/denial-plugins --help > help.txt
    grep --fixed-strings 'denial-plugins apply' help.txt
    test -f $out/bin/denial-plugins.installation.json
  '';
  meta = {
    description = "Build-time plugin composition manager for Denial";
    license = lib.licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
}
