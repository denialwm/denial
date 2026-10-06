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
  expectedChooser = "${pkgs.zenity}/bin/zenity --list --title='Share your screen' --text='Choose a source to share' --column='Source' --width=520 --height=320";
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
        };
        system.stateVersion = "26.05";
      }
    ];
  };
  disabledCfg = disabledIntegrations.config;
in
pkgs.runCommand "denial-module-evaluation" { } ''
  test '${toString cfg.programs.denial.enable}' = 1
  test '${toString (builtins.elem cfg.programs.denial.package cfg.services.displayManager.sessionPackages)}' = 1
  test '${toString cfg.security.polkit.enable}' = 1
  test '${toString cfg.security.rtkit.enable}' = 1
  test '${toString cfg.hardware.i2c.enable}' = 1
  test '${toString cfg.programs.xwayland.enable}' = 1
  test '${toString (builtins.elem pkgs.source-han-sans cfg.fonts.packages)}' = 1
  test '${cfg.xdg.portal.wlr.settings.screencast.chooser_type}' = dmenu
  test '${toString (cfg.xdg.portal.wlr.settings.screencast.chooser_cmd == expectedChooser)}' = 1
  test '${
    toString (
      cfg.systemd.user.services.denial-polkit-agent.serviceConfig.ExecStart
      == "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"
    )
  }' = 1
  test '${toString (builtins.elem "denial-session.target" cfg.systemd.user.services.denial-polkit-agent.wantedBy)}' = 1
  test '${toString (!disabledCfg.hardware.i2c.enable)}' = 1
  test '${toString (!builtins.hasAttr "denial-polkit-agent" disabledCfg.systemd.user.services)}' = 1
  touch $out
''
