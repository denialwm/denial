import 'package:flutter/foundation.dart';

/// The letters the software keyboard shows for one XKB layout.
///
/// The panel types text, and Denial types it through the active layout, so
/// these rows only decide where each letter sits: the arrangement a user of
/// that layout knows, with the letters the language needs.
@immutable
class OskLetterLayout {
  const OskLetterLayout(this.language, this.rows, {this.capitals = const {}});

  /// The ISO 639-1 language its letters write, which chooses the accented
  /// letters a long press offers.
  final String language;

  /// Three rows of keys separated by spaces. The third sits between Shift
  /// and Backspace.
  final List<String> rows;

  /// Capitals that are not the letter's `toUpperCase`: Turkish `i` and `ı`.
  final Map<String, String> capitals;

  List<List<String>> get keys => [for (final row in rows) row.split(' ')];

  @override
  bool operator ==(Object other) =>
      other is OskLetterLayout &&
      other.language == language &&
      listEquals(other.rows, rows);

  @override
  int get hashCode => Object.hash(language, Object.hashAll(rows));
}

const _qwerty = ['q w e r t y u i o p', 'a s d f g h j k l', 'z x c v b n m'];
const _qwertz = ['q w e r t z u i o p', 'a s d f g h j k l', 'y x c v b n m'];
const _southSlavic = [
  'q w e r t z u i o p š đ',
  'a s d f g h j k l č ć ž',
  'y x c v b n m',
];

/// The letters for the XKB [layout] and [variant], as Denial's keyboard
/// settings name them. A layout without its own arrangement types as US.
OskLetterLayout oskLetterLayout(String layout, String variant) => switch ((
  layout,
  variant,
)) {
  ('us', final v) when v.startsWith('dvorak') => const OskLetterLayout('en', [
    'p y f g c r l',
    'a o e u i d h t n s',
    'q j k x b m w v z',
  ]),
  ('us', final v) when v.startsWith('colemak') => const OskLetterLayout('en', [
    'q w f p g j l u y',
    'a r s t d h n e i o',
    'z x c v b k m',
  ]),
  ('us' || 'gb' || 'ie' || 'au', _) => const OskLetterLayout('en', _qwerty),
  ('ca', 'eng') => const OskLetterLayout('en', _qwerty),
  ('ca', _) => const OskLetterLayout('fr', _qwerty),
  ('fr' || 'be', _) => const OskLetterLayout('fr', [
    'a z e r t y u i o p',
    'q s d f g h j k l m',
    "w x c v b n '",
  ]),
  ('de' || 'at', _) => const OskLetterLayout('de', [
    'q w e r t z u i o p ü',
    'a s d f g h j k l ö ä',
    'y x c v b n m',
  ]),
  ('ch', final v) when v.startsWith('fr') => const OskLetterLayout('fr', [
    'q w e r t z u i o p è',
    'a s d f g h j k l é à',
    'y x c v b n m',
  ]),
  ('ch', _) => const OskLetterLayout('de', [
    'q w e r t z u i o p ü',
    'a s d f g h j k l ö ä',
    'y x c v b n m',
  ]),
  ('it', _) => const OskLetterLayout('it', _qwerty),
  ('es' || 'latam', _) => const OskLetterLayout('es', [
    'q w e r t y u i o p',
    'a s d f g h j k l ñ',
    'z x c v b n m',
  ]),
  ('pt' || 'br', _) => const OskLetterLayout('pt', [
    'q w e r t y u i o p',
    'a s d f g h j k l ç',
    'z x c v b n m',
  ]),
  ('se', _) => const OskLetterLayout('sv', [
    'q w e r t y u i o p å',
    'a s d f g h j k l ö ä',
    'z x c v b n m',
  ]),
  ('fi', _) => const OskLetterLayout('fi', [
    'q w e r t y u i o p å',
    'a s d f g h j k l ö ä',
    'z x c v b n m',
  ]),
  ('no', _) => const OskLetterLayout('nb', [
    'q w e r t y u i o p å',
    'a s d f g h j k l ø æ',
    'z x c v b n m',
  ]),
  ('dk', _) => const OskLetterLayout('da', [
    'q w e r t y u i o p å',
    'a s d f g h j k l æ ø',
    'z x c v b n m',
  ]),
  ('is', _) => const OskLetterLayout('is', [
    'q w e r t y u i o p ð',
    'a s d f g h j k l æ',
    'z x c v b n m þ',
  ]),
  ('ee', _) => const OskLetterLayout('et', [
    'q w e r t y u i o p ü õ',
    'a s d f g h j k l ö ä',
    'z x c v b n m',
  ]),
  ('nl', _) => const OskLetterLayout('nl', _qwerty),
  ('pl', _) => const OskLetterLayout('pl', _qwerty),
  ('ro', _) => const OskLetterLayout('ro', _qwerty),
  ('lt', _) => const OskLetterLayout('lt', _qwerty),
  ('lv', _) => const OskLetterLayout('lv', _qwerty),
  ('cz', 'qwerty') => const OskLetterLayout('cs', _qwerty),
  ('cz', _) => const OskLetterLayout('cs', _qwertz),
  ('sk', 'qwerty') => const OskLetterLayout('sk', _qwerty),
  ('sk', _) => const OskLetterLayout('sk', _qwertz),
  ('hu', _) => const OskLetterLayout('hu', _qwertz),
  ('hr' || 'ba', _) => const OskLetterLayout('hr', _southSlavic),
  ('si', _) => const OskLetterLayout('sl', _southSlavic),
  ('rs', final v) when v.startsWith('latin') => const OskLetterLayout(
    'sr',
    _southSlavic,
  ),
  ('rs', _) => const OskLetterLayout('sr', [
    'љ њ е р т з у и о п ш ђ',
    'а с д ф г х ј к л ч ћ ж',
    'ѕ џ ц в б н м',
  ]),
  ('tr', 'f') => const OskLetterLayout(
    'tr',
    ['f g ğ ı o d r n h p q w', 'u i e a ü t k m l y ş x', 'j ö v c ç z s b'],
    capitals: {'i': 'İ', 'ı': 'I'},
  ),
  ('tr', _) => const OskLetterLayout(
    'tr',
    ['q w e r t y u ı o p ğ ü', 'a s d f g h j k l ş i', 'z x c v b n m ö ç'],
    capitals: {'i': 'İ', 'ı': 'I'},
  ),
  ('ru', _) => const OskLetterLayout('ru', [
    'й ц у к е н г ш щ з х',
    'ф ы в а п р о л д ж э',
    'я ч с м и т ь б ю',
  ]),
  ('ua', _) => const OskLetterLayout('uk', [
    'й ц у к е н г ш щ з х ї',
    'ф і в а п р о л д ж є',
    'я ч с м и т ь б ю',
  ]),
  ('by', _) => const OskLetterLayout('be', [
    'й ц у к е н г ш ў з х',
    'ф ы в а п р о л д ж э',
    'я ч с м і т ь б ю',
  ]),
  ('bg', _) => const OskLetterLayout('bg', [
    'я в е р т ъ у и о п ч',
    'а с д ф г х й к л ш щ',
    'з ь ц ж б н м ю',
  ]),
  ('gr', _) => const OskLetterLayout('el', [
    'ς ε ρ τ υ θ ι ο π',
    'α σ δ φ γ η ξ κ λ',
    'ζ χ ψ ω β ν μ',
  ]),
  ('il', _) => const OskLetterLayout('he', [
    'ק ר א ט ו ן ם פ',
    'ש ד ג כ ע י ח ל ך ף',
    'ז ס ב ה נ מ צ ת ץ',
  ]),
  ('ara', _) => const OskLetterLayout('ar', [
    'ض ص ث ق ف غ ع ه خ ح ج',
    'ش س ي ب ل ا ت ن م ك ط',
    'ذ ء ؤ ر ى ة و ز ظ د',
  ]),
  _ => const OskLetterLayout('en', _qwerty),
};

/// Accented letters a long press offers, per language.
const oskAccents = <String, Map<String, List<String>>>{
  'it': {
    'a': ['à'],
    'e': ['è', 'é'],
    'i': ['ì'],
    'o': ['ò'],
    'u': ['ù'],
  },
  'fr': {
    'a': ['à', 'â', 'æ'],
    'c': ['ç'],
    'e': ['é', 'è', 'ê', 'ë'],
    'i': ['î', 'ï'],
    'o': ['ô', 'œ'],
    'u': ['ù', 'û', 'ü'],
    'y': ['ÿ'],
  },
  'de': {
    'a': ['ä'],
    'o': ['ö'],
    's': ['ß'],
    'u': ['ü'],
  },
  'es': {
    'a': ['á'],
    'e': ['é'],
    'i': ['í'],
    'n': ['ñ'],
    'o': ['ó'],
    'u': ['ú', 'ü'],
  },
  'pt': {
    'a': ['á', 'à', 'â', 'ã'],
    'c': ['ç'],
    'e': ['é', 'ê'],
    'i': ['í'],
    'o': ['ó', 'ô', 'õ'],
    'u': ['ú'],
  },
  'ca': {
    'a': ['à'],
    'c': ['ç'],
    'e': ['è', 'é'],
    'i': ['í', 'ï'],
    'o': ['ò', 'ó'],
    'u': ['ú', 'ü'],
  },
  'nl': {
    'e': ['é', 'ë'],
    'i': ['ï'],
    'o': ['ó', 'ö'],
    'u': ['ü'],
  },
  'sv': {
    'a': ['å', 'ä'],
    'e': ['é'],
    'o': ['ö'],
  },
  'fi': {
    'a': ['å', 'ä'],
    'o': ['ö'],
    's': ['š'],
    'z': ['ž'],
  },
  'nb': {
    'a': ['å', 'æ'],
    'e': ['é'],
    'o': ['ø'],
  },
  'da': {
    'a': ['å', 'æ'],
    'e': ['é'],
    'o': ['ø'],
  },
  'is': {
    'a': ['á'],
    'e': ['é'],
    'i': ['í'],
    'o': ['ó', 'ö'],
    'u': ['ú'],
    'y': ['ý'],
  },
  'et': {
    'a': ['ä'],
    'o': ['ö', 'õ'],
    's': ['š'],
    'u': ['ü'],
    'z': ['ž'],
  },
  'pl': {
    'a': ['ą'],
    'c': ['ć'],
    'e': ['ę'],
    'l': ['ł'],
    'n': ['ń'],
    'o': ['ó'],
    's': ['ś'],
    'z': ['ż', 'ź'],
  },
  'cs': {
    'a': ['á'],
    'c': ['č'],
    'd': ['ď'],
    'e': ['é', 'ě'],
    'i': ['í'],
    'n': ['ň'],
    'o': ['ó'],
    'r': ['ř'],
    's': ['š'],
    't': ['ť'],
    'u': ['ú', 'ů'],
    'y': ['ý'],
    'z': ['ž'],
  },
  'sk': {
    'a': ['á', 'ä'],
    'c': ['č'],
    'd': ['ď'],
    'e': ['é'],
    'i': ['í'],
    'l': ['ľ', 'ĺ'],
    'n': ['ň'],
    'o': ['ó', 'ô'],
    'r': ['ŕ'],
    's': ['š'],
    't': ['ť'],
    'u': ['ú'],
    'y': ['ý'],
    'z': ['ž'],
  },
  'hu': {
    'a': ['á'],
    'e': ['é'],
    'i': ['í'],
    'o': ['ó', 'ö', 'ő'],
    'u': ['ú', 'ü', 'ű'],
  },
  'ro': {
    'a': ['ă', 'â'],
    'i': ['î'],
    's': ['ș'],
    't': ['ț'],
  },
  'lt': {
    'a': ['ą'],
    'c': ['č'],
    'e': ['ę', 'ė'],
    'i': ['į'],
    's': ['š'],
    'u': ['ų', 'ū'],
    'z': ['ž'],
  },
  'lv': {
    'a': ['ā'],
    'c': ['č'],
    'e': ['ē'],
    'g': ['ģ'],
    'i': ['ī'],
    'k': ['ķ'],
    'l': ['ļ'],
    'n': ['ņ'],
    's': ['š'],
    'u': ['ū'],
    'z': ['ž'],
  },
  'tr': {
    'c': ['ç'],
    'g': ['ğ'],
    'o': ['ö'],
    's': ['ş'],
    'u': ['ü'],
  },
  'ru': {
    'е': ['ё'],
    'ь': ['ъ'],
  },
  'uk': {
    'г': ['ґ'],
  },
  'el': {
    'α': ['ά'],
    'ε': ['έ'],
    'η': ['ή'],
    'ι': ['ί', 'ϊ', 'ΐ'],
    'ο': ['ό'],
    'υ': ['ύ', 'ϋ', 'ΰ'],
    'ω': ['ώ'],
  },
};
