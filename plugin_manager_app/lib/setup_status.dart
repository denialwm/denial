enum SetupProblem { missingDart, incompatibleDart, tools }

/// Read-only setup facts. User-facing descriptions use SDK localizations.
final class SetupNotice {
  const SetupNotice(
    this.problem, {
    this.installed,
    this.constraint,
    this.expected,
  });
  final SetupProblem problem;
  final String? installed;
  final String? constraint;
  final String? expected;

  static SetupNotice fromState(Map<String, Object?> state) {
    final dart = state['dart'];
    if (dart is Map && dart['available'] == false) {
      final expected = dart['expectedVersion'] as String?;
      final constraint = dart['constraint'] as String?;
      final installed = dart['version'] as String?;
      if (installed != null && constraint != null) {
        return SetupNotice(
          SetupProblem.incompatibleDart,
          installed: installed,
          constraint: constraint,
        );
      }
      if (expected != null) {
        return SetupNotice(SetupProblem.missingDart, expected: expected);
      }
    }
    return const SetupNotice(SetupProblem.tools);
  }
}
