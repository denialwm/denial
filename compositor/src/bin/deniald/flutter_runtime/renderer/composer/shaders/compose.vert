#version 450
#extension GL_GOOGLE_include_directive : require
#include "draw.glsl"

layout(location = 0) out vec2 v_local;
layout(location = 1) out vec3 v_scene;
layout(location = 2) flat out uint v_draw;

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
  v_draw = index;
}
