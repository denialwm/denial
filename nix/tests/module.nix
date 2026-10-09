{
  pkgs,
  module,
  nixosSystem,
}:

let
  evaluated = nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      module
      {
        # A consumer overlay must reach Denial's native runtime rather than
        # being bypassed by self.packages from the flake's own package set.
        nixpkgs.overlays = [
          (_final: prev: {
            libgbm = prev.libgbm.overrideAttrs (_: {
              pname = "denial-module-host-libgbm";
            });
            libglvnd = prev.libglvnd.overrideAttrs (_: {
              pname = "denial-module-host-libglvnd";
            });
            fontconfig = prev.fontconfig.overrideAttrs (_: {
              pname = "denial-module-host-fontconfig";
            });
          })
        ];
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        programs.denial.enable = true;
        system.stateVersion = "26.05";
      }
    ];
  };
  cfg = evaluated.config;
  hostPkgs = evaluated.pkgs;
  expectedChooser = "GDK_DEBUG=no-portals ${hostPkgs.zenity}/bin/zenity --list --title='Share your screen' --text='Choose a source to share' --column='Source' --width=520 --height=320";
  disabledIntegrations = nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      module
      {
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        programs.denial = {
          enable = true;
          polkitAgent.enable = false;
          ddc.enable = false;
          engine.buildFromSource = true;
        };
        system.stateVersion = "26.05";
      }
    ];
  };
  disabledCfg = disabledIntegrations.config;
  compatible =
    args:
    import ../engine-compatible.nix (
      {
        inherit (pkgs) lib;
        libcVersion = "2.42-67";
        compilerVersion = "15.2.0";
        isGNU = true;
        minimumGlibc = "2.42";
        minimumCompilerRuntime = "15.2";
      }
      // args
    );
in
pkgs.runCommand "denial-module-evaluation" { } ''
  test '${toString cfg.programs.denial.enable}' = 1
  test '${toString (cfg.programs.denial.package.drvPath == hostPkgs.denial.drvPath)}' = 1
  test '${toString (builtins.elem hostPkgs.libgbm cfg.programs.denial.package.compositor.buildInputs)}' = 1
  test '${
    toString (
      cfg.programs.denial.package.compositor.stdenv.cc.libc.drvPath == hostPkgs.stdenv.cc.libc.drvPath
    )
  }' = 1
  test '${
    toString (
      builtins.elem hostPkgs.fontconfig.drvPath (
        map (dep: dep.drvPath) hostPkgs.denialFlutter.engine.buildInputs
      )
    )
  }' = 1
  test '${
    toString (hostPkgs.denialFlutter.engine.nativeLibc.drvPath == hostPkgs.stdenv.cc.libc.drvPath)
  }' = 1
  test '${toString (hostPkgs.denialFlutter.engine.buildStrategy == "cached-engine")}' = 1
  test '${
    toString (hostPkgs.denialFlutter.dart.drvPath == hostPkgs.denialFlutter.engine.dart.drvPath)
  }' = 1
  test '${toString (builtins.elem "--slimpeller" pkgs.denialFlutter.pinnedRawEngine.sourceEngine.release.configureFlags)}' = 1
  test '${
    toString (
      pkgs.lib.hasInfix "denial-args.gn" (
        pkgs.denialFlutter.pinnedRawEngine.sourceEngine.release.preInstall or ""
      )
    )
  }' = 1
  test '${
    toString (
      hostPkgs.denialFlutter.engine.rawEngine.drvPath == pkgs.denialFlutter.pinnedRawEngine.drvPath
    )
  }' = 1
  test '${
    toString (disabledIntegrations.pkgs.denialFlutter.engine.buildStrategy == "host-source")
  }' = 1
  test '${
    toString (
      disabledIntegrations.pkgs.denialFlutter.dart.drvPath
      == disabledIntegrations.pkgs.denialFlutter.engine.dart.drvPath
    )
  }' = 1
  test '${
    toString (
      disabledIntegrations.pkgs.denialFlutter.engine.nativeLibc.drvPath
      == disabledIntegrations.pkgs.stdenv.cc.libc.drvPath
    )
  }' = 1
  test '${toString (builtins.elem cfg.programs.denial.package cfg.services.displayManager.sessionPackages)}' = 1
  test '${toString cfg.security.polkit.enable}' = 1
  test '${toString cfg.security.rtkit.enable}' = 1
  test '${toString cfg.hardware.i2c.enable}' = 1
  test '${toString cfg.programs.xwayland.enable}' = 1
  test '${toString (builtins.elem hostPkgs.source-han-sans cfg.fonts.packages)}' = 1
  test '${cfg.xdg.portal.wlr.settings.screencast.chooser_type}' = dmenu
  test '${toString (cfg.xdg.portal.wlr.settings.screencast.chooser_cmd == expectedChooser)}' = 1
  test '${
    toString (
      cfg.systemd.user.services.denial-polkit-agent.serviceConfig.ExecStart == [
        ""
        "${cfg.programs.denial.package}/bin/denial-polkit-agent"
      ]
    )
  }' = 1
  test '${toString (builtins.elem "denial-session.target" cfg.systemd.user.services.denial-polkit-agent.wantedBy)}' = 1
  test '${toString (!disabledCfg.hardware.i2c.enable)}' = 1
  test '${toString (!disabledCfg.systemd.user.units."denial-polkit-agent.service".enable)}' = 1
  test '${toString (compatible { })}' = 1
  test '${
    toString (compatible {
      libcVersion = "2.44";
      compilerVersion = "16.2.0";
    })
  }' = 1
  test '${toString (!(compatible { libcVersion = "2.41"; }))}' = 1
  test '${toString (!(compatible { compilerVersion = "14.2.0"; }))}' = 1
  test '${
    toString (
      !(compatible {
        compilerVersion = "21.1.8";
        isGNU = false;
      })
    )
  }' = 1
  touch $out
''
