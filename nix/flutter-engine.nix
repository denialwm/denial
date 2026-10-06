{
  lib,
  pkgs,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  fetchzip,
  runCommand,
  maintenanceOnly ? false,
}:

let
  sourceLock = lib.importJSON ../prebuilt/flutter-engine/SOURCE_LOCK.json;
  nixLock = lib.importJSON ./flutter-engine-lock.json;
  sourceLockHash = builtins.hashFile "sha256" ../prebuilt/flutter-engine/SOURCE_LOCK.json;
  flutterVersion = "3.44.7";
  flutterRevision = sourceLock.flutter.revision;
  engineVersion = lib.removeSuffix "\n" (
    builtins.readFile ../prebuilt/flutter-engine/linux-x64-release/ENGINE_REVISION
  );
  dartVersion = nixLock.dart.version;

  dartHash =
    {
      x86_64-linux = nixLock.dart.hash;
    }
    .${stdenv.hostPlatform.system}
      or (throw "Denial Flutter does not support ${stdenv.hostPlatform.system}");

  dart = pkgs.dart-bin.overrideAttrs (_: {
    version = dartVersion;
    src = fetchurl {
      url = "https://storage.googleapis.com/dart-archive/channels/stable/release/${dartVersion}/sdk/dartsdk-linux-x64-release.zip";
      hash = dartHash;
    };
  });

  fetchedFlutter = fetchFromGitHub {
    owner = "denialwm";
    repo = "flutter";
    rev = flutterRevision;
    hash = nixLock.flutter.hash;
  };
  materialFonts = fetchzip {
    url = "https://storage.googleapis.com/flutter_infra_release/flutter/fonts/${nixLock.material_fonts.revision}/fonts.zip";
    hash = nixLock.material_fonts.hash;
    stripRoot = false;
  };

  # Flutter expects these cache markers even when the engine is supplied by
  # Nix. Keep the fetched source immutable and add only the generated markers.
  flutterSource = runCommand "denial-flutter-${flutterVersion}-source" { } ''
    cp --recursive ${fetchedFlutter} $out
    chmod --recursive u+w $out/bin
    mkdir --parents $out/bin/cache
    cp $out/bin/internal/engine.version $out/bin/cache/engine.stamp
    mkdir --parents $out/bin/cache/artifacts
    cp --recursive ${materialFonts} $out/bin/cache/artifacts/material_fonts
    cp $out/bin/internal/material_fonts.version $out/bin/cache/material_fonts.stamp
    touch $out/bin/cache/engine.realm
    actual_pubspec_hash="$(sha256sum $out/packages/flutter_tools/pubspec.yaml | cut -d ' ' -f 1)"
    test "$actual_pubspec_hash" = '${pubspecLock.source_pubspec_sha256}' || {
      echo 'Flutter tools pubspec.yaml changed without regenerating nix/flutter-pubspec-lock.json' >&2
      echo 'run `tools/denial-nix refresh-pub-locks`' >&2
      exit 1
    }
  '';

  flutterNix = pkgs.path + "/pkgs/development/compilers/flutter";
  mkCustomFlutter = pkgs.callPackage (flutterNix + "/flutter.nix");
  # These are part of Denial's locked Nixpkgs input. Keeping the references
  # there avoids maintaining a downstream Flutter patch series in this tree.
  frameworkPatches = map (name: flutterNix + "/patches/${name}") [
    "copy-without-perms.patch"
    "do-not-log-os-release-read-failure.patch"
    "dont-validate-executable-location.patch"
    "flutter-pub-dart-override.patch"
    "override-host-platform.patch"
    "override-operating-system.patch"
  ];

  versionPatches = map (name: flutterNix + "/versions/3_41/patches/${name}") [
    "disable-auto-update.patch"
    "deregister-pub-dependencies-artifact.patch"
  ];

  engineTools = pkgs.callPackage (flutterNix + "/engine/tools.nix") {
    inherit (stdenv) hostPlatform buildPlatform;
    depot_toolsCommit = sourceLock.depot_tools.revision;
    depot_toolsHash = nixLock.depot_tools.hash;
  };
  enginePackageCallPackage =
    path: args:
    pkgs.callPackage path (
      args
      // lib.optionalAttrs (path == flutterNix + "/engine/source.nix") {
        tools = engineTools;
      }
    );
  engineCallPackage =
    path: args:
    pkgs.callPackage path (
      args
      // {
        inherit dart;
      }
      // lib.optionalAttrs (path == flutterNix + "/engine/package.nix") {
        tools = engineTools;
        callPackage = enginePackageCallPackage;
      }
    );
  flutterCallPackage =
    path: args:
    pkgs.callPackage path (
      args
      // lib.optionalAttrs (path == flutterNix + "/engine/default.nix") {
        # Nixpkgs passes the requested Dart version into engine/default.nix but
        # does not forward the matching bootstrap SDK to engine/package.nix.
        callPackage = engineCallPackage;
      }
    );
  rawEngine = flutterCallPackage (flutterNix + "/engine/default.nix") {
    dartSdkVersion = dart.version;
    inherit flutterVersion;
    swiftshaderRev = nixLock.swiftshader.revision;
    swiftshaderHash = nixLock.swiftshader.hash;
    version = engineVersion;
    hashes = {
      x86_64-linux.x86_64-linux = nixLock.engine.source_hash;
    };
    url = "${sourceLock.flutter.repository}@${flutterRevision}";
    patches = [ ];
    runtimeModes = [
      "release"
      "release"
    ];
  };
  releaseEngine = rawEngine.overrideAttrs (_: {
    runtimeModes = [ "release" ];
    altRuntimeMode = "release";
    installPhase = ''
      runHook preInstall
      mkdir --parents $out/out
      ln --symbolic ${rawEngine.release}/out/${rawEngine.release.outName} \
        $out/out/${rawEngine.release.outName}
      runHook postInstall
    '';
  });

  # Lock maintenance must remain evaluable after SOURCE_LOCK.json advances and
  # before the Flutter application lock has been regenerated. In particular,
  # none of these fetchers may cross the application-only assertions below.
  maintenanceSources = {
    inherit dart fetchedFlutter;
    depotToolsSource = engineTools.depot_tools;
    engineSource = rawEngine.src;
  };

  pubspecLock = lib.importJSON ./flutter-pubspec-lock.json;
  flutterPub2Nix = pkgs.pub2nix // {
    readPubspecLock =
      args:
      pkgs.pub2nix.readPubspecLock (
        args
        // {
          gitHashes = {
            assets_for_android_views = "sha256-GN7nBxBwnlByp3E8uUDabWiuMUoYYHPtIveF+RiEpS8=";
          }
          // (args.gitHashes or { });
          sdkSourceBuilders = (args.sdkSourceBuilders or { }) // {
            flutter =
              name:
              runCommand "flutter-sdk-${name}" { passthru.packageRoot = "."; } ''
                for source in \
                  ${flutterSource}/packages/${name} \
                  ${releaseEngine}/out/${rawEngine.release.outName}/gen/dart-pkg/${name}; do
                  if [ -d "$source" ]; then
                    ln --symbolic "$source" $out
                    exit 0
                  fi
                done
                echo "Flutter SDK package is unavailable: ${name}" >&2
                exit 1
              '';
          };
        }
      );
  };
  flutterBuildDartApplication = pkgs.buildDartApplication.override {
    pub2nix = flutterPub2Nix;
  };
  flutterTools = pkgs.callPackage (flutterNix + "/flutter-tools.nix") {
    inherit dart pubspecLock;
    buildDartApplication = flutterBuildDartApplication;
    version = flutterVersion;
    flutterSrc = flutterSource;
    patches = frameworkPatches ++ versionPatches;
    systemPlatform = stdenv.hostPlatform.system;
    inherit engineVersion;
  };

  packages = rec {
    unwrapped =
      (mkCustomFlutter {
        useNixpkgsEngine = false;
        version = flutterVersion;
        inherit engineVersion dart;
        engineSwiftShaderRev = "unused";
        engineSwiftShaderHash = "unused";
        patches = frameworkPatches ++ versionPatches;
        channel = "stable";
        src = flutterSource;
        inherit pubspecLock flutterTools;
        artifactHashes = { };
      }).overrideAttrs
        (oldAttrs: {
          passthru = oldAttrs.passthru // {
            engine = releaseEngine;
            engineSource = rawEngine.src;
            depotToolsSource = engineTools.depot_tools;
            inherit fetchedFlutter flutterSource;
            buildFlutterApplication =
              pkgs.callPackage (flutterNix + "/build-support/build-flutter-application.nix")
                {
                  flutter = packages.wrapped;
                  buildDartApplication = flutterBuildDartApplication;
                };
          };
        });

    # Denial builds Linux applications only, with the locally compiled engine.
    # buildFlutterApplication normally re-enables universal and target artifact
    # downloads through `override`; keep this wrapper source-only instead.
    wrapped = wrappedBase // {
      override = _: packages.wrapped;
      engine = releaseEngine;
      engineSource = rawEngine.src;
      depotToolsSource = engineTools.depot_tools;
      inherit dart;
      inherit fetchedFlutter flutterSource;
    };
    wrappedBase = (pkgs.flutterPackages.wrapFlutter packages.unwrapped).override {
      supportedTargetFlutterPlatforms = [ ];
    };
  };
in
if maintenanceOnly then
  maintenanceSources
else
  assert lib.assertMsg (
    nixLock.schema_version == 1
  ) "unsupported nix/flutter-engine-lock.json schema";
  assert lib.assertMsg (nixLock.source_lock_sha256 == sourceLockHash) ''
    prebuilt/flutter-engine/SOURCE_LOCK.json changed without refreshing nix/flutter-engine-lock.json;
    run `tools/denial-nix refresh-engine-lock`
  '';
  assert lib.assertMsg (
    nixLock.flutter.revision == flutterRevision
  ) "Flutter revisions differ between the engine locks";
  assert lib.assertMsg (
    nixLock.skia.revision == sourceLock.skia.revision
  ) "Skia revisions differ between the engine locks";
  assert lib.assertMsg (
    nixLock.depot_tools.revision == sourceLock.depot_tools.revision
  ) "depot_tools revisions differ between the engine locks";
  assert lib.assertMsg (
    nixLock.engine.revision == engineVersion
  ) "Flutter engine revisions differ between the engine locks";
  assert lib.assertMsg (pubspecLock.flutter_revision == flutterRevision) ''
    Flutter changed without regenerating nix/flutter-pubspec-lock.json;
    run `tools/denial-nix refresh-pub-locks`
  '';
  packages.wrapped
