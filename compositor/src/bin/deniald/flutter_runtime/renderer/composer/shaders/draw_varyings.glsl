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
