# glim, as a release ships it: the tarball CI built with mise's Zig and
# released (`mise run dist`), fetched by the hash nix/release.json gives,
# not built again from source (Dan, 2026-11-15: a second build here only
# made a second binary that was not the one released). What comes with it
# -- the units, the udev rules, the module-load file -- is laid out where
# NixOS's systemd.packages and services.udev.packages look for them.
{
  lib,
  stdenvNoCC,
  fetchurl,
  version,
  url,
  hash,
}:

stdenvNoCC.mkDerivation {
  pname = "glim";
  inherit version;

  src = fetchurl { inherit url hash; };
  # The tarball's entries are at its top (./glim, ./glim.service, ...).
  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm0755 glim $out/bin/glim
    mkdir -p $out/lib/systemd/system
    substitute glim.service $out/lib/systemd/system/glim.service \
      --replace-fail /usr/local/bin/glim $out/bin/glim
    mkdir -p $out/lib/systemd/user
    substitute glim-follow.service $out/lib/systemd/user/glim-follow.service \
      --replace-fail /usr/local/bin/glim $out/bin/glim
    install -Dm644 glim.conf $out/lib/modules-load.d/glim.conf
    # The binary is static with no libc, so it runs here, in the sandbox.
    mkdir -p $out/lib/udev/rules.d
    $out/bin/glim udev-rules > $out/lib/udev/rules.d/70-glim.rules
    runHook postInstall
  '';

  # Byte for byte the binary in the tarball, which SHA256SUMS covers: it is
  # static and stripped already, so there is nothing to patch or strip.
  dontFixup = true;

  # The binary says the version release.json gives the package.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test "$($out/bin/glim --version)" = ${lib.escapeShellArg version}
    runHook postInstallCheck
  '';

  meta = {
    description = "A Razer Blade's keyboard backlight, as an LED the desktop can drive";
    homepage = "https://github.com/danielbodart/glim";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "glim";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
