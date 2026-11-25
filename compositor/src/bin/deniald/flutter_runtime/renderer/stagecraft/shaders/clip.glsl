#ifndef CLIP_GLSL
#define CLIP_GLSL
// A rectangle, rounded-rectangle or path clip, as draws and glass records carry
// it. Fragment shaders evaluate it with clip_coverage.glsl.
struct Clip {
  // Scene to clip space, rows of a projective 3x3.
  vec4 m0;
  vec4 m1;
  vec4 m2;
  // Left, top, right, bottom in clip space.
  vec4 rect;
  // Corner radii (x, y): upper left, upper right | lower right, lower left.
  // All zero: a hard-edged rectangle.
  vec4 radii_top;
  vec4 radii_bottom;
  // A path clip: first edge, edge count, 1 for even-odd, 1 for a path.
  // Zeros for a rectangle; `rect` then holds the path's bounds.
  uvec4 path;
};

// The frame's clips; draws and glass records name a run of them.
layout(std430, set = 0, binding = 2) restrict readonly buffer Clips {
  Clip clips[];
};
#endif
