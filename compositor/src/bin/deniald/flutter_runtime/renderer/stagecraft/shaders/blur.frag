#version 450
// One direction of a separable Gaussian. The sampler clamps at the edges,
// as Impeller's kClamp frost. Taps go in pairs: one linear read between two
// texels carries both their weights, so a kernel of `radius` texels on each
// side takes about half as many reads.

layout(set = 1, binding = 0) uniform sampler2D source;

layout(push_constant) uniform Pass {
  // One texel along the blur direction, in texture coordinates.
  vec2 step;
  float sigma;
  // Texels on each side.
  float radius;
}
pass;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag_color;

void main() {
  vec4 sum = texture(source, v_uv);
  float total = 1.0;
  const float falloff = -0.5 / (pass.sigma * pass.sigma);
  for (float i = 1.0; i <= pass.radius; i += 2.0) {
    const float near = exp(i * i * falloff);
    const float far = i + 1.0 <= pass.radius ? exp((i + 1.0) * (i + 1.0) * falloff) : 0.0;
    const float weight = near + far;
    const vec2 offset = pass.step * (i + far / weight);
    sum += weight * (texture(source, v_uv + offset) + texture(source, v_uv - offset));
    total += 2.0 * weight;
  }
  frag_color = sum / total;
}
