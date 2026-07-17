import 'package:denial_dart_shell/src/config/startup_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup environment is immutable and parses explicit flags', () {
    final source = <String, String>{
      'ON': ' yes ',
      'OFF': '0',
      'UNKNOWN': 'sometimes',
    };
    final environment = StartupEnvironment(source);
    source['ON'] = 'no';

    expect(environment['ON'], ' yes ');
    expect(environment.flag('ON'), isTrue);
    expect(environment.flag('OFF', defaultValue: true), isFalse);
    expect(environment.flag('MISSING'), isFalse);
    expect(environment.flag('UNKNOWN', defaultValue: true), isTrue);
    expect(
      () => environment.values['NEW'] = 'value',
      throwsUnsupportedError,
    );
  });
}
