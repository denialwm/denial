//! The word list and its prefix trie.
//!
//! Keys are the lowercase spelling of a word without accents (ASCII letters
//! and apostrophes): the letters layer has no accented keys, so "perche"
//! and "perché" share a key. One key can carry several written forms, such
//! as "us" and "US" or "e" and "è"; entries sharing a key are adjacent, most
//! frequent first.

use std::collections::HashMap;
use std::io::Read;
use std::path::Path;

/// Trie node. Children of a node are a sibling list in byte order.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Node {
    pub first_child: u32,
    pub next_sibling: u32,
    pub byte: u8,
    /// Highest frequency of an offerable entry in this subtree, 0 for none.
    pub best: u8,
    pub entry_count: u16,
    pub entry_start: u32,
}

pub(crate) const NONE: u32 = 0;
pub(crate) const ROOT: u32 = 0;

/// The word lists an entry or shortcut comes from, one bit per list in
/// load order.
pub type Languages = u8;

pub struct Lexicon {
    words: Vec<Box<str>>,
    frequency: Vec<u8>,
    offensive: Vec<bool>,
    languages: Vec<Languages>,
    shortcuts: HashMap<Box<str>, (Box<str>, Languages)>,
    nodes: Vec<Node>,
}

#[derive(Debug)]
pub enum LoadError {
    Io(std::io::Error),
    Format { line: usize, reason: &'static str },
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(f, "{error}"),
            Self::Format { line, reason } => write!(f, "line {line}: {reason}"),
        }
    }
}

impl std::error::Error for LoadError {}

/// The key byte of a character: its lowercase ASCII letter with any accent
/// dropped, or the apostrophe. None for a character no key may contain.
pub fn key_char(character: char) -> Option<u8> {
    let lower = character.to_lowercase().next()?;
    let byte = match lower {
        'a'..='z' | '\'' => lower as u8,
        'à' | 'á' | 'â' | 'ä' | 'ã' | 'å' => b'a',
        'è' | 'é' | 'ê' | 'ë' => b'e',
        'ì' | 'í' | 'î' | 'ï' => b'i',
        'ò' | 'ó' | 'ô' | 'ö' | 'õ' => b'o',
        'ù' | 'ú' | 'û' | 'ü' => b'u',
        'ç' => b'c',
        'ñ' => b'n',
        _ => return None,
    };
    Some(byte)
}

/// The key for a typed or written word, None if it holds anything but
/// letters and apostrophes.
pub fn key_of(word: &str) -> Option<Vec<u8>> {
    word.chars().map(key_char).collect()
}

/// The text of a word list file, gzipped or plain.
pub fn decode(bytes: &[u8]) -> Result<String, LoadError> {
    if bytes.starts_with(&[0x1f, 0x8b]) {
        let mut text = String::new();
        flate2::read::GzDecoder::new(bytes)
            .read_to_string(&mut text)
            .map_err(LoadError::Io)?;
        Ok(text)
    } else {
        String::from_utf8(bytes.to_vec()).map_err(|_| LoadError::Format {
            line: 0,
            reason: "not UTF-8",
        })
    }
}

impl Lexicon {
    /// Reads a word list written by tools/build-dictionary, gzipped or plain.
    pub fn load(path: &Path) -> Result<Self, LoadError> {
        Self::load_all(std::slice::from_ref(&path))
    }

    /// Reads several word lists, one per language (eight at most), into one
    /// lexicon.
    pub fn load_all<P: AsRef<Path>>(paths: &[P]) -> Result<Self, LoadError> {
        let mut texts = Vec::with_capacity(paths.len());
        for path in paths {
            texts.push(decode(
                &std::fs::read(path.as_ref()).map_err(LoadError::Io)?,
            )?);
        }
        Self::parse_all(&texts)
    }

    pub fn parse(text: &str) -> Result<Self, LoadError> {
        Self::parse_all(&[text])
    }

    /// Parses one text per language. A word two languages share is one
    /// entry with both languages, its higher frequency, and offensive only
    /// if every language marks it so.
    pub fn parse_all<T: AsRef<str>>(texts: &[T]) -> Result<Self, LoadError> {
        if texts.len() > Languages::BITS as usize {
            return Err(LoadError::Format {
                line: 0,
                reason: "more than eight word lists",
            });
        }
        let mut entries: Vec<(Vec<u8>, Box<str>, u8, bool, Languages)> = Vec::new();
        let mut shortcuts: HashMap<Box<str>, (Box<str>, Languages)> = HashMap::new();
        for (language, text) in texts.iter().enumerate() {
            let bit: Languages = 1 << language;
            Self::parse_into(text.as_ref(), bit, &mut entries, &mut shortcuts)?;
        }
        // One entry per written form.
        entries.sort_by(|a, b| a.1.cmp(&b.1).then(b.2.cmp(&a.2)));
        entries.dedup_by(|later, kept| {
            if later.1 != kept.1 {
                return false;
            }
            kept.3 &= later.3;
            kept.4 |= later.4;
            true
        });
        entries.sort_by(|a, b| a.0.cmp(&b.0).then(b.2.cmp(&a.2)).then(a.1.cmp(&b.1)));
        Self::build(entries, shortcuts)
    }

    #[allow(clippy::type_complexity)]
    fn parse_into(
        text: &str,
        language: Languages,
        entries: &mut Vec<(Vec<u8>, Box<str>, u8, bool, Languages)>,
        shortcuts: &mut HashMap<Box<str>, (Box<str>, Languages)>,
    ) -> Result<(), LoadError> {
        for (index, line) in text.lines().enumerate() {
            let line_number = index + 1;
            let bad = |reason| LoadError::Format {
                line: line_number,
                reason,
            };
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(rest) = line.strip_prefix('>') {
                let (typed, replacement) =
                    rest.split_once('\t').ok_or(bad("shortcut needs a tab"))?;
                let key = key_of(typed).ok_or(bad("shortcut source is not a word"))?;
                let key = String::from_utf8(key).expect("ASCII key");
                shortcuts
                    .entry(key.into_boxed_str())
                    .or_insert_with(|| (replacement.into(), 0))
                    .1 |= language;
                continue;
            }
            let mut fields = line.split('\t');
            let word = fields.next().ok_or(bad("empty line"))?;
            let frequency: u8 = fields
                .next()
                .and_then(|value| value.parse().ok())
                .ok_or(bad("missing frequency"))?;
            let offensive = fields.next() == Some("o");
            let key = key_of(word).ok_or(bad("word holds a byte keys cannot"))?;
            if key.is_empty() {
                return Err(bad("empty word"));
            }
            entries.push((key, word.into(), frequency, offensive, language));
        }
        Ok(())
    }

    #[allow(clippy::type_complexity)]
    fn build(
        entries: Vec<(Vec<u8>, Box<str>, u8, bool, Languages)>,
        shortcuts: HashMap<Box<str>, (Box<str>, Languages)>,
    ) -> Result<Self, LoadError> {
        let mut nodes = vec![Node {
            first_child: NONE,
            next_sibling: NONE,
            byte: 0,
            best: 0,
            entry_count: 0,
            entry_start: 0,
        }];
        let mut parent = vec![u32::MAX];
        // Path from the root to the node of the previous key, and each path
        // node's last child so far: keys arrive sorted, so a new child always
        // goes at the end of its sibling list.
        let mut path: Vec<u32> = vec![ROOT];
        let mut last_child: Vec<u32> = vec![NONE];
        let mut previous: &[u8] = &[];
        for (index, (key, ..)) in entries.iter().enumerate() {
            let common = key.iter().zip(previous).take_while(|(a, b)| a == b).count();
            path.truncate(common + 1);
            last_child.truncate(common + 1);
            for &byte in &key[common..] {
                let node = nodes.len() as u32;
                let owner = *path.last().expect("root");
                nodes.push(Node {
                    first_child: NONE,
                    next_sibling: NONE,
                    byte,
                    best: 0,
                    entry_count: 0,
                    entry_start: 0,
                });
                parent.push(owner);
                let depth = path.len() - 1;
                match last_child[depth] {
                    NONE => nodes[owner as usize].first_child = node,
                    sibling => nodes[sibling as usize].next_sibling = node,
                }
                last_child[depth] = node;
                path.push(node);
                last_child.push(NONE);
            }
            let node = &mut nodes[*path.last().expect("key node") as usize];
            if node.entry_count == 0 {
                node.entry_start = index as u32;
            }
            node.entry_count += 1;
            previous = key;
        }

        let mut words = Vec::with_capacity(entries.len());
        let mut frequency = Vec::with_capacity(entries.len());
        let mut offensive = Vec::with_capacity(entries.len());
        let mut languages = Vec::with_capacity(entries.len());
        for (_, word, value, flag, language) in entries {
            words.push(word);
            frequency.push(value);
            offensive.push(flag);
            languages.push(language);
        }
        // Nodes are numbered in preorder, so children follow their parent.
        for index in (1..nodes.len()).rev() {
            let node = nodes[index];
            let own = (node.entry_start..node.entry_start + u32::from(node.entry_count))
                .filter(|&entry| !offensive[entry as usize])
                .map(|entry| frequency[entry as usize])
                .max()
                .unwrap_or(0);
            let best = node.best.max(own);
            nodes[index].best = best;
            let owner = parent[index] as usize;
            nodes[owner].best = nodes[owner].best.max(best);
        }
        Ok(Self {
            words,
            frequency,
            offensive,
            languages,
            shortcuts,
            nodes,
        })
    }

    pub fn len(&self) -> usize {
        self.words.len()
    }

    pub fn is_empty(&self) -> bool {
        self.words.is_empty()
    }

    pub(crate) fn node(&self, index: u32) -> &Node {
        &self.nodes[index as usize]
    }

    pub(crate) fn children(&self, index: u32) -> Children<'_> {
        Children {
            lexicon: self,
            next: self.nodes[index as usize].first_child,
        }
    }

    pub fn word(&self, entry: u32) -> &str {
        &self.words[entry as usize]
    }

    pub fn frequency(&self, entry: u32) -> u8 {
        self.frequency[entry as usize]
    }

    pub fn is_offensive(&self, entry: u32) -> bool {
        self.offensive[entry as usize]
    }

    pub fn languages(&self, entry: u32) -> Languages {
        self.languages[entry as usize]
    }

    fn find(&self, key: &[u8]) -> Option<u32> {
        let mut node = ROOT;
        for &byte in key {
            node = self
                .children(node)
                .find(|&child| self.node(child).byte == byte)?;
        }
        Some(node)
    }

    /// Entries written with this key, most frequent first.
    pub fn entries(&self, key: &[u8]) -> std::ops::Range<u32> {
        match self.find(key) {
            Some(node) if node != ROOT => {
                let node = self.node(node);
                node.entry_start..node.entry_start + u32::from(node.entry_count)
            }
            _ => 0..0,
        }
    }

    pub fn contains_key(&self, key: &[u8]) -> bool {
        !self.entries(key).is_empty()
    }

    /// A whitelist correction for this lowercase key, and the languages
    /// that make it.
    pub fn shortcut(&self, key: &[u8]) -> Option<(&str, Languages)> {
        let key = std::str::from_utf8(key).ok()?;
        self.shortcuts
            .get(key)
            .map(|(value, languages)| (&**value, *languages))
    }
}

pub(crate) struct Children<'a> {
    lexicon: &'a Lexicon,
    next: u32,
}

impl Iterator for Children<'_> {
    type Item = u32;

    fn next(&mut self) -> Option<u32> {
        if self.next == NONE {
            return None;
        }
        let current = self.next;
        self.next = self.lexicon.nodes[current as usize].next_sibling;
        Some(current)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "the\t222\nThe\t10\nus\t150\nUS\t140\nhello\t150\nhelp\t160\nheld\t120\nhell\t100\to\n>im\tI'm\n";

    #[test]
    fn keys_share_entries_most_frequent_first() {
        let lexicon = Lexicon::parse(SAMPLE).unwrap();
        let forms: Vec<_> = lexicon.entries(b"us").map(|e| lexicon.word(e)).collect();
        assert_eq!(forms, ["us", "US"]);
        assert!(lexicon.contains_key(b"hello"));
        assert!(!lexicon.contains_key(b"hel"));
        assert_eq!(lexicon.shortcut(b"im"), Some(("I'm", 1)));
    }

    #[test]
    fn accents_share_the_plain_key() {
        let lexicon = Lexicon::parse("e\t210\nè\t200\nperché\t159\nCittà\t20\n").unwrap();
        let forms: Vec<_> = lexicon.entries(b"e").map(|e| lexicon.word(e)).collect();
        assert_eq!(forms, ["e", "è"]);
        assert_eq!(key_of("PERCHÉ").as_deref(), Some(&b"perche"[..]));
        assert!(lexicon.contains_key(b"citta"));
        assert_eq!(key_of("straße"), None);
    }

    #[test]
    fn languages_merge_shared_words() {
        let lexicon = Lexicon::parse_all(&[
            "come\t180\nCome\t50\npartner\t120\n",
            "come\t200\npartner\t100\to\n",
        ])
        .unwrap();
        let forms: Vec<_> = lexicon
            .entries(b"come")
            .map(|e| (lexicon.word(e), lexicon.frequency(e), lexicon.languages(e)))
            .collect();
        assert_eq!(forms, [("come", 200, 0b11), ("Come", 50, 0b01)]);
        let partner = lexicon.entries(b"partner").start;
        assert!(!lexicon.is_offensive(partner));
    }

    #[test]
    fn subtree_best_skips_offensive_words() {
        let lexicon = Lexicon::parse(SAMPLE).unwrap();
        let hell = lexicon.find(b"hell").unwrap();
        assert_eq!(lexicon.node(hell).best, 150);
        let hel = lexicon.find(b"hel").unwrap();
        assert_eq!(lexicon.node(hel).best, 160);
    }
}
