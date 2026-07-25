# Denial localization catalog

`app_en.arb` is the canonical English template for Flutter's `gen_l10n`
pipeline. Generated Dart sources live in `generated/` and are rebuilt by the
normal Flutter bundle build.

To add a locale:

1. Copy `app_en.arb` to `app_<locale>.arb` and update `@@locale`.
2. Translate message values while preserving every message key and placeholder.
3. Run `flutter gen-l10n`, or build through `tools/denial-pc bundle`.
4. Add or update widget tests for copy length, semantics, and minimum-window
   layout in that locale.

No shell-root wiring is needed for an additional ARB file. The generated
`supportedLocales` catalog and `DenialLocalizationScope` resolve the platform
locale automatically, with English as the fallback.
