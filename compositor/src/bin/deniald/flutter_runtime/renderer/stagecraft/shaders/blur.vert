#version 450
// One triangle covering the pass's target; uv 0..1 across it.

layout(location = 0) out vec2 v_uv;

void main() {
  const vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
  v_uv = uv;
  gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
