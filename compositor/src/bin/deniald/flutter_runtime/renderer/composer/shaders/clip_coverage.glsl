// Clip coverage for fragment shaders; needs clip.glsl.

// The frame's clips; draws and glass records name a run of them.
layout(std430, set = 0, binding = 2) readonly buffer Clips {
  Clip clips[];
};

// Path clips' polygon edges in their clips' spaces: x0, y0, x1, y1.
layout(std430, set = 0, binding = 3) readonly buffer Edges {
  vec4 edges[];
};

// A path clip at the pixel centre `q`, as the engine's single-sample
// stencil fill: in or out. Edges count where they cross the ray from `q`
// towards +x, each row half-open (an edge holds its upper end, not its
// lower), signed by direction for the nonzero rule.
float pathCoverage(uvec4 path, vec4 bounds, vec2 q) {
  if (q.x < bounds.x || q.x >= bounds.z || q.y < bounds.y || q.y >= bounds.w) {
    return 0.0;
  }
  int winding = 0;
  for (uint i = path.x; i < path.x + path.y; ++i) {
    const vec4 e = edges[i];
    if ((e.y <= q.y) != (e.w <= q.y)) {
      const float x = e.x + (q.y - e.y) * (e.z - e.x) / (e.w - e.y);
      if (x > q.x) {
        winding += e.w > e.y ? 1 : -1;
      }
    }
  }
  const bool inside = path.z != 0u ? (winding & 1) != 0 : winding != 0;
  return inside ? 1.0 : 0.0;
}

// One physical pixel of antialiasing, as Impeller's analytic edges.
float edge(float distance) {
  return clamp(0.5 - distance / max(fwidth(distance), 0.00001), 0.0, 1.0);
}

float clipCoverage(Clip clip, vec2 scene) {
  const vec3 p = vec3(scene, 1.0);
  const float w = dot(clip.m2.xyz, p);
  const vec2 q = vec2(dot(clip.m0.xyz, p), dot(clip.m1.xyz, p)) / w;
  const vec4 rect = clip.rect;
  if (clip.path.w != 0u) {
    return pathCoverage(clip.path, rect, q);
  }
  if (all(equal(clip.radii_top, vec4(0.0))) &&
      all(equal(clip.radii_bottom, vec4(0.0)))) {
    // Hard edges: a pixel is in when its centre is, as a non-AA clip.
    return (q.x >= rect.x && q.x < rect.z && q.y >= rect.y && q.y < rect.w)
               ? 1.0
               : 0.0;
  }
  // Radii are scaled to fit (record.rs), so the four corner boxes are
  // disjoint: a point is in at most one, and only there is the edge curved.
  const vec2 upper_left = clip.radii_top.xy;
  const vec2 upper_right = clip.radii_top.zw;
  const vec2 lower_right = clip.radii_bottom.xy;
  const vec2 lower_left = clip.radii_bottom.zw;
  vec2 radius = vec2(0.0);
  vec2 corner = vec2(0.0);
  if (q.x < rect.x + upper_left.x && q.y < rect.y + upper_left.y) {
    radius = upper_left;
    corner = rect.xy + upper_left;
  } else if (q.x > rect.z - upper_right.x && q.y < rect.y + upper_right.y) {
    radius = upper_right;
    corner = vec2(rect.z - upper_right.x, rect.y + upper_right.y);
  } else if (q.x > rect.z - lower_right.x && q.y > rect.w - lower_right.y) {
    radius = lower_right;
    corner = rect.zw - lower_right;
  } else if (q.x < rect.x + lower_left.x && q.y > rect.w - lower_left.y) {
    radius = lower_left;
    corner = vec2(rect.x + lower_left.x, rect.w - lower_left.y);
  }
  float distance;
  if (radius.x > 0.0 && radius.y > 0.0) {
    // Scaled circle distance to the corner's ellipse.
    distance = (length((q - corner) / radius) - 1.0) * min(radius.x, radius.y);
  } else {
    distance = max(max(rect.x - q.x, q.x - rect.z), max(rect.y - q.y, q.y - rect.w));
  }
  return edge(distance);
}

// The product of `count` clips from `first`.
float clipsCoverage(uint first, uint count, vec2 scene) {
  float coverage = 1.0;
  for (uint i = 0u; i < count; ++i) {
    coverage *= clipCoverage(clips[first + i], scene);
  }
  return coverage;
}
