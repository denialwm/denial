//! Every weight of the search and the correction decision, settable by name
//! so a benchmark sweep needs no rebuild.

macro_rules! tuning {
    ($($(#[doc = $doc:literal])* $name:ident = $value:expr;)*) => {
        #[derive(Clone, Debug, PartialEq)]
        pub struct Tuning {
            $($(#[doc = $doc])* pub $name: f32,)*
        }

        impl Default for Tuning {
            fn default() -> Self {
                Self { $($name: $value,)* }
            }
        }

        impl Tuning {
            pub const NAMES: &[&str] = &[$(stringify!($name),)*];

            pub fn set(&mut self, name: &str, value: f32) -> Result<(), String> {
                match name {
                    $(stringify!($name) => self.$name = value,)*
                    _ => return Err(format!("unknown tuning value {name:?}")),
                }
                Ok(())
            }

            pub fn get(&self, name: &str) -> Option<f32> {
                match name {
                    $(stringify!($name) => Some(self.$name),)*
                    _ => None,
                }
            }
        }
    };
}

tuning! {
    /// Substitution cost: base + scale * distance in key pitches, clamped.
    sub_base = 0.07;
    sub_scale = 0.45;
    sub_min = 0.22;
    sub_max = 1.0;
    /// A typed key the word does not have.
    insert = 1.1;
    /// The same key typed twice in a row.
    insert_repeat = 0.35;
    /// A letter of the word that was not typed.
    delete = 0.42;
    /// A doubled letter typed once ("hapy").
    delete_repeat = 0.6;
    /// An apostrophe not typed: the letters layer has none.
    delete_apostrophe = 0.1;
    /// Two neighbouring letters swapped.
    transpose = 0.45;

    /// Search radius by typed length: up to 3, up to 5, longer.
    max_cost_short = 1.0;
    max_cost_mid = 1.2;
    max_cost_long = 1.6;
    /// How far a typed word may be from a prefix it completes: up to 2
    /// letters (exact only), up to 4, longer.
    seed_cost_short = 0.0;
    seed_cost_mid = 0.6;
    seed_cost_long = 1.1;
    /// Completion candidates explored per search.
    completion_seeds = 8.0;
    completion_words = 4.0;

    /// Score = frequency - cost_weight * cost - completion terms + bonus.
    cost_weight = 105.0;
    completion_penalty = 12.0;
    completion_per_char = 3.0;
    /// The typed word itself, spelled exactly.
    exact_bonus = 35.0;

    /// Autocorrect: shortest typed word it touches, its cost limit up to 4
    /// letters and longer, and the score the replacement needs.
    auto_min_length = 2.0;
    auto_cost_mid = 0.95;
    auto_cost_long = 0.9;
    auto_min_score = 12.0;
}

impl Tuning {
    pub(crate) fn max_cost(&self, length: usize) -> f32 {
        match length {
            0..=3 => self.max_cost_short,
            4..=5 => self.max_cost_mid,
            _ => self.max_cost_long,
        }
    }

    pub(crate) fn seed_cost(&self, length: usize) -> f32 {
        match length {
            0..=2 => self.seed_cost_short,
            3..=4 => self.seed_cost_mid,
            _ => self.seed_cost_long,
        }
    }

    pub(crate) fn auto_cost(&self, length: usize) -> f32 {
        if (length as f32) < self.auto_min_length {
            -1.0
        } else if length <= 4 {
            self.auto_cost_mid
        } else {
            self.auto_cost_long
        }
    }

    /// Applies `name=value` assignments, as given on the command line.
    pub fn apply(&mut self, assignment: &str) -> Result<(), String> {
        let (name, value) = assignment
            .split_once('=')
            .ok_or_else(|| format!("expected name=value, got {assignment:?}"))?;
        let value: f32 = value
            .parse()
            .map_err(|_| format!("{name}: {value:?} is not a number"))?;
        self.set(name.trim(), value)
    }
}
