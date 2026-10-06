{
  lib,
  denialFlutter,
  stdenv,
  clang,
  cmake,
  ninja,
  pkg-config,
  patchelf,
  gtk3,
  glib,
  pango,
  cairo,
  at-spi2-core,
  libepoxy,
  fontconfig,
  src,
  sourceLockHash,
  version ? "0.0.0+unknown",
}:

let
  pubspecLock = lib.importJSON ./settings_app-pubspec-lock.json;
in
assert lib.assertMsg (pubspecLock.source_sha256 == sourceLockHash) ''
  settings_app/pubspec.lock changed without regenerating nix/settings_app-pubspec-lock.json;
  run `tools/denial-nix refresh-pub-locks`
'';
denialFlutter.buildFlutterApplication {
  pname = "denial-settings";
  inherit version src;
  sourceRoot = "source/settings_app";
  inherit pubspecLock;
  flutterMode = "release";

  nativeBuildInputs = [
    clang
    cmake
    ninja
    patchelf
    pkg-config
  ];
  buildInputs = [ gtk3 ];
  dontUseCmakeConfigure = true;

  flutterBuildFlags = [
    "--target=lib/main.dart"
    "--tree-shake-icons"
  ];

  # Nixpkgs' Flutter engine build presents its libraries through a synthetic
  # toolchain root. The generated GTK embedder consequently carries invalid
  # `$toolchain/nix/store/...` RUNPATH entries. Replace them after the normal
  # fixup pass with the real runtime libraries, keeping the build toolchain out
  # of the installed closure.
  postFixup = ''
    patchelf --set-rpath '$ORIGIN:${
      lib.makeLibraryPath [
        glib
        pango
        cairo
        gtk3
        at-spi2-core
        libepoxy
        fontconfig
        stdenv.cc.cc.lib
        stdenv.cc.libc
      ]
    }' $out/app/denial-settings/lib/libflutter_linux_gtk.so
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    test -x $out/app/denial-settings/denial-settings
    test -x $out/app/denial-settings/lib/libapp.so
    test -x $out/app/denial-settings/lib/libflutter_linux_gtk.so
    ! grep --binary-files=text --recursive --fixed-strings \
      'flutter-engine-toolchain-' $out/app/denial-settings
  '';

  meta = {
    description = "Settings application for Denial";
    homepage = "https://github.com/denialwm/denial";
    license = lib.licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
}
