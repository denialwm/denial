#version 450
// One direction of a separable Gaussian. Taps clamp to the frost's texels,
// as Impeller's kClamp frost clamps at its edges: the images may hold room
// beyond them. Taps go in pairs: one linear read between two texels carries
// both their weights, so a kernel of `radius` texels on each side takes
// about half as many reads.

layout(set = 1, binding = 0) uniform sampler2D source;

layout(push_constant) uniform Pass {
  // Texture coordinates of the first and last texel centers of the frost.
  vec4 limits;
  // One texel along the blur direction, in texture coordinates.
  vec2 step;
  // The pass's area (uv 0..1) to texture coordinates.
  vec2 scale;
  float sigma;
  // Texels on each side.
  float radius;
}
pass;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag_color;

vec4 tap(vec2 uv) {
  return texture(source, clamp(uv, pass.limits.xy, pass.limits.zw));
}

void main() {
  const vec2 uv = v_uv * pass.scale;
  vec4 sum = tap(uv);
  float total = 1.0;
  const float falloff = -0.5 / (pass.sigma * pass.sigma);
  for (float i = 1.0; i <= pass.radius; i += 2.0) {
    const float near = exp(i * i * falloff);
    const float far = i + 1.0 <= pass.radius ? exp((i + 1.0) * (i + 1.0) * falloff) : 0.0;
    const float weight = near + far;
    const vec2 offset = pass.step * (i + far / weight);
    sum += weight * (tap(uv + offset) + tap(uv - offset));
    total += 2.0 * weight;
  }
  frag_color = sum / total;
}
