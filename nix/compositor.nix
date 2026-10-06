{
  lib,
  rustPlatform,
  coreutils,
  pkg-config,
  libglvnd,
  libgbm,
  libinput,
  seatd,
  libxkbcommon,
  pam,
  libpulseaudio,
  ddcutil,
  systemd,
  wayland,
  src,
  version ? "0.0.0+unknown",
  buildIdentity ? "nix.unknown",
}:

rustPlatform.buildRustPackage {
  pname = "denial-compositor";
  inherit version src;
  sourceRoot = "source/compositor";
  DENIAL_BUILD_VERSION = buildIdentity;

  cargoLock = {
    # Keep evaluation-time lock parsing on the flake source. `src` is a
    # filtered store path that is materialized for the build, and recent Nix
    # versions do not guarantee that it exists while import-cargo-lock reads
    # the lock file during evaluation.
    lockFile = ../compositor/Cargo.lock;
    outputHashes = {
      "smithay-0.7.0" = "sha256-Dov9wh6qGuciLMTwOXM/eRA/Uo4jSvhcCqwJFdB2Vbg=";
      "smithay-drm-extras-0.1.0" = "sha256-Dov9wh6qGuciLMTwOXM/eRA/Uo4jSvhcCqwJFdB2Vbg=";
    };
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    libglvnd
    libgbm
    libinput
    seatd
    libxkbcommon
    pam
    libpulseaudio
    ddcutil
    systemd
    wayland
  ];

  cargoBuildFlags = [
    "--workspace"
    "--features"
    "denial/flutter"
    "--bins"
  ];

  doCheck = true;
  nativeCheckInputs = [ coreutils ];
  DENIAL_TEST_CAT = "${coreutils}/bin/cat";
  cargoTestFlags = [
    "--workspace"
    "--features"
    "denial/flutter"
  ];

  postInstall = ''
    test -x $out/bin/deniald
    test -x $out/bin/denialctl
    test -x $out/bin/denial-portal
  '';

  # EGL, PAM, PulseAudio, and DDC support are loaded with dlopen rather than
  # recorded as ELF dependencies. Give those sonames deterministic Nix-store
  # locations instead of relying on a host-global /usr/lib search path.
  postFixup = ''
    patchelf --add-rpath ${
      lib.makeLibraryPath [
        libglvnd
        pam
        libpulseaudio
        ddcutil
      ]
    } $out/bin/deniald
  '';

  meta = {
    description = "Native compositor and portal processes for Denial";
    homepage = "https://github.com/denialwm/denial";
    license = lib.licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
}
