// A window draw's coverage and client, as Impeller's window_surface.glsl.
// Shared by compose.frag and window_glass.frag; the includer declares
// `surface_texture` and the draw's varyings (draw_varyings.glsl).

// The client's app look; a stand-in when it has none (params.w is 0).
layout(set = 1, binding = 2) uniform sampler3D look_texture;

// A premultiplied client sample through its app look, as GLES grades the
// copy: straight color, the look on the SDR range, premultiplied again.
vec4 graded(vec4 color) {
  if (v_params.w == 0.0) {
    return color;
  }
  const float alpha = color.a;
  const vec3 rgb = color.rgb / max(alpha, 1.0 / 1024.0);
  // Sample texel centres: 0 and 1 land on the first and last entries.
  const float size = float(textureSize(look_texture, 0).x);
  const vec3 at = clamp(rgb, 0.0, 1.0) * ((size - 1.0) / size) + 0.5 / size;
  // Highlights above white keep their excess; GLES stores the graded copy
  // in RGBA8, which clamps.
  const vec3 looked = textureLod(look_texture, at, 0.0).rgb + max(rgb - 1.0, 0.0);
  return clamp(vec4(looked * alpha, alpha), 0.0, 1.0);
}

// Local units per target pixel, from how the window's frame maps to the
// target. Unlike fwidth of a distance, it does not jump where the distance
// turns from one edge to the other (a square corner's diagonal): there
// fwidth sums both axes, and a corner pixel whole inside the window was
// drawn partly transparent.
float localPixel(vec2 local) {
  const vec2 dx = dFdx(local);
  const vec2 dy = dFdy(local);
  return sqrt(max(abs(dx.x * dy.y - dx.y * dy.x), 1e-12));
}

// Bounds with one corner radius: whole where a pixel's centre is half a
// pixel inside.
float roundedCoverage(vec2 position, vec4 bounds, float corner_radius) {
  vec2 half_size = max((bounds.zw - bounds.xy) * 0.5, vec2(0.0));
  corner_radius = clamp(corner_radius, 0.0, min(half_size.x, half_size.y));
  vec2 q = abs(position - (bounds.xy + bounds.zw) * 0.5) - half_size +
           corner_radius;
  float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - corner_radius;
  return clamp(0.5 - d / localPixel(position), 0.0, 1.0);
}

// The window's coverage (`outer`) and its content's (`inner`), disjoint at
// the inner antialiased edge.
void windowCoverage(vec2 local, out float outer, out float inner) {
  const vec4 window = v_window;
  const vec4 content = v_content;
  const float radius = v_params.x;
  outer = roundedCoverage(local, window, radius);
  const float inset = max(content.x - window.x, 0.0);
  inner = min(outer, roundedCoverage(local, content, max(radius - inset, 0.0)));
}

// Whether `uv` falls in the draw's backing strip: a content-inset
// presentation fills it with one texel of the client
// (DenialTexturePresentation).
bool inStrip(vec2 uv) {
  const vec4 strip = v_strip;
  return strip.z > strip.x && all(greaterThanEqual(uv, strip.xy)) &&
         all(lessThan(uv, strip.zw));
}

// The strip's fill: its texel's centre, which linear sampling reads alone.
vec4 stripColor() {
  return graded(textureLod(surface_texture, v_strip_texel, 0.0));
}

bool inCoverage(vec2 uv) {
  const vec4 coverage = v_coverage;
  return all(greaterThanEqual(uv, coverage.xy)) && all(lessThanEqual(uv, coverage.zw));
}

#ifdef LAYERED
// A native window's further layers, lowest first. A layer the window does
// not have has no opacity; its binding holds a stand-in.
layout(set = 1, binding = 3) uniform sampler2D layer_textures[3];

// One layer where it covers: its buffer within its limits, times its
// opacity; transparent elsewhere, as a quad of its own would leave it.
vec4 layerColor(sampler2D image, vec2 uv, vec4 limits, vec4 coverage, float opacity) {
  if (opacity > 0.0 && all(greaterThanEqual(uv, coverage.xy)) &&
      all(lessThanEqual(uv, coverage.zw))) {
    return textureLod(image, clamp(uv, limits.xy, limits.zw), 0.0) * opacity;
  }
  return vec4(0.0);
}

// The window's layers over each other, premultiplied: what a merge of
// them into one image would hold at this point.
vec4 layeredClient() {
  vec4 color = layerColor(surface_texture, v_uv, v_limits, v_coverage, v_layer_opacity.x);
  vec4 above = layerColor(layer_textures[0], v_layer_uv[0], v_layer_limits[0],
                          v_layer_coverage[0], v_layer_opacity.y);
  color = above + color * (1.0 - above.a);
  above = layerColor(layer_textures[1], v_layer_uv[1], v_layer_limits[1],
                     v_layer_coverage[1], v_layer_opacity.z);
  color = above + color * (1.0 - above.a);
  above = layerColor(layer_textures[2], v_layer_uv[2], v_layer_limits[2],
                     v_layer_coverage[2], v_layer_opacity.w);
  return above + color * (1.0 - above.a);
}

// The layers under the window's look and surface opacity.
vec4 windowSurface(vec2 uv, float inner) {
  if (inner > 0.0 && v_flags.z != 0u) {
    return graded(layeredClient()) * v_params.z;
  }
  return vec4(0.0);
}
#else
// The client at `uv`, with its surface opacity; its strip's fill beside
// it, and transparent elsewhere outside the texture's coverage.
vec4 windowSurface(vec2 uv, float inner) {
  const vec4 limits = v_limits;
  if (inner > 0.0 && v_flags.z != 0u) {
    if (inCoverage(uv)) {
      return graded(texture(surface_texture, clamp(uv, limits.xy, limits.zw))) * v_params.z;
    }
    if (inStrip(uv)) {
      return stripColor() * v_params.z;
    }
  }
  return vec4(0.0);
}
#endif
