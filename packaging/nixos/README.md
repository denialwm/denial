# NixOS

Denial ships its Nix package, overlay, and NixOS module in this repository.
The package builds the Rust compositor, the locked Denial Flutter engine, the
embedded shell, and Settings from source. It does not download Denial release
binaries.

Add Denial to the flake that owns the NixOS system:

```nix
{
  nixConfig = {
    extra-substituters = [ "https://denial.cachix.org" ];
    extra-trusted-public-keys = [
      "denial.cachix.org-1:wd8YTnvPmugFrtdMJWtR1XdVknR3/g2nmBJkT+vAruo="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    denial.url = "github:denialwm/denial";
  };

  outputs =
    { nixpkgs, denial, ... }:
    {
      nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          denial.nixosModules.default
          {
            programs.denial.enable = true;
          }
        ];
      };
    };
}
```

Rebuild the system normally, then choose **Denial** in the existing display
manager. The module deliberately does not enable a display manager, select a
default session, or configure autologin.

`programs.denial.package` can replace the package without replacing the
module. Denial deliberately builds against its locked Nixpkgs revision; the
module does not couple the private Flutter expressions to the host's Nixpkgs.
The module also registers the Wayland session, Denial's Settings portal and
systemd user unit, the wlroots screenshot/screencast portal, Xwayland, polkit,
realtime scheduling, and Denial's CJK fallback font.

The module starts a PolicyKit authentication agent by default and enables I2C
access for DDC monitor controls. Existing desktop integrations can replace or
disable these defaults:

```nix
{ pkgs, ... }:
{
  programs.denial = {
    polkitAgent.enable = false;
    # Or retain the service with another absolute executable:
    # polkitAgent.command = "${pkgs.someAgent}/bin/some-agent";
    ddc.enable = false;
  };
}
```

Screen sharing uses an absolute Zenity executable path. Denial does not yet
implement layer-shell, so the module explicitly supplies this regular
xdg-shell chooser to `xdg-desktop-portal-wlr` instead of relying on its default
Slurp chooser.

Denial resolves its compositor, control client, Settings executable, Flutter
bundle, and packaged defaults from the installed package prefix. A Nix store
path is therefore supported directly; no `/usr/bin` compatibility links are
needed. Machine-specific configuration can still replace the packaged
defaults conventionally:

```nix
{
  environment.etc."denial/session.conf".source = ./session.conf;
  environment.etc."denial/outputs.conf".source = ./outputs.conf;
}
```

An ordinary writable `~/.config/denial/outputs.conf` remains the live display
state for compatibility. A read-only file or symlink there, including a Home
Manager link into the Nix store, is instead treated as declarative input. The
launcher gives Denial a writable copy at
`$XDG_STATE_HOME/denial/outputs.conf`; live changes persist until the
declarative source changes, at which point that source becomes the new state.
When no per-user file exists, `/etc/denial/outputs.conf` is the declarative
source and therefore follows later system rebuilds.

## Build resources and lock maintenance

Trusted `dev` and `main` validation builds publish Denial's Nix outputs to the
public `denial.cachix.org` cache. The top-level example repeats the cache URL
and signing key because Nix does not apply the `nixConfig` of a flake used only
as an input. Direct commands against the Denial flake can accept its identical
checked-in configuration with `--accept-flake-config`.

An exact cache hit downloads the package instead of compiling the pinned
Flutter engine. A cache miss still performs the complete source build and has
required more than 48 GiB of temporary Nix store space on the validation host;
plan a builder with at least 64 GiB of free working space. Subsequent builds
reuse Nix store objects, and source filtering keeps the engine and unrelated
Flutter applications from rebuilding.

The following checked-in locks make source changes explicit:

- `nix/flutter-engine-lock.json` records every fixed-output hash associated
  with `prebuilt/flutter-engine/SOURCE_LOCK.json`;
- the three `nix/*-pubspec-lock.json` files are generated representations of
  their authoritative Dart lock or Flutter tool input.

After advancing the engine source lock, run:

```sh
tools/denial-nix refresh-engine-lock
tools/denial-nix refresh-pub-locks
tools/denial-nix verify-locks
```

The helper obtains its pinned `jq` and `yq` maintenance tools from this flake,
so they do not need to be installed globally.

The regular `tools/denial-flutter-engine refresh-metadata` workflow invokes
the corresponding Nix refresh when its required tools are available. Nix
evaluation rejects a stale engine or Pub lock before a normal package build
can silently use it.

The flake currently exposes `x86_64-linux`; native AArch64 Nix output will be
added after its engine source closure is independently pinned and validated.
