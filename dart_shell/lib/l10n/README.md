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

The Settings language page persists an optional `ShellLocalePreference`.
`system` leaves the scope override empty so platform locale changes continue
to apply; explicit preferences update the shell immediately. Add a preference
and its self-named selector label only when a new locale should be selectable
independently of the system locale.

`app_zh.arb` is the Simplified Chinese base catalog. A future Traditional
Chinese translation should use `app_zh_Hant.arb`; Flutter will select that
script-specific catalog before falling back to `zh`.
