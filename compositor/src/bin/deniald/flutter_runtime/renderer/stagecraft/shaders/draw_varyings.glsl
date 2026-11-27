// What the fragment shaders need of their draw, passed flat from
// compose.vert. Adreno reads a storage buffer slowly per pixel: reading the
// draw record in every fragment cost about 6 ms of a full-screen frame on
// an Adreno 722. Includers define DRAW_VARYING as `out` (the vertex shader)
// or `in` (fragment shaders).
layout(location = 0) DRAW_VARYING vec2 v_local;
layout(location = 1) DRAW_VARYING vec3 v_scene;
// Normalized texture coordinates: affine in v_local, so interpolating them
// matches computing them per fragment.
layout(location = 2) DRAW_VARYING vec2 v_uv;
// Draw.flags, params, limits, coverage, window, content, frame and strip.
layout(location = 3) flat DRAW_VARYING uvec4 v_flags;
layout(location = 4) flat DRAW_VARYING vec4 v_params;
layout(location = 5) flat DRAW_VARYING vec4 v_limits;
layout(location = 6) flat DRAW_VARYING vec4 v_coverage;
layout(location = 7) flat DRAW_VARYING vec4 v_window;
layout(location = 8) flat DRAW_VARYING vec4 v_content;
layout(location = 9) flat DRAW_VARYING vec4 v_frame;
layout(location = 10) flat DRAW_VARYING vec4 v_strip;
layout(location = 11) flat DRAW_VARYING vec2 v_strip_texel;
layout(location = 12) flat DRAW_VARYING uint v_clip_first;
// The draw's first clip, zeros without one (clip.glsl).
layout(location = 13) flat DRAW_VARYING vec4 v_clip_m0;
layout(location = 14) flat DRAW_VARYING vec4 v_clip_m1;
layout(location = 15) flat DRAW_VARYING vec4 v_clip_m2;
layout(location = 16) flat DRAW_VARYING vec4 v_clip_rect;
layout(location = 17) flat DRAW_VARYING vec4 v_clip_radii_top;
layout(location = 18) flat DRAW_VARYING vec4 v_clip_radii_bottom;
layout(location = 19) flat DRAW_VARYING uvec4 v_clip_path;
#ifdef LAYERED
// A layered client's three further layers, lowest first: their texture
// coordinates, limits and coverage, as v_uv, v_limits and v_coverage are
// its lowest layer's. Opacities: x the lowest layer's, yzw the further ones'.
layout(location = 20) DRAW_VARYING vec2 v_layer_uv[3];
layout(location = 23) flat DRAW_VARYING vec4 v_layer_limits[3];
layout(location = 26) flat DRAW_VARYING vec4 v_layer_coverage[3];
layout(location = 29) flat DRAW_VARYING vec4 v_layer_opacity;
#endif

// The draw's clips at `scene`: its first from the varyings.
#define DRAW_CLIP_HEAD                                                  \
  Clip(v_clip_m0, v_clip_m1, v_clip_m2, v_clip_rect, v_clip_radii_top, \
       v_clip_radii_bottom, v_clip_path)
