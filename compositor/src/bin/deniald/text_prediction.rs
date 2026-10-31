//! Word suggestions for the software keyboard.
//!
//! A helper thread owns the predictor, so loading the word lists and walking
//! the trie never delay a frame. The keyboard asks again on every key; only
//! the newest question waits, older ones are dropped unanswered.
//!
//! English is built in. Another language is on when its word list is
//! installed as `denial/dictionaries/<language>.words.gz` in a data
//! directory; an installed English list replaces the built-in one.

use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Instant;

use denial_text_prediction::lexicon::{decode, key_char};
use denial_text_prediction::{KeyboardLayout, Lexicon, Point, Predictor, Tuning, Typed};
use smithay::reexports::calloop::channel::{Channel, Sender, channel};
use tracing::{info, warn};

use crate::wire::{TextPrediction, TextPredictionRequest};

const DICTIONARY_DIRECTORY: &str = "denial/dictionaries";
const DICTIONARY_SUFFIX: &str = ".words.gz";
const ENGLISH: &str = "en";
/// Word lists past the predictor's limit are ignored.
const MAX_LANGUAGES: usize = 8;
/// The layout touches are measured on; offsets come in key pitches, so only
/// its proportions matter. These are the ones the tuning was fitted on.
const LAYOUT_WIDTH: f32 = 632.0;
const LAYOUT_ROW_HEIGHT: f32 = 70.0;

#[derive(Default)]
struct Inbox {
    request: Option<TextPredictionRequest>,
    closed: bool,
}

type Shared = Arc<(Mutex<Inbox>, Condvar)>;

pub(super) struct TextPredictionService {
    inbox: Shared,
    worker: Option<JoinHandle<()>>,
}

impl TextPredictionService {
    pub(super) fn start() -> Result<(Self, Channel<TextPrediction>), std::io::Error> {
        let (answers, source) = channel();
        let inbox = Shared::default();
        let worker_inbox = inbox.clone();
        let worker = thread::Builder::new()
            .name("denial-predict".to_owned())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("text-prediction");
                serve(&worker_inbox, &answers);
            })?;
        Ok((
            Self {
                inbox,
                worker: Some(worker),
            },
            source,
        ))
    }

    /// Replaces any question still waiting.
    pub(super) fn ask(&self, request: TextPredictionRequest) {
        let (inbox, wake) = &*self.inbox;
        inbox
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .request = Some(request);
        wake.notify_one();
    }
}

impl Drop for TextPredictionService {
    fn drop(&mut self) {
        let (inbox, wake) = &*self.inbox;
        inbox
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .closed = true;
        wake.notify_one();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn serve(inbox: &Shared, answers: &Sender<TextPrediction>) {
    let started = Instant::now();
    let (predictor, languages) = match load() {
        Ok(loaded) => loaded,
        Err(error) => {
            warn!(%error, "the keyboard has no word suggestions");
            return;
        }
    };
    info!(
        languages = ?languages,
        words = predictor.lexicon.len(),
        elapsed_ms = started.elapsed().as_millis() as u64,
        "keyboard word suggestions ready"
    );
    let (inbox, wake) = &**inbox;
    loop {
        let request = {
            let mut guard = inbox.lock().unwrap_or_else(|error| error.into_inner());
            loop {
                if guard.closed {
                    return;
                }
                if let Some(request) = guard.request.take() {
                    break request;
                }
                guard = wake.wait(guard).unwrap_or_else(|error| error.into_inner());
            }
        };
        if answers
            .send(answer(&predictor, &languages, request))
            .is_err()
        {
            return;
        }
    }
}

fn answer(
    predictor: &Predictor,
    languages: &[String],
    request: TextPredictionRequest,
) -> TextPrediction {
    let touches: Vec<Option<Point>> = request
        .word
        .chars()
        .zip(
            request
                .touches
                .iter()
                .copied()
                .chain(std::iter::repeat(None)),
        )
        .map(|(character, offset)| {
            let (dx, dy) = offset?;
            predictor.layout.touch_at(key_char(character)?, dx, dy)
        })
        .collect();
    let prediction = predictor.predict(Typed {
        text: &request.word,
        touches: &touches,
        manual_capital: request.manual_capital,
    });
    TextPrediction {
        serial: request.serial,
        word: request.word,
        correction: prediction.correction,
        suggestions: prediction.suggestions,
        languages: languages.to_vec(),
    }
}

/// English first, then the installed languages in name order.
fn load() -> Result<(Predictor, Vec<String>), String> {
    let mut installed = installed_dictionaries();
    let english = match installed
        .iter()
        .position(|(language, _)| language == ENGLISH)
    {
        Some(index) => {
            let (_, path) = installed.remove(index);
            read(&path)?
        }
        None => decode(denial_text_prediction::ENGLISH_WORDS).map_err(|error| error.to_string())?,
    };
    let mut languages = vec![ENGLISH.to_owned()];
    let mut texts = vec![english];
    for (language, path) in installed.into_iter().take(MAX_LANGUAGES - 1) {
        match read(&path) {
            Ok(text) => {
                languages.push(language);
                texts.push(text);
            }
            Err(error) => warn!(%error, "skipping a keyboard word list"),
        }
    }
    let lexicon = Lexicon::parse_all(&texts).map_err(|error| error.to_string())?;
    let layout = KeyboardLayout::phone(LAYOUT_WIDTH, LAYOUT_ROW_HEIGHT);
    Ok((
        Predictor::new(lexicon, layout, Tuning::default()),
        languages,
    ))
}

fn read(path: &PathBuf) -> Result<String, String> {
    std::fs::read(path)
        .map_err(|error| error.to_string())
        .and_then(|bytes| decode(&bytes).map_err(|error| error.to_string()))
        .map_err(|error| format!("{}: {error}", path.display()))
}

/// One list per language, the first data directory holding it winning.
fn installed_dictionaries() -> Vec<(String, PathBuf)> {
    let mut found: Vec<(String, PathBuf)> = Vec::new();
    for directory in data_directories() {
        let Ok(entries) = std::fs::read_dir(directory.join(DICTIONARY_DIRECTORY)) else {
            continue;
        };
        let mut names: Vec<(String, PathBuf)> = entries
            .filter_map(Result::ok)
            .filter_map(|entry| {
                let name = entry.file_name().into_string().ok()?;
                let language = name.strip_suffix(DICTIONARY_SUFFIX)?;
                let valid = !language.is_empty()
                    && language.len() <= 16
                    && language
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-');
                valid.then(|| (language.to_owned(), entry.path()))
            })
            .collect();
        names.sort();
        for (language, path) in names {
            if !found.iter().any(|(known, _)| *known == language) {
                found.push((language, path));
            }
        }
    }
    found.sort();
    found
}

fn data_directories() -> Vec<PathBuf> {
    let home = std::env::var_os("XDG_DATA_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")));
    let system = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".to_owned());
    let beside = std::env::current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.parent()?.join("share")));
    home.into_iter()
        .chain(
            system
                .split(':')
                .filter(|path| !path.is_empty())
                .map(PathBuf::from),
        )
        .chain(beside)
        .filter(|path| path.is_absolute())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_with_the_built_in_english_list() {
        let lexicon =
            Lexicon::parse_all(&[decode(denial_text_prediction::ENGLISH_WORDS).unwrap()]).unwrap();
        let predictor = Predictor::new(
            lexicon,
            KeyboardLayout::phone(LAYOUT_WIDTH, LAYOUT_ROW_HEIGHT),
            Tuning::default(),
        );
        let languages = vec![ENGLISH.to_owned()];
        let request = TextPredictionRequest {
            serial: 3,
            word: "becuase".into(),
            touches: vec![
                Some((0.0, 0.0)),
                None,
                Some((0.1, -0.1)),
                Some((0.0, 0.0)),
                None,
                None,
                None,
            ],
            manual_capital: false,
        };
        let prediction = answer(&predictor, &languages, request);
        assert_eq!(prediction.serial, 3);
        assert_eq!(prediction.correction.as_deref(), Some("because"));
        assert_eq!(prediction.languages, ["en"]);
    }
}
