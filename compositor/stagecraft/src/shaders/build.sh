#!/bin/sh
# Compiles the composer's shaders. The SPIR-V is committed; run this after
# editing a shader.
set -eu
cd "$(dirname "$0")"
for shader in compose.vert compose.frag glass.vert glass.frag blur.vert blur.frag window_glass.frag; do
  glslc -O --target-env=vulkan1.3 "$shader" -o "$shader.spv"
done
# The same programs for a native window drawn from its layers.
for shader in compose.vert compose.frag window_glass.frag; do
  glslc -O --target-env=vulkan1.3 -DLAYERED "$shader" -o "${shader%.*}_layered.${shader##*.}.spv"
done
