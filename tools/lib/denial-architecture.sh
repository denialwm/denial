#!/usr/bin/env bash

# Canonical architecture mapping shared by Denial's build tools. The build
# machine's architecture comes from uname(1). The target is the build machine
# unless DENIAL_TARGET_ARCH names another one: then the build is a cross build.
# The only cross build is x86_64 to aarch64.

denial_arch_normalize() {
  case "${1:-}" in
    x86_64 | amd64 | x64)
      printf '%s\n' x86_64
      ;;
    aarch64 | arm64)
      printf '%s\n' aarch64
      ;;
    *)
      printf 'unsupported build architecture: %s (expected x86_64 or aarch64)\n' \
        "${1:-<empty>}" >&2
      return 1
      ;;
  esac
}

denial_flutter_arch() {
  case "$1" in
    x86_64) printf '%s\n' x64 ;;
    aarch64) printf '%s\n' arm64 ;;
  esac
}

denial_arch_configure() {
  local detected="${1:-${DENIAL_TARGET_ARCH:-}}"
  local host="${2:-}"

  if [[ -z "$host" ]]; then
    host="$(uname -m)"
  fi
  DENIAL_HOST_ARCH="$(denial_arch_normalize "$host")" || return
  if [[ -z "$detected" ]]; then
    detected="$DENIAL_HOST_ARCH"
  fi
  DENIAL_ARCH="$(denial_arch_normalize "$detected")" || return

  DENIAL_CROSS=0
  DENIAL_RUST_TARGET=''
  if [[ "$DENIAL_ARCH" != "$DENIAL_HOST_ARCH" ]]; then
    [[ "$DENIAL_HOST_ARCH" == x86_64 && "$DENIAL_ARCH" == aarch64 ]] || {
      printf 'unsupported cross build: %s to %s (only x86_64 to aarch64)\n' \
        "$DENIAL_HOST_ARCH" "$DENIAL_ARCH" >&2
      return 1
    }
    DENIAL_CROSS=1
    DENIAL_RUST_TARGET=aarch64-unknown-linux-gnu
  fi

  DENIAL_FLUTTER_ARCH="$(denial_flutter_arch "$DENIAL_ARCH")"
  DENIAL_HOST_FLUTTER_ARCH="$(denial_flutter_arch "$DENIAL_HOST_ARCH")"
  DENIAL_FLUTTER_PLATFORM="linux-$DENIAL_FLUTTER_ARCH"
  DENIAL_HOST_FLUTTER_PLATFORM="linux-$DENIAL_HOST_FLUTTER_ARCH"

  export \
    DENIAL_ARCH \
    DENIAL_CROSS \
    DENIAL_FLUTTER_ARCH \
    DENIAL_FLUTTER_PLATFORM \
    DENIAL_HOST_ARCH \
    DENIAL_HOST_FLUTTER_ARCH \
    DENIAL_HOST_FLUTTER_PLATFORM \
    DENIAL_RUST_TARGET
}

# Engine output directories. A cross build compiles the target engine in its
# own directory, beside the build machine's.
denial_flutter_engine_target() {
  local mode="${1:-}"

  case "$mode" in
    debug | profile | release) ;;
    *)
      printf 'unsupported Flutter engine mode: %s\n' "${mode:-<empty>}" >&2
      return 1
      ;;
  esac
  [[ -n "${DENIAL_FLUTTER_ARCH:-}" ]] \
    || { printf 'build architecture is not configured\n' >&2; return 1; }

  if ((DENIAL_CROSS)); then
    printf 'denial_linux_%s_%s\n' "$DENIAL_FLUTTER_ARCH" "$mode"
  elif [[ "$DENIAL_FLUTTER_ARCH" == x64 ]]; then
    printf 'denial_host_%s\n' "$mode"
  else
    printf 'denial_host_%s_%s\n' "$mode" "$DENIAL_FLUTTER_ARCH"
  fi
}

# The build machine's engine output, which runs the Dart and asset compilers.
denial_flutter_host_engine_target() {
  local mode="${1:-}"

  if ((DENIAL_CROSS)); then
    printf 'denial_host_%s\n' "$mode"
  else
    denial_flutter_engine_target "$mode"
  fi
}

# Points Cargo, cc and pkg-config at the cross compiler and the target root
# in DENIAL_ARM64_SYSROOT. A native build changes nothing.
denial_cross_configure_rust() {
  ((DENIAL_CROSS)) || return 0
  local sysroot="${DENIAL_ARM64_SYSROOT:-}"

  [[ -n "$sysroot" && -d "$sysroot/usr/lib/pkgconfig" ]] || {
    printf 'DENIAL_ARM64_SYSROOT must name an Arch Linux ARM root: %s\n' \
      "${sysroot:-<unset>}" >&2
    return 1
  }
  command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || {
    printf 'missing cross compiler: aarch64-linux-gnu-gcc\n' >&2
    return 1
  }
  export PKG_CONFIG_ALLOW_CROSS=1
  export PKG_CONFIG_SYSROOT_DIR="$sysroot"
  export PKG_CONFIG_LIBDIR="$sysroot/usr/lib/pkgconfig:$sysroot/usr/share/pkgconfig"
  export CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc
  export CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++
  export AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar
  export CFLAGS_aarch64_unknown_linux_gnu="--sysroot=$sysroot"
  export CXXFLAGS_aarch64_unknown_linux_gnu="--sysroot=$sysroot"
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
  # The root's own library directory goes first: the cross compiler's built-in
  # one holds linker scripts that name the build machine's /lib.
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=--sysroot=$sysroot -C link-arg=-L$sysroot/usr/lib -C link-arg=-Wl,-rpath-link,$sysroot/usr/lib"
}

# Prints the canonical architecture of an ELF file, from its e_machine field.
# Packaging reads the architecture from what it packages.
denial_elf_arch() {
  local machine

  machine="$(od -An -j18 -N2 -tu2 -- "$1" 2>/dev/null | tr -d '[:space:]')"
  case "$machine" in
    62) printf '%s\n' x86_64 ;;
    183) printf '%s\n' aarch64 ;;
    *)
      printf 'not an x86_64 or aarch64 ELF file: %s\n' "$1" >&2
      return 1
      ;;
  esac
}
