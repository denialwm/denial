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
  // The surface (glass) or the material's bounds (blur), from the origin of
  // its own frame, and its corner radii: upper left, upper right, lower
  // right, lower left.
  vec4 shape;
  vec4 radii;
  // The target pixels the frost covers, and its texture coordinate limits.
  vec4 frost;
  vec4 frost_limits;
  // Non-premultiplied tint.
  vec4 tint;
  // Target pixels to the frame `shape` and `radii` are in (rows of a 2x3
  // affine; Impeller's material coordinates), and that frame's normals back
  // to target pixels (xy multiplies normal x, zw normal y).
  vec4 to_material0;
  vec4 to_material1;
  vec4 normal_transform;
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
  // A blur turned off the target's axes: it covers `shape`, not all of
  // `quad`.
  uint shaped_blur;
  uint pad0;
  uint pad1;
  // Frozen glass: drawn over the material within its shape, premultiplied;
  // zero otherwise.
  vec4 overlay;
  // Fades the material under the overlay; 1 for every other material.
  float material_opacity;
  uint pad2;
  uint pad3;
  uint pad4;
};

layout(std430, set = 0, binding = 1) readonly buffer Glasses {
  Glass glasses[];
};
