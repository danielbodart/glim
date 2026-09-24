# glim on NixOS: what dist/install.sh does everywhere else. The unit and the
# udev rules come from the package, so they are the same files a tarball
# install puts in /etc; this only switches them on and loads uleds.
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
  };

  config = lib.mkIf cfg.enable {
    # Nothing loads uleds on demand: it has no device alias.
    boot.kernelModules = [ "uleds" ];

    # glim.service is not enabled: the udev rules start it when a Blade
    # appears, so on any other machine it never runs.
    systemd.packages = [ cfg.package ];
    services.udev.packages = [ cfg.package ];

    # For `glim probe`.
    environment.systemPackages = [ cfg.package ];
  };
}
