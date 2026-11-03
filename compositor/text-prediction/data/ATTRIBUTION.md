# Word list attribution

`tools/build-dictionary` generates both lists from the sources below,
downloaded on 2026-10-24. It keeps words and frequencies, drops shortcuts
from one real word to another and drops unaccented twins of accented words.
Build commands are in the README.

## en.words.gz

- Source: AOSP LatinIME
  [`dictionaries/en_US_wordlist.combined.gz`](https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/refs/heads/main/dictionaries/en_US_wordlist.combined.gz)
- Source SHA-256:
  `0f78dd455b532be169a23f233227b811fabced4b5bd7fc9c40cc05839793bcbd`
- Generated SHA-256:
  `4dfa051c7d58f2965cc69ef6bd011e2c2c4a46716e067afded260097a82472cc`
- License: Apache License 2.0, Copyright The Android Open Source Project.
  The full text is in [`LICENSES/Apache-2.0.txt`](../../../LICENSES/Apache-2.0.txt).

## it.words.gz

- Source: AOSP LatinIME
  [`dictionaries/it_wordlist.combined.gz`](https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/refs/heads/main/dictionaries/it_wordlist.combined.gz)
  (Apache License 2.0, as above)
- Source SHA-256:
  `4ac1fa3b112130416843f5abc2a61fdbd2395a41fb6a719790cd7c45934218ec`
- Supplement: Hermit Dave's
  [FrequencyWords](https://github.com/hermitdave/FrequencyWords)
  [`content/2018/it/it_50k.txt`](https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/it/it_50k.txt),
  word counts from OpenSubtitles 2018
- Supplement SHA-256:
  `bb96cdcb56d28342c1e909db6b2525448b7767136b7e86a2ccc649a1be66fc19`
- Generated SHA-256:
  `0dba149885e1e76521c7023020c684a9d670d8f84d496efb66656587a3631aba`
- License: the supplement is
  [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), so Denial
  distributes `it.words.gz` under CC BY-SA 4.0. The full text is in
  [`LICENSES/CC-BY-SA-4.0.txt`](../../../LICENSES/CC-BY-SA-4.0.txt).

### Denial modifications to the supplement

Words LatinIME lacks were added with frequencies fitted to LatinIME's scale,
less a fixed penalty. Words with apostrophes, letters Italian does not use,
endings that are not Italian, English words, and unaccented spellings of
accented words were left out.
