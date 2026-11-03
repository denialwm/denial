#version 460 core

// Window glass over a precomputed frost.
//
// A port of the engine's glass filter shader (Impeller glass.frag) for
// translucent windows over a backdrop frosted once for a whole scene. It
// draws the material directly: no layer, backdrop read or blur. Lengths are
// physical pixels, as in the engine. The caller keeps the depth fixed on
// screen while the shape follows the window through any scale.
//
// Only the edge band runs the full material. The flat interior, which no
// bevel, refraction or edge light reaches, reads a second copy of the frost
// with the tint, saturation and brightness already applied. A scrim over the
// window is blended here too, instead of in a second pass over the shape.
//
// The rounded surface, Snell refraction, and adaptive rim-lighting model is
// adapted from liquid_glass_renderer, Copyright 2025 Tim Lehmann for
// whynotmake.it, used under the MIT License.

#include <flutter/runtime_effect.glsl>

precision highp float;

// The material's top-left corner in drawing coordinates.
uniform vec2 uOrigin;
// Physical pixels per drawing unit along x and y.
uniform vec2 uScale;
uniform vec2 uMaterialSize;
// Top-left, top-right, bottom-right, bottom-left.
uniform vec4 uCornerRadii;
// Frost coordinates at the material origin and per physical pixel along the
// material's x and y axes.
uniform vec2 uFrostOrigin;
uniform vec2 uFrostX;
uniform vec2 uFrostY;
// Frost coordinates beyond these read the edge texels.
uniform vec4 uFrostBounds;
// Straight RGB and alpha.
uniform vec4 uTint;
uniform float uThickness;
uniform float uRefractiveIndex;
uniform float uDispersion;
uniform float uSaturation;
uniform float uTintStrength;
uniform float uBrightness;
uniform float uLightAngle;
uniform float uLightIntensity;
uniform float uEdgeStrength;
uniform float uBevelWidthScale;
uniform float uRefractionDepthScale;
uniform float uRimWidth;
uniform float uRimFalloff;
uniform float uOppositeLightStrength;
uniform float uOpacity;
// Where the window's edge is farther away than this (the bevel and its
// antialiasing), the shaded frost is the whole material.
uniform float uInteriorInset;
// Premultiplied scrim over the material, within the window's shape.
uniform vec4 uOverlay;

uniform sampler2D uFrost;
// uFrost with the tint, saturation and brightness applied.
uniform sampler2D uShadedFrost;

out vec4 fragColor;

float selectedCornerRadius(vec2 centered) {
  if (centered.y < 0.0) {
    return centered.x < 0.0 ? uCornerRadii.x : uCornerRadii.y;
  }
  return centered.x < 0.0 ? uCornerRadii.w : uCornerRadii.z;
}

float roundedBoxDistance(vec2 position) {
  vec2 half_size = max(uMaterialSize * 0.5, vec2(0.0001));
  vec2 centered = position - half_size;
  float radius =
      clamp(selectedCornerRadius(centered), 0.0, min(half_size.x, half_size.y));
  vec2 q = abs(centered) - (half_size - vec2(radius));
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// The scrim over a premultiplied material, both masked by [coverage].
vec4 withOverlay(vec4 material, float coverage) {
  vec4 overlay = uOverlay * coverage;
  return overlay + material * (1.0 - overlay.a);
}

void roundedBoxField(vec2 position,
                     out float signed_distance,
                     out vec2 outward_normal,
                     out float normal_confidence) {
  vec2 half_size = max(uMaterialSize * 0.5, vec2(0.0001));
  vec2 centered = position - half_size;
  float radius =
      clamp(selectedCornerRadius(centered), 0.0, min(half_size.x, half_size.y));
  vec2 q = abs(centered) - (half_size - vec2(radius));
  vec2 outside = max(q, 0.0);
  signed_distance = length(outside) + min(max(q.x, q.y), 0.0) - radius;

  // Below the bevel the surface is exactly flat.
  if (signed_distance <= -max(uThickness * uBevelWidthScale, 0.0001)) {
    outward_normal = vec2(0.0);
    normal_confidence = 0.0;
    return;
  }

  vec2 sign_position =
      vec2(centered.x < 0.0 ? -1.0 : 1.0, centered.y < 0.0 ? -1.0 : 1.0);
  // Smooth the distance field's undefined inner medial axis, exactly as the
  // engine shader does, so a thick bevel never splits the refracted image.
  if (outside.x > 0.0 && outside.y > 0.0) {
    outward_normal = normalize(outside) * sign_position;
  } else if (outside.x > 0.0) {
    outward_normal = vec2(sign_position.x, 0.0);
  } else if (outside.y > 0.0) {
    outward_normal = vec2(0.0, sign_position.y);
  } else {
    vec2 inward = max(-q, 0.0);
    vec2 smooth_weights = vec2(inward.y * inward.y, inward.x * inward.x);
    vec2 core_extent = max(half_size - vec2(radius), vec2(0.0001));
    smooth_weights *= clamp(abs(centered) / core_extent, 0.0, 1.0);
    float weight_length = length(smooth_weights);
    outward_normal = (weight_length > 0.0001 ? smooth_weights / weight_length
                                             : normalize(vec2(1.0))) *
                     sign_position;
  }
  // Flatten one physical pixel at the corner centre's point singularity.
  normal_confidence = smoothstep(0.0, 1.0, length(q));
}

vec4 sampleFrost(vec2 coords, vec2 pixel_offset, float spread) {
  vec2 offset = pixel_offset * spread;
  return texture(uFrost,
                 clamp(coords + uFrostX * offset.x + uFrostY * offset.y,
                       uFrostBounds.xy, uFrostBounds.zw));
}

vec3 straightRgb(vec4 color) {
  return color.rgb / max(color.a, 0.00001);
}

float glassHeight(float signed_distance, float thickness) {
  if (signed_distance < -thickness) {
    return thickness;
  }
  float x = thickness + signed_distance;
  return sqrt(max(0.0, thickness * thickness - x * x));
}

vec3 adaptiveHighlightColor(vec3 background_color) {
  const vec3 luma_weights = vec3(0.299, 0.587, 0.114);
  float luminance = dot(background_color, luma_weights);
  float maximum =
      max(max(background_color.r, background_color.g), background_color.b);
  float minimum =
      min(min(background_color.r, background_color.g), background_color.b);
  float color_saturation = maximum > 0.0 ? (maximum - minimum) / maximum : 0.0;
  vec3 colored_highlight = vec3(1.0);
  if (luminance > 0.001) {
    colored_highlight = background_color / luminance;
    float gray = dot(colored_highlight, luma_weights);
    colored_highlight = min(mix(vec3(gray), colored_highlight, 1.3), vec3(1.0));
  }
  float color_influence =
      smoothstep(0.0, 0.6, luminance) * smoothstep(0.0, 0.4, color_saturation);
  return mix(vec3(1.0), colored_highlight, color_influence);
}

vec3 glassLighting(vec3 surface_normal,
                   float signed_distance,
                   float thickness,
                   float height,
                   vec2 light_direction,
                   vec3 background_color) {
  float normalized_height = height / thickness;
  float surface_shape = clamp((1.0 - normalized_height) * 1.111, 0.0, 1.0);
  float thickness_factor = clamp((thickness - 5.0) * 0.5, 0.0, 1.0);
  float rim_position = signed_distance / uRimWidth;
  float rim = 1.0 / (1.0 + uRimFalloff * rim_position * rim_position);
  if (surface_shape < 0.01 || thickness_factor < 0.01 || rim < 0.01 ||
      uLightIntensity < 0.01 || uEdgeStrength < 0.01) {
    return vec3(0.0);
  }

  float main_light = max(0.0, dot(surface_normal.xy, light_direction));
  float opposite_light = max(0.0, dot(surface_normal.xy, -light_direction));
  float influence = main_light + opposite_light * uOppositeLightStrength;
  vec3 highlight_color = adaptiveHighlightColor(background_color);
  vec3 directional = highlight_color * 0.7 * influence * influence *
                     uLightIntensity * 2.0;
  return directional * rim * thickness_factor * surface_shape * uEdgeStrength;
}

vec3 applyGlassTint(vec3 color) {
  float strength = clamp(uTintStrength * uTint.a, 0.0, 1.0);
  float tint_luminance = dot(uTint.rgb, vec3(0.299, 0.587, 0.114));
  if (tint_luminance < 0.5) {
    return mix(color, color * uTint.rgb * 2.0, strength);
  }
  vec3 screened = vec3(1.0) - (vec3(1.0) - color) * (vec3(1.0) - uTint.rgb);
  return mix(color, screened, strength);
}

void main() {
  vec2 position = (FlutterFragCoord().xy - uOrigin) * uScale;
  vec2 coords = uFrostOrigin + uFrostX * position.x + uFrostY * position.y;
  if (roundedBoxDistance(position) < -uInteriorInset) {
    fragColor = withOverlay(
        texture(uShadedFrost, clamp(coords, uFrostBounds.xy, uFrostBounds.zw)) *
            uOpacity,
        1.0);
    return;
  }

  float signed_distance;
  vec2 outward_normal;
  float normal_confidence;
  roundedBoxField(position, signed_distance, outward_normal,
                  normal_confidence);

  float thickness = max(uThickness, 0.0001);
  float foreground_alpha = 1.0 - smoothstep(-2.0, 0.0, signed_distance);
  if (foreground_alpha < 0.01) {
    fragColor = vec4(0.0);
    return;
  }

  vec3 surface_normal = vec3(0.0, 0.0, 1.0);
  float height = thickness;
  vec2 displacement = vec2(0.0);
  float bevel_width = thickness * uBevelWidthScale;
  if (signed_distance > -bevel_width) {
    float normal_xy_length =
        clamp((bevel_width + signed_distance) / bevel_width, 0.0, 1.0) *
        normal_confidence;
    float normal_z = sqrt(max(0.0, 1.0 - normal_xy_length * normal_xy_length));
    surface_normal = normalize(
        vec3(outward_normal * normal_xy_length / uBevelWidthScale, normal_z));
    height = glassHeight(signed_distance / uBevelWidthScale, thickness);
    vec3 incident = vec3(0.0, 0.0, -1.0);
    vec3 refracted_ray =
        refract(incident, surface_normal, 1.0 / max(uRefractiveIndex, 1.0));
    float ray_length =
        (height + thickness * 8.0) / max(0.001, abs(refracted_ray.z));
    displacement = refracted_ray.xy * ray_length * uRefractionDepthScale;
  }

  vec4 refracted_green = sampleFrost(coords, displacement, 1.0);
  vec3 refracted_rgb = straightRgb(refracted_green);
  if (uDispersion > 0.0001 && any(notEqual(displacement, vec2(0.0)))) {
    float chroma = uDispersion * 0.5;
    vec4 refracted_red = sampleFrost(coords, displacement, 1.0 + chroma);
    vec4 refracted_blue = sampleFrost(coords, displacement, 1.0 - chroma);
    refracted_rgb = vec3(straightRgb(refracted_red).r, refracted_rgb.g,
                         straightRgb(refracted_blue).b);
  }

  float material_alpha = refracted_green.a;
  vec3 material_rgb = applyGlassTint(refracted_rgb);
  vec2 light_direction = vec2(cos(uLightAngle), sin(uLightAngle));
  material_rgb += glassLighting(surface_normal, signed_distance, thickness,
                                height, light_direction, refracted_rgb);
  float luminance = dot(material_rgb, vec3(0.2126, 0.7152, 0.0722));
  material_rgb = mix(vec3(luminance), material_rgb, uSaturation);
  material_rgb += uBrightness >= 0.0 ? uBrightness * (1.0 - material_rgb)
                                     : uBrightness * material_rgb;
  material_rgb = clamp(material_rgb, 0.0, 1.0);

  // Premultiplied, masked to the window's shape.
  fragColor = withOverlay(vec4(material_rgb * material_alpha, material_alpha) *
                              (foreground_alpha * uOpacity),
                          foreground_alpha);
}
