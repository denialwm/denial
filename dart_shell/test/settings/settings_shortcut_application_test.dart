import 'package:denial_dart_shell/src/launcher/models/desktop_app.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/shortcut_configuration.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_shortcut_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('application shortcut identity survives control-socket JSON', () {
    final target = DenialShortcutSpawnTarget(const <String>[
      'foot',
    ], desktopFileId: 'org.example.Terminal.desktop');

    expect(target.toJson(), <String, Object>{
      'type': 'spawn',
      'command': <String>['foot'],
      'desktopFileId': 'org.example.Terminal.desktop',
    });
    final decoded = DenialShortcutTarget.fromJson(target.toJson());
    expect(decoded, isA<DenialShortcutSpawnTarget>());
    expect(
      (decoded as DenialShortcutSpawnTarget).desktopFileId,
      'org.example.Terminal.desktop',
    );
  });

  testWidgets('Application target saves desktop ID with parsed Exec argv', (
    tester,
  ) async {
    const application = DesktopApp(
      id: 'org.example.Terminal.desktop',
      name: 'Example Terminal',
      exec: 'foot --title %c',
      desktopPath: '/usr/share/applications/org.example.Terminal.desktop',
      categories: <String>[],
    );
    DenialShortcutBinding? saved;
    final configuration = DenialShortcutConfiguration(
      revision: 1,
      shortcuts: <DenialShortcutBinding>[],
      supportedActions: <DenialShortcutAction>[
        DenialShortcutAction.openApplications,
      ],
      supportedInputs: <DenialShortcutInput>[],
    );

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: Material(
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => SizedBox(
                  width: 720,
                  height: 700,
                  child: SettingsShortcutEditor(
                    configuration: configuration,
                    applications: const <DesktopApp>[application],
                    binding: null,
                    busy: false,
                    deleteBusy: false,
                    nativeError: null,
                    onValidate: ({required shortcut, existingShortcut}) async {
                      return DenialShortcutValidation(
                        revision: 1,
                        kind: DenialShortcutValidationKind.valid,
                        canonical: shortcut.shortcut.isEmpty
                            ? 'Super+T'
                            : shortcut.shortcut,
                      );
                    },
                    onSave: (binding) async {
                      saved = binding;
                      return true;
                    },
                    onDelete: null,
                    onClearError: () {},
                    onClose: () {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Super+T');
    await tester.tap(find.text('Application'));
    await tester.pump();
    await tester.tap(find.text('Choose an application'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example Terminal'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();

    final target = saved?.target;
    expect(target, isA<DenialShortcutSpawnTarget>());
    expect((target as DenialShortcutSpawnTarget).desktopFileId, application.id);
    expect(target.command, <String>['foot', '--title', 'Example Terminal']);
    expect(tester.takeException(), isNull);
  });
}
