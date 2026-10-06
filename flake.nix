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

  outputs =
    { self, nixpkgs }:
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
      };
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ localOverlay ];
        };
    in
    {
      # Keep package builds on Denial's locked Nixpkgs. Consumers can still use
      # the overlay without coupling Flutter's private Nix expressions to their
      # system Nixpkgs revision.
      overlays.default = final: _prev: {
        denial = self.packages.${final.stdenv.hostPlatform.system}.denial;
        denialFlutter = self.packages.${final.stdenv.hostPlatform.system}.denial-flutter;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
          flutterMaintenanceSources = pkgs.callPackage ./nix/flutter-engine.nix {
            maintenanceOnly = true;
          };
        in
        {
          default = pkgs.denial;
          denial = pkgs.denial;
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
        in
        {
          inherit (pkgs.denial.tests) path-contract;
          locks = pkgs.callPackage ./nix/tests/locks.nix {
            source = ./.;
            flutterSource = pkgs.denialFlutter.flutterSource;
          };
          module = import ./nix/tests/module.nix {
            inherit pkgs;
            module = self.nixosModules.denial;
            nixosSystem = nixpkgs.lib.nixosSystem;
          };
        }
      );

      nixosModules.denial =
        { lib, pkgs, ... }:
        {
          imports = [ ./nix/module.nix ];
          programs.denial.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.denial;
        };
      nixosModules.default = self.nixosModules.denial;

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
