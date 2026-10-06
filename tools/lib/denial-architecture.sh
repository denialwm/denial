#!/usr/bin/env bash

# Canonical native-architecture mapping shared by Denial's build tools.
# Production callers deliberately configure this from uname(1): Denial does
# not claim that an unqualified native build is a cross build.

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

denial_arch_configure() {
  local detected="${1:-}"

  if [[ -z "$detected" ]]; then
    detected="$(uname -m)"
  fi
  DENIAL_ARCH="$(denial_arch_normalize "$detected")" || return

  case "$DENIAL_ARCH" in
    x86_64)
      DENIAL_FLUTTER_ARCH=x64
      ;;
    aarch64)
      DENIAL_FLUTTER_ARCH=arm64
      ;;
  esac

  DENIAL_FLUTTER_PLATFORM="linux-$DENIAL_FLUTTER_ARCH"

  export \
    DENIAL_ARCH \
    DENIAL_FLUTTER_ARCH \
    DENIAL_FLUTTER_PLATFORM
}

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

  if [[ "$DENIAL_FLUTTER_ARCH" == x64 ]]; then
    printf 'denial_host_%s\n' "$mode"
  else
    printf 'denial_host_%s_%s\n' "$mode" "$DENIAL_FLUTTER_ARCH"
  fi
}
