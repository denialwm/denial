import 'dart:io';

import 'package:denial_dart_shell/src/models/clipboard_history.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/state/clipboard_tray.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('window offset follows every configured tray edge', () {
    const tray = ClipboardTrayState(open: true, progress: 0.5);
    const extent = 400.0;

    expect(
      clipboardTrayWindowOffset(
        tray,
        const ShellLayoutSettings(
          clipboardTrayEdge: ClipboardTrayEdge.left,
          clipboardTrayExtent: extent,
        ),
      ),
      const Offset(200, 0),
    );
    expect(
      clipboardTrayWindowOffset(
        tray,
        const ShellLayoutSettings(
          clipboardTrayEdge: ClipboardTrayEdge.right,
          clipboardTrayExtent: extent,
        ),
      ),
      const Offset(-200, 0),
    );
    expect(
      clipboardTrayWindowOffset(
        tray,
        const ShellLayoutSettings(
          clipboardTrayEdge: ClipboardTrayEdge.top,
          clipboardTrayExtent: extent,
        ),
      ),
      const Offset(0, 200),
    );
    expect(
      clipboardTrayWindowOffset(
        tray,
        const ShellLayoutSettings(
          clipboardTrayEdge: ClipboardTrayEdge.bottom,
          clipboardTrayExtent: extent,
        ),
      ),
      const Offset(0, -200),
    );
  });

  test('tray controller clamps gesture progress and settles atomically', () {
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    final controller = container.read(clipboardTrayProvider.notifier);

    controller
      ..open(monitorId: 42)
      ..setMotionProgress(2, gestureActive: true);
    expect(
      container.read(clipboardTrayProvider),
      isA<ClipboardTrayState>()
          .having((state) => state.open, 'open', isTrue)
          .having((state) => state.progress, 'progress', 1)
          .having((state) => state.gestureActive, 'gestureActive', isTrue)
          .having((state) => state.monitorId, 'monitorId', 42),
    );

    controller.settle(open: false);
    expect(container.read(clipboardTrayProvider).open, isFalse);
    expect(container.read(clipboardTrayProvider).gestureActive, isFalse);
  });

  test('MIME helpers distinguish image and file history entries', () {
    final image = _entry(
      kind: ClipboardHistoryContentKind.image,
      mimeTypes: const <String>['image/png', 'text/plain'],
    );
    final files = _entry(
      kind: ClipboardHistoryContentKind.text,
      mimeTypes: const <String>['text/uri-list', 'text/plain'],
    );

    expect(clipboardImageMimeType(image), 'image/png');
    expect(clipboardFileMimeType(image), isNull);
    expect(clipboardImageMimeType(files), isNull);
    expect(clipboardFileMimeType(files), 'text/uri-list');
  });

  test('window offset is monitor-local and uses the output-sized extent', () {
    const tray = ClipboardTrayState(progress: 0.5, monitorId: 7);
    const layout = ShellLayoutSettings(
      clipboardTrayEdge: ClipboardTrayEdge.left,
      clipboardTrayExtent: clipboardTrayMaximumExtent,
    );

    expect(
      clipboardTrayWindowOffset(
        tray,
        layout,
        monitorId: 8,
        outputSize: const Size(220, 900),
      ),
      Offset.zero,
    );
    expect(
      clipboardTrayWindowOffset(
        tray,
        layout,
        monitorId: 7,
        outputSize: const Size(220, 900),
      ),
      const Offset(62, 0),
    );
  });

  test('uppercase JPEG file URIs load as bounded local previews', () async {
    final directory = await Directory.systemTemp.createTemp(
      'denial-clipboard-preview-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/CAPTURE.JPG');
    await file.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
    final uris = clipboardFileUris(
      '# copied by a file manager\r\n${file.uri}\r\n',
    );

    expect(uris, <Uri>[file.uri]);
    expect(clipboardUriCanRenderAsImage(file.uri), isTrue);
    expect(clipboardUriCanRenderAsImage(Uri.file('/tmp/archive.tar')), isFalse);

    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    final preview = await container.read(
      clipboardLocalFilePreviewProvider(file.uri).future,
    );
    expect(preview, <int>[0xff, 0xd8, 0xff, 0xd9]);
  });
}

ClipboardHistoryEntry _entry({
  required ClipboardHistoryContentKind kind,
  required List<String> mimeTypes,
}) {
  return ClipboardHistoryEntry(
    id: 1,
    capturedAt: DateTime.fromMillisecondsSinceEpoch(0),
    byteLength: 12,
    width: 0,
    height: 0,
    origin: ClipboardHistoryOrigin.wayland,
    kind: kind,
    pinned: false,
    active: false,
    preview: 'preview',
    sourceAppId: '',
    sourceTitle: '',
    mimeTypes: mimeTypes,
  );
}
