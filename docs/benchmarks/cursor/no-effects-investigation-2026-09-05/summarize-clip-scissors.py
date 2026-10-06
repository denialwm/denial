from pathlib import Path
import json, statistics
p = Path(__file__).resolve().parent
rows = json.loads((p / 'clip-records.json').read_text())

def transform(rect, matrix):
    xs = [rect[0] * matrix[0] + matrix[12], rect[2] * matrix[0] + matrix[12]]
    ys = [rect[1] * matrix[5] + matrix[13], rect[3] * matrix[5] + matrix[13]]
    return [min(xs), min(ys), max(xs), max(ys)]

def intersect(a, b):
    return [max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])]

def contains(a, b):
    return a[0] <= b[0] and a[1] <= b[1] and a[2] >= b[2] and a[3] >= b[3]

eligible, scissor = [], []
for clip in rows:
    if (clip['type'] != 'round_rect' or not clip.get('translation_scale_only')
            or clip['op'] != 1 or not clip['rendered']):
        continue
    bounds, matrix, current = clip['bounds'], clip['matrix'], clip['current_coverage']
    rx, ry = clip['radii']
    outer = transform(bounds, matrix)
    # Expand the existing clip before intersecting the rounded bounds, so the
    # proof stays one physical pixel away from corners. Outer straight edges
    # retain the existing rectangular clip's antialiasing rules.
    needed = intersect(outer, [current[0] - 1, current[1] - 1, current[2] + 1, current[3] + 1])
    actual = intersect(outer, current)
    if needed[0] >= needed[2] or needed[1] >= needed[3]:
        continue
    strips = [[bounds[0] + rx, bounds[1], bounds[2] - rx, bounds[3]],
              [bounds[0], bounds[1] + ry, bounds[2], bounds[3] - ry]]
    if any(r[0] < r[2] and r[1] < r[3] and contains(transform(r, matrix), needed) for r in strips):
        clip['effective_clip_is_rect_with_1px_corner_margin'] = True
        clip['effective_clip'] = actual
        clip['matches_existing_scissor_threshold'] = not clip['aa'] or all(abs(round(v) - v) <= .124 for v in actual)
        eligible.append(clip)
        if clip['matches_existing_scissor_threshold']:
            scissor.append(clip)

summary = {
    'rounded_clips_rendered': sum(c['type'] == 'round_rect' and c['rendered'] for c in rows),
    'whole_current_clip_contained': sum(c['type'] == 'round_rect' and c.get('contained_with_1px_margin', False) for c in rows),
    'effective_rect_clips_with_1px_corner_margin': len(eligible),
    'effective_rect_clips_matching_existing_scissor_threshold': len(scissor),
    'post_coverage_mean_us_for_scissor_candidates': statistics.mean(c['post_coverage_us'] for c in scissor) if scissor else None,
    'examples': scissor[:2],
}
(p / 'clip-scissor-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
(p / 'clip-scissor-candidates.json').write_text(json.dumps(eligible) + '\n')
print(json.dumps({k: v for k, v in summary.items() if k != 'examples'}, indent=2))
