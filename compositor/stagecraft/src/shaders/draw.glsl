// Shared by compose.vert and compose.frag. One record per draw, read by
// instance index; the layout matches `composer::record::Draw`.
#include "clip.glsl"

struct Draw {
  // Local to normalized device coordinates and local to scene, rows of
  // projective 3x3 matrices.
  vec4 ndc0;
  vec4 ndc1;
  vec4 ndc2;
  vec4 scene0;
  vec4 scene1;
  vec4 scene2;
  // The local quad: left, top, right, bottom.
  vec4 quad;
  // Local to normalized texture coordinates: u = dot(uv_x.xyz, (x, y, 1)).
  vec4 uv_x;
  vec4 uv_y;
  // Texture coordinates are clamped to these limits.
  vec4 limits;
  // Window: where the texture covers, in texture coordinates.
  vec4 coverage;
  // Window bounds and content bounds, local.
  vec4 window;
  vec4 content;
  // Window frame color, premultiplied.
  vec4 frame;
  // x radius, y opacity, z surface opacity, w 1 when the client has an
  // app look (window.glsl).
  vec4 params;
  // x kind (0 slice, 1 texture, 2 window), y clip count, z a window's
  // surface or a merged layer's edge (compose.frag), w a window's material
  // record (window_glass.frag).
  uvec4 flags;
  // A presentation's backing strip in texture coordinates, empty without
  // one (window.glsl).
  vec4 strip;
  // The first of the draw's clips in the frame's clip buffer.
  uint clip_first;
  // The texel centre that fills the strip, in texture coordinates.
  float strip_u;
  float strip_v;
  // A layered draw (the LAYERED programs): the first of the three records
  // that hold its further layers. Each gives a layer's uv_x, uv_y, limits,
  // coverage and, in params.z, opacity; the first one's params.w is the
  // opacity of this draw's own layer, the lowest.
  uint layers_first;
};

// Binding 1 holds glass records (glass.glsl), binding 2 clips
// (clip_coverage.glsl).
layout(std430, set = 0, binding = 0) readonly buffer Draws {
  Draw draws[];
};
