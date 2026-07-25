import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:denial_dart_shell/src/input/shell_interaction_registry.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/services/clipboard_history_service.dart';
import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/state/clipboard_tray.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/clipboard_tray_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('does not expose a pointer trigger while the tray is closed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(
      denialClipboardChannel,
      (_) async => _emptySnapshotPacket(),
    );
    addTearDown(
      () => messenger.setMockMessageHandler(denialClipboardChannel, null),
    );
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(_MemorySettingsStore()),
        displayLayoutProvider.overrideWithBuild(
          (ref, controller) => DisplayLayout.fallback(const Size(1000, 700), 1),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const ShellTheme(
            data: ShellThemeData(),
            child: ClipboardTrayLayer(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Clipboard history · Super+V'), findsNothing);
    expect(
      container
          .read(shellInteractionRegistryProvider)
          .surfaces
          .values
          .where(
            (surface) => surface.debugLabel == 'Clipboard tray edge handle',
          ),
      isEmpty,
    );

    await tester.tapAt(const Offset(996, 350));
    await tester.pump();
    expect(container.read(clipboardTrayProvider).open, isFalse);
  });

  testWidgets('renders image, file, and bounded text history cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final screenshotFile = File(
      'test/widgets/fixtures/clipboard_screenshot.jpg',
    ).absolute;
    final screenshot = await tester.runAsync(screenshotFile.readAsBytes);
    // Keep the fixture small enough that software-rendered CI exercises the
    // image path without turning the visual test into an image benchmark.
    expect(screenshot, isNotNull);
    final screenshotBytes = screenshot!;
    expect(screenshotBytes.length, lessThan(100000));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(denialClipboardChannel, (message) async {
      final bytes = _bytes(message!);
      return switch (bytes[6]) {
        0 => _snapshotPacket(),
        1 => _dataPacket(
          itemId: _uint64(bytes, 8),
          mimeType: _string16(bytes, 16),
          bytes: _uint64(bytes, 8) == 3
              ? screenshotBytes
              : utf8.encode(
                  '${screenshotFile.uri}\r\n'
                  'file:///home/example/Documents/ideas.md\r\n',
                ),
        ),
        _ => _ackPacket(8),
      };
    });
    addTearDown(
      () => messenger.setMockMessageHandler(denialClipboardChannel, null),
    );

    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(_MemorySettingsStore()),
        displayLayoutProvider.overrideWithBuild(
          (ref, controller) => DisplayLayout.fallback(const Size(1200, 800), 1),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true),
          home: const ShellTheme(
            data: ShellThemeData(
              accent: Color(0xff83d8ff),
              panelOpacity: 0.84,
              backdropBlurSigma: 22,
            ),
            child: ClipboardTrayLayer(),
          ),
        ),
      ),
    );
    await tester.pump();
    container.read(clipboardTrayProvider.notifier).open();
    for (var frame = 0; frame < 50; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 120));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();

    expect(find.text('Clipboard'), findsNothing);
    expect(find.text('clipboard_screenshot.jpg'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    expect(find.textContaining('Architecture is the shape'), findsOneWidget);
    expect(
      find.textContaining('This tail must never be visible'),
      findsNothing,
    );
    _expectClipboardContentsInsideView(tester);
    expect(tester.takeException(), isNull);

    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey<String>('clipboard-history-card-1')),
      ),
    );
    await gesture.moveBy(const Offset(-70, 24));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('clipboard-drag-preview')),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('clipboard-drag-preview')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey<String>('clipboard-drag-preview')),
      findsNothing,
    );

    container
        .read(shellSettingsProvider.notifier)
        .setClipboardTrayEdge(ClipboardTrayEdge.bottom);
    for (var frame = 0; frame < 45; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    _expectClipboardContentsInsideView(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out cleanly from every configured edge', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(denialClipboardChannel, (message) async {
      return _emptySnapshotPacket();
    });
    addTearDown(
      () => messenger.setMockMessageHandler(denialClipboardChannel, null),
    );
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(_MemorySettingsStore()),
        displayLayoutProvider.overrideWithBuild(
          (ref, controller) => DisplayLayout.fallback(const Size(1000, 700), 1),
        ),
      ],
    );
    addTearDown(container.dispose);
    final settings = container.read(shellSettingsProvider.notifier)
      ..setClipboardTrayExtent(280);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const ShellTheme(
            data: ShellThemeData(),
            child: ClipboardTrayLayer(),
          ),
        ),
      ),
    );
    await tester.pump();
    container.read(clipboardTrayProvider.notifier).open();

    for (final edge in ClipboardTrayEdge.values) {
      settings.setClipboardTrayEdge(edge);
      for (var frame = 0; frame < 40; frame += 1) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final position = tester.getTopLeft(find.byType(TextField));
      switch (edge) {
        case ClipboardTrayEdge.left:
          expect(position.dx, lessThan(100));
          break;
        case ClipboardTrayEdge.right:
          expect(position.dx, greaterThan(650));
          break;
        case ClipboardTrayEdge.top:
          expect(position.dy, lessThan(100));
          break;
        case ClipboardTrayEdge.bottom:
          expect(position.dy, greaterThan(400));
          break;
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'keeps app keyboard routing until search is focused and dismisses outside',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler(
        denialClipboardChannel,
        (_) async => _emptySnapshotPacket(),
      );
      addTearDown(
        () => messenger.setMockMessageHandler(denialClipboardChannel, null),
      );
      final container = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(_MemorySettingsStore()),
          displayLayoutProvider.overrideWithBuild(
            (ref, controller) =>
                DisplayLayout.fallback(const Size(1000, 700), 1),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: const ShellTheme(
              data: ShellThemeData(),
              child: ClipboardTrayLayer(),
            ),
          ),
        ),
      );
      await tester.pump();
      container.read(clipboardTrayProvider.notifier).open();
      for (var frame = 0; frame < 40; frame += 1) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        container.read(shellInteractionRegistryProvider).capturesKeyboard,
        isFalse,
      );
      expect(
        container.read(shellInteractionRegistryProvider).capturesFullScene,
        isTrue,
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pump();
      expect(
        container.read(shellInteractionRegistryProvider).capturesKeyboard,
        isTrue,
      );

      await tester.tapAt(const Offset(100, 350));
      await tester.pump();
      expect(container.read(clipboardTrayProvider).open, isFalse);
      expect(
        container.read(shellInteractionRegistryProvider).capturesKeyboard,
        isFalse,
      );
    },
  );
}

void _expectClipboardContentsInsideView(WidgetTester tester) {
  _expectInsideView(tester, find.byType(TextField));
  for (final itemId in const [1, 2, 3]) {
    _expectInsideView(
      tester,
      find.byKey(ValueKey<String>('clipboard-history-card-$itemId')),
    );
  }
}

void _expectInsideView(WidgetTester tester, Finder finder) {
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  final viewSize = tester.view.physicalSize / tester.view.devicePixelRatio;

  expect(rect.width, greaterThan(0));
  expect(rect.height, greaterThan(0));
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(viewSize.width));
  expect(rect.bottom, lessThanOrEqualTo(viewSize.height));
}

ByteData _snapshotPacket() {
  final writer = _response(1)
    ..uint64(7)
    ..uint64(200000)
    ..uint64(3)
    ..uint8(0)
    ..uint16(3);
  _entry(
    writer,
    id: 3,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    byteLength: 180000,
    width: 640,
    height: 360,
    kind: 1,
    flags: 2,
    preview: 'Abstract test image',
    appId: 'org.denial.Screenshot',
    title: 'Screenshot',
    mimeTypes: const <String>['image/jpeg'],
  );
  _entry(
    writer,
    id: 2,
    timestamp: DateTime.now()
        .subtract(const Duration(minutes: 3))
        .millisecondsSinceEpoch,
    byteLength: 150,
    kind: 0,
    flags: 1,
    preview: 'file:///home/example/Pictures/sample-preview.png',
    appId: 'org.gnome.Nautilus',
    title: 'Files',
    mimeTypes: const <String>['text/uri-list', 'text/plain'],
  );
  _entry(
    writer,
    id: 1,
    timestamp: DateTime.now()
        .subtract(const Duration(hours: 2))
        .millisecondsSinceEpoch,
    byteLength: 1200,
    kind: 0,
    flags: 0,
    preview:
        'Architecture is the shape of a promise: motion, state, and input '
        'must agree on every frame. Smooth motion keeps the compositor calm. '
        'Smooth motion keeps the compositor calm. Smooth motion keeps the '
        'compositor calm. Smooth motion keeps the compositor calm. Smooth '
        'motion keeps the compositor calm. Smooth motion keeps the compositor '
        'calm. Smooth motion keeps the compositor calm. Smooth motion keeps '
        'the compositor calm. This tail must never be visible.',
    appId: 'dev.zed.Zed',
    title: 'Editor',
    mimeTypes: const <String>['text/plain;charset=utf-8'],
  );
  return writer.data();
}

ByteData _emptySnapshotPacket() {
  return (_response(1)
        ..uint64(1)
        ..uint64(0)
        ..uint64(0)
        ..uint8(0)
        ..uint16(0))
      .data();
}

void _entry(
  _Writer writer, {
  required int id,
  required int timestamp,
  required int byteLength,
  required int kind,
  required int flags,
  required String preview,
  required String appId,
  required String title,
  required List<String> mimeTypes,
  int width = 0,
  int height = 0,
}) {
  writer
    ..uint64(id)
    ..uint64(timestamp)
    ..uint64(byteLength)
    ..uint32(width)
    ..uint32(height)
    ..uint8(0)
    ..uint8(kind)
    ..uint8(flags)
    ..uint8(mimeTypes.length)
    ..string16(preview)
    ..string16(appId)
    ..string16(title);
  for (final mimeType in mimeTypes) {
    writer.string16(mimeType);
  }
}

ByteData _dataPacket({
  required int itemId,
  required String mimeType,
  required List<int> bytes,
}) {
  return (_response(2)
        ..uint64(itemId)
        ..string16(mimeType)
        ..uint64(bytes.length)
        ..bytes(bytes))
      .data();
}

ByteData _ackPacket(int revision) => (_response(0)..uint64(revision)).data();

_Writer _response(int kind) {
  return _Writer()
    ..bytes(const <int>[0x44, 0x43, 0x4c, 0x53])
    ..uint16(1)
    ..uint8(kind)
    ..uint8(0);
}

Uint8List _bytes(ByteData data) =>
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

int _uint64(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 8).getUint64(0, Endian.little);

String _string16(Uint8List bytes, int offset) {
  final length = ByteData.sublistView(
    bytes,
    offset,
    offset + 2,
  ).getUint16(0, Endian.little);
  return utf8.decode(bytes.sublist(offset + 2, offset + 2 + length));
}

class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void bytes(List<int> value) => _builder.add(value);

  void uint8(int value) => _builder.add(<int>[value]);

  void uint16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void uint32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void uint64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void string16(String value) {
    final bytes = utf8.encode(value);
    uint16(bytes.length);
    this.bytes(bytes);
  }

  ByteData data() => ByteData.sublistView(_builder.takeBytes());
}

class _MemorySettingsStore implements SettingsStore {
  @override
  Future<ShellSettings?> read() async => null;

  @override
  Future<void> write(ShellSettings settings) async {}
}
