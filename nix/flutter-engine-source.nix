# Source builder shared by the pinned cache producer and host-source fallback.
{
  lib,
  pkgs,
  stdenv,
  fetchurl,
  flutterNixpkgs ? pkgs.path,
  maintenanceOnly ? false,
}:
let
  sourceLock = lib.importJSON ../prebuilt/flutter-engine/SOURCE_LOCK.json;
  nixLock = lib.importJSON ./flutter-engine-lock.json;
  sourceLockHash = builtins.hashFile "sha256" ../prebuilt/flutter-engine/SOURCE_LOCK.json;
  flutterVersion = "3.47.5";
  flutterRevision = sourceLock.flutter.revision;
  engineVersion = lib.removeSuffix "\n" (
    builtins.readFile ../prebuilt/flutter-engine/linux-x64-release/ENGINE_REVISION
  );
  dartVersion = nixLock.dart.version;
  flutterNix = flutterNixpkgs + "/pkgs/development/compilers/flutter";
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

  # The builder's Nix daemon exposes this directory to the sandbox
  # (packaging/arch/runner/install-host), so an engine commit recompiles only
  # what it changed. Without it the wrapper compiles directly; the output is
  # the same either way.
  ccacheDir = "/var/cache/denial-nix-ccache";
  # GN calls this before every clang compile. Ninja runs below the output
  # path, which changes with every engine commit; debug info records "."
  # instead, so objects do not depend on it and the linked build-ids match
  # with or without the cache.
  engineCcache = pkgs.writeShellScriptBin "ccache" ''
    if [[ -w ${ccacheDir} ]]; then
      exec ${lib.getExe pkgs.ccache} "$@" -ffile-compilation-dir=.
    fi
    exec "$@" -ffile-compilation-dir=.
  '';
  engineCcacheSetup = ''
    export CCACHE_DIR=${ccacheDir} CCACHE_UMASK=007
    export CCACHE_NOHASHDIR=1
    export CCACHE_SLOPPINESS=include_file_ctime,include_file_mtime
    # The compiler is the wrapped clang plus the flags Nix passes through
    # the environment, less -frandom-seed: it carries the output path, and
    # clang ignores it.
    export CCACHE_COMPILERCHECK="string:$(
      {
        readlink -f src/buildtools/*/clang/bin/clang++
        env | grep -E '^NIX_(CFLAGS_COMPILE|CXXSTDLIB_COMPILE|HARDENING_ENABLE|CC)' \
          | sed -E 's/ ?-frandom-seed=[^ ]*//g' | sort
      } | sha256sum | cut -d ' ' -f 1
    )"
    export CCACHE_STATSLOG=$TMPDIR/ccache-stats
  '';

  engineTools = pkgs.callPackage (flutterNix + "/engine/tools.nix") {
    inherit (stdenv) hostPlatform buildPlatform;
    depot_toolsCommit = sourceLock.depot_tools.revision;
    depot_toolsHash = nixLock.depot_tools.hash;
  };
  enginePackageCallPackage =
    path: args:
    pkgs.callPackage path (
      args
      // lib.optionalAttrs (toString path == flutterNix + "/engine/source.nix") {
        tools = engineTools;
      }
    );
  engineCallPackage =
    path: args:
    let
      isEnginePackage = toString path == flutterNix + "/engine/package.nix";
      package = pkgs.callPackage path (
        args
        // {
          inherit dart;
        }
        // lib.optionalAttrs isEnginePackage {
          tools = engineTools;
          callPackage = enginePackageCallPackage;
        }
      );
    in
    if isEnginePackage then
      package.overrideAttrs (oldAttrs: {
        # Retain the actual configuration for the raw artifact's manifest.
        preInstall = (oldAttrs.preInstall or "") + ''
          cp $out/out/host_release/args.gn $out/denial-args.gn
        '';
        nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [ engineCcache ];
        preBuild = (oldAttrs.preBuild or "") + engineCcacheSetup;
        postBuild = ''
          if [[ -s $CCACHE_STATSLOG ]]; then
            ${lib.getExe pkgs.ccache} --show-log-stats
          fi
        '' + (oldAttrs.postBuild or "");
        configureFlags = (oldAttrs.configureFlags or [ ]) ++ [
          "--ccache"
          "--slimpeller"
          "--gn-args=shell_enable_vulkan=false"
          "--gn-args=test_enable_vulkan=false"
          "--gn-args=skia_use_vulkan=false"
        ];
      })
    else
      package;
  flutterCallPackage =
    path: args:
    pkgs.callPackage path (
      args
      // lib.optionalAttrs (toString path == flutterNix + "/engine/default.nix") {
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
in
assert lib.assertMsg (
  maintenanceOnly
  || (
    nixLock.schema_version == 1
    && nixLock.source_lock_sha256 == sourceLockHash
    && nixLock.flutter.revision == flutterRevision
    && nixLock.skia.revision == sourceLock.skia.revision
    && nixLock.depot_tools.revision == sourceLock.depot_tools.revision
    && nixLock.engine.revision == engineVersion
  )
) "Engine source locks differ; run tools/denial-nix refresh-engine-lock";
rawEngine.overrideAttrs (oldAttrs: {
  runtimeModes = [ "release" ];
  altRuntimeMode = "release";
  installPhase = ''
    runHook preInstall
    mkdir --parents $out/out
    ln --symbolic ${rawEngine.release}/out/${rawEngine.release.outName} \
      $out/out/${rawEngine.release.outName}
    runHook postInstall
  '';
  passthru = oldAttrs.passthru // {
    sourceLockSha256 = sourceLockHash;
    depotToolsSource = engineTools.depot_tools;
    nativeLibc = stdenv.cc.libc;
    buildStrategy = "host-source";
  };
})
