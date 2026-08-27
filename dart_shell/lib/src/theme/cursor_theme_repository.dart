import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'cursor_themes.dart';

const int _cursorManifestVersion = 1;
const int _maximumArchiveBytes = 64 * 1024 * 1024;
const int _maximumArchiveEntries = 512;
const int _maximumExpandedBytes = 128 * 1024 * 1024;
const int _maximumEntryBytes = 32 * 1024 * 1024;
const int _maximumCursorDimension = 512;
const int _maximumAniFrames = 512;
const int _maximumFrameDurationMicroseconds = 60 * 1000 * 1000;

class CursorThemeException implements Exception {
  const CursorThemeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Local cursor catalog rooted below XDG data home. Imported material never
/// becomes a Flutter asset and therefore cannot accidentally enter a Denial
/// package or source commit.
class CursorThemeRepository {
  CursorThemeRepository({required String dataHome})
    : _root = Directory(p.join(dataHome, 'denial', 'cursors')) {
    if (!p.isAbsolute(dataHome)) {
      throw const CursorThemeException('XDG data home must be absolute.');
    }
  }

  final Directory _root;

  Future<List<ShellCursorThemeData>> discover() async {
    final imported = <ShellCursorThemeData>[];
    if (!await _root.exists()) {
      return ShellCursorThemes.all;
    }
    await _rejectLink(_root.path, description: 'cursor theme directory');
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is! Directory || p.basename(entity.path).startsWith('.')) {
        continue;
      }
      try {
        imported.add(await _loadManifest(entity));
      } on Object {
        // A broken or interrupted third-party directory must not make the
        // bundled cursor unavailable. Imports are only published after a
        // complete manifest validates, so silently omit invalid remnants.
      }
    }
    imported.sort((first, second) {
      final label = first.label.toLowerCase().compareTo(
        second.label.toLowerCase(),
      );
      return label != 0 ? label : first.id.compareTo(second.id);
    });
    return <ShellCursorThemeData>[...ShellCursorThemes.all, ...imported];
  }

  Future<ShellCursorThemeData> importWindowsCursorZip(
    String archivePath,
  ) async {
    final source = File(archivePath);
    final sourceType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    if (sourceType != FileSystemEntityType.file) {
      throw const CursorThemeException(
        'Choose a regular ZIP file containing a Windows cursor theme.',
      );
    }
    final sourceLength = await source.length();
    if (sourceLength <= 0 || sourceLength > _maximumArchiveBytes) {
      throw const CursorThemeException('The cursor ZIP is empty or too large.');
    }
    final bytes = await source.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    final themeId = 'imported:$digest';
    final destination = Directory(p.join(_root.path, digest));

    if (await destination.exists()) {
      return _loadManifest(destination);
    }

    final archive = _decodeArchive(bytes);
    final files = _validateArchive(archive);
    final infEntry = files.values.where(
      (file) => p.basename(file.name).toLowerCase() == 'install.inf',
    );
    if (infEntry.length != 1) {
      throw const CursorThemeException(
        'The ZIP must contain exactly one Windows install.inf file.',
      );
    }
    final inf = _parseWindowsInf(_archiveBytes(infEntry.single));
    final aniFilesByName = <String, ArchiveFile>{};
    for (final file in files.values) {
      if (!file.name.toLowerCase().endsWith('.ani')) {
        continue;
      }
      final name = p.basename(file.name).toLowerCase();
      if (aniFilesByName.containsKey(name)) {
        throw CursorThemeException('Duplicate animated cursor file: $name');
      }
      aniFilesByName[name] = file;
    }

    final parsedRoles = <ShellCursorKind, WindowsAnimatedCursor>{};
    for (final entry in inf.roleFiles.entries) {
      final file = aniFilesByName[entry.value.toLowerCase()];
      if (file == null) {
        throw CursorThemeException(
          'install.inf references missing cursor ${entry.value}.',
        );
      }
      parsedRoles[entry.key] = parseWindowsAnimatedCursor(_archiveBytes(file));
    }
    if (!parsedRoles.containsKey(ShellCursorKind.normal)) {
      throw const CursorThemeException(
        'The imported theme does not define a normal cursor.',
      );
    }

    await _root.create(recursive: true);
    await _rejectLink(_root.path, description: 'cursor theme directory');
    final temporary = Directory(
      p.join(
        _root.path,
        '.import-$pid-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await temporary.create();
    try {
      final manifestRoles = <String, Object>{};
      for (final entry in parsedRoles.entries) {
        final roleDirectory = Directory(p.join(temporary.path, entry.key.name));
        await roleDirectory.create();
        final cursor = entry.value;
        final imagePaths = <int, String>{};
        for (var index = 0; index < cursor.images.length; index += 1) {
          final relativePath =
              '${entry.key.name}/${index.toString().padLeft(3, '0')}.png';
          final png = await _normalizeCursorImage(cursor.images[index]);
          await File(
            p.join(temporary.path, relativePath),
          ).writeAsBytes(png, flush: true);
          imagePaths[index] = relativePath;
        }
        manifestRoles[entry.key.name] = <String, Object>{
          'size': <String, Object>{
            'width': cursor.size.width,
            'height': cursor.size.height,
          },
          'frames': <Object>[
            for (final step in cursor.steps)
              <String, Object>{
                'path': imagePaths[step.imageIndex]!,
                'durationMicroseconds': step.duration.inMicroseconds,
                'hotspot': <String, Object>{
                  'x': step.hotspot.dx,
                  'y': step.hotspot.dy,
                },
              },
          ],
        };
      }
      final manifest = <String, Object>{
        'version': _cursorManifestVersion,
        'id': themeId,
        'label': inf.label,
        'author': '',
        'sourceFormat': 'windows-ani',
        'sourceArchiveSha256': digest,
        'roles': manifestRoles,
      };
      await File(p.join(temporary.path, 'theme.json')).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
        flush: true,
      );
      try {
        await temporary.rename(destination.path);
      } on FileSystemException {
        if (!await destination.exists()) {
          rethrow;
        }
      }
      return _loadManifest(destination);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
    }
  }

  Future<void> remove(ShellCursorThemeData theme) async {
    final root = theme.fileRoot;
    if (!theme.isImported || root == null) {
      throw const CursorThemeException(
        'Bundled cursor themes cannot be removed.',
      );
    }
    final normalizedRoot = p.normalize(p.absolute(root));
    final normalizedCatalog = p.normalize(p.absolute(_root.path));
    if (!p.isWithin(normalizedCatalog, normalizedRoot) ||
        p.dirname(normalizedRoot) != normalizedCatalog ||
        p.basename(normalizedRoot).startsWith('.')) {
      throw const CursorThemeException(
        'Refusing to remove an invalid theme path.',
      );
    }
    await _rejectLink(normalizedRoot, description: 'imported cursor theme');
    final directory = Directory(normalizedRoot);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Archive _decodeArchive(Uint8List bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes, verify: true);
    } on Object {
      throw const CursorThemeException('The selected file is not a valid ZIP.');
    }
  }

  Map<String, ArchiveFile> _validateArchive(Archive archive) {
    if (archive.length > _maximumArchiveEntries) {
      throw const CursorThemeException(
        'The cursor ZIP contains too many files.',
      );
    }
    var expandedBytes = 0;
    final files = <String, ArchiveFile>{};
    for (final entry in archive.files) {
      final name = entry.name.replaceAll('\\', '/');
      final segments = name.split('/');
      if (name.isEmpty ||
          name.startsWith('/') ||
          name.contains('\u0000') ||
          segments.any((segment) => segment == '..')) {
        throw const CursorThemeException(
          'The cursor ZIP contains an unsafe path.',
        );
      }
      if (entry.isSymbolicLink) {
        throw const CursorThemeException('Cursor ZIP links are not supported.');
      }
      if (!entry.isFile) {
        continue;
      }
      if (entry.size < 0 || entry.size > _maximumEntryBytes) {
        throw const CursorThemeException('A cursor ZIP entry is too large.');
      }
      expandedBytes += entry.size;
      if (expandedBytes > _maximumExpandedBytes) {
        throw const CursorThemeException(
          'The expanded cursor theme is too large.',
        );
      }
      final normalized = p.posix.normalize(name).toLowerCase();
      if (files.containsKey(normalized)) {
        throw CursorThemeException('Duplicate cursor ZIP path: $name');
      }
      files[normalized] = entry;
    }
    return files;
  }

  Future<ShellCursorThemeData> _loadManifest(Directory directory) async {
    await _rejectLink(directory.path, description: 'imported cursor theme');
    final manifestFile = File(p.join(directory.path, 'theme.json'));
    final manifestType = await FileSystemEntity.type(
      manifestFile.path,
      followLinks: false,
    );
    if (manifestType != FileSystemEntityType.file ||
        await manifestFile.length() > 1024 * 1024) {
      throw const CursorThemeException(
        'The cursor manifest is missing or invalid.',
      );
    }
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != _cursorManifestVersion ||
        decoded['roles'] is! Map<String, dynamic>) {
      throw const CursorThemeException('Unsupported cursor manifest.');
    }
    final digest = p.basename(directory.path);
    final expectedId = 'imported:$digest';
    final label = decoded['label'];
    final author = decoded['author'];
    if (decoded['id'] != expectedId ||
        !_isSha256(digest) ||
        label is! String ||
        label.trim().isEmpty ||
        author is! String) {
      throw const CursorThemeException('Invalid cursor theme identity.');
    }
    final roles = <ShellCursorKind, ShellCursorRoleData>{};
    final roleValues = decoded['roles'] as Map<String, dynamic>;
    for (final entry in roleValues.entries) {
      final kind = _cursorKind(entry.key);
      if (kind == null || roles.containsKey(kind) || entry.value is! Map) {
        throw const CursorThemeException('Invalid cursor role in manifest.');
      }
      final role = Map<String, dynamic>.from(entry.value as Map);
      final size = _manifestPoint(role['size']);
      final framesValue = role['frames'];
      if (size == null ||
          size.dx <= 0 ||
          size.dy <= 0 ||
          size.dx > _maximumCursorDimension ||
          size.dy > _maximumCursorDimension ||
          framesValue is! List ||
          framesValue.isEmpty ||
          framesValue.length > _maximumAniFrames) {
        throw const CursorThemeException('Invalid cursor role dimensions.');
      }
      final frames = <ShellCursorFrameData>[];
      for (final value in framesValue) {
        if (value is! Map) {
          throw const CursorThemeException('Invalid cursor frame.');
        }
        final frame = Map<String, dynamic>.from(value);
        final relativePath = frame['path'];
        final duration = frame['durationMicroseconds'];
        final hotspot = _manifestPoint(frame['hotspot']);
        if (relativePath is! String ||
            !_safeRelativePath(relativePath) ||
            duration is! int ||
            duration <= 0 ||
            duration > _maximumFrameDurationMicroseconds ||
            hotspot == null ||
            hotspot.dx < 0 ||
            hotspot.dy < 0 ||
            hotspot.dx >= size.dx ||
            hotspot.dy >= size.dy) {
          throw const CursorThemeException('Invalid cursor frame metadata.');
        }
        final imagePath = p.join(directory.path, relativePath);
        if (!p.isWithin(directory.path, imagePath) ||
            await FileSystemEntity.type(imagePath, followLinks: false) !=
                FileSystemEntityType.file) {
          throw const CursorThemeException('Cursor frame image is missing.');
        }
        frames.add(
          ShellCursorFrameData(
            path: relativePath,
            duration: Duration(microseconds: duration),
            hotspot: hotspot,
          ),
        );
      }
      roles[kind] = ShellCursorRoleData(
        assetDirectory: kind.name,
        size: ui.Size(size.dx, size.dy),
        hotspot: frames.first.hotspot,
        frames: List<ShellCursorFrameData>.unmodifiable(frames),
      );
    }
    if (!roles.containsKey(ShellCursorKind.normal)) {
      throw const CursorThemeException('The cursor theme has no normal role.');
    }
    return ShellCursorThemeData(
      id: expectedId,
      label: label.trim(),
      author: author.trim(),
      assetRoot: null,
      fileRoot: directory.path,
      roles: Map<ShellCursorKind, ShellCursorRoleData>.unmodifiable(roles),
    );
  }
}

@immutable
class WindowsCursorImage {
  const WindowsCursorImage({
    required this.bytes,
    required this.size,
    required this.hotspot,
  });

  final Uint8List bytes;
  final ui.Size size;
  final ui.Offset hotspot;
}

@immutable
class WindowsCursorStep {
  const WindowsCursorStep({
    required this.imageIndex,
    required this.duration,
    required this.hotspot,
  });

  final int imageIndex;
  final Duration duration;
  final ui.Offset hotspot;
}

@immutable
class WindowsAnimatedCursor {
  const WindowsAnimatedCursor({
    required this.images,
    required this.steps,
    required this.size,
  });

  final List<WindowsCursorImage> images;
  final List<WindowsCursorStep> steps;
  final ui.Size size;
}

WindowsAnimatedCursor parseWindowsAnimatedCursor(Uint8List bytes) {
  if (bytes.length < 12 ||
      _ascii(bytes, 0) != 'RIFF' ||
      _ascii(bytes, 8) != 'ACON') {
    throw const CursorThemeException('An ANI file has an invalid RIFF header.');
  }
  final riffLength = _u32(bytes, 4);
  final riffEnd = 8 + riffLength;
  if (riffLength < 4 || riffEnd > bytes.length) {
    throw const CursorThemeException('An ANI RIFF length is invalid.');
  }

  Uint8List? header;
  Uint8List? rates;
  Uint8List? sequence;
  final imageChunks = <Uint8List>[];
  for (final chunk in _riffChunks(bytes, 12, riffEnd)) {
    switch (chunk.id) {
      case 'anih':
        if (header != null) {
          throw const CursorThemeException(
            'An ANI file has duplicate headers.',
          );
        }
        header = chunk.data;
        break;
      case 'rate':
        if (rates != null) {
          throw const CursorThemeException('An ANI file has duplicate rates.');
        }
        rates = chunk.data;
        break;
      case 'seq ':
        if (sequence != null) {
          throw const CursorThemeException(
            'An ANI file has duplicate sequences.',
          );
        }
        sequence = chunk.data;
        break;
      case 'LIST':
        if (chunk.data.length < 4 || _ascii(chunk.data, 0) != 'fram') {
          continue;
        }
        for (final frameChunk in _riffChunks(
          chunk.data,
          4,
          chunk.data.length,
        )) {
          if (frameChunk.id == 'icon') {
            imageChunks.add(frameChunk.data);
          }
        }
        break;
    }
  }
  if (header == null || header.length < 36 || _u32(header, 0) < 36) {
    throw const CursorThemeException('An ANI file has no valid header.');
  }
  final declaredFrames = _u32(header, 4);
  final declaredSteps = _u32(header, 8);
  final defaultJiffies = _u32(header, 28);
  final flags = _u32(header, 32);
  if (flags & 1 == 0 ||
      declaredFrames <= 0 ||
      declaredFrames > _maximumAniFrames ||
      declaredSteps <= 0 ||
      declaredSteps > _maximumAniFrames ||
      imageChunks.length != declaredFrames) {
    throw const CursorThemeException('Unsupported or inconsistent ANI frames.');
  }
  final images = <WindowsCursorImage>[
    for (final chunk in imageChunks) _parseWindowsCursor(chunk),
  ];
  final size = images.first.size;
  if (images.any((image) => image.size != size)) {
    throw const CursorThemeException(
      'All frames in an animated cursor must have one size.',
    );
  }
  final sequenceValues = sequence == null
      ? List<int>.generate(declaredSteps, (index) => index)
      : _u32List(sequence);
  if (sequenceValues.length != declaredSteps ||
      sequenceValues.any((index) => index >= images.length)) {
    throw const CursorThemeException('An ANI sequence is invalid.');
  }
  final rateValues = rates == null ? const <int>[] : _u32List(rates);
  if (rateValues.isNotEmpty && rateValues.length != declaredSteps) {
    throw const CursorThemeException('An ANI rate table is invalid.');
  }
  final steps = <WindowsCursorStep>[];
  for (var index = 0; index < declaredSteps; index += 1) {
    final imageIndex = sequenceValues[index];
    final jiffies = rateValues.isEmpty ? defaultJiffies : rateValues[index];
    if (jiffies <= 0) {
      throw const CursorThemeException('ANI frame durations must be positive.');
    }
    final duration = Duration(
      microseconds: (jiffies * Duration.microsecondsPerSecond / 60).round(),
    );
    if (duration.inMicroseconds > _maximumFrameDurationMicroseconds) {
      throw const CursorThemeException('An ANI frame duration is too long.');
    }
    steps.add(
      WindowsCursorStep(
        imageIndex: imageIndex,
        duration: duration,
        hotspot: images[imageIndex].hotspot,
      ),
    );
  }
  return WindowsAnimatedCursor(
    images: List<WindowsCursorImage>.unmodifiable(images),
    steps: List<WindowsCursorStep>.unmodifiable(steps),
    size: size,
  );
}

WindowsCursorImage _parseWindowsCursor(Uint8List bytes) {
  if (bytes.length < 22 || _u16(bytes, 0) != 0 || _u16(bytes, 2) != 2) {
    throw const CursorThemeException('An ANI frame is not a Windows cursor.');
  }
  final count = _u16(bytes, 4);
  if (count <= 0 || count > 256 || 6 + count * 16 > bytes.length) {
    throw const CursorThemeException('A Windows cursor directory is invalid.');
  }
  var selectedOffset = -1;
  var selectedArea = -1;
  for (var index = 0; index < count; index += 1) {
    final offset = 6 + index * 16;
    final width = bytes[offset] == 0 ? 256 : bytes[offset];
    final height = bytes[offset + 1] == 0 ? 256 : bytes[offset + 1];
    if (width > _maximumCursorDimension || height > _maximumCursorDimension) {
      continue;
    }
    final area = width * height;
    if (area > selectedArea) {
      selectedArea = area;
      selectedOffset = offset;
    }
  }
  if (selectedOffset < 0) {
    throw const CursorThemeException('A Windows cursor image is too large.');
  }
  final width = bytes[selectedOffset] == 0 ? 256 : bytes[selectedOffset];
  final height = bytes[selectedOffset + 1] == 0
      ? 256
      : bytes[selectedOffset + 1];
  final hotspotX = _u16(bytes, selectedOffset + 4);
  final hotspotY = _u16(bytes, selectedOffset + 6);
  final imageLength = _u32(bytes, selectedOffset + 8);
  final imageOffset = _u32(bytes, selectedOffset + 12);
  if (hotspotX >= width ||
      hotspotY >= height ||
      imageLength <= 0 ||
      imageOffset < 6 + count * 16 ||
      imageOffset + imageLength > bytes.length) {
    throw const CursorThemeException(
      'A Windows cursor image entry is invalid.',
    );
  }
  final single = Uint8List(22 + imageLength);
  // Skia decodes ICO but not CUR. The image payload is identical; synthesize
  // a single-image ICO directory for decoding while retaining the CUR hotspot
  // from the original directory entry above.
  single[2] = 1;
  single[4] = 1;
  single.setRange(6, 22, bytes, selectedOffset);
  _setU16(single, 10, 1);
  _setU16(single, 12, _cursorPayloadBitCount(bytes, imageOffset, imageLength));
  _setU32(single, 18, 22);
  single.setRange(22, single.length, bytes, imageOffset);
  return WindowsCursorImage(
    bytes: single,
    size: ui.Size(width.toDouble(), height.toDouble()),
    hotspot: ui.Offset(hotspotX.toDouble(), hotspotY.toDouble()),
  );
}

Future<Uint8List> _normalizeCursorImage(WindowsCursorImage source) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(source.bytes);
    final frame = await codec.getNextFrame();
    image = frame.image;
    if (image.width != source.size.width.round() ||
        image.height != source.size.height.round()) {
      throw const CursorThemeException(
        'A decoded cursor frame has unexpected dimensions.',
      );
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw const CursorThemeException('A cursor frame could not be encoded.');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on CursorThemeException {
    rethrow;
  } on Object {
    throw const CursorThemeException('A cursor frame could not be decoded.');
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

class _WindowsInfTheme {
  const _WindowsInfTheme({required this.label, required this.roleFiles});

  final String label;
  final Map<ShellCursorKind, String> roleFiles;
}

_WindowsInfTheme _parseWindowsInf(Uint8List bytes) {
  final source = utf8.decode(bytes, allowMalformed: true);
  var section = '';
  final strings = <String, String>{};
  for (final rawLine in const LineSplitter().convert(source)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith(';')) {
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.substring(1, line.length - 1).trim().toLowerCase();
      continue;
    }
    if (section != 'strings') {
      continue;
    }
    final equals = line.indexOf('=');
    if (equals <= 0) {
      continue;
    }
    final key = line.substring(0, equals).trim().toLowerCase();
    var value = line.substring(equals + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (strings.containsKey(key)) {
      throw CursorThemeException('Duplicate install.inf value: $key');
    }
    strings[key] = value.trim();
  }
  const variables = <ShellCursorKind, String>{
    ShellCursorKind.normal: 'pointer',
    ShellCursorKind.help: 'help',
    ShellCursorKind.working: 'working',
    ShellCursorKind.busy: 'busy',
    ShellCursorKind.precision: 'precision',
    ShellCursorKind.text: 'text',
    ShellCursorKind.handwriting: 'hand',
    ShellCursorKind.unavailable: 'unavailable',
    ShellCursorKind.verticalResize: 'vert',
    ShellCursorKind.horizontalResize: 'horz',
    ShellCursorKind.diagonalNwSeResize: 'dgn1',
    ShellCursorKind.diagonalNeSwResize: 'dgn2',
    ShellCursorKind.move: 'move',
    ShellCursorKind.alternate: 'alternate',
    ShellCursorKind.link: 'link',
    ShellCursorKind.person: 'person',
    ShellCursorKind.pin: 'pin',
  };
  final roles = <ShellCursorKind, String>{};
  for (final variable in variables.entries) {
    final value = strings[variable.value];
    if (value == null || value.isEmpty) {
      continue;
    }
    final file = p.basename(value.replaceAll('\\', '/'));
    if (!file.toLowerCase().endsWith('.ani')) {
      throw CursorThemeException(
        'install.inf role ${variable.value} is not animated.',
      );
    }
    roles[variable.key] = file;
  }
  final label = strings['scheme_name']?.trim();
  if (label == null || label.isEmpty || roles.isEmpty) {
    throw const CursorThemeException(
      'install.inf does not describe a Windows cursor scheme.',
    );
  }
  return _WindowsInfTheme(
    label: label,
    roleFiles: Map<ShellCursorKind, String>.unmodifiable(roles),
  );
}

class _RiffChunk {
  const _RiffChunk(this.id, this.data);

  final String id;
  final Uint8List data;
}

Iterable<_RiffChunk> _riffChunks(Uint8List bytes, int start, int end) sync* {
  var offset = start;
  while (offset < end) {
    if (offset + 8 > end) {
      throw const CursorThemeException('A RIFF chunk header is truncated.');
    }
    final id = _ascii(bytes, offset);
    final length = _u32(bytes, offset + 4);
    final dataStart = offset + 8;
    final dataEnd = dataStart + length;
    if (dataEnd > end) {
      throw const CursorThemeException('A RIFF chunk is truncated.');
    }
    yield _RiffChunk(id, Uint8List.sublistView(bytes, dataStart, dataEnd));
    offset = dataEnd + (length.isOdd ? 1 : 0);
  }
}

Uint8List _archiveBytes(ArchiveFile file) {
  final content = file.content;
  if (content is Uint8List) {
    return content;
  }
  if (content is List<int>) {
    return Uint8List.fromList(content);
  }
  throw const CursorThemeException('A cursor ZIP entry could not be read.');
}

Future<void> _rejectLink(String path, {required String description}) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw CursorThemeException('The $description must not be a link.');
  }
}

ui.Offset? _manifestPoint(Object? value) {
  if (value is! Map) {
    return null;
  }
  final map = Map<String, dynamic>.from(value);
  final x = map['x'] ?? map['width'];
  final y = map['y'] ?? map['height'];
  if (x is! num || y is! num || !x.isFinite || !y.isFinite) {
    return null;
  }
  return ui.Offset(x.toDouble(), y.toDouble());
}

ShellCursorKind? _cursorKind(String name) {
  for (final kind in ShellCursorKind.values) {
    if (kind.name == name) {
      return kind;
    }
  }
  return null;
}

bool _safeRelativePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.isNotEmpty &&
      !normalized.startsWith('/') &&
      !normalized.contains('\u0000') &&
      !normalized.split('/').any((segment) => segment == '..') &&
      p.posix.normalize(normalized) == normalized;
}

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

String _ascii(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw const CursorThemeException('A binary cursor field is truncated.');
  }
  return String.fromCharCodes(bytes.sublist(offset, offset + 4));
}

int _u16(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 2 > bytes.length) {
    throw const CursorThemeException('A binary cursor field is truncated.');
  }
  return ByteData.sublistView(bytes).getUint16(offset, Endian.little);
}

int _u32(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw const CursorThemeException('A binary cursor field is truncated.');
  }
  return ByteData.sublistView(bytes).getUint32(offset, Endian.little);
}

List<int> _u32List(Uint8List bytes) {
  if (bytes.length % 4 != 0) {
    throw const CursorThemeException('An ANI integer table is truncated.');
  }
  return <int>[
    for (var offset = 0; offset < bytes.length; offset += 4)
      _u32(bytes, offset),
  ];
}

void _setU32(Uint8List bytes, int offset, int value) {
  ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);
}

void _setU16(Uint8List bytes, int offset, int value) {
  ByteData.sublistView(bytes).setUint16(offset, value, Endian.little);
}

int _cursorPayloadBitCount(Uint8List bytes, int offset, int length) {
  const pngSignature = <int>[0x89, 0x50, 0x4e, 0x47];
  if (length >= pngSignature.length &&
      listEquals(
        bytes.sublist(offset, offset + pngSignature.length),
        pngSignature,
      )) {
    return 32;
  }
  if (length >= 16 && _u32(bytes, offset) >= 16) {
    return _u16(bytes, offset + 14).clamp(1, 32);
  }
  return 32;
}
