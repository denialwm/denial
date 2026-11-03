//! Accuracy benchmark: a simulated thumb typist on the keyboard geometry.
//!
//! Each corpus word is typed key by key. A touch lands at the key center
//! plus Gaussian noise (in key pitches) and a vertical bias; square hit boxes
//! turn it into a key. Discrete slips (omitted, doubled and swapped letters)
//! come on top. Apostrophes are never typed: the letters layer has none. The
//! Accented letters are typed without their accent, as on a letters layer
//! without accented keys. The predictor then sees exactly what a keyboard
//! would hand it. Every sample
//! draws from its own seeded generator, so results do not depend on the
//! thread count.

use std::time::Instant;

use crate::layout::Point;
use crate::lexicon::{Lexicon, key_char, key_of};
use crate::predict::{Predictor, Typed};

#[derive(Clone, Debug)]
pub struct Typist {
    /// Touch spread, standard deviation in key pitches.
    pub noise_x: f32,
    pub noise_y: f32,
    /// Mean vertical offset in key pitches; thumbs tend to land low.
    pub bias_y: f32,
    pub omit: f32,
    pub double: f32,
    pub transpose: f32,
}

impl Default for Typist {
    fn default() -> Self {
        Self {
            noise_x: 0.15,
            noise_y: 0.15,
            bias_y: 0.05,
            omit: 0.004,
            double: 0.004,
            transpose: 0.004,
        }
    }
}

/// A word to type and what the typist intends.
#[derive(Clone, Debug)]
pub struct Sample {
    /// What should end up in the text.
    pub target: String,
    /// The typist presses shift for its capitals: a name or an acronym.
    pub manual_capital: bool,
    pub in_lexicon: bool,
}

/// Words of a text, as a typist would intend them mid-sentence: lowercase
/// unless the word list (or, for unknown words, the text away from a
/// sentence start) writes them with capitals.
pub fn corpus_samples(text: &str, lexicon: &Lexicon) -> Vec<Sample> {
    let mut samples = Vec::new();
    let mut sentence_start = true;
    let mut token = String::new();
    // A digit or a letter without a key makes the whole word untypeable.
    let mut untypeable = false;
    let mut flush = |token: &mut String, untypeable: &mut bool, sentence_start: bool| {
        let word = token.trim_matches('\'');
        if !*untypeable && word.chars().any(char::is_alphabetic) {
            samples.push(sample_for(word, sentence_start, lexicon));
        }
        token.clear();
        *untypeable = false;
    };
    for character in text.chars() {
        let character = if character == '\u{2019}' {
            '\''
        } else {
            character
        };
        if (character.is_alphabetic() && key_char(character).is_some())
            || (character == '\'' && !token.is_empty())
        {
            token.push(character);
            continue;
        }
        if character.is_alphanumeric() {
            token.push('x');
            untypeable = true;
            continue;
        }
        if !token.is_empty() {
            flush(&mut token, &mut untypeable, sentence_start);
            sentence_start = false;
        }
        if matches!(character, '.' | '!' | '?') {
            sentence_start = true;
        }
    }
    if !token.is_empty() {
        flush(&mut token, &mut untypeable, sentence_start);
    }
    samples
}

fn sample_for(word: &str, sentence_start: bool, lexicon: &Lexicon) -> Sample {
    let key = key_of(word).expect("letters and apostrophes");
    let has_capitals = word.chars().any(char::is_uppercase);
    let entries = lexicon.entries(&key);
    if entries.is_empty() {
        return if has_capitals && !sentence_start {
            Sample {
                target: word.to_owned(),
                manual_capital: true,
                in_lexicon: false,
            }
        } else {
            Sample {
                target: word.to_lowercase(),
                manual_capital: false,
                in_lexicon: false,
            }
        };
    }
    let forms: Vec<&str> = entries.clone().map(|entry| lexicon.word(entry)).collect();
    if has_capitals && !sentence_start && forms.contains(&word) {
        return Sample {
            target: word.to_owned(),
            manual_capital: true,
            in_lexicon: true,
        };
    }
    let lowercase = forms
        .iter()
        .find(|form| {
            form.to_lowercase() == word.to_lowercase() && !form.chars().any(char::is_uppercase)
        })
        .or_else(|| {
            forms
                .iter()
                .find(|form| !form.chars().any(char::is_uppercase))
        });
    Sample {
        target: lowercase.copied().unwrap_or(forms[0]).to_owned(),
        manual_capital: false,
        in_lexicon: true,
    }
}

/// SplitMix64: small, fast and seedable per sample.
struct Rng(u64);

impl Rng {
    fn new(seed: u64, stream: u64) -> Self {
        let mut rng = Self(seed ^ stream.wrapping_mul(0x9e37_79b9_7f4a_7c15));
        rng.next();
        rng
    }

    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn unit(&mut self) -> f32 {
        (self.next() >> 40) as f32 / (1u64 << 24) as f32
    }

    fn gaussian(&mut self) -> f32 {
        let u = self.unit().max(1e-7);
        let v = self.unit();
        (-2.0 * u.ln()).sqrt() * (std::f32::consts::TAU * v).cos()
    }
}

/// Types `sample` as the typist would: the text the keyboard produced and
/// each key's touch point.
fn type_word(
    predictor: &Predictor,
    typist: &Typist,
    sample: &Sample,
    rng: &mut Rng,
) -> (String, Vec<Option<Point>>) {
    let layout = &predictor.layout;
    let pitch = layout.pitch();
    let space_row = layout.letters_bottom() + 3.5;
    let mut letters: Vec<char> = sample.target.chars().filter(|&c| c != '\'').collect();
    for index in 0..letters.len().saturating_sub(1) {
        if rng.unit() < typist.transpose {
            letters.swap(index, index + 1);
        }
    }
    let mut text = String::new();
    let mut touches = Vec::new();
    for letter in letters {
        if rng.unit() < typist.omit {
            continue;
        }
        let Some(center) = key_char(letter).and_then(|byte| layout.center(byte)) else {
            continue;
        };
        let repeats = if rng.unit() < typist.double { 2 } else { 1 };
        for _ in 0..repeats {
            let touch = Point::new(
                center.x + rng.gaussian() * typist.noise_x * pitch,
                center.y + (typist.bias_y + rng.gaussian() * typist.noise_y) * pitch,
            );
            if touch.y > space_row {
                continue;
            }
            if let Some(Some(byte)) = layout.key_at(touch) {
                let byte = if letter.is_uppercase() {
                    byte.to_ascii_uppercase()
                } else {
                    byte
                };
                text.push(byte as char);
                touches.push(Some(touch));
            }
        }
    }
    (text, touches)
}

#[derive(Clone, Debug, Default)]
pub struct Failure {
    pub target: String,
    pub typed: String,
    pub committed: String,
}

#[derive(Clone, Debug, Default)]
pub struct Report {
    pub words: usize,
    /// Typed exactly as intended (the target without apostrophes counts as
    /// needing a fix).
    pub clean: usize,
    pub clean_kept: usize,
    pub dirty: usize,
    pub dirty_fixed: usize,
    pub committed_right: usize,
    pub strip_right: usize,
    pub unknown: usize,
    pub unknown_kept: usize,
    pub typed_chars: usize,
    pub saved_chars: usize,
    pub latencies_us: Vec<u32>,
    pub false_corrections: Vec<Failure>,
    pub missed_fixes: Vec<Failure>,
}

impl Report {
    fn merge(&mut self, other: Report, keep: usize) {
        self.words += other.words;
        self.clean += other.clean;
        self.clean_kept += other.clean_kept;
        self.dirty += other.dirty;
        self.dirty_fixed += other.dirty_fixed;
        self.committed_right += other.committed_right;
        self.strip_right += other.strip_right;
        self.unknown += other.unknown;
        self.unknown_kept += other.unknown_kept;
        self.typed_chars += other.typed_chars;
        self.saved_chars += other.saved_chars;
        self.latencies_us.extend(other.latencies_us);
        for failure in other.false_corrections {
            if self.false_corrections.len() < keep {
                self.false_corrections.push(failure);
            }
        }
        for failure in other.missed_fixes {
            if self.missed_fixes.len() < keep {
                self.missed_fixes.push(failure);
            }
        }
    }

    pub fn accuracy(&self) -> f64 {
        ratio(self.committed_right, self.words)
    }

    pub fn false_correction_rate(&self) -> f64 {
        1.0 - ratio(self.clean_kept, self.clean)
    }

    pub fn fix_rate(&self) -> f64 {
        ratio(self.dirty_fixed, self.dirty)
    }

    pub fn strip_rate(&self) -> f64 {
        ratio(self.strip_right, self.words)
    }

    pub fn saved_rate(&self) -> f64 {
        ratio(self.saved_chars, self.typed_chars)
    }

    /// Errors per word, a false correction counting twice: undoing a
    /// changed word costs the user more than fixing a typo left alone.
    pub fn weighted_error(&self) -> f64 {
        let missed = self.dirty - self.dirty_fixed;
        let false_corrections = self.clean - self.clean_kept;
        ratio(missed + 2 * false_corrections, self.words)
    }

    pub fn latency_percentile(&self, percentile: f64) -> u32 {
        let mut sorted = self.latencies_us.clone();
        sorted.sort_unstable();
        sorted
            .get(((sorted.len() as f64 - 1.0) * percentile).round() as usize)
            .copied()
            .unwrap_or(0)
    }

    pub fn summary(&self) -> String {
        format!(
            "words {}  error {:.2}  accuracy {:.2}%  clean {:.1}%  fixed {:.1}% of {}  false {:.2}% of {}  strip3 {:.2}%  unknown kept {:.1}% of {}  saved {:.1}%  p50 {}us p99 {}us",
            self.words,
            100.0 * self.weighted_error(),
            100.0 * self.accuracy(),
            100.0 * ratio(self.clean, self.words),
            100.0 * self.fix_rate(),
            self.dirty,
            100.0 * self.false_correction_rate(),
            self.clean,
            100.0 * self.strip_rate(),
            100.0 * ratio(self.unknown_kept, self.unknown),
            self.unknown,
            100.0 * self.saved_rate(),
            self.latency_percentile(0.5),
            self.latency_percentile(0.99),
        )
    }
}

fn ratio(part: usize, whole: usize) -> f64 {
    if whole == 0 {
        0.0
    } else {
        part as f64 / whole as f64
    }
}

#[derive(Clone, Debug)]
pub struct Options {
    pub seed: u64,
    pub threads: usize,
    /// Measure keystrokes saved by completions (one prediction per prefix).
    pub completions: bool,
    /// Failure examples kept per kind.
    pub keep_failures: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            seed: 1,
            threads: 1,
            completions: true,
            keep_failures: 20,
        }
    }
}

fn run_one(
    predictor: &Predictor,
    typist: &Typist,
    sample: &Sample,
    index: usize,
    options: &Options,
    report: &mut Report,
) {
    let mut rng = Rng::new(options.seed, index as u64);
    let (typed, touches) = type_word(predictor, typist, sample, &mut rng);
    if typed.is_empty() {
        return;
    }
    let started = Instant::now();
    let prediction = predictor.predict(Typed {
        text: &typed,
        touches: &touches,
        manual_capital: sample.manual_capital,
    });
    report
        .latencies_us
        .push(started.elapsed().as_micros().min(u128::from(u32::MAX)) as u32);
    let committed = prediction.committed();
    let right = committed == sample.target;
    report.words += 1;
    report.committed_right += usize::from(right);
    report.strip_right += usize::from(prediction.strip(3).any(|word| word == sample.target));
    let failure = || Failure {
        target: sample.target.clone(),
        typed: typed.clone(),
        committed: committed.to_owned(),
    };
    if typed == sample.target {
        report.clean += 1;
        if right {
            report.clean_kept += 1;
        } else {
            report.false_corrections.push(failure());
        }
    } else {
        report.dirty += 1;
        if right {
            report.dirty_fixed += 1;
        } else {
            report.missed_fixes.push(failure());
        }
    }
    if !sample.in_lexicon {
        report.unknown += 1;
        report.unknown_kept += usize::from(right);
    }
    if options.completions {
        report.typed_chars += typed.len();
        for length in 1..typed.len() {
            let prefix = Typed {
                text: &typed[..length],
                touches: &touches[..length],
                manual_capital: sample.manual_capital,
            };
            if predictor
                .predict(prefix)
                .strip(3)
                .any(|word| word == sample.target)
            {
                report.saved_chars += typed.len() - length;
                break;
            }
        }
    }
}

pub fn run(
    predictor: &Predictor,
    typist: &Typist,
    samples: &[Sample],
    options: &Options,
) -> Report {
    let threads = options.threads.max(1).min(samples.len().max(1));
    let chunk = samples.len().div_ceil(threads).max(1);
    let mut report = Report::default();
    std::thread::scope(|scope| {
        let handles: Vec<_> = samples
            .chunks(chunk)
            .enumerate()
            .map(|(part, slice)| {
                scope.spawn(move || {
                    let mut local = Report::default();
                    for (offset, sample) in slice.iter().enumerate() {
                        run_one(
                            predictor,
                            typist,
                            sample,
                            part * chunk + offset,
                            options,
                            &mut local,
                        );
                    }
                    local
                })
            })
            .collect();
        for handle in handles {
            report.merge(
                handle.join().expect("benchmark thread"),
                options.keep_failures,
            );
        }
    });
    report
}

/// Known misspellings, one `typo<TAB>right` or `typo->right[, right]` per
/// line (Birkbeck and Wikipedia list formats).
#[derive(Clone, Debug, Default)]
pub struct PairReport {
    pub pairs: usize,
    pub skipped: usize,
    pub committed_right: usize,
    pub strip_right: usize,
    pub misses: Vec<Failure>,
}

pub fn run_pairs(predictor: &Predictor, text: &str, keep: usize) -> PairReport {
    let mut report = PairReport::default();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((typo, right)) = line.split_once("->").or_else(|| line.split_once('\t')) else {
            continue;
        };
        let typo = typo.trim();
        let rights: Vec<&str> = right
            .split(',')
            .map(str::trim)
            .filter(|r| !r.is_empty())
            .collect();
        let usable = key_of(typo).is_some_and(|key| !predictor.lexicon.contains_key(&key))
            && rights.iter().any(|r| key_of(r).is_some());
        if !usable {
            report.skipped += 1;
            continue;
        }
        let prediction = predictor.predict(Typed::plain(typo));
        report.pairs += 1;
        let committed = prediction.committed();
        if rights.contains(&committed) {
            report.committed_right += 1;
        } else if report.misses.len() < keep {
            report.misses.push(Failure {
                target: rights.join(", "),
                typed: typo.to_owned(),
                committed: committed.to_owned(),
            });
        }
        report.strip_right += usize::from(prediction.strip(3).any(|word| rights.contains(&word)));
    }
    report
}
