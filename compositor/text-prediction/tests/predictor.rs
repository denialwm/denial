//! Behaviour on the shipped word list, and an accuracy floor on a small
//! message corpus. The full benchmark runs with `denial-predict bench`.

use std::sync::OnceLock;

use denial_text_prediction::bench::{self, Options, Typist};
use denial_text_prediction::{KeyboardLayout, Lexicon, Point, Predictor, Tuning, Typed};

fn predictor() -> &'static Predictor {
    static PREDICTOR: OnceLock<Predictor> = OnceLock::new();
    PREDICTOR.get_or_init(|| {
        let lexicon =
            Lexicon::load(&denial_text_prediction::default_dictionary()).expect("word list");
        Predictor::new(
            lexicon,
            KeyboardLayout::phone(632.0, 70.0),
            Tuning::default(),
        )
    })
}

fn committed(text: &str) -> String {
    predictor()
        .predict(Typed::plain(text))
        .committed()
        .to_owned()
}

#[test]
fn common_typos_are_fixed() {
    for (typed, expected) in [
        ("teh", "the"),
        ("thw", "the"),
        ("wierd", "weird"),
        ("becuase", "because"),
        ("recieve", "receive"),
    ] {
        assert_eq!(committed(typed), expected, "{typed}");
    }
}

#[test]
fn apostrophes_and_capitals_are_restored() {
    for (typed, expected) in [
        ("dont", "don't"),
        ("youre", "you're"),
        ("im", "I'm"),
        ("i", "I"),
        ("ive", "I've"),
        ("monday", "Monday"),
        ("alot", "a lot"),
    ] {
        assert_eq!(committed(typed), expected, "{typed}");
    }
}

#[test]
fn valid_words_stay() {
    for word in ["hello", "its", "were", "well", "us", "form", "Hello"] {
        assert_eq!(committed(word), word);
    }
}

#[test]
fn typed_capitals_mark_names() {
    let name = Typed {
        text: "Logix",
        touches: &[],
        manual_capital: true,
    };
    assert_eq!(predictor().predict(name).committed(), "Logix");
    let typo = Typed {
        text: "Alicce",
        touches: &[],
        manual_capital: true,
    };
    assert_eq!(predictor().predict(typo).committed(), "Alice");
}

#[test]
fn touch_points_decide_between_neighbours() {
    // "thr" with the last touch on the r/e border reads as "the"; centred
    // on r it may stay a prefix of "three" or "through".
    let layout = &predictor().layout;
    let e = layout.center(b'e').unwrap();
    let r = layout.center(b'r').unwrap();
    let border = Point::new((e.x + r.x) / 2.0 + 1.0, r.y);
    let touches = [layout.center(b't'), layout.center(b'h'), Some(border)];
    let prediction = predictor().predict(Typed {
        text: "thr",
        touches: &touches,
        manual_capital: false,
    });
    assert_eq!(prediction.committed(), "the");
}

#[test]
fn completions_offer_the_word_early() {
    let prediction = predictor().predict(Typed::plain("tomor"));
    assert!(
        prediction.strip(3).any(|word| word == "tomorrow"),
        "{prediction:?}"
    );
}

#[test]
fn message_corpus_accuracy_floor() {
    let text = include_str!("data/messages.txt");
    let samples = bench::corpus_samples(text, &predictor().lexicon);
    assert!(samples.len() > 600);
    let options = Options {
        seed: 7,
        threads: 2,
        completions: true,
        keep_failures: 10,
    };
    let report = bench::run(predictor(), &Typist::default(), &samples, &options);
    eprintln!("{}", report.summary());
    for failure in report.false_corrections.iter().chain(&report.missed_fixes) {
        eprintln!(
            "  {} -> {} (typed {})",
            failure.target, failure.committed, failure.typed
        );
    }
    assert!(report.accuracy() >= 0.97, "{}", report.summary());
    assert!(
        report.false_correction_rate() <= 0.01,
        "{}",
        report.summary()
    );
    assert!(report.strip_rate() >= 0.98, "{}", report.summary());
}
