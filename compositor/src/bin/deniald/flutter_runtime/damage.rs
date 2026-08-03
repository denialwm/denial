use denial_flutter_engine::sys;

// Flutter normally emits a small damage list. Keep callback work and storage
// bounded if a pathological sequence produces many disjoint rectangles. Once
// the cap is reached, pairwise compaction may repaint extra pixels but can
// never miss damage.
const MAX_DAMAGE_RECTS: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq)]
struct DamageRect {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
}

impl DamageRect {
    const EMPTY: Self = Self {
        left: 0.0,
        top: 0.0,
        right: 0.0,
        bottom: 0.0,
    };

    fn bounding(self, other: Self) -> Self {
        Self {
            left: self.left.min(other.left),
            top: self.top.min(other.top),
            right: self.right.max(other.right),
            bottom: self.bottom.max(other.bottom),
        }
    }

    fn contains(self, other: Self) -> bool {
        self.left <= other.left
            && self.top <= other.top
            && self.right >= other.right
            && self.bottom >= other.bottom
    }

    fn area(self) -> f64 {
        (self.right - self.left) * (self.bottom - self.top)
    }

    fn intersection_area(self, other: Self) -> f64 {
        let width = self.right.min(other.right) - self.left.max(other.left);
        let height = self.bottom.min(other.bottom) - self.top.max(other.top);
        width.max(0.0) * height.max(0.0)
    }

    fn merge_without_overdraw(self, other: Self) -> Option<Self> {
        if self.contains(other) {
            return Some(self);
        }
        if other.contains(self) {
            return Some(other);
        }

        let same_vertical_span = self.top == other.top && self.bottom == other.bottom;
        let horizontal_intervals_touch = self.left <= other.right && other.left <= self.right;
        if same_vertical_span && horizontal_intervals_touch {
            return Some(self.bounding(other));
        }

        let same_horizontal_span = self.left == other.left && self.right == other.right;
        let vertical_intervals_touch = self.top <= other.bottom && other.top <= self.bottom;
        (same_horizontal_span && vertical_intervals_touch).then(|| self.bounding(other))
    }

    fn merge_overdraw(self, other: Self) -> f64 {
        self.bounding(other).area() - (self.area() + other.area() - self.intersection_area(other))
    }

    fn as_flutter(self) -> sys::FlutterRect {
        sys::FlutterRect {
            left: self.left,
            top: self.top,
            right: self.right,
            bottom: self.bottom,
        }
    }
}

enum ClippedRect {
    Empty,
    Invalid,
    Rect(DamageRect),
}

#[derive(Clone, Debug)]
pub(crate) struct DamageRegion {
    bounds: DamageRect,
    rects: [DamageRect; MAX_DAMAGE_RECTS],
    len: usize,
}

impl DamageRegion {
    pub(super) fn empty(width: u32, height: u32) -> Self {
        Self {
            bounds: DamageRect {
                left: 0.0,
                top: 0.0,
                right: f64::from(width),
                bottom: f64::from(height),
            },
            rects: [DamageRect::EMPTY; MAX_DAMAGE_RECTS],
            len: 0,
        }
    }

    pub(super) fn full(width: u32, height: u32) -> Self {
        let mut damage = Self::empty(width, height);
        damage.set_full();
        damage
    }

    #[cfg(test)]
    fn from_flutter(width: u32, height: u32, rects: &[sys::FlutterRect]) -> Self {
        let mut damage = Self::empty(width, height);
        damage.replace_from_flutter(rects);
        damage
    }

    pub(super) fn replace_from_flutter(&mut self, rects: &[sys::FlutterRect]) {
        self.clear();
        for rect in rects {
            match self.clip(*rect) {
                ClippedRect::Empty => {}
                ClippedRect::Invalid => {
                    // Invalid engine damage must degrade to a full repaint;
                    // silently dropping it could leave stale pixels visible.
                    self.set_full();
                    break;
                }
                ClippedRect::Rect(rect) => self.insert(rect),
            }
        }
    }

    pub(super) fn clear(&mut self) {
        self.len = 0;
    }

    pub(super) fn invalidate(&mut self) {
        self.set_full();
    }

    pub(super) fn union(&mut self, other: &Self) {
        if self.bounds != other.bounds {
            // Regions from different atlas generations must never be mixed.
            // If that invariant is violated, a full repaint of our own bounds
            // is the only conservative result and avoids debug-only panics.
            self.set_full();
            return;
        }
        if self.is_full() || other.is_empty() {
            return;
        }
        if other.is_full() {
            self.set_full();
            return;
        }
        for rect in other.as_slice() {
            self.insert(*rect);
        }
    }

    pub(super) fn write_flutter(&self, output: &mut Vec<sys::FlutterRect>) {
        output.extend(self.as_slice().iter().copied().map(DamageRect::as_flutter));
    }

    pub(super) fn rect_count(&self) -> usize {
        self.len
    }

    /// Returns the conservative number of damaged pixels represented by this
    /// normalized region. Coalescing can include undamaged pixels, but never
    /// excludes pixels Flutter asked the embedder to repair.
    pub(super) fn damaged_area(&self) -> f64 {
        let represented = self
            .as_slice()
            .iter()
            .copied()
            .map(DamageRect::area)
            .sum::<f64>();
        // Rectangles remain exact until the fixed-capacity compactor is
        // needed. Its conservative pair merges can overlap other entries, so
        // the sum is an upper bound and must not exceed the atlas area in
        // audit output.
        represented.min(self.bounds.area())
    }

    pub(super) fn compact_description(&self) -> String {
        if self.is_empty() {
            return "-".to_owned();
        }
        self.as_slice()
            .iter()
            .map(|rect| {
                format!(
                    "{:.0},{:.0}-{:.0},{:.0}",
                    rect.left, rect.top, rect.right, rect.bottom
                )
            })
            .collect::<Vec<_>>()
            .join(";")
    }

    pub(crate) fn intersects_pixel_rect(&self, x: u32, y: u32, width: u32, height: u32) -> bool {
        let left = f64::from(x);
        let top = f64::from(y);
        let right = left + f64::from(width);
        let bottom = top + f64::from(height);
        self.as_slice().iter().any(|damage| {
            damage.left < right && damage.right > left && damage.top < bottom && damage.bottom > top
        })
    }

    fn clip(&self, rect: sys::FlutterRect) -> ClippedRect {
        if !rect.left.is_finite()
            || !rect.top.is_finite()
            || !rect.right.is_finite()
            || !rect.bottom.is_finite()
            || rect.left > rect.right
            || rect.top > rect.bottom
        {
            return ClippedRect::Invalid;
        }

        let rect = DamageRect {
            left: rect.left.max(self.bounds.left),
            top: rect.top.max(self.bounds.top),
            right: rect.right.min(self.bounds.right),
            bottom: rect.bottom.min(self.bounds.bottom),
        };
        if rect.left >= rect.right || rect.top >= rect.bottom {
            ClippedRect::Empty
        } else {
            ClippedRect::Rect(rect)
        }
    }

    fn insert(&mut self, mut incoming: DamageRect) {
        if self.is_full() {
            return;
        }
        if incoming == self.bounds {
            self.set_full();
            return;
        }

        // Coalesce only when the union is exactly rectangular. Bounding two
        // merely touching or overlapping rectangles can fill an L-shaped gap;
        // on a multi-output atlas that gap can be most of the desktop.
        loop {
            let Some((index, merged)) =
                self.as_slice()
                    .iter()
                    .enumerate()
                    .find_map(|(index, rect)| {
                        incoming
                            .merge_without_overdraw(*rect)
                            .map(|merged| (index, merged))
                    })
            else {
                break;
            };
            incoming = merged;
            self.remove(index);
        }

        if incoming == self.bounds {
            self.set_full();
            return;
        }

        if self.len < MAX_DAMAGE_RECTS {
            self.rects[self.len] = incoming;
            self.len += 1;
            return;
        }

        // Keep callback storage bounded without collapsing the entire region
        // to one bounding box. Select the pair whose bounding rectangle adds
        // the fewest undamaged pixels. The extra candidate at index `len` is
        // `incoming`; all other candidates live in the fixed array.
        let candidate = |index: usize| {
            if index == self.len {
                incoming
            } else {
                self.rects[index]
            }
        };
        let mut best = (f64::INFINITY, f64::INFINITY, 0, self.len);
        for first in 0..self.len {
            for second in (first + 1)..=self.len {
                let a = candidate(first);
                let b = candidate(second);
                let merged = a.bounding(b);
                let choice = (a.merge_overdraw(b), merged.area(), first, second);
                if choice < best {
                    best = choice;
                }
            }
        }

        let (_, _, first, second) = best;
        let merged = candidate(first).bounding(candidate(second));
        if merged == self.bounds {
            self.set_full();
        } else if second == self.len {
            self.rects[first] = merged;
        } else {
            self.rects[first] = merged;
            self.remove(second);
            self.rects[self.len] = incoming;
            self.len += 1;
        }
    }

    fn remove(&mut self, index: usize) {
        debug_assert!(index < self.len);
        self.len -= 1;
        self.rects[index] = self.rects[self.len];
    }

    pub(super) fn is_full(&self) -> bool {
        self.as_slice() == [self.bounds]
    }

    fn set_full(&mut self) {
        self.len = 0;
        if self.bounds.left < self.bounds.right && self.bounds.top < self.bounds.bottom {
            self.rects[0] = self.bounds;
            self.len = 1;
        }
    }

    pub(super) fn is_empty(&self) -> bool {
        self.len == 0
    }

    fn as_slice(&self) -> &[DamageRect] {
        &self.rects[..self.len]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn covers(rect: &sys::FlutterRect, x: f64, y: f64) -> bool {
        rect.left <= x && x < rect.right && rect.top <= y && y < rect.bottom
    }

    fn assert_covers_expected(
        region: &DamageRegion,
        expected: &[bool],
        width: usize,
        height: usize,
    ) {
        let mut actual = Vec::new();
        region.write_flutter(&mut actual);
        for rect in &actual {
            assert!(rect.left >= 0.0 && rect.top >= 0.0);
            assert!(rect.right <= width as f64 && rect.bottom <= height as f64);
        }
        for y in 0..height {
            for x in 0..width {
                if expected[y * width + x] {
                    assert!(
                        actual
                            .iter()
                            .any(|rect| covers(rect, x as f64 + 0.5, y as f64 + 0.5)),
                        "damage did not cover ({x}, {y}): {actual:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn clipping_and_bounded_coalescing_are_conservative() {
        const WIDTH: usize = 17;
        const HEIGHT: usize = 13;
        let mut inputs = Vec::new();
        let mut expected = vec![false; WIDTH * HEIGHT];

        // Deterministic property-like corpus: negative coordinates, rectangles
        // crossing every edge, overlaps and enough islands to hit the cap.
        for index in 0..96_i32 {
            let left = (index * 37 % 29) - 8;
            let top = (index * 19 % 23) - 6;
            let right = left + 1 + (index * 11 % 7);
            let bottom = top + 1 + (index * 5 % 6);
            inputs.push(sys::FlutterRect {
                left: f64::from(left),
                top: f64::from(top),
                right: f64::from(right),
                bottom: f64::from(bottom),
            });
            for y in 0..HEIGHT {
                for x in 0..WIDTH {
                    if left <= x as i32
                        && (x as i32) < right
                        && top <= y as i32
                        && (y as i32) < bottom
                    {
                        expected[y * WIDTH + x] = true;
                    }
                }
            }
        }

        let region = DamageRegion::from_flutter(WIDTH as u32, HEIGHT as u32, &inputs);
        assert_covers_expected(&region, &expected, WIDTH, HEIGHT);

        let islands = (0..=MAX_DAMAGE_RECTS)
            .map(|index| {
                let left = (index % 11) as f64 * 3.0;
                let top = (index / 11) as f64 * 3.0;
                sys::FlutterRect {
                    left,
                    top,
                    right: left + 1.0,
                    bottom: top + 1.0,
                }
            })
            .collect::<Vec<_>>();
        let bounded = DamageRegion::from_flutter(40, 20, &islands);
        let mut bounded_rects = Vec::new();
        bounded.write_flutter(&mut bounded_rects);
        assert_eq!(bounded_rects.len(), MAX_DAMAGE_RECTS);
        assert!(!bounded.is_full());
        assert_eq!(bounded.damaged_area(), 35.0);
        assert!(!bounded.intersects_pixel_rect(4, 0, 1, 1));

        let invalid = DamageRegion::from_flutter(
            WIDTH as u32,
            HEIGHT as u32,
            &[sys::FlutterRect {
                left: f64::NAN,
                top: 0.0,
                right: 1.0,
                bottom: 1.0,
            }],
        );
        let mut invalid_rects = Vec::new();
        invalid.write_flutter(&mut invalid_rects);
        assert_eq!(invalid_rects.len(), 1);
        assert_eq!(invalid_rects[0].right, WIDTH as f64);
        assert_eq!(invalid_rects[0].bottom, HEIGHT as f64);
    }

    #[test]
    fn audit_summary_uses_the_normalized_damage_region() {
        let region = DamageRegion::from_flutter(
            100,
            80,
            &[
                sys::FlutterRect {
                    left: 10.0,
                    top: 12.0,
                    right: 30.0,
                    bottom: 32.0,
                },
                sys::FlutterRect {
                    left: 30.0,
                    top: 12.0,
                    right: 50.0,
                    bottom: 32.0,
                },
            ],
        );

        expect_damage_summary(&region, 1, 800.0, "10,12-50,32");
        assert!(!region.is_full());
        assert!(!region.is_empty());
    }

    #[test]
    fn touching_l_shape_does_not_fill_its_bounding_box() {
        let region = DamageRegion::from_flutter(
            100,
            80,
            &[
                sys::FlutterRect {
                    left: 0.0,
                    top: 0.0,
                    right: 40.0,
                    bottom: 80.0,
                },
                sys::FlutterRect {
                    left: 40.0,
                    top: 0.0,
                    right: 100.0,
                    bottom: 30.0,
                },
                sys::FlutterRect {
                    left: 40.0,
                    top: 50.0,
                    right: 100.0,
                    bottom: 80.0,
                },
            ],
        );

        assert_eq!(region.rect_count(), 3);
        assert!(!region.is_full());
        assert!(region.intersects_pixel_rect(5, 35, 1, 1));
        assert!(!region.intersects_pixel_rect(50, 35, 1, 1));
    }

    #[test]
    fn complex_frame_region_stays_partial_when_added_to_buffer_history() {
        let frame = DamageRegion::from_flutter(
            100,
            80,
            &[
                sys::FlutterRect {
                    left: 0.0,
                    top: 0.0,
                    right: 40.0,
                    bottom: 80.0,
                },
                sys::FlutterRect {
                    left: 40.0,
                    top: 0.0,
                    right: 100.0,
                    bottom: 30.0,
                },
                sys::FlutterRect {
                    left: 40.0,
                    top: 50.0,
                    right: 100.0,
                    bottom: 80.0,
                },
            ],
        );
        let mut history = DamageRegion::empty(100, 80);

        history.union(&frame);

        assert_eq!(history.rect_count(), 3);
        assert!(!history.is_full());
        assert!(!history.intersects_pixel_rect(50, 35, 1, 1));
    }

    #[test]
    fn identical_and_rectangular_neighbors_coalesce_without_growth() {
        let mut region = DamageRegion::from_flutter(
            100,
            80,
            &[
                sys::FlutterRect {
                    left: 10.0,
                    top: 12.0,
                    right: 30.0,
                    bottom: 32.0,
                },
                sys::FlutterRect {
                    left: 30.0,
                    top: 12.0,
                    right: 50.0,
                    bottom: 32.0,
                },
            ],
        );
        let identical = region.clone();

        for _ in 0..100 {
            region.union(&identical);
        }

        expect_damage_summary(&region, 1, 800.0, "10,12-50,32");
    }

    fn expect_damage_summary(
        region: &DamageRegion,
        rect_count: usize,
        area: f64,
        description: &str,
    ) {
        assert_eq!(region.rect_count(), rect_count);
        assert_eq!(region.damaged_area(), area);
        assert_eq!(region.compact_description(), description);
    }

    #[test]
    fn cross_generation_union_degrades_to_full_local_damage() {
        let mut current = DamageRegion::from_flutter(
            20,
            10,
            &[sys::FlutterRect {
                left: 1.0,
                top: 1.0,
                right: 2.0,
                bottom: 2.0,
            }],
        );
        let stale_generation = DamageRegion::from_flutter(
            30,
            15,
            &[sys::FlutterRect {
                left: 25.0,
                top: 12.0,
                right: 29.0,
                bottom: 14.0,
            }],
        );

        current.union(&stale_generation);
        let mut output = Vec::new();
        current.write_flutter(&mut output);
        assert_eq!(output.len(), 1);
        assert_eq!(output[0].left, 0.0);
        assert_eq!(output[0].top, 0.0);
        assert_eq!(output[0].right, 20.0);
        assert_eq!(output[0].bottom, 10.0);
    }
}
