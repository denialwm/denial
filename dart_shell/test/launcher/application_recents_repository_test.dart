import 'dart:convert';
import 'dart:io';

import 'package:denial_dart_shell/src/launcher/repositories/application_recents_repository.dart';
import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;
  late RuntimePaths paths;
  late ApplicationRecentsRepository repository;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'denial-application-recents-',
    );
    paths = RuntimePaths(
      environment: <String, String>{
        'HOME': temporary.path,
        'XDG_STATE_HOME': temporary.path,
      },
    );
    repository = ApplicationRecentsRepository(paths: paths);
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('round-trips a bounded recent application order', () async {
    final entries = <String>[
      for (var index = 0; index < applicationRecentEntryLimit + 3; index += 1)
        'desktop:app-$index.desktop',
    ];

    await repository.saveEntries(entries);

    expect(
      await repository.readEntries(),
      entries.take(applicationRecentEntryLimit),
    );
  });

  test('discards malformed and duplicate persisted entries', () async {
    final file = await paths.applicationRecentsFile();
    await file.writeAsString(
      jsonEncode(<String, Object>{
        'version': 1,
        'entries': <Object>[
          'local:settings',
          'local:settings',
          42,
          '',
          'desktop:browser.desktop',
        ],
      }),
    );

    expect(await repository.readEntries(), <String>[
      'local:settings',
      'desktop:browser.desktop',
    ]);
  });
}
