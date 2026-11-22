#version 450
#extension GL_GOOGLE_include_directive : require
// A window over its backdrop material, in one draw: Impeller's
// window_surface.glsl with its backdrop. The client covers the material,
// which shows through where the client is translucent and its alpha
// exceeds the material's threshold: surface + material * (1 - surface.a).
#include "draw.glsl"
#include "glass.glsl"
#include "clip_coverage.glsl"

layout(set = 1, binding = 0) uniform sampler2D surface_texture;
layout(set = 1, binding = 1) uniform sampler2D frost_texture;

layout(location = 0) in vec2 v_local;
layout(location = 1) in vec3 v_scene;
layout(location = 2) flat in uint v_draw;
layout(location = 0) out vec4 frag_color;

#include "window.glsl"
#include "glass_shading.glsl"

// Inside the window's material bounds, when it has them (a popup's
// geometry inside its client-drawn shadow).
float materialCoverage() {
  if (GLASS.has_material_bounds == 0u) {
    return 1.0;
  }
  const vec4 bounds = GLASS.quad;
  const vec2 inside = min(v_local - bounds.xy, bounds.zw - v_local);
  const vec2 coverage =
      clamp(inside / max(fwidth(v_local), vec2(0.00001)) + 0.5, 0.0, 1.0);
  return coverage.x * coverage.y;
}

void main() {
  const uint index = v_draw;
  glass_index = draws[index].flags.w;
  const float clip = clipsCoverage(draws[index].clip_first, draws[index].flags.y,
                                   v_scene.xy / v_scene.z);
  float outer;
  float inner;
  windowCoverage(index, v_local, outer, inner);
  // Before any branch: it takes derivatives.
  const float material = materialCoverage();
  vec4 surface = windowSurface(index, surfaceUv(index, v_local), inner);
  if (material > 0.0 && surface.a > 0.0 &&
      surface.a * inner > GLASS.alpha_threshold &&
      surface.a < 1.0 - 1.0 / 1024.0) {
    // Fragment rows run top-down in memory, target pixels bottom-up.
    const vec2 target = vec2(gl_FragCoord.x, GLASS.target_height - gl_FragCoord.y);
    const vec4 backdrop =
        GLASS.mode == kModeGlass ? glass(target) : sampleFrost(target);
    surface += backdrop * material * (1.0 - surface.a);
  }
  // Disjoint coverages avoid double blending at the inner AA edge.
  frag_color = (surface * inner + draws[index].frame * (outer - inner)) *
               draws[index].params.y * clip;
}
