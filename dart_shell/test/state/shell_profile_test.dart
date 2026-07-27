import 'package:denial_dart_shell/src/config/startup_environment.dart';
import 'package:denial_dart_shell/src/state/shell_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShellProfile.fromEnvironment', () {
    test('defaults to desktop when the profile is absent', () {
      expect(
        ShellProfile.fromEnvironment(const <String, String>{}),
        ShellProfile.desktop,
      );
    });

    test('defaults to desktop for empty or malformed values', () {
      for (final value in <String>['', ' ', 'phone', 'Mobile', ' mobile ']) {
        expect(
          ShellProfile.fromEnvironment(<String, String>{
            'DENIA_SHELL_PROFILE': value,
          }),
          ShellProfile.desktop,
          reason: 'unexpected profile for "$value"',
        );
      }
    });

    test('selects desktop when requested explicitly', () {
      expect(
        ShellProfile.fromEnvironment(const <String, String>{
          'DENIA_SHELL_PROFILE': 'desktop',
        }),
        ShellProfile.desktop,
      );
    });

    test('selects mobile only when requested explicitly', () {
      expect(
        ShellProfile.fromEnvironment(const <String, String>{
          'DENIA_SHELL_PROFILE': 'mobile',
        }),
        ShellProfile.mobile,
      );
    });
  });

  test('shell profile provider defaults to desktop', () {
    final container = ProviderContainer(
      overrides: [
        startupEnvironmentProvider.overrideWithValue(
          const StartupEnvironment.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(shellProfileProvider), ShellProfile.desktop);
  });
}
