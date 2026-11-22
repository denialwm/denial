// Shared by glass.vert and glass.frag. One record per material, read by
// instance index; the layout matches `composer::record::Glass`. Lengths are
// target pixels, y down.
#include "clip.glsl"

const uint kModeBlur = 0u;
const uint kModeGlass = 1u;

struct Glass {
  // Target pixels to normalized device coordinates and to scene
  // coordinates (for the clips), rows of projective 3x3 matrices.
  vec4 ndc0;
  vec4 ndc1;
  vec4 ndc2;
  vec4 scene0;
  vec4 scene1;
  vec4 scene2;
  // Where the material draws: left, top, right, bottom. Behind a window:
  // its material bounds, window-local.
  vec4 quad;
  // The glass surface and its corner radii: upper left, upper right,
  // lower right, lower left.
  vec4 shape;
  vec4 radii;
  // The target pixels the frost covers, and its texture coordinate limits.
  vec4 frost;
  vec4 frost_limits;
  // Non-premultiplied tint.
  vec4 tint;
  float thickness;
  float refractive_index;
  float dispersion;
  float bevel_width_scale;
  float refraction_depth_scale;
  float light_angle;
  float light_intensity;
  float edge_strength;
  float rim_width;
  float rim_falloff;
  float opposite_light_strength;
  float saturation;
  float tint_strength;
  float brightness;
  float opacity;
  uint mode;
  uint clip_count;
  // Window materials: the target's height, the client alpha the material
  // needs, and whether `quad` holds window-local material bounds.
  float target_height;
  float alpha_threshold;
  uint has_material_bounds;
  // The first of the `clip_count` clips in the frame's clip buffer.
  uint clip_first;
  uint pad0;
  uint pad1;
  uint pad2;
};

layout(std430, set = 0, binding = 1) readonly buffer Glasses {
  Glass glasses[];
};
