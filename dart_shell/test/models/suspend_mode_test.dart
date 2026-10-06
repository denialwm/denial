import 'package:denial_dart_shell/src/models/suspend_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses supported and selected Linux memory sleep modes', () {
    final capabilities = SuspendModeCapabilities.parse('s2idle [deep]\n');

    expect(capabilities.supported, <SuspendMode>[
      SuspendMode.s2idle,
      SuspendMode.deep,
    ]);
    expect(capabilities.current, SuspendMode.deep);
    expect(capabilities.canSelect, isTrue);
    expect(
      capabilities.effectiveSelection(SuspendMode.systemDefault),
      SuspendMode.deep,
    );
    expect(
      capabilities.effectiveSelection(SuspendMode.s2idle),
      SuspendMode.s2idle,
    );
  });

  test('a machine with one reported mode cannot select another', () {
    final capabilities = SuspendModeCapabilities.parse('[s2idle]\n');

    expect(capabilities.supported, <SuspendMode>[SuspendMode.s2idle]);
    expect(capabilities.current, SuspendMode.s2idle);
    expect(capabilities.canSelect, isFalse);
    expect(
      capabilities.effectiveSelection(SuspendMode.deep),
      SuspendMode.s2idle,
    );
  });

  test('unknown or missing kernel modes produce an unavailable selector', () {
    final capabilities = SuspendModeCapabilities.parse('[future-mode]\n');

    expect(capabilities.supported, isEmpty);
    expect(capabilities.current, isNull);
    expect(capabilities.canSelect, isFalse);
    expect(
      capabilities.effectiveSelection(SuspendMode.deep),
      SuspendMode.systemDefault,
    );
  });
}
