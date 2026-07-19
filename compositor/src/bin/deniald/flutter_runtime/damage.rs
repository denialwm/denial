use denial_flutter_engine::sys;

// Flutter normally emits a small damage list. Keep callback work and storage
// bounded if a pathological sequence produces many disjoint rectangles. A
// bounding-box collapse can repaint more pixels, but can never miss damage.
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

    fn touches(self, other: Self) -> bool {
        self.left <= other.right
            && self.right >= other.left
            && self.top <= other.bottom
            && self.bottom >= other.top
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

        // Merge transitively: growing the bounding rectangle can make it touch
        // rectangles examined earlier. The resulting superset is conservative.
        let mut index = 0;
        while index < self.len {
            if incoming.touches(self.rects[index]) {
                incoming = incoming.bounding(self.rects[index]);
                self.len -= 1;
                self.rects[index] = self.rects[self.len];
                index = 0;
            } else {
                index += 1;
            }
        }

        if self.len == MAX_DAMAGE_RECTS {
            // Equivalent to pushing a 33rd rectangle and bounding the whole
            // vector, without ever spilling the fixed-capacity hot storage.
            let bounding = self
                .as_slice()
                .iter()
                .copied()
                .fold(incoming, DamageRect::bounding);
            self.rects[0] = bounding;
            self.len = 1;
        } else {
            self.rects[self.len] = incoming;
            self.len += 1;
        }
    }

    fn is_full(&self) -> bool {
        self.as_slice() == [self.bounds]
    }

    fn set_full(&mut self) {
        self.len = 0;
        if self.bounds.left < self.bounds.right && self.bounds.top < self.bounds.bottom {
            self.rects[0] = self.bounds;
            self.len = 1;
        }
    }

    fn is_empty(&self) -> bool {
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
        assert_eq!(bounded_rects.len(), 1);

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
