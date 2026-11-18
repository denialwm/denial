{
  description = "Denial, a Flutter-native Wayland compositor";

  # Flake schema requires this to be a literal set. The lock consistency check
  # keeps these values aligned with nix/cachix-cache.json, which is consumed by
  # the runner installer and CI upload.
  nixConfig = {
    extra-substituters = [ "https://denial.cachix.org" ];
    extra-trusted-public-keys = [
      "denial.cachix.org-1:wd8YTnvPmugFrtdMJWtR1XdVknR3/g2nmBJkT+vAruo="
    ];
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  # Validation host only; it must never replace the engine producer's pin.
  inputs.nixpkgsUnstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.denialPlugins = {
    url = "github:denialwm/denial-plugins/4b7adf998852b09b9a91c1cfab48be58debf2e80";
    flake = false;
  };
  # Settings: the commits settings/SOURCE_LOCK.json names, which the lock
  # consistency check compares with these.
  inputs.denialApps = {
    url = "github:denialwm/denial-apps/fe3317279b38c629394a9bb7162d2dcd6cf5f753";
    flake = false;
  };
  inputs.gpuiTouch = {
    url = "github:denialwm/gpui-touch/c6d856299c3206311045e5135abb4dc0455e97d2";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgsUnstable,
      denialPlugins,
      denialApps,
      gpuiTouch,
    }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      cleanRevision = self.rev or null;
      dirtyRevision = self.dirtyRev or null;
      gitRevision = if cleanRevision != null then cleanRevision else dirtyRevision;
      revisionIsDirty = cleanRevision == null && dirtyRevision != null;
      revisionBase =
        if gitRevision != null then
          nixpkgs.lib.removeSuffix "-dirty" gitRevision
        else
          builtins.substring 0 16 (builtins.hashString "sha256" (self.narHash or "unidentified-source"));
      revisionShort = builtins.substring 0 12 revisionBase;
      revisionKind = if gitRevision != null then "git" else "src";
      revisionSuffix = nixpkgs.lib.optionalString revisionIsDirty ".dirty";
      version = "0.0.0+${revisionKind}.${revisionShort}${revisionSuffix}";
      buildIdentity = "nix.${revisionKind}.${revisionShort}${revisionSuffix}";
      sourceRevision = if gitRevision != null then gitRevision else "nar:${self.narHash or revisionBase}";
      localOverlay = import ./nix/overlay.nix {
        inherit version buildIdentity sourceRevision;
        flutterNixpkgs = nixpkgs;
        pluginCollection = denialPlugins;
        inherit denialApps gpuiTouch;
      };
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ localOverlay ];
        };
      mkUnstablePkgs =
        system:
        import nixpkgsUnstable {
          inherit system;
          overlays = [ localOverlay ];
        };
    in
    {
      # Native dependencies come from the consumer's package set. Only the
      # Flutter helper definitions come from our locked Nixpkgs source.
      overlays.default = localOverlay;

      packages = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
          unstablePkgs = mkUnstablePkgs system;
          flutterMaintenanceSources = pkgs.callPackage ./nix/flutter-engine.nix {
            maintenanceOnly = true;
            flutterNixpkgs = nixpkgs;
          };
        in
        {
          default = pkgs.denial;
          denial = pkgs.denial;
          denial-unstable = unstablePkgs.denial;
          denial-plugin-manager = pkgs.denialPluginManager;
          denial-cachix-cli = pkgs.cachix;
          denial-nix-maintenance-tools = pkgs.buildEnv {
            name = "denial-nix-maintenance-tools";
            paths = [
              pkgs.jq
              pkgs.yq-go
            ];
          };
          denial-flutter = pkgs.denialFlutter;
          denial-flutter-engine = pkgs.denialFlutter.engine;
          denial-flutter-engine-raw = pkgs.denialFlutter.pinnedRawEngine;
          denial-flutter-engine-source-build = pkgs.denialFlutter.hostSourceEngine;
          denial-flutter-engine-source = flutterMaintenanceSources.engineSource;
          denial-flutter-depot-tools-source = flutterMaintenanceSources.depotToolsSource;
          denial-flutter-framework-source = flutterMaintenanceSources.fetchedFlutter;
          denial-flutter-dart = flutterMaintenanceSources.dart;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
          unstablePkgs = mkUnstablePkgs system;
        in
        {
          inherit (pkgs.denial.tests) path-contract;
          locks = pkgs.callPackage ./nix/tests/locks.nix {
            source = ./.;
            flutterSource = pkgs.denialFlutter.flutterSource;
            pluginCollection = denialPlugins;
            inherit denialApps gpuiTouch;
          };
          module = import ./nix/tests/module.nix {
            inherit pkgs;
            module = self.nixosModules.denial;
            nixosSystem = nixpkgs.lib.nixosSystem;
          };
          module-unstable = import ./nix/tests/module.nix {
            pkgs = mkUnstablePkgs system;
            module = self.nixosModules.denial;
            nixosSystem = nixpkgsUnstable.lib.nixosSystem;
          };
          engine-manifest = pkgs.callPackage ./nix/tests/engine-manifest.nix { };
          engine-cache = pkgs.callPackage ./nix/tests/engine-cache.nix {
            expectedRawEngine = pkgs.denialFlutter.pinnedRawEngine;
            newerDriver =
              if
                (nixpkgs.lib.versionOlder (nixpkgs.lib.versions.majorMinor pkgs.stdenv.cc.libc.version) (
                  nixpkgs.lib.versions.majorMinor unstablePkgs.stdenv.cc.libc.version
                ))
              then
                "${unstablePkgs.mesa}/lib/libgallium-${unstablePkgs.mesa.version}.so"
              else
                null;
          };
          engine-cache-unstable = unstablePkgs.callPackage ./nix/tests/engine-cache.nix {
            expectedRawEngine = pkgs.denialFlutter.pinnedRawEngine;
          };
        }
      );

      nixosModules.denial =
        { config, lib, ... }:
        {
          imports = [ ./nix/module.nix ];
          nixpkgs.overlays = lib.mkIf config.programs.denial.enable [ localOverlay ];
        };
      nixosModules.default = self.nixosModules.denial;

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
