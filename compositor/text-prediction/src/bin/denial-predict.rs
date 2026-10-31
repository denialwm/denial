//! Run the keyboard predictor on its own.
//!
//!   denial-predict [GLOBAL] suggest WORD...
//!   denial-predict [GLOBAL] bench CORPUS... [BENCH]
//!   denial-predict [GLOBAL] tune CORPUS... --params NAME[,NAME...] [TUNE]
//!   denial-predict [GLOBAL] pairs FILE... [--failures N]
//!   denial-predict [GLOBAL] tuning
//!
//! GLOBAL: --lang en[,it...] (bundled lists, default en) or --dict PATH
//!         (repeatable), --set NAME=VALUE (repeatable), --width PX,
//!         --row-height PX
//! BENCH:  --words N, --seed N, --noise SIGMA[,SIGMA...], --bias-y F,
//!         --omit P, --double P, --transpose P, --threads N,
//!         --no-completions, --failures N, --sweep NAME=V1,V2,...
//! TUNE:   --words N, --noise SIGMA[,SIGMA...], --rounds N, --threads N.
//!         Coordinate descent on the weighted error of a training sample;
//!         the held-out sample (other words, other seed) checks the result.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

use denial_text_prediction::bench::{self, Options, Sample, Typist};
use denial_text_prediction::{KeyboardLayout, Lexicon, Predictor, Tuning, Typed};

struct Args {
    rest: Vec<String>,
}

impl Args {
    fn take_value(&mut self, flag: &str) -> Result<Option<String>, String> {
        let Some(index) = self.rest.iter().position(|arg| arg == flag) else {
            return Ok(None);
        };
        if index + 1 >= self.rest.len() {
            return Err(format!("{flag} needs a value"));
        }
        let value = self.rest.remove(index + 1);
        self.rest.remove(index);
        Ok(Some(value))
    }

    fn take_all(&mut self, flag: &str) -> Result<Vec<String>, String> {
        let mut values = Vec::new();
        while let Some(value) = self.take_value(flag)? {
            values.push(value);
        }
        Ok(values)
    }

    fn take_flag(&mut self, flag: &str) -> bool {
        match self.rest.iter().position(|arg| arg == flag) {
            Some(index) => {
                self.rest.remove(index);
                true
            }
            None => false,
        }
    }

    fn parse<T: std::str::FromStr>(&mut self, flag: &str, default: T) -> Result<T, String> {
        match self.take_value(flag)? {
            Some(value) => value
                .parse()
                .map_err(|_| format!("{flag}: {value:?} is not valid")),
            None => Ok(default),
        }
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("denial-predict: {message}");
            ExitCode::FAILURE
        }
    }
}

fn default_threads() -> usize {
    // Leave four logical CPUs to the rest of the machine.
    std::thread::available_parallelism()
        .map_or(1, |count| count.get().saturating_sub(4))
        .max(1)
}

fn run() -> Result<(), String> {
    let mut args = Args {
        rest: std::env::args().skip(1).collect(),
    };
    let mut dictionaries: Vec<PathBuf> = args
        .take_all("--dict")?
        .into_iter()
        .map(PathBuf::from)
        .collect();
    if let Some(languages) = args.take_value("--lang")? {
        dictionaries.extend(
            languages
                .split(',')
                .map(denial_text_prediction::bundled_dictionary),
        );
    }
    if dictionaries.is_empty() {
        dictionaries.push(denial_text_prediction::default_dictionary());
    }
    let mut tuning = Tuning::default();
    for assignment in args.take_all("--set")? {
        tuning.apply(&assignment)?;
    }
    let width: f32 = args.parse("--width", 632.0)?;
    let row_height: f32 = args.parse("--row-height", 70.0)?;
    let command = if args.rest.is_empty() {
        String::new()
    } else {
        args.rest.remove(0)
    };
    if command == "tuning" {
        for name in Tuning::NAMES {
            println!("{name}={}", tuning.get(name).expect("listed name"));
        }
        return Ok(());
    }

    let started = Instant::now();
    let lexicon =
        Lexicon::load_all(&dictionaries).map_err(|error| format!("{dictionaries:?}: {error}"))?;
    eprintln!(
        "{} words from {} list(s) in {} ms",
        lexicon.len(),
        dictionaries.len(),
        started.elapsed().as_millis()
    );
    let mut predictor = Predictor::new(lexicon, KeyboardLayout::phone(width, row_height), tuning);

    match command.as_str() {
        "suggest" => {
            for word in &args.rest {
                let started = Instant::now();
                let prediction = predictor.predict(Typed::plain(word));
                let elapsed = started.elapsed().as_micros();
                println!(
                    "{word:>16} -> {:<16} word={} strip=[{}] more=[{}] {elapsed}us",
                    prediction.committed(),
                    prediction.typed_is_word,
                    prediction.strip(3).collect::<Vec<_>>().join(", "),
                    prediction.suggestions.join(", "),
                );
            }
            Ok(())
        }
        "bench" => bench_command(&mut predictor, args),
        "tune" => tune_command(&mut predictor, args),
        "pairs" => {
            let keep: usize = args.parse("--failures", 20)?;
            let mut text = String::new();
            for path in &args.rest {
                text.push_str(
                    &std::fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?,
                );
                text.push('\n');
            }
            let report = bench::run_pairs(&predictor, &text, keep);
            let percent = |part: usize| 100.0 * part as f64 / report.pairs.max(1) as f64;
            println!(
                "pairs {}  committed {:.2}%  strip3 {:.2}%  skipped {}",
                report.pairs,
                percent(report.committed_right),
                percent(report.strip_right),
                report.skipped
            );
            for miss in &report.misses {
                println!(
                    "  miss {:>16} -> {:<16} want {}",
                    miss.typed, miss.committed, miss.target
                );
            }
            Ok(())
        }
        _ => Err("command: suggest, bench, pairs or tuning".into()),
    }
}

/// `words` samples spread evenly over the corpora; `part` 1 takes the words
/// between those of part 0, for a held-out set.
fn load_samples(
    predictor: &Predictor,
    paths: &[String],
    words: usize,
    part: usize,
) -> Result<Vec<Sample>, String> {
    let mut all: Vec<Sample> = Vec::new();
    for path in paths {
        let text = std::fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
        all.extend(bench::corpus_samples(&text, &predictor.lexicon));
    }
    let stride = (all.len() / words.max(1)).max(2);
    let offset = if part == 0 { 0 } else { stride / 2 };
    Ok(all
        .into_iter()
        .skip(offset)
        .step_by(stride)
        .take(words)
        .collect())
}

fn parse_list(flag: &str, value: Option<String>, default: f32) -> Result<Vec<f32>, String> {
    value.map_or(Ok(vec![default]), |list| {
        list.split(',')
            .map(|value| {
                value
                    .trim()
                    .parse()
                    .map_err(|_| format!("{flag}: {value:?}"))
            })
            .collect()
    })
}

fn tune_command(predictor: &mut Predictor, mut args: Args) -> Result<(), String> {
    let words: usize = args.parse("--words", 30_000)?;
    let rounds: usize = args.parse("--rounds", 6)?;
    let threads = args.parse("--threads", default_threads())?;
    let noises = parse_list("--noise", args.take_value("--noise")?, 0.18)?;
    let params: Vec<String> = args
        .take_value("--params")?
        .ok_or("tune needs --params NAME[,NAME...]")?
        .split(',')
        .map(str::to_owned)
        .collect();
    for name in &params {
        predictor
            .tuning
            .get(name)
            .ok_or_else(|| format!("unknown tuning value {name:?}"))?;
    }
    if args.rest.is_empty() {
        return Err("tune needs at least one corpus file".into());
    }
    let train = load_samples(predictor, &args.rest, words, 0)?;
    let test = load_samples(predictor, &args.rest, words, 1)?;
    let evaluate = |predictor: &Predictor, samples: &[Sample], seed: u64| -> f64 {
        let options = Options {
            seed,
            threads,
            completions: false,
            keep_failures: 0,
        };
        noises
            .iter()
            .map(|&noise| {
                let typist = Typist {
                    noise_x: noise,
                    noise_y: noise,
                    ..Typist::default()
                };
                bench::run(predictor, &typist, samples, &options).weighted_error()
            })
            .sum::<f64>()
            / noises.len() as f64
    };
    let before_test = evaluate(predictor, &test, 2);
    let mut best = evaluate(predictor, &train, 1);
    eprintln!(
        "start: train {:.3}%  test {:.3}%",
        100.0 * best,
        100.0 * before_test
    );
    let mut fraction = 0.25f32;
    for round in 0..rounds {
        let mut improved = false;
        for name in &params {
            let current = predictor.tuning.get(name).expect("checked");
            let step = if current.abs() > 1e-6 {
                current.abs() * fraction
            } else {
                fraction * 0.4
            };
            for candidate in [current + step, current - step] {
                predictor.tuning.set(name, candidate)?;
                let error = evaluate(predictor, &train, 1);
                if error < best - 1e-6 {
                    best = error;
                    improved = true;
                    eprintln!(
                        "round {round}: {name}={candidate} train {:.3}%",
                        100.0 * error
                    );
                    break;
                }
                predictor.tuning.set(name, current)?;
            }
        }
        if !improved {
            fraction /= 2.0;
            if fraction < 0.03 {
                break;
            }
        }
    }
    let after_test = evaluate(predictor, &test, 2);
    println!(
        "train {:.3}%  test {:.3}% (was {:.3}%)",
        100.0 * best,
        100.0 * after_test,
        100.0 * before_test
    );
    for name in &params {
        println!(
            "--set {name}={}",
            predictor.tuning.get(name).expect("checked")
        );
    }
    Ok(())
}

fn bench_command(predictor: &mut Predictor, mut args: Args) -> Result<(), String> {
    let words: usize = args.parse("--words", 20_000)?;
    let options = Options {
        seed: args.parse("--seed", 1)?,
        threads: args.parse("--threads", default_threads())?,
        completions: !args.take_flag("--no-completions"),
        keep_failures: args.parse("--failures", 0)?,
    };
    let defaults = Typist::default();
    let noises = parse_list("--noise", args.take_value("--noise")?, defaults.noise_x)?;
    let base = Typist {
        bias_y: args.parse("--bias-y", defaults.bias_y)?,
        omit: args.parse("--omit", defaults.omit)?,
        double: args.parse("--double", defaults.double)?,
        transpose: args.parse("--transpose", defaults.transpose)?,
        ..defaults
    };
    let sweep = args
        .take_value("--sweep")?
        .map(|spec| -> Result<(String, Vec<f32>), String> {
            let (name, values) = spec
                .split_once('=')
                .ok_or_else(|| format!("--sweep wants NAME=V1,V2, got {spec:?}"))?;
            let values = values
                .split(',')
                .map(|value| value.parse().map_err(|_| format!("--sweep: {value:?}")))
                .collect::<Result<Vec<f32>, String>>()?;
            Ok((name.to_owned(), values))
        })
        .transpose()?;
    if args.rest.is_empty() {
        return Err("bench needs at least one corpus file".into());
    }
    if let Some(flag) = args.rest.iter().find(|arg| arg.starts_with("--")) {
        return Err(format!("unknown option {flag}"));
    }

    let samples = load_samples(predictor, &args.rest, words, 0)?;
    eprintln!("{} samples, {} threads", samples.len(), options.threads);

    let values: Vec<Option<f32>> = match &sweep {
        Some((_, values)) => values.iter().copied().map(Some).collect(),
        None => vec![None],
    };
    for value in values {
        if let (Some((name, _)), Some(value)) = (&sweep, value) {
            predictor.tuning.set(name, value)?;
        }
        for &noise in &noises {
            let typist = Typist {
                noise_x: noise,
                noise_y: noise,
                ..base.clone()
            };
            let started = Instant::now();
            let report = bench::run(predictor, &typist, &samples, &options);
            let label = match (&sweep, value) {
                (Some((name, _)), Some(value)) => format!("{name}={value} "),
                _ => String::new(),
            };
            println!(
                "{label}noise {noise:.2}  {}  ({:.1}s)",
                report.summary(),
                started.elapsed().as_secs_f32()
            );
            for failure in &report.false_corrections {
                println!(
                    "  false  {:>16} -> {:<16} typed {}",
                    failure.target, failure.committed, failure.typed
                );
            }
            for failure in &report.missed_fixes {
                println!(
                    "  missed {:>16} -> {:<16} typed {}",
                    failure.target, failure.committed, failure.typed
                );
            }
        }
    }
    Ok(())
}
