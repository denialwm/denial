import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/launcher/models/desktop_app.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_environment_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('adds, edits, removes, and deletes environment overrides', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var settings = const ShellApplicationEnvironmentSettings();
    late StateSetter rebuild;

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: Material(
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return SizedBox(
                      width: 720,
                      height: 900,
                      child: SettingsEnvironmentPage(
                        settings: settings,
                        onSave: (_, previousName, name, value) {
                          rebuild(() {
                            if (previousName != null && previousName != name) {
                              settings = settings.withoutOverride(previousName);
                            }
                            settings = settings.withOverride(name, value);
                          });
                        },
                        onDelete: (_, name) => rebuild(
                          () => settings = settings.withoutOverride(name),
                        ),
                        onReset: () => rebuild(
                          () => settings =
                              const ShellApplicationEnvironmentSettings(),
                        ),
                        onResetScope: (_) {},
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(settingsEnvironmentNameFieldKey),
      'MOZ_ENABLE_WAYLAND',
    );
    await tester.enterText(find.byKey(settingsEnvironmentValueFieldKey), '1');
    final saveButton = find.byKey(settingsEnvironmentSaveButtonKey);
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pump();
    expect(settings.variables, <String, String?>{'MOZ_ENABLE_WAYLAND': '1'});
    final editButton = find.byTooltip('Edit MOZ_ENABLE_WAYLAND');
    await tester.ensureVisible(editButton);
    await tester.pump();
    expect(
      find.bySemanticsLabel('Added to launched applications'),
      findsOneWidget,
    );

    await tester.tap(editButton);
    await tester.pump();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(settingsEnvironmentNameFieldKey),
              matching: find.byType(EditableText),
            ),
          )
          .readOnly,
      isTrue,
    );
    await tester.tap(find.byKey(settingsEnvironmentHideModeKey));
    await tester.pump();
    expect(find.byKey(settingsEnvironmentValueFieldKey), findsNothing);
    await tester.tap(find.byKey(settingsEnvironmentSaveButtonKey));
    await tester.pump();
    expect(settings.variables, <String, String?>{'MOZ_ENABLE_WAYLAND': null});
    expect(find.textContaining('<hidden>'), findsNothing);
    expect(find.byTooltip('Edit MOZ_ENABLE_WAYLAND'), findsNothing);
    final deleteButton = find.byTooltip('Delete MOZ_ENABLE_WAYLAND');
    await tester.ensureVisible(deleteButton);
    await tester.pump();
    expect(
      find.bySemanticsLabel('Hidden from launched applications'),
      findsOneWidget,
    );

    await tester.tap(deleteButton);
    await tester.pump();
    expect(settings.variables, isEmpty);
    expect(find.text('No overrides'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('validates names inline and supports narrow large-text layouts', (
    tester,
  ) async {
    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: MediaQuery(
          data: const MediaQueryData(
            size: Size(420, 900),
            textScaler: TextScaler.linear(1.5),
          ),
          child: Material(
            child: Overlay(
              initialEntries: <OverlayEntry>[
                OverlayEntry(
                  builder: (_) => SizedBox(
                    width: 420,
                    height: 900,
                    child: SettingsEnvironmentPage(
                      settings: const ShellApplicationEnvironmentSettings(),
                      onSave: (_, _, _, _) {},
                      onDelete: (_, _) {},
                      onReset: () {},
                      onResetScope: (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(settingsEnvironmentAllApplicationsScopeKey));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(settingsEnvironmentNameFieldKey),
      '9INVALID',
    );
    final saveButton = find.byKey(settingsEnvironmentSaveButtonKey);
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pump();

    expect(
      find.text(
        'Use letters, numbers, and underscores, beginning with a letter or underscore.',
      ),
      findsOneWidget,
    );
    expect(find.byType(SettingsCardGroup), findsAtLeastNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('stores overrides in the selected desktop application scope', (
    tester,
  ) async {
    const application = DesktopApp(
      id: 'org.example.App.desktop',
      name: 'Example App',
      exec: '/usr/bin/example',
      desktopPath: '/usr/share/applications/org.example.App.desktop',
      categories: <String>[],
    );
    var settings = const ShellApplicationEnvironmentSettings(
      variables: <String, String?>{'MODE': 'default'},
    );
    late StateSetter rebuild;

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: Material(
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return SizedBox(
                      width: 720,
                      height: 900,
                      child: SettingsEnvironmentPage(
                        settings: settings,
                        applications: const <DesktopApp>[application],
                        onSave: (desktopFileId, previousName, name, value) {
                          rebuild(() {
                            if (previousName != null && previousName != name) {
                              settings = settings.withoutOverride(
                                previousName,
                                desktopFileId: desktopFileId,
                              );
                            }
                            settings = settings.withOverride(
                              name,
                              value,
                              desktopFileId: desktopFileId,
                            );
                          });
                        },
                        onDelete: (desktopFileId, name) => rebuild(
                          () => settings = settings.withoutOverride(
                            name,
                            desktopFileId: desktopFileId,
                          ),
                        ),
                        onReset: () {},
                        onResetScope: (_) {},
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(settingsEnvironmentApplicationScopeKey(application.id)),
    );
    await tester.pump();
    await tester.enterText(find.byKey(settingsEnvironmentNameFieldKey), 'MODE');
    await tester.enterText(
      find.byKey(settingsEnvironmentValueFieldKey),
      'application',
    );
    final saveButton = find.byKey(settingsEnvironmentSaveButtonKey);
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pump();

    expect(settings.variables, <String, String?>{'MODE': 'default'});
    expect(settings.applications, <String, Map<String, String?>>{
      application.id: <String, String?>{'MODE': 'application'},
    });
    expect(find.text('DEFAULT → APP'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
