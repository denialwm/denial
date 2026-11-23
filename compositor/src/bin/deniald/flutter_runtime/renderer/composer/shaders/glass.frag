#version 450
#extension GL_GOOGLE_include_directive : require
// A backdrop material: the frost (the Gaussian-blurred scene below it),
// drawn plain for a blur, or refracted and lit through a rounded glass
// surface (glass_shading.glsl). The output is premultiplied and blended
// over the scene: at the surface's antialiased edge that is Impeller's
// mix(scene, material, coverage) for an opaque frost.
#include "glass.glsl"
#include "clip_coverage.glsl"

layout(set = 1, binding = 0) uniform sampler2D frost_texture;

layout(location = 0) in vec2 v_target;
layout(location = 1) flat in uint v_glass;
layout(location = 0) out vec4 frag_color;

#include "glass_shading.glsl"

void main() {
  glass_index = v_glass;
  const vec3 p = vec3(v_target, 1.0);
  const vec3 scene = vec3(dot(GLASS.scene0.xyz, p), dot(GLASS.scene1.xyz, p),
                          dot(GLASS.scene2.xyz, p));
  const float clip = clipsCoverage(GLASS.clip_first, GLASS.clip_count, scene.xy / scene.z);
  // No discard: derivatives stay defined for the whole quad.
  // A turned blur's edge, antialiased over one physical pixel as
  // Impeller's analytic edges; before any branch, it takes derivatives.
  const float bounds = GLASS.shaped_blur != 0u ? edge(boundsDistance(v_target)) : 1.0;
  const vec4 material = GLASS.mode == kModeGlass ? glass(v_target) : sampleFrost(v_target);
  frag_color = material * (GLASS.opacity * clip * bounds);
}
