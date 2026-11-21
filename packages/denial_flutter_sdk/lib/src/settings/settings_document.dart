import 'dart:convert';

/// Retains fields outside the typed shell projection across preference saves.
final class SettingsDocumentProjection {
  int _revision = 0;
  Map<String, Object?> _document = const {};

  int get revision => _revision;

  void remember({required int revision, required String document}) {
    if (revision <= 0) {
      throw StateError('Denial returned an invalid settings revision');
    }
    if (revision < _revision) return;
    final decoded = jsonDecode(document);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Denial settings root is not an object');
    }
    _document = decoded;
    _revision = revision;
  }

  String encode(Map<String, Object?> settings) =>
      '${const JsonEncoder.withIndent('  ').convert(_merge(_document, settings))}\n';

  static Map<String, Object?> _merge(
    Map<String, Object?> document,
    Map<String, Object?> settings,
  ) => {
    ...document,
    for (final entry in settings.entries)
      entry.key:
          // Environment maps and shell scales express the complete desired
          // overrides. Merging would resurrect entries deliberately removed
          // by the user.
          entry.key != 'applicationEnvironment' &&
              entry.key != 'shellScales' &&
              document[entry.key] is Map<String, Object?> &&
              entry.value is Map<String, Object?>
          ? _merge(
              document[entry.key]! as Map<String, Object?>,
              entry.value! as Map<String, Object?>,
            )
          : entry.value,
  };
}
