//! Letter-key geometry for the spatial model.
//!
//! [`KeyboardLayout::phone`] mirrors the letters layer of the mobile shell's
//! keyboard (`shell_osk_panel.dart`). The shell reports each touch as an
//! offset from its key's center in key pitches, which
//! [`KeyboardLayout::touch_at`] places on this geometry, so the keyboard's
//! real size never matters. Hit testing uses square hit boxes:
//! every point of a row band belongs to the key whose box is nearest, gaps and
//! side insets included.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

impl Point {
    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }

    pub fn distance(self, other: Self) -> f32 {
        (self.x - other.x).hypot(self.y - other.y)
    }
}

/// One key: its visual rectangle and what it types. `None` for keys that
/// type no letter (shift, backspace).
#[derive(Clone, Copy, Debug)]
pub struct Key {
    pub byte: Option<u8>,
    pub left: f32,
    pub right: f32,
}

#[derive(Clone, Debug)]
pub struct Row {
    pub top: f32,
    pub bottom: f32,
    pub keys: Vec<Key>,
}

#[derive(Clone, Debug)]
pub struct KeyboardLayout {
    rows: Vec<Row>,
    centers: [Option<Point>; 128],
    /// Horizontal distance between neighbouring letter centers, the unit of
    /// every spatial cost.
    pitch: f32,
    /// Vertical distance between neighbouring row centers.
    row_pitch: f32,
}

impl KeyboardLayout {
    pub fn new(rows: Vec<Row>) -> Self {
        let mut centers = [None; 128];
        for row in &rows {
            let y = (row.top + row.bottom) / 2.0;
            for key in &row.keys {
                if let Some(byte) = key.byte {
                    centers[usize::from(byte)] = Some(Point::new((key.left + key.right) / 2.0, y));
                }
            }
        }
        let pitch = rows
            .first()
            .and_then(|row| {
                let letters: Vec<_> = row.keys.iter().filter(|key| key.byte.is_some()).collect();
                (letters.len() >= 2).then(|| {
                    let first = letters[0];
                    let last = letters[letters.len() - 1];
                    ((last.left + last.right) - (first.left + first.right))
                        / 2.0
                        / (letters.len() - 1) as f32
                })
            })
            .unwrap_or(1.0);
        let row_pitch = match rows.as_slice() {
            [first, second, ..] => (second.top + second.bottom - first.top - first.bottom) / 2.0,
            _ => pitch,
        };
        Self {
            rows,
            centers,
            pitch,
            row_pitch,
        }
    }

    /// The mobile shell's letters layer on a `width` x `row_height` keyboard
    /// (logical pixels), with its padding, gaps and second-row inset.
    pub fn phone(width: f32, row_height: f32) -> Self {
        let compact = width < 560.0;
        let padding = if compact { 8.0 } else { 12.0 };
        let gap = if compact { 5.0 } else { 6.0 };
        let row_gap = if compact { 6.0 } else { 7.0 };
        let inner = width - 2.0 * padding;
        let rows: [(&[(Option<u8>, f32)], f32); 3] = [
            (&row_keys(b"qwertyuiop"), 0.0),
            (&row_keys(b"asdfghjkl"), 28.0f32.min(inner * 0.08)),
            (&with_ends(b"zxcvbnm"), 0.0),
        ];
        let mut out = Vec::new();
        for (index, (keys, inset)) in rows.into_iter().enumerate() {
            let top = index as f32 * (row_height + row_gap);
            let left = padding + inset;
            let span = inner - 2.0 * inset;
            let flex: f32 = keys.iter().map(|(_, flex)| flex).sum();
            let unit = (span - gap * (keys.len() - 1) as f32) / flex;
            let mut x = left;
            let mut row = Vec::new();
            for &(byte, flex) in keys {
                let right = x + unit * flex;
                row.push(Key {
                    byte,
                    left: x,
                    right,
                });
                x = right + gap;
            }
            out.push(Row {
                top,
                bottom: top + row_height,
                keys: row,
            });
        }
        Self::new(out)
    }

    pub fn pitch(&self) -> f32 {
        self.pitch
    }

    pub fn center(&self, byte: u8) -> Option<Point> {
        self.centers.get(usize::from(byte)).copied().flatten()
    }

    /// Where a touch landed that a keyboard reports as `dx` letter pitches
    /// right and `dy` row pitches down from the center of the key `byte`.
    pub fn touch_at(&self, byte: u8, dx: f32, dy: f32) -> Option<Point> {
        let center = self.center(byte)?;
        Some(Point::new(
            center.x + dx * self.pitch,
            center.y + dy * self.row_pitch,
        ))
    }

    /// The key under `point` with square hit boxes. `Some(None)` is a key
    /// that types no letter; `None` is outside every row.
    pub fn key_at(&self, point: Point) -> Option<Option<u8>> {
        let count = self.rows.len();
        let row = self.rows.iter().enumerate().find(|(index, row)| {
            let above = if *index == 0 {
                f32::NEG_INFINITY
            } else {
                (self.rows[index - 1].bottom + row.top) / 2.0
            };
            let below = if index + 1 == count {
                f32::INFINITY
            } else {
                (row.bottom + self.rows[index + 1].top) / 2.0
            };
            point.y >= above && point.y < below
        })?;
        let keys = &row.1.keys;
        let index = keys
            .iter()
            .position(|key| point.x < key.right)
            .map(|index| {
                // Between two keys the nearer edge wins.
                if index > 0 && point.x < keys[index].left {
                    let previous = keys[index - 1].right;
                    if point.x - previous < keys[index].left - point.x {
                        return index - 1;
                    }
                }
                index
            })
            .unwrap_or(keys.len() - 1);
        Some(keys[index].byte)
    }

    /// Bottom edge of the letter rows; the space row starts below it.
    pub fn letters_bottom(&self) -> f32 {
        self.rows.last().map_or(0.0, |row| row.bottom)
    }
}

fn row_keys<const N: usize>(letters: &[u8; N]) -> [(Option<u8>, f32); N] {
    letters.map(|byte| (Some(byte), 10.0))
}

fn with_ends(letters: &[u8; 7]) -> [(Option<u8>, f32); 9] {
    let mut keys = [(None, 15.0); 9];
    for (index, &byte) in letters.iter().enumerate() {
        keys[index + 1] = (Some(byte), 10.0);
    }
    keys
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn square_hit_boxes_cover_gaps_and_insets() {
        let layout = KeyboardLayout::phone(632.0, 78.0);
        let q = layout.center(b'q').unwrap();
        let w = layout.center(b'w').unwrap();
        // Just left of the q/w midpoint is q, just right is w.
        let middle = (q.x + w.x) / 2.0;
        assert_eq!(
            layout.key_at(Point::new(middle - 0.5, q.y)),
            Some(Some(b'q'))
        );
        assert_eq!(
            layout.key_at(Point::new(middle + 0.5, q.y)),
            Some(Some(b'w'))
        );
        // The second row's side inset belongs to a.
        let a = layout.center(b'a').unwrap();
        assert_eq!(layout.key_at(Point::new(1.0, a.y)), Some(Some(b'a')));
        // Shift types no letter.
        let z = layout.center(b'z').unwrap();
        assert_eq!(layout.key_at(Point::new(5.0, z.y)), Some(None));
        assert!((layout.pitch() - (w.x - q.x)).abs() < 0.01);
    }
}
