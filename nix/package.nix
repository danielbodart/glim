# glim, built from source. Nothing to link: the binary is static with no
# libc, and what comes with it -- the unit, the udev rules, the module-load
# file -- is laid out where NixOS's systemd.packages and services.udev.packages
# look for them.
{
  lib,
  stdenv,
  zig_0_15,
  version,
}:

stdenv.mkDerivation {
  pname = "glim";
  inherit version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      ../dist/glim.service
      ../dist/glim.conf
    ];
  };

  nativeBuildInputs = [ zig_0_15 ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    # Baseline, as the release tarball is: a store path is shared through the
    # binary cache with machines other than the one that built it.
    zig build install --prefix "$out" \
      -Doptimize=ReleaseSafe -Dcpu=baseline -Dversion=${version}
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    zig build test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/systemd/system
    substitute dist/glim.service $out/lib/systemd/system/glim.service \
      --replace-fail /usr/local/bin/glim $out/bin/glim
    install -Dm644 dist/glim.conf $out/lib/modules-load.d/glim.conf
    mkdir -p $out/lib/udev/rules.d
    $out/bin/glim udev-rules > $out/lib/udev/rules.d/70-glim.rules
    runHook postInstall
  '';

  meta = {
    description = "A Razer Blade's keyboard backlight, as an LED the desktop can drive";
    homepage = "https://github.com/danielbodart/glim";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "glim";
  };
}
