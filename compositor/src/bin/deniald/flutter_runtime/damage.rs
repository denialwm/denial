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

    pub(crate) fn matches_size(&self, width: u32, height: u32) -> bool {
        self.bounds.left == 0.0
            && self.bounds.top == 0.0
            && self.bounds.right == f64::from(width)
            && self.bounds.bottom == f64::from(height)
    }

    #[cfg(test)]
    pub(super) fn intersects_pixel_rect(&self, x: u32, y: u32, width: u32, height: u32) -> bool {
        let left = f64::from(x);
        let top = f64::from(y);
        let right = left + f64::from(width);
        let bottom = top + f64::from(height);
        self.as_slice().iter().any(|damage| {
            damage.left < right && damage.right > left && damage.top < bottom && damage.bottom > top
        })
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
        // on a large native output that gap can be a material overdraw cost.
        while let Some((index, merged)) =
            self.as_slice()
                .iter()
                .enumerate()
                .find_map(|(index, rect)| {
                    incoming
                        .merge_without_overdraw(*rect)
                        .map(|merged| (index, merged))
                })
        {
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
#[path = "damage/tests.rs"]
mod tests;
