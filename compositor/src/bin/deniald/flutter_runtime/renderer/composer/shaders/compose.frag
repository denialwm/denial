#version 450
#extension GL_GOOGLE_include_directive : require
#include "draw.glsl"
#include "clip_coverage.glsl"

layout(set = 1, binding = 0) uniform sampler2D surface_texture;

layout(location = 0) in vec2 v_local;
layout(location = 1) in vec3 v_scene;
layout(location = 2) flat in uint v_draw;
layout(location = 0) out vec4 frag_color;

const uint kSlice = 0u;
const uint kTexture = 1u;
const uint kWindow = 2u;

#include "window.glsl"

void main() {
  const uint index = v_draw;
  const uvec4 flags = draws[index].flags;
  const vec4 params = draws[index].params;
  const float clip =
      clipsCoverage(draws[index].clip_first, flags.y, v_scene.xy / v_scene.z);
  // No discard: derivatives stay defined for the whole quad, and a
  // transparent premultiplied result leaves the target unchanged.
  const vec4 limits = draws[index].limits;
  const vec2 uv = surfaceUv(index, v_local);
  if (flags.x == kSlice || flags.x == kTexture) {
    // A merged window's layer (flags.z) covers nothing where it reaches
    // past its buffer, as the GLES merge pass discards there.
    const bool past = flags.z != 0u &&
                      (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))));
    // A slice inside a material carries the material's clips and opacity.
    frag_color = graded(index, texture(surface_texture, clamp(uv, limits.xy, limits.zw))) *
                 (past ? 0.0 : params.y * clip);
    return;
  }
  float outer;
  float inner;
  windowCoverage(index, v_local, outer, inner);
  const vec4 surface = windowSurface(index, uv, inner);
  // Disjoint coverages avoid double blending at the inner AA edge.
  frag_color =
      (surface * inner + draws[index].frame * (outer - inner)) * params.y * clip;
}
