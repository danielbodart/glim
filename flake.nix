{
  description = "glim -- a Razer Blade's keyboard backlight, as an LED the desktop can drive";

  inputs = {
    # A default rather than a constraint: `follows` it onto your own nixpkgs.
    # glim builds from source into a static binary, so any nixpkgs with Zig
    # 0.15 will do.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Razer's laptops are all x86_64.
      system = "x86_64-linux";

      # The same 0.<commits>.<build> shape `./run version` gives the release
      # binaries. Only a git ref carries revCount: reference the flake as
      # `git+https://github.com/danielbodart/glim` to get it; a `github:` ref
      # lands on 0.0.<date>.
      version = "0.${toString (self.revCount or 0)}.${self.lastModifiedDate}";

      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} = {
        glim = pkgs.callPackage ./nix/package.nix { inherit version; };
        default = self.packages.${system}.glim;
      };

      nixosModules.default = import ./nix/nixos-module.nix { inherit self; };

      checks.${system} = {
        # No Blade in a VM, so this stops short of the EC: it checks that the
        # module loads uleds and puts the unit and udev rules where systemd
        # and udev will find them, and that glim, finding no Blade, says so
        # and fails rather than registering an LED that controls nothing.
        nixos-module = pkgs.testers.runNixOSTest {
          name = "glim-nixos-module";
          nodes.machine = {
            imports = [ self.nixosModules.default ];
            services.glim.enable = true;
          };
          testScript = ''
            machine.wait_for_unit("multi-user.target")
            machine.succeed("lsmod | grep -w uleds")
            machine.succeed("test -c /dev/uleds")
            machine.succeed("systemctl cat glim.service | grep -q 'Type=notify'")
            machine.succeed("systemctl cat glim.service | grep -q 'RuntimeDirectory=glim'")
            # Enabled for every user's graphical session.
            machine.succeed("test -e /etc/systemd/user/graphical-session.target.wants/glim-follow.service")
            machine.succeed("grep -q 'ATTRS{idProduct}==\"029f\".*SYSTEMD_WANTS.*glim.service' /etc/udev/rules.d/70-glim.rules")
            machine.fail("glim probe")
            machine.fail("systemctl start glim.service")
            machine.fail("ls /sys/class/leds | grep kbd_backlight")
            # With no Blade, glim follow has nothing to do and says so, cleanly.
            machine.succeed("glim follow 2>&1 | grep -q 'nothing to follow'")
          '';
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
