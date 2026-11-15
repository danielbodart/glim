{
  description = "glim -- a Razer Blade's keyboard backlight, as an LED the desktop can drive";

  inputs = {
    # nixos-26.05, as every one of danielbodart's flakes. A default rather
    # than a constraint: `follows` it onto your own nixpkgs. The package is
    # a release tarball, fetched and laid out, so it needs little from it.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      # Razer's laptops are all x86_64.
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # THE PACKAGE IS THE RELEASE TARBALL, not a build from source (Dan,
      # 2026-11-15): glim is built once, by mise's Zig in CI's dist job,
      # checked and released, and building it again here only made a second
      # binary that was not the one released. So a release's tag is a
      # commit of its own, a child of the released trunk commit, that adds
      # nix/release.json: the version, and the tarball's URL and hash
      # (scripts/release-json.sh writes it; ci.yml's release job commits and
      # tags it). A flake fetched as github:danielbodart/glim/v<V> cannot
      # see its tag, only its commit, which is why the version is in the
      # file.
      #
      # On trunk there is no such file and no package: pin a release tag.
      # Absent rather than an error, so `nix flake check` still works there.
      releaseFile = ./nix/release.json;
      release = if builtins.pathExists releaseFile then lib.importJSON releaseFile else null;
    in
    {
      packages = lib.optionalAttrs (release != null) (
        lib.mapAttrs (
          system: asset:
          let
            glim = nixpkgs.legacyPackages.${system}.callPackage ./nix/package.nix {
              inherit (release) version;
              inherit (asset) url hash;
            };
          in
          {
            inherit glim;
            default = glim;
          }
        ) release.assets
      );

      nixosModules.default = import ./nix/nixos-module.nix { inherit self; };

      # The NixOS module's test needs the package, so it exists where
      # nix/release.json does: on a release tag, and wherever `./run nix`
      # has staged one for a tarball built there (CI's nix job, with the
      # dist job's tarball, so it tests the glim the run releases).
      checks.${system} = lib.optionalAttrs (self.packages ? ${system}) {
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
            # The release's own glim, saying it is that release.
            machine.succeed("test \"$(glim --version)\" = ${self.packages.${system}.glim.version}")
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
