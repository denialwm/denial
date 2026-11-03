# denial-text-prediction

Word suggestions and autocorrection for Denial's software keyboard. deniald
runs the library on a helper thread next to its text-input broker;
`denial-predict` runs it on its own, so tuning needs neither a compositor nor
a device.

## Languages

English is built into deniald. Another language is on when its list is
installed as `denial/dictionaries/<language>.words.gz` in a data directory
(`$XDG_DATA_HOME`, then `$XDG_DATA_DIRS`, then `share/` beside deniald). An
installed `en.words.gz` replaces the built-in one. Every installed language
is on at once: a word from any list is a word, and a shortcut from one
language never rewrites a word of another (`il` stays `il` with Italian on).
The keyboard learns the languages from each answer and offers their accents
on a long press.

## How it decides

- **Word lists.** `data/en.words.gz` and `data/it.words.gz`, built by
  `tools/build-dictionary` from AOSP LatinIME's combined word lists. Each
  holds LatinIME's 0–255 frequencies plus whitelist fixes for non-words,
  contractions and capitals (`im` → `I'm`, `alot` → `a lot`). Fixes from one
  real word to another are dropped: a valid word is never replaced by a
  different one. Accents fold into the plain key, so `perche` reaches
  `perché`. LatinIME's Italian list misses common words (`uomo`, `vi`), so
  the Italian list adds FrequencyWords' `it_50k` words it lacks. Sources and
  licenses: [`data/ATTRIBUTION.md`](data/ATTRIBUTION.md).
- **Search.** The search walks a prefix trie with one weighted
  Damerau-Levenshtein row per depth. A substitution costs by the distance
  from the touch point to the intended key, in key pitches. A missing
  apostrophe is nearly free, since the letters layer has none. Prefixes
  within reach seed completions, which are read best first from subtree
  frequencies.
- **Correction.** A space commits the correction when the typed text is not
  a word, a candidate is within the cost limit for its length, and its score
  clears `auto_min_score`. A capital the user typed (not the sentence start)
  marks a name: only a capitalized word may replace it.

Every weight is in `src/tuning.rs` and can be set at run time with
`--set NAME=VALUE`.

## Running

```sh
cargo build --release -p denial-text-prediction     # in compositor/
target/release/denial-predict suggest teh dont monday
target/release/denial-predict --lang en,it suggest perche piu il
target/release/denial-predict tuning                # current weights
```

`--lang` picks lists from `data/`; `--dict PATH` (repeatable) takes any list.

Rebuilding the lists, with the sources in `$S`:

```sh
tools/build-dictionary $S/en_US_wordlist.combined.gz data/en.words.gz
tools/build-dictionary $S/it_wordlist.combined.gz data/it.words.gz \
    --supplement $S/it_50k.txt --exclude $S/en_US_wordlist.combined.gz \
    --endings aeiouàèéìòù --foreign jkwxy
```

## Benchmarking

`tools/fetch-bench-data` downloads public-domain Gutenberg prose, English
into `prose/en/` and Italian into `prose/it/`, and three English misspelling
lists into `~/.cache/denial/text-prediction` (not committed).

```sh
D=~/.cache/denial/text-prediction
denial-predict bench $D/prose/en/*.txt --noise 0.15,0.22 --failures 10
denial-predict --lang en,it bench $D/prose/it/*.txt --failures 10
denial-predict bench $D/prose/en/*.txt --sweep auto_min_score=30,50,70
denial-predict tune  $D/prose/en/*.txt --params cost_weight,auto_min_score
denial-predict pairs $D/pairs/*.txt
```

`bench` types each corpus word with a simulated thumb typist on the mobile
shell's letters layer:

- touches land at the key center with Gaussian noise (`--noise`, in key
  pitches) and a downward bias, and square hit boxes turn them into keys;
- omitted, doubled and swapped letters come on top;
- apostrophes are never typed, and accented letters are typed as their
  plain letter.

Every sample has its own seeded generator, so a run is reproducible and
independent of the thread count. It reports:

- `error`: missed fixes plus twice the false corrections, per 100 words.
  `tune` minimizes this.
- `accuracy`: the word a space commits is the intended one.
- `fixed` / `false`: typo'd words repaired, correctly typed words broken.
- `strip3`: the intended word is in the three-slot suggestion strip.
- `unknown kept`: words outside the list survive.
- `saved`: keystrokes saved by tapping a completion as soon as it shows.

`tune` runs coordinate descent on a training sample and checks the result on
a held-out one (the words in between, another seed). Its output is
`--set` lines ready for `src/tuning.rs`.

`pairs` checks known misspellings (`typo->right`) without touch points.
These are mostly spelling mistakes rather than typing slips, so read them
as a second opinion.

`cargo test --release -p denial-text-prediction` checks behaviour cases and
an accuracy floor on `tests/data/messages.txt`.
