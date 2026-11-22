// The frost and glass shading of one material, shared by glass.frag and
// window_glass.frag. The surface, refraction and lighting model is
// Impeller's glass.frag (Denial's fork), adapted from liquid_glass_renderer,
// Copyright 2025 Tim Lehmann for whynotmake.it, used under the MIT License.
// The including shader declares `frost_texture` and includes glass.glsl.

// The material this fragment draws: set first in main.
uint glass_index;
#define GLASS glasses[glass_index]

vec4 sampleFrost(vec2 target) {
  const vec2 uv = (target - GLASS.frost.xy) / (GLASS.frost.zw - GLASS.frost.xy);
  // One level: no derivatives, so it may run in non-uniform control flow.
  return textureLod(frost_texture, clamp(uv, GLASS.frost_limits.xy, GLASS.frost_limits.zw), 0.0);
}

float cornerRadius(vec2 centered) {
  if (centered.y < 0.0) {
    return centered.x < 0.0 ? GLASS.radii.x : GLASS.radii.y;
  }
  return centered.x < 0.0 ? GLASS.radii.w : GLASS.radii.z;
}

// Signed distance to the rounded surface, its outward normal, and how far
// that normal can be trusted (it is undefined at a corner's centre).
void roundedBoxField(vec2 position, out float signed_distance,
                     out vec2 outward_normal, out float normal_confidence) {
  const vec2 half_size = max((GLASS.shape.zw - GLASS.shape.xy) * 0.5, vec2(0.0001));
  const vec2 centered = position - half_size;
  const float radius =
      clamp(cornerRadius(centered), 0.0, min(half_size.x, half_size.y));
  const vec2 q = abs(centered) - (half_size - vec2(radius));
  const vec2 outside = max(q, 0.0);
  signed_distance = length(outside) + min(max(q.x, q.y), 0.0) - radius;
  outward_normal = vec2(0.0);
  normal_confidence = 0.0;
  // Below the bevel the surface is flat.
  if (signed_distance <= -max(GLASS.thickness * GLASS.bevel_width_scale, 0.0001)) {
    return;
  }
  const vec2 side = vec2(centered.x < 0.0 ? -1.0 : 1.0,
                         centered.y < 0.0 ? -1.0 : 1.0);
  if (outside.x > 0.0 && outside.y > 0.0) {
    outward_normal = normalize(outside) * side;
  } else if (outside.x > 0.0) {
    outward_normal = vec2(side.x, 0.0);
  } else if (outside.y > 0.0) {
    outward_normal = vec2(0.0, side.y);
  } else {
    // Inside the corner core the exact field has no gradient on its medial
    // axis: blend the two edge normals with a harmonic smooth-min instead,
    // cancelled where the core crosses the centre lines.
    const vec2 inward = max(-q, 0.0);
    vec2 weights = vec2(inward.y * inward.y, inward.x * inward.x);
    const vec2 core = max(half_size - vec2(radius), vec2(0.0001));
    weights *= clamp(abs(centered) / core, 0.0, 1.0);
    const float weight = length(weights);
    outward_normal =
        (weight > 0.0001 ? weights / weight : normalize(vec2(1.0))) * side;
  }
  normal_confidence = smoothstep(0.0, 1.0, length(q));
}

float glassHeight(float signed_distance, float thickness) {
  if (signed_distance < -thickness) {
    return thickness;
  }
  const float x = thickness + signed_distance;
  return sqrt(max(0.0, thickness * thickness - x * x));
}

vec3 straightRgb(vec4 color) {
  return color.rgb / max(color.a, 0.00001);
}

vec3 highlightColor(vec3 background) {
  const vec3 luma = vec3(0.299, 0.587, 0.114);
  const float luminance = dot(background, luma);
  const float maximum = max(max(background.r, background.g), background.b);
  const float minimum = min(min(background.r, background.g), background.b);
  const float saturation = maximum > 0.0 ? (maximum - minimum) / maximum : 0.0;
  vec3 colored = vec3(1.0);
  if (luminance > 0.001) {
    colored = background / luminance;
    colored = min(mix(vec3(dot(colored, luma)), colored, 1.3), vec3(1.0));
  }
  const float influence =
      smoothstep(0.0, 0.6, luminance) * smoothstep(0.0, 0.4, saturation);
  return mix(vec3(1.0), colored, influence);
}

vec3 rimLight(vec3 normal, float signed_distance, float thickness,
              float height, vec3 background) {
  const float shape = clamp((1.0 - height / thickness) * 1.111, 0.0, 1.0);
  const float thick = clamp((thickness - 5.0) * 0.5, 0.0, 1.0);
  const float rim_position = signed_distance / GLASS.rim_width;
  const float rim = 1.0 / (1.0 + GLASS.rim_falloff * rim_position * rim_position);
  if (shape < 0.01 || thick < 0.01 || rim < 0.01 ||
      GLASS.light_intensity < 0.01 || GLASS.edge_strength < 0.01) {
    return vec3(0.0);
  }
  const vec2 light = vec2(cos(GLASS.light_angle), sin(GLASS.light_angle));
  const float influence = max(0.0, dot(normal.xy, light)) +
                          max(0.0, dot(normal.xy, -light)) *
                              GLASS.opposite_light_strength;
  return highlightColor(background) * 1.4 * influence * influence *
         GLASS.light_intensity * rim * thick * shape * GLASS.edge_strength;
}

vec3 tinted(vec3 color) {
  const float strength = clamp(GLASS.tint_strength * GLASS.tint.a, 0.0, 1.0);
  if (dot(GLASS.tint.rgb, vec3(0.299, 0.587, 0.114)) < 0.5) {
    return mix(color, color * GLASS.tint.rgb * 2.0, strength);
  }
  return mix(color, vec3(1.0) - (vec3(1.0) - color) * (vec3(1.0) - GLASS.tint.rgb),
             strength);
}

// The glass surface at target pixel `target`.
vec4 glass(vec2 target) {
  const vec2 position = target - GLASS.shape.xy;
  float signed_distance;
  vec2 outward_normal;
  float normal_confidence;
  roundedBoxField(position, signed_distance, outward_normal,
                  normal_confidence);
  const float coverage = 1.0 - smoothstep(-2.0, 0.0, signed_distance);
  if (coverage < 0.01) {
    return vec4(0.0);
  }
  const float thickness = max(GLASS.thickness, 0.0001);
  vec3 normal = vec3(0.0, 0.0, 1.0);
  float height = thickness;
  vec2 displacement = vec2(0.0);
  const float bevel = thickness * GLASS.bevel_width_scale;
  if (signed_distance > -bevel) {
    const float slope = clamp((bevel + signed_distance) / bevel, 0.0, 1.0) *
                        normal_confidence;
    normal = normalize(vec3(outward_normal * slope / GLASS.bevel_width_scale,
                            sqrt(max(0.0, 1.0 - slope * slope))));
    height = glassHeight(signed_distance / GLASS.bevel_width_scale, thickness);
    const vec3 ray = refract(vec3(0.0, 0.0, -1.0), normal,
                             1.0 / max(GLASS.refractive_index, 1.0));
    displacement = ray.xy * ((height + thickness * 8.0) /
                             max(0.001, abs(ray.z))) *
                   GLASS.refraction_depth_scale;
  }
  const vec4 green = sampleFrost(target + displacement);
  vec3 rgb = straightRgb(green);
  if (GLASS.dispersion > 0.0001 && any(notEqual(displacement, vec2(0.0)))) {
    const float chroma = GLASS.dispersion * 0.5;
    rgb.r = straightRgb(sampleFrost(target + displacement * (1.0 + chroma))).r;
    rgb.b = straightRgb(sampleFrost(target + displacement * (1.0 - chroma))).b;
  }
  const vec3 background = rgb;
  rgb = tinted(rgb);
  rgb += rimLight(normal, signed_distance, thickness, height, background);
  rgb = mix(vec3(dot(rgb, vec3(0.2126, 0.7152, 0.0722))), rgb, GLASS.saturation);
  rgb += GLASS.brightness >= 0.0 ? GLASS.brightness * (1.0 - rgb) : GLASS.brightness * rgb;
  rgb = clamp(rgb, 0.0, 1.0);
  return vec4(rgb * green.a, green.a) * coverage;
}

