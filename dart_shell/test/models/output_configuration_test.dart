import 'package:denial_dart_shell/src/models/output_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes output control snapshots and preserves exact millihertz', () {
    final configuration = DenialOutputConfiguration.fromJson(<String, Object?>{
      'serial': 9,
      'capabilities': <String, Object?>{
        'apply': true,
        'position': true,
        'mode': true,
        'scale': true,
        'transform': true,
        'persistent': true,
      },
      'pending_confirmation': <String, Object?>{
        'token': 27,
        'deadline_unix_milliseconds': 1755421200000,
      },
      'outputs': <Object?>[
        <String, Object?>{
          'name': 'DP-1',
          'description': 'Desk display',
          'connected': true,
          'enabled': true,
          'powered': true,
          'x': -1080,
          'y': 0,
          'logical_width': 1080,
          'logical_height': 1920,
          'scale': 1.0,
          'transform': '90',
          'adaptive_sync': false,
          'current_mode': <String, Object?>{
            'width': 1920,
            'height': 1080,
            'refresh_millihz': 59940,
            'preferred': true,
          },
          'modes': <Object?>[
            <String, Object?>{
              'width': 1920,
              'height': 1080,
              'refresh_millihz': 59940,
              'preferred': true,
            },
          ],
        },
      ],
    });

    final output = configuration.outputs.single;
    expect(configuration.serial, 9);
    expect(configuration.capabilities.transform, isTrue);
    expect(configuration.pendingConfirmation?.token, 27);
    expect(
      configuration.pendingConfirmation?.deadlineUnixMilliseconds,
      1755421200000,
    );
    expect(output.transform, DenialOutputTransform.rotate90);
    expect(output.effectiveMode.refreshMillihz, 59940);
    expect(output.draftLogicalSize.width, 1080);
    expect(output.draftLogicalSize.height, 1920);
    expect(output.toApplyJson()['transform'], '90');
  });

  test('draft mode, scale, and rotation recalculate logical size', () {
    const mode = DenialOutputMode(
      width: 2560,
      height: 1440,
      refreshMillihz: 144000,
      preferred: true,
    );
    const output = DenialOutput(
      name: 'DP-2',
      description: 'DP-2',
      connected: true,
      enabled: true,
      powered: true,
      x: 0,
      y: 0,
      logicalWidth: 2560,
      logicalHeight: 1440,
      scale: 1,
      transform: DenialOutputTransform.normal,
      adaptiveSync: false,
      currentMode: mode,
      modes: <DenialOutputMode>[mode],
    );

    final portrait = output.copyWith(
      transform: DenialOutputTransform.rotate270,
      scale: 2,
    );
    expect(portrait.logicalWidth, 720);
    expect(portrait.logicalHeight, 1280);
    expect(portrait.toApplyJson()['scale'], 2);
    expect(portrait.toApplyJson()['transform'], '270');
  });
}
