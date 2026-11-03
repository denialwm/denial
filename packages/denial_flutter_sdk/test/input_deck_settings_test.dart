import 'package:denial_flutter_sdk/src/settings/input_deck_settings.dart';
import 'package:test/test.dart';

void main() {
  test('missing preferences leave touch displays in their normal role', () {
    final settings = InputDeckSettings.fromJson(null);
    expect(settings.enabled, isFalse);
    expect(settings.outputName, isEmpty);
    expect(settings.showCpu, isFalse);
    expect(settings.showGpu, isFalse);
  });

  test('saving a manual stop retains the output and customization', () {
    const settings = InputDeckSettings(
      enabled: true,
      outputName: 'eDP-1',
      keyboardHeight: 0.6,
      touchpadWidth: 0.8,
      showCpu: true,
    );
    final stopped = InputDeckSettings.fromJson(
      settings.copyWith(enabled: false).toJson(),
    );
    expect(stopped.enabled, isFalse);
    expect(stopped.outputName, 'eDP-1');
    expect(stopped.keyboardHeight, 0.6);
    expect(stopped.touchpadWidth, 0.8);
    expect(stopped.showCpu, isTrue);
  });

  test('corrupt dimensions cannot produce nonfinite or unusable layouts', () {
    final settings = InputDeckSettings.fromJson({
      'keyboardHeight': double.nan,
      'touchpadWidth': -12,
      'pointerSpeed': double.infinity,
      'outputName': 'bad\u0000name',
    });
    expect(settings.keyboardHeight, const InputDeckSettings().keyboardHeight);
    expect(settings.touchpadWidth, 0.35);
    expect(settings.pointerSpeed, const InputDeckSettings().pointerSpeed);
    expect(settings.outputName, isEmpty);
  });
  test(
    'undocking suspends a remembered opt-in and reconnecting restores it',
    () {
      const settings = InputDeckSettings(enabled: true, outputName: 'eDP-1');
      expect(
        settings.desiredOutput(touchOutputs: ['eDP-1'], available: true),
        'eDP-1',
      );
      expect(
        settings.desiredOutput(touchOutputs: ['eDP-1'], available: false),
        isNull,
      );
      expect(settings.enabled, isTrue);
      expect(
        settings.desiredOutput(touchOutputs: ['eDP-1'], available: true),
        'eDP-1',
      );
      expect(
        settings
            .copyWith(enabled: false)
            .desiredOutput(touchOutputs: ['eDP-1'], available: true),
        isNull,
      );
    },
  );

  test(
    'lock and unrelated touch screens cannot activate the selected panel',
    () {
      const settings = InputDeckSettings(enabled: true, outputName: 'eDP-1');
      expect(
        settings.desiredOutput(touchOutputs: ['HDMI-A-1'], available: true),
        isNull,
      );
      expect(
        settings.desiredOutput(
          touchOutputs: ['eDP-1'],
          available: true,
          locked: true,
        ),
        isNull,
      );
      expect(
        settings.desiredOutput(
          touchOutputs: ['eDP-1'],
          available: true,
          locked: false,
        ),
        'eDP-1',
      );
    },
  );
}
