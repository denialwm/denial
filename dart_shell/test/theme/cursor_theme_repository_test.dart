import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:denial_dart_shell/src/theme/cursor_theme_repository.dart';
import 'package:denial_dart_shell/src/theme/cursor_themes.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ANI parsing preserves sequence, per-step timing, and hotspots', () {
    final ani = _ani(
      cursors: <Uint8List>[
        _cursor(width: 2, height: 2, hotspotX: 0, hotspotY: 1),
        _cursor(width: 2, height: 2, hotspotX: 1, hotspotY: 0),
      ],
      sequence: const <int>[1, 0],
      rates: const <int>[3, 9],
    );

    final parsed = parseWindowsAnimatedCursor(ani);

    expect(parsed.images, hasLength(2));
    expect(parsed.steps, hasLength(2));
    expect(parsed.steps[0].imageIndex, 1);
    expect(parsed.steps[0].duration, const Duration(milliseconds: 50));
    expect(parsed.steps[0].hotspot.dx, 1);
    expect(parsed.steps[0].hotspot.dy, 0);
    expect(parsed.steps[1].imageIndex, 0);
    expect(parsed.steps[1].duration, const Duration(milliseconds: 150));
    expect(parsed.steps[1].hotspot.dx, 0);
    expect(parsed.steps[1].hotspot.dy, 1);
  });

  test(
    'ZIP imports persist a discoverable manifest and can be removed',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'denial-cursor-import-test-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final asset = await rootBundle.load(
        'assets/cursors/bibata_modern_ice/normal/00.png',
      );
      final png = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'Theme/install.inf',
            '[Strings]\nSCHEME_NAME="Test animation"\npointer="Normal.ani"\n',
          ),
        )
        ..addFile(
          ArchiveFile(
            'Theme/Normal.ani',
            0,
            _ani(
              cursors: <Uint8List>[
                _cursor(
                  width: 32,
                  height: 32,
                  hotspotX: 6,
                  hotspotY: 2,
                  png: png,
                ),
              ],
              sequence: const <int>[0],
              rates: const <int>[5],
            ),
          ),
        );
      final archiveBytes = ZipEncoder().encode(archive)!;
      final zip = File('${temporary.path}/theme.zip');
      await zip.writeAsBytes(archiveBytes);
      final repository = CursorThemeRepository(dataHome: temporary.path);

      final imported = await repository.importWindowsCursorZip(zip.path);
      final discovered = await repository.discover();

      expect(imported.isImported, isTrue);
      expect(imported.label, 'Test animation');
      expect(imported.roleFor(ShellCursorKind.normal).frames, hasLength(1));
      expect(discovered.map((theme) => theme.id), contains(imported.id));
      expect(File('${imported.fileRoot}/theme.json'), _isExistingRegularFile);

      await repository.remove(imported);
      expect(await Directory(imported.fileRoot!).exists(), isFalse);
    },
  );
}

final Matcher _isExistingRegularFile = predicate<File>(
  (file) =>
      file.existsSync() && file.statSync().type == FileSystemEntityType.file,
  'an existing regular file',
);

Uint8List _ani({
  required List<Uint8List> cursors,
  required List<int> sequence,
  required List<int> rates,
}) {
  final header = Uint8List(36);
  final headerData = ByteData.sublistView(header);
  headerData.setUint32(0, 36, Endian.little);
  headerData.setUint32(4, cursors.length, Endian.little);
  headerData.setUint32(8, sequence.length, Endian.little);
  headerData.setUint32(28, 5, Endian.little);
  headerData.setUint32(32, 3, Endian.little);
  final frameList = BytesBuilder(copy: false)..add(ascii.encode('fram'));
  for (final cursor in cursors) {
    frameList.add(_chunk('icon', cursor));
  }
  final body = BytesBuilder(copy: false)
    ..add(ascii.encode('ACON'))
    ..add(_chunk('anih', header))
    ..add(_chunk('rate', _integers(rates)))
    ..add(_chunk('seq ', _integers(sequence)))
    ..add(_chunk('LIST', frameList.takeBytes()));
  final bodyBytes = body.takeBytes();
  final result = BytesBuilder(copy: false)
    ..add(ascii.encode('RIFF'))
    ..add(_integer(bodyBytes.length))
    ..add(bodyBytes);
  return result.takeBytes();
}

Uint8List _cursor({
  required int width,
  required int height,
  required int hotspotX,
  required int hotspotY,
  Uint8List? png,
}) {
  png ??= base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR42mP8z8Dwn4GBgYGJAQoAHgQCAZy4V7kAAAAASUVORK5CYII=',
  );
  final result = Uint8List(22 + png.length);
  final data = ByteData.sublistView(result);
  data.setUint16(2, 2, Endian.little);
  data.setUint16(4, 1, Endian.little);
  result[6] = width;
  result[7] = height;
  data.setUint16(10, hotspotX, Endian.little);
  data.setUint16(12, hotspotY, Endian.little);
  data.setUint32(14, png.length, Endian.little);
  data.setUint32(18, 22, Endian.little);
  result.setRange(22, result.length, png);
  return result;
}

Uint8List _chunk(String id, Uint8List data) {
  final result = BytesBuilder(copy: false)
    ..add(ascii.encode(id))
    ..add(_integer(data.length))
    ..add(data);
  if (data.length.isOdd) {
    result.addByte(0);
  }
  return result.takeBytes();
}

Uint8List _integers(List<int> values) {
  final result = Uint8List(values.length * 4);
  final data = ByteData.sublistView(result);
  for (var index = 0; index < values.length; index += 1) {
    data.setUint32(index * 4, values[index], Endian.little);
  }
  return result;
}

Uint8List _integer(int value) {
  final result = Uint8List(4);
  ByteData.sublistView(result).setUint32(0, value, Endian.little);
  return result;
}
