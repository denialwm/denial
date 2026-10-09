#!/usr/bin/env bash

# The local engine, shared by Denial's development tools. During development
# the Flutter and Skia source trees are the truth as they are on disk,
# uncommitted changes included; SOURCE_LOCK.json is the authority only for CI
# and release builds (AGENTS.md).

# Prints a short hash of a checkout's uncommitted changes, tracked and
# untracked, or nothing when it is clean. Ignored files, such as build output
# and synchronized dependencies, are not changes.
denial_local_changes() {
  local checkout="$1"

  [[ -n "$(git -C "$checkout" status --porcelain=v1 --untracked-files=normal)" ]] \
    || return 0
  {
    git -C "$checkout" diff --binary HEAD
    git -C "$checkout" ls-files -z --others --exclude-standard \
      | (cd -- "$checkout" && xargs -0r sha256sum --)
  } | sha256sum | cut -c1-16
}

# Prints a checkout's state: its HEAD, and the hash of its uncommitted
# changes after a plus when it has any.
denial_local_state() {
  local checkout="$1"
  local changes

  changes="$(denial_local_changes "$checkout")"
  printf '%s%s\n' "$(git -C "$checkout" rev-parse HEAD)" "${changes:++$changes}"
}

# Prints the source root a GN output directory was generated from. One output
# directory serves every development build, so a build from another tree
# repoints it.
denial_engine_output_root() {
  local output="$1"
  local root

  root="$(
    sed -n 's/^  command = .* --root=\([^ ]*\) .*/\1/p' "$output/build.ninja" 2>/dev/null \
      | head -n 1
  )"
  [[ -n "$root" ]] || return 1
  (cd -- "$output" && realpath -- "$root")
}

# Generates the development engine output from a Flutter tree with the
# engine tool's prepare-graph, unless it was generated from that tree
# already: lets a build or deploy use the tree it names, never the last one
# another build pointed the output at.
denial_prepare_engine_output() {
  local tool="$1"
  local flutter_root="$2"
  local output="$3"
  local wanted

  wanted="$(realpath -- "$flutter_root/engine/src")"
  [[ "$(denial_engine_output_root "$output" || true)" == "$wanted" ]] \
    && return 0
  printf 'The engine output %s is not generated from %s; generating it.\n' \
    "$output" "$flutter_root"
  "$tool" prepare-graph
  [[ "$(denial_engine_output_root "$output" || true)" == "$wanted" ]] || {
    printf 'prepare-graph did not generate %s from %s\n' "$output" "$flutter_root" >&2
    return 1
  }
}
