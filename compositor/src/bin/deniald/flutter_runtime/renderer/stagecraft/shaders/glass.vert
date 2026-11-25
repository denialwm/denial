#version 450
#extension GL_GOOGLE_include_directive : require
#include "glass.glsl"

layout(location = 0) out vec2 v_target;
layout(location = 1) flat out uint v_glass;

void main() {
  const uint index = gl_InstanceIndex;
  const vec4 quad = glasses[index].quad;
  const vec2 corner = vec2((gl_VertexIndex & 1) != 0 ? quad.z : quad.x,
                           (gl_VertexIndex & 2) != 0 ? quad.w : quad.y);
  const vec3 p = vec3(corner, 1.0);
  gl_Position = vec4(dot(glasses[index].ndc0.xyz, p),
                     dot(glasses[index].ndc1.xyz, p), 0.0,
                     dot(glasses[index].ndc2.xyz, p));
  v_target = corner;
  v_glass = index;
}
