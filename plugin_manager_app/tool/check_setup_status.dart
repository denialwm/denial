import 'dart:io';

import 'package:denial_plugin_manager_app/setup_status.dart';

void main() {
  void check(String name, bool value) {
    if (!value) throw StateError(name);
    stdout.writeln('PASS $name');
  }

  final missing = SetupNotice.fromState({
    'dart': {
      'available': false,
      'found': false,
      'expectedVersion': '3.13.4',
      'constraint': '>=3.13.0 <4.0.0',
    },
  });
  check(
    'Missing Dart prompts package installation',
    missing.problem == SetupProblem.missingDart && missing.expected == '3.13.4',
  );

  final incompatible = SetupNotice.fromState({
    'dart': {
      'available': false,
      'found': true,
      'expectedVersion': '3.13.4',
      'constraint': '>=3.13.0 <4.0.0',
      'version': '4.0.0',
    },
  });
  check(
    'Incompatible Dart names both versions',
    incompatible.problem == SetupProblem.incompatibleDart &&
        incompatible.installed == '4.0.0' &&
        incompatible.constraint == '>=3.13.0 <4.0.0',
  );

  check(
    'Other setup failures retain generic recovery',
    SetupNotice.fromState(const {}).problem == SetupProblem.tools,
  );
}
