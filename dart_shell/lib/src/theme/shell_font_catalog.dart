import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'tokens.dart';

/// Discovers font families exposed by the same Fontconfig installation used
/// by Denial's Flutter engine.
class ShellFontCatalog {
  const ShellFontCatalog();

  Future<List<String>> discover() {
    return Future<List<String>>(_discover);
  }

  List<String> _discover() {
    try {
      final library = DynamicLibrary.open('libfontconfig.so.1');
      final initialize = library
          .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
            'FcInitLoadConfigAndFonts',
          );
      final configFonts = library
          .lookupFunction<
            Pointer<_FcFontSet> Function(Pointer<Void>, Int32),
            Pointer<_FcFontSet> Function(Pointer<Void>, int)
          >('FcConfigGetFonts');
      final patternString = library
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Uint8>,
              Int32,
              Pointer<Pointer<Uint8>>,
            ),
            int Function(
              Pointer<Void>,
              Pointer<Uint8>,
              int,
              Pointer<Pointer<Uint8>>,
            )
          >('FcPatternGetString');
      final destroy = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('FcConfigDestroy');

      final config = initialize();
      if (config == nullptr) {
        return normalizeShellFontFamilies(const <String>[]);
      }
      final familyProperty = 'family'.toNativeUtf8().cast<Uint8>();
      final value = calloc<Pointer<Uint8>>();
      try {
        final fontSet = configFonts(config, _fcSetSystem);
        if (fontSet == nullptr) {
          return normalizeShellFontFamilies(const <String>[]);
        }
        final families = <String>[];
        final set = fontSet.ref;
        for (var fontIndex = 0; fontIndex < set.nfont; fontIndex += 1) {
          final pattern = set.fonts[fontIndex];
          for (var familyIndex = 0; ; familyIndex += 1) {
            final result = patternString(
              pattern,
              familyProperty,
              familyIndex,
              value,
            );
            if (result != _fcResultMatch || value.value == nullptr) {
              break;
            }
            families.add(value.value.cast<Utf8>().toDartString());
          }
        }
        return normalizeShellFontFamilies(families);
      } finally {
        calloc.free(value);
        calloc.free(familyProperty);
        destroy(config);
      }
    } on Object {
      return normalizeShellFontFamilies(const <String>[]);
    }
  }
}

List<String> normalizeShellFontFamilies(Iterable<String> families) {
  final normalized = <String, String>{
    ShellText.systemBarFontFamily.toLowerCase(): ShellText.systemBarFontFamily,
  };
  for (final rawFamily in families) {
    final family = rawFamily.trim();
    if (family.isEmpty ||
        family.length > maximumShellFontFamilyLength ||
        family.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      continue;
    }
    normalized.putIfAbsent(family.toLowerCase(), () => family);
  }
  final result = normalized.values.toList(growable: false);
  result.sort((first, second) {
    final folded = first.toLowerCase().compareTo(second.toLowerCase());
    return folded != 0 ? folded : first.compareTo(second);
  });
  return result;
}

const int _fcSetSystem = 0;
const int _fcResultMatch = 0;

final class _FcFontSet extends Struct {
  @Int32()
  external int nfont;

  @Int32()
  external int sfont;

  external Pointer<Pointer<Void>> fonts;
}
