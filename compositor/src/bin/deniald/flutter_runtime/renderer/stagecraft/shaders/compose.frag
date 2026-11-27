#version 450
#extension GL_GOOGLE_include_directive : require
#include "clip.glsl"
#include "clip_coverage.glsl"

layout(set = 1, binding = 0) uniform sampler2D surface_texture;

#define DRAW_VARYING in
#include "draw_varyings.glsl"
layout(location = 0) out vec4 frag_color;

const uint kSlice = 0u;
const uint kTexture = 1u;
const uint kWindow = 2u;

#include "window.glsl"

void main() {
  const uvec4 flags = v_flags;
  const vec4 params = v_params;
  const float clip =
      drawClipsCoverage(DRAW_CLIP_HEAD, v_clip_first, flags.y, v_scene.xy / v_scene.z);
  // No discard: derivatives stay defined for the whole quad, and a
  // transparent premultiplied result leaves the target unchanged.
  const vec4 limits = v_limits;
  const vec2 uv = v_uv;
#ifdef LAYERED
  if (flags.x == kTexture) {
    // A native window's layers drawn as one texture.
    frag_color = graded(layeredClient()) * params.y * clip;
    return;
  }
#endif
  if (flags.x == kSlice || flags.x == kTexture) {
    // A merged window's layer (flags.z) covers nothing where it reaches
    // past its buffer, as the GLES merge pass discards there.
    const bool past = flags.z != 0u &&
                      (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))));
    const float alpha = past ? 0.0 : params.y * clip;
    // A texture beside its backing strip covers only its destination; the
    // strip takes its texel, the rest of the quad stays clear.
    if (v_strip.z > v_strip.x && !inCoverage(uv)) {
      frag_color = inStrip(uv) ? stripColor() * alpha : vec4(0.0);
      return;
    }
    // A slice inside a material carries the material's clips and opacity.
    frag_color = graded(texture(surface_texture, clamp(uv, limits.xy, limits.zw))) * alpha;
    return;
  }
  float outer;
  float inner;
  windowCoverage(v_local, outer, inner);
  const vec4 surface = windowSurface(uv, inner);
  // Disjoint coverages avoid double blending at the inner AA edge.
  frag_color = (surface * inner + v_frame * (outer - inner)) * params.y * clip;
}
