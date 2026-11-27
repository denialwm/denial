#version 450
#extension GL_GOOGLE_include_directive : require
#include "draw.glsl"

#define DRAW_VARYING out
#include "draw_varyings.glsl"

void main() {
  const uint index = gl_InstanceIndex;
  const vec4 quad = draws[index].quad;
  const vec2 corner = vec2((gl_VertexIndex & 1) != 0 ? quad.z : quad.x,
                           (gl_VertexIndex & 2) != 0 ? quad.w : quad.y);
  const vec3 p = vec3(corner, 1.0);
  const vec3 ndc = vec3(dot(draws[index].ndc0.xyz, p),
                        dot(draws[index].ndc1.xyz, p),
                        dot(draws[index].ndc2.xyz, p));
  gl_Position = vec4(ndc.xy, 0.0, ndc.z);
  v_local = corner;
  v_scene = vec3(dot(draws[index].scene0.xyz, p),
                 dot(draws[index].scene1.xyz, p),
                 dot(draws[index].scene2.xyz, p));
  v_uv = vec2(dot(draws[index].uv_x.xyz, p), dot(draws[index].uv_y.xyz, p));
  v_flags = draws[index].flags;
  v_params = draws[index].params;
  v_limits = draws[index].limits;
  v_coverage = draws[index].coverage;
  v_window = draws[index].window;
  v_content = draws[index].content;
  v_frame = draws[index].frame;
  v_strip = draws[index].strip;
  v_strip_texel = vec2(draws[index].strip_u, draws[index].strip_v);
  v_clip_first = draws[index].clip_first;
  Clip head = Clip(vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), uvec4(0u));
  if (draws[index].flags.y > 0u) {
    head = clips[draws[index].clip_first];
  }
  v_clip_m0 = head.m0;
  v_clip_m1 = head.m1;
  v_clip_m2 = head.m2;
  v_clip_rect = head.rect;
  v_clip_radii_top = head.radii_top;
  v_clip_radii_bottom = head.radii_bottom;
  v_clip_path = head.path;
#ifdef LAYERED
  const uint first = draws[index].layers_first;
  for (uint layer = 0u; layer < 3u; ++layer) {
    v_layer_uv[layer] = vec2(dot(draws[first + layer].uv_x.xyz, p),
                             dot(draws[first + layer].uv_y.xyz, p));
    v_layer_limits[layer] = draws[first + layer].limits;
    v_layer_coverage[layer] = draws[first + layer].coverage;
  }
  v_layer_opacity = vec4(draws[first].params.w, draws[first].params.z,
                         draws[first + 1u].params.z, draws[first + 2u].params.z);
#endif
}
