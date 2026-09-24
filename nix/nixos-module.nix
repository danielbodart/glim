# glim on NixOS: what dist/install.sh does everywhere else. The units and the
# udev rules come from the package, so they are the same files a tarball
# install puts in /etc; this switches them on and loads uleds.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.glim;
in
{
  options.services.glim = {
    enable = lib.mkEnableOption "glim, a Razer Blade's keyboard backlight as an LED UPower can drive";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.glim;
      defaultText = lib.literalExpression "glim.packages.\${system}.glim";
      description = "The glim package to use.";
    };

    follow = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run `glim follow` in every graphical session, so that brightness set
        with the Fn keys -- which the EC acts on without the desktop hearing
        of it -- reaches GNOME's slider and the level GNOME restores after
        dimming. On a machine with no Blade it exits at once.
      '';
    };

    fnHoldMs = lib.mkOption {
      type = lib.types.ints.between 0 10000;
      default = 250;
      description = ''
        After the Fn keys change the brightness, how long glim ignores the
        desktop's changes: GNOME's echo of the Fn change, coming back through
        `glim follow`, which would otherwise undo presses made since. The
        echo was measured at 15 ms at most.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Nothing loads uleds on demand: it has no device alias.
    boot.kernelModules = [ "uleds" ];

    # glim.service is not enabled: the udev rules start it when a Blade
    # appears, so on any other machine it never runs.
    systemd.packages = [ cfg.package ];
    services.udev.packages = [ cfg.package ];

    systemd.services.glim.serviceConfig.ExecStart = lib.mkIf (cfg.fnHoldMs != 250) [
      ""
      "${lib.getExe cfg.package} run --fn-hold-ms ${toString cfg.fnHoldMs}"
    ];

    systemd.user.services.glim-follow.wantedBy = lib.mkIf cfg.follow [ "graphical-session.target" ];

    # For `glim probe`.
    environment.systemPackages = [ cfg.package ];
  };
}
