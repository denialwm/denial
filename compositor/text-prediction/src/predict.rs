//! Spatial typo search over the trie and the autocorrect decision.
//!
//! The search walks the trie with one weighted Damerau-Levenshtein row per
//! depth. A substitution costs by how far the finger landed from the
//! intended key, so a touch on the border of two keys is cheap to reread.
//! Words whose prefix lies within reach seed completions, read best first
//! from the subtree's highest frequencies.

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};

use crate::layout::{KeyboardLayout, Point};
use crate::lexicon::{Lexicon, NONE, ROOT, key_of};
use crate::tuning::Tuning;

/// What a keyboard has typed of the current word: its text, and where each
/// key was touched (`None` for keys typed without a touch point).
#[derive(Clone, Copy, Debug)]
pub struct Typed<'a> {
    pub text: &'a str,
    pub touches: &'a [Option<Point>],
    /// The first letter was capitalized by the user, not by the keyboard's
    /// sentence start: probably a name, never autocorrected.
    pub manual_capital: bool,
}

impl<'a> Typed<'a> {
    pub fn plain(text: &'a str) -> Self {
        Self {
            text,
            touches: &[],
            manual_capital: false,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Prediction {
    pub typed: String,
    /// The typed spelling is a known word.
    pub typed_is_word: bool,
    /// What a space commits instead of the typed text.
    pub correction: Option<String>,
    /// Other words, best first; never the typed text or the correction.
    pub suggestions: Vec<String>,
}

impl Prediction {
    /// What a space commits.
    pub fn committed(&self) -> &str {
        self.correction.as_deref().unwrap_or(&self.typed)
    }

    /// The suggestion strip: the committed word and the next `slots - 1`.
    pub fn strip(&self, slots: usize) -> impl Iterator<Item = &str> {
        std::iter::once(self.committed())
            .chain(self.correction.is_some().then_some(self.typed.as_str()))
            .chain(self.suggestions.iter().map(String::as_str))
            .take(slots)
    }
}

pub struct Predictor {
    pub lexicon: Lexicon,
    pub layout: KeyboardLayout,
    pub tuning: Tuning,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Case {
    Lower,
    Capitalized,
    Upper,
    Mixed,
}

fn case_of(text: &str) -> Case {
    let mut letters = text.chars().filter(|c| c.is_alphabetic());
    let Some(first) = letters.next() else {
        return Case::Lower;
    };
    let rest: Vec<bool> = letters.map(char::is_uppercase).collect();
    match (
        first.is_uppercase(),
        rest.iter().all(|&u| u),
        rest.iter().any(|&u| u),
    ) {
        (false, _, false) => Case::Lower,
        (true, true, _) if !rest.is_empty() => Case::Upper,
        (true, _, false) => Case::Capitalized,
        _ => Case::Mixed,
    }
}

fn apply_case(word: &str, case: Case) -> String {
    match case {
        Case::Lower | Case::Mixed => word.to_owned(),
        Case::Upper => word.to_uppercase(),
        Case::Capitalized => {
            let mut out = String::with_capacity(word.len());
            let mut chars = word.chars();
            if let Some(first) = chars.next() {
                out.extend(first.to_uppercase());
            }
            out.extend(chars);
            out
        }
    }
}

fn has_capitals(word: &str) -> bool {
    word.chars().any(char::is_uppercase)
}

/// `typed` spells `word`: the same letters and accents, with every capital
/// of `word` typed as one. "hello" spells "hello" and "Hello" does too, but
/// "monday" does not spell "Monday", nor "esi" "ESI".
fn spells(typed: &str, word: &str) -> bool {
    let mut typed = typed.chars();
    let mut word = word.chars();
    loop {
        match (typed.next(), word.next()) {
            (None, None) => return true,
            (Some(t), Some(w)) => {
                let same = t == w || t.to_lowercase().eq(w.to_lowercase());
                if !same || (w.is_uppercase() && !t.is_uppercase()) {
                    return false;
                }
            }
            _ => return false,
        }
    }
}

const SYMBOLS: usize = 27;

fn symbol(byte: u8) -> usize {
    match byte {
        b'a'..=b'z' => usize::from(byte - b'a'),
        _ => 26,
    }
}

fn symbol_byte(index: usize) -> u8 {
    if index < 26 {
        b'a' + index as u8
    } else {
        b'\''
    }
}

#[derive(Clone, Copy, Debug)]
struct Candidate {
    entry: u32,
    score: f32,
    cost: f32,
    completion: bool,
}

struct Search<'p> {
    lexicon: &'p Lexicon,
    tuning: &'p Tuning,
    typed: &'p [u8],
    sub: Vec<[f32; SYMBOLS]>,
    ins: Vec<f32>,
    rows: Vec<f32>,
    path: Vec<u8>,
    max_cost: f32,
    seed_cost: f32,
    max_depth: usize,
    full: Vec<(u32, f32)>,
    seeds: Vec<(u32, f32, usize)>,
}

impl Search<'_> {
    fn width(&self) -> usize {
        self.typed.len() + 1
    }

    /// Fills row `depth + 1` for the trie byte `byte` from rows up to `depth`.
    fn step(&mut self, depth: usize, byte: u8) -> (f32, f32) {
        let n = self.typed.len();
        let w = self.width();
        let t = self.tuning;
        let c = symbol(byte);
        let previous = depth.checked_sub(1).map(|index| self.path[index]);
        let delete = if byte == b'\'' {
            t.delete_apostrophe
        } else if previous == Some(byte) {
            t.delete_repeat
        } else {
            t.delete
        };
        let (done, rest) = self.rows.split_at_mut((depth + 1) * w);
        let current = &mut rest[..w];
        let above = &done[depth * w..];
        let before = depth
            .checked_sub(1)
            .map(|index| &done[index * w..(index + 1) * w]);
        current[0] = above[0] + delete;
        let mut min = current[0];
        for i in 1..=n {
            let mut value = (above[i - 1] + self.sub[i - 1][c])
                .min(above[i] + delete)
                .min(current[i - 1] + self.ins[i - 1]);
            if let (Some(before), Some(previous)) = (before, previous) {
                if i >= 2
                    && self.typed[i - 1] == previous
                    && self.typed[i - 2] == byte
                    && previous != byte
                {
                    value = value.min(before[i - 2] + t.transpose);
                }
            }
            current[i] = value;
            min = min.min(value);
        }
        (min, current[n])
    }

    fn descend(&mut self, parent: u32, depth: usize) {
        if depth >= self.max_depth {
            return;
        }
        let mut child = self.lexicon.node(parent).first_child;
        while child != NONE {
            let node = *self.lexicon.node(child);
            self.path.truncate(depth);
            self.path.push(node.byte);
            let (min, cost) = self.step(depth, node.byte);
            if min <= self.max_cost {
                if node.entry_count > 0 && cost <= self.max_cost {
                    self.full.push((child, cost));
                }
                if cost <= self.seed_cost {
                    self.seeds.push((child, cost, depth + 1));
                }
                self.descend(child, depth + 1);
            }
            child = node.next_sibling;
        }
    }
}

/// Best-first completion items, ordered by frequency through the heap
/// tuple; at equal frequency a word comes out before a subtree.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
enum Item {
    Node(u32),
    Entry(u32),
}

impl Predictor {
    pub fn new(lexicon: Lexicon, layout: KeyboardLayout, tuning: Tuning) -> Self {
        Self {
            lexicon,
            layout,
            tuning,
        }
    }

    fn substitution_table(&self, typed: &[u8], touches: &[Option<Point>]) -> Vec<[f32; SYMBOLS]> {
        let t = &self.tuning;
        let pitch = self.layout.pitch();
        typed
            .iter()
            .enumerate()
            .map(|(index, &byte)| {
                let from = touches
                    .get(index)
                    .copied()
                    .flatten()
                    .or_else(|| self.layout.center(byte));
                let mut row = [t.sub_max; SYMBOLS];
                for (symbol_index, cost) in row.iter_mut().enumerate() {
                    let target = symbol_byte(symbol_index);
                    if target == byte {
                        *cost = 0.0;
                    } else if let (Some(from), Some(to)) = (from, self.layout.center(target)) {
                        let distance = from.distance(to) / pitch;
                        *cost = (t.sub_base + t.sub_scale * distance).clamp(t.sub_min, t.sub_max);
                    }
                }
                row
            })
            .collect()
    }

    fn score(&self, entry: u32, cost: f32, completion_extra: Option<usize>) -> f32 {
        let t = &self.tuning;
        let mut score = f32::from(self.lexicon.frequency(entry)) - t.cost_weight * cost;
        match completion_extra {
            Some(extra) => score -= t.completion_penalty + t.completion_per_char * extra as f32,
            None if cost == 0.0 => score += t.exact_bonus,
            None => {}
        }
        score
    }

    fn candidates(&self, typed: &[u8], touches: &[Option<Point>]) -> Vec<Candidate> {
        let n = typed.len();
        let t = &self.tuning;
        let w = n + 1;
        let max_depth = n + 6;
        let mut ins = Vec::with_capacity(n);
        for index in 0..n {
            ins.push(if index > 0 && typed[index] == typed[index - 1] {
                t.insert_repeat
            } else {
                t.insert
            });
        }
        let mut rows = vec![0.0; (max_depth + 1) * w];
        for i in 1..=n {
            rows[i] = rows[i - 1] + ins[i - 1];
        }
        let mut search = Search {
            lexicon: &self.lexicon,
            tuning: t,
            typed,
            sub: self.substitution_table(typed, touches),
            ins,
            rows,
            path: Vec::with_capacity(max_depth),
            max_cost: t.max_cost(n),
            seed_cost: t.seed_cost(n),
            max_depth,
            full: Vec::new(),
            seeds: Vec::new(),
        };
        search.descend(ROOT, 0);

        let mut best: HashMap<u32, Candidate> = HashMap::new();
        let mut offer = |candidate: Candidate| {
            best.entry(candidate.entry)
                .and_modify(|current| {
                    if candidate.score > current.score {
                        *current = candidate;
                    }
                })
                .or_insert(candidate);
        };
        for &(node, cost) in &search.full {
            let node = self.lexicon.node(node);
            for entry in node.entry_start..node.entry_start + u32::from(node.entry_count) {
                offer(Candidate {
                    entry,
                    score: self.score(entry, cost, None),
                    cost,
                    completion: false,
                });
            }
        }

        let mut seeds = search.seeds;
        seeds.sort_by(|a, b| {
            a.1.partial_cmp(&b.1).unwrap_or(Ordering::Equal).then(
                self.lexicon
                    .node(b.0)
                    .best
                    .cmp(&self.lexicon.node(a.0).best),
            )
        });
        for &(seed, cost, depth) in seeds.iter().take(t.completion_seeds as usize) {
            let mut heap = BinaryHeap::new();
            for child in self.lexicon.children(seed) {
                heap.push((self.lexicon.node(child).best, Item::Node(child)));
            }
            let mut found = 0;
            while let Some((_, item)) = heap.pop() {
                if found >= t.completion_words as usize {
                    break;
                }
                match item {
                    Item::Entry(entry) => {
                        found += 1;
                        let extra = self
                            .lexicon
                            .word(entry)
                            .chars()
                            .count()
                            .saturating_sub(depth);
                        offer(Candidate {
                            entry,
                            score: self.score(entry, cost, Some(extra)),
                            cost,
                            completion: true,
                        });
                    }
                    Item::Node(index) => {
                        let node = self.lexicon.node(index);
                        for entry in
                            node.entry_start..node.entry_start + u32::from(node.entry_count)
                        {
                            if !self.lexicon.is_offensive(entry) {
                                heap.push((self.lexicon.frequency(entry), Item::Entry(entry)));
                            }
                        }
                        for child in self.lexicon.children(index) {
                            let best = self.lexicon.node(child).best;
                            if best > 0 {
                                heap.push((best, Item::Node(child)));
                            }
                        }
                    }
                }
            }
        }

        let mut out: Vec<Candidate> = best.into_values().collect();
        out.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(Ordering::Equal)
                .then(a.entry.cmp(&b.entry))
        });
        out
    }

    pub fn predict(&self, typed: Typed<'_>) -> Prediction {
        let mut prediction = Prediction {
            typed: typed.text.to_owned(),
            ..Prediction::default()
        };
        let Some(key) = key_of(typed.text) else {
            return prediction;
        };
        if key.is_empty() {
            return prediction;
        }
        let case = case_of(typed.text);
        let entries = self.lexicon.entries(&key);
        // The spelling itself, accents and capitals included: "citta" shares
        // a key with "città" but is not a word, and "monday" ranks "Monday"
        // like any other candidate.
        let typed_lower = typed.text.to_lowercase();
        prediction.typed_is_word = entries
            .clone()
            .any(|entry| spells(typed.text, self.lexicon.word(entry)));
        let candidates = self.candidates(&key, typed.touches);
        let t = &self.tuning;

        // A form written with capitals ("Monday", "I've") keeps them.
        let display = |entry: u32| {
            let word = self.lexicon.word(entry);
            if has_capitals(word) && case != Case::Upper {
                word.to_owned()
            } else {
                apply_case(word, case)
            }
        };

        // A capital the user typed marks a name: only a name replaces it.
        let name_typed = typed.manual_capital && case != Case::Lower;
        let capitals = has_capitals;
        // A shortcut never replaces a lowercase word of another language:
        // Italian "il" stays, though English fixes it to "I'll".
        let foreign_word = |languages: crate::lexicon::Languages| {
            entries.clone().any(|entry| {
                self.lexicon.languages(entry) & !languages != 0
                    && self.lexicon.word(entry) == typed_lower
            })
        };
        if let Some(replacement) = self
            .lexicon
            .shortcut(&key)
            .filter(|&(_, languages)| !foreign_word(languages))
            .map(|(replacement, _)| replacement)
            .filter(|replacement| !name_typed || capitals(replacement))
        {
            prediction.correction = Some(if capitals(replacement) {
                replacement.to_owned()
            } else {
                apply_case(replacement, case)
            });
        } else if !prediction.typed_is_word {
            let limit = t.auto_cost(key.len());
            prediction.correction = candidates
                .iter()
                .filter(|candidate| {
                    !candidate.completion && !self.lexicon.is_offensive(candidate.entry)
                })
                .find(|candidate| !name_typed || capitals(self.lexicon.word(candidate.entry)))
                .filter(|candidate| candidate.cost <= limit && candidate.score >= t.auto_min_score)
                .map(|candidate| display(candidate.entry));
        }
        if prediction.correction.as_deref() == Some(typed.text) {
            prediction.correction = None;
        }

        for candidate in &candidates {
            let word = self.lexicon.word(candidate.entry);
            if self.lexicon.is_offensive(candidate.entry)
                && key_of(word).as_deref() != Some(key.as_slice())
            {
                continue;
            }
            let shown = display(candidate.entry);
            if shown == typed.text
                || prediction.correction.as_deref() == Some(shown.as_str())
                || prediction.suggestions.contains(&shown)
            {
                continue;
            }
            prediction.suggestions.push(shown);
            if prediction.suggestions.len() >= 5 {
                break;
            }
        }
        prediction
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn case_patterns() {
        assert_eq!(case_of("hello"), Case::Lower);
        assert_eq!(case_of("Hello"), Case::Capitalized);
        assert_eq!(case_of("I"), Case::Capitalized);
        assert_eq!(case_of("HELLO"), Case::Upper);
        assert_eq!(case_of("iPhone"), Case::Mixed);
        assert_eq!(apply_case("hello", Case::Capitalized), "Hello");
        assert_eq!(apply_case("è", Case::Capitalized), "È");
        assert_eq!(case_of("Perché"), Case::Capitalized);
        assert!(spells("Hello", "hello"));
        assert!(spells("MONDAY", "Monday"));
        assert!(!spells("monday", "Monday"));
        assert!(!spells("citta", "città"));
    }
}
