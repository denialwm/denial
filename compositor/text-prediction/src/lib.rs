//! Word suggestions and autocorrection for Denial's software keyboard.
//!
//! The library is the engine deniald hosts next to its text-input broker;
//! `denial-predict` runs it on its own, and its `bench` command
//! measures accuracy against a simulated typist, so tuning needs neither a
//! compositor nor a device.

pub mod bench;
pub mod layout;
pub mod lexicon;
pub mod predict;
pub mod tuning;

pub use layout::{KeyboardLayout, Point};
pub use lexicon::Lexicon;
pub use predict::{Prediction, Predictor, Typed};
pub use tuning::Tuning;

/// A word list in this crate's `data/`, built by tools/build-dictionary:
/// `en`, `it`.
pub fn bundled_dictionary(language: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("data/{language}.words.gz"))
}

/// The English word list.
pub fn default_dictionary() -> std::path::PathBuf {
    bundled_dictionary("en")
}

/// The English word list, built in: the keyboard always has it.
pub const ENGLISH_WORDS: &[u8] = include_bytes!("../data/en.words.gz");
