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

// The record, pushed per draw: uniform across the draw, so Adreno loads it
// once rather than per pixel (a flat varying index reads the storage buffer
// per pixel).
layout(push_constant) uniform GlassPass {
  uint record;
} pass;

layout(location = 0) in vec2 v_target;
layout(location = 0) out vec4 frag_color;

#include "glass_shading.glsl"

void main() {
  glass_index = pass.record;
  const vec3 p = vec3(v_target, 1.0);
  const vec3 scene = vec3(dot(GLASS.scene0.xyz, p), dot(GLASS.scene1.xyz, p),
                          dot(GLASS.scene2.xyz, p));
  const float clip = clipsCoverage(GLASS.clip_first, GLASS.clip_count, scene.xy / scene.z);
  // No discard: derivatives stay defined for the whole quad.
  // A turned blur's edge, antialiased over one physical pixel as
  // Impeller's analytic edges; before any branch, it takes derivatives.
  const float bounds = GLASS.shaped_blur != 0u ? edge(boundsDistance(v_target)) : 1.0;
  const vec4 material = GLASS.mode == kModeGlass ? glass(v_target) : sampleFrost(v_target);
  // Frozen glass's overlay within the surface, over the faded material;
  // a no-op for every other material.
  const vec4 overlay = GLASS.overlay * glass_coverage;
  frag_color = (overlay + material * GLASS.material_opacity * (1.0 - overlay.a)) *
               (GLASS.opacity * clip * bounds);
}
