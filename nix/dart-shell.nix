{
  lib,
  denialFlutter,
  stdenv,
  src,
  sourceLockHash,
  version ? "0.0.0+unknown",
}:

let
  pubspecLock = lib.importJSON ./dart_shell-pubspec-lock.json;
  targetPlatform =
    if stdenv.hostPlatform.system == "x86_64-linux" then
      "linux-x64"
    else
      throw "Denial does not support ${stdenv.hostPlatform.system}";
in
assert lib.assertMsg (pubspecLock.source_sha256 == sourceLockHash) ''
  dart_shell/pubspec.lock changed without regenerating nix/dart_shell-pubspec-lock.json;
  run `tools/denial-nix refresh-pub-locks`
'';
denialFlutter.buildFlutterApplication {
  pname = "denial-dart-shell";
  inherit version src;
  sourceRoot = "source/dart_shell";
  inherit pubspecLock;
  flutterMode = "release";

  buildPhase = ''
    runHook preBuild
    mkdir --parents build/nix-assembly
    flutter assemble \
      --local-engine host_release \
      --suppress-analytics \
      --output=build/nix-assembly \
      -dTargetFile=lib/main.dart \
      -dBuildMode=release \
      -dTargetPlatform=${targetPlatform} \
      -dDartObfuscation=false \
      -dTrackWidgetCreation=true \
      -dTreeShakeIcons=true \
      release_bundle_linux-x64_assets
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -d $out/data/flutter_assets $out/lib $debug
    cp --recursive build/nix-assembly/flutter_assets/. $out/data/flutter_assets/
    install -m755 build/nix-assembly/lib/libapp.so $out/lib/libapp.so
    install -m644 ${denialFlutter.engine}/out/host_release/icudtl.dat $out/data/icudtl.dat
    install -m755 ${denialFlutter.engine}/out/host_release/libflutter_engine.so \
      $out/lib/libflutter_engine.so
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    test -f $out/data/flutter_assets/AssetManifest.bin
    test -f $out/data/icudtl.dat
    test -x $out/lib/libapp.so
    test -x $out/lib/libflutter_engine.so
  '';

  meta = {
    description = "Embedded Flutter desktop shell for Denial";
    homepage = "https://github.com/denialwm/denial";
    license = lib.licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
}
