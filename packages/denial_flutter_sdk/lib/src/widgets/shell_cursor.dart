import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/cursor_themes.dart';
import '../models/display_layout.dart';
import '../diagnostics/cursor_benchmark.dart';

/// Cursor intents for Flutter-owned shell regions.
///
/// Sessions report a semantic shape to the compositor.
abstract final class ShellMouseCursors {
  static const MouseCursor normal = _ShellMouseCursor(ShellCursorKind.normal);
  static const MouseCursor help = _ShellMouseCursor(ShellCursorKind.help);
  static const MouseCursor working = _ShellMouseCursor(ShellCursorKind.working);
  static const MouseCursor text = _ShellMouseCursor(ShellCursorKind.text);
  static const MouseCursor link = _ShellMouseCursor(ShellCursorKind.link);
  static const MouseCursor busy = _ShellMouseCursor(ShellCursorKind.busy);
  static const MouseCursor precision = _ShellMouseCursor(
    ShellCursorKind.precision,
  );
  static const MouseCursor handwriting = _ShellMouseCursor(
    ShellCursorKind.handwriting,
  );
  static const MouseCursor unavailable = _ShellMouseCursor(
    ShellCursorKind.unavailable,
  );
  static const MouseCursor verticalResize = _ShellMouseCursor(
    ShellCursorKind.verticalResize,
  );
  static const MouseCursor horizontalResize = _ShellMouseCursor(
    ShellCursorKind.horizontalResize,
  );
  static const MouseCursor diagonalNwSeResize = _ShellMouseCursor(
    ShellCursorKind.diagonalNwSeResize,
  );
  static const MouseCursor diagonalNeSwResize = _ShellMouseCursor(
    ShellCursorKind.diagonalNeSwResize,
  );
  static const MouseCursor move = _ShellMouseCursor(ShellCursorKind.move);
  static const MouseCursor alternate = _ShellMouseCursor(
    ShellCursorKind.alternate,
  );
  static const MouseCursor person = _ShellMouseCursor(ShellCursorKind.person);
  static const MouseCursor pin = _ShellMouseCursor(ShellCursorKind.pin);
}

/// Declares the cursor's place in shell paint order. Native code supplies
/// the texture and owns its pixels, placement, damage and animation clock.
class StagecraftCursor extends StatefulWidget {
  const StagecraftCursor({
    super.key,
    required this.child,
    required this.theme,
    required this.size,
    required this.hidden,
    this.layout,
    this.benchmarkSocket,
  });

  final Widget child;
  final ShellCursorThemeData theme;
  final double size;
  final bool hidden;
  final DisplayLayout? layout;
  final String? benchmarkSocket;

  @override
  State<StagecraftCursor> createState() => _StagecraftCursorState();
}

class _StagecraftCursorState extends State<StagecraftCursor> {
  static const _channel = BasicMessageChannel<String>(
    'denial/cursor_theme',
    StringCodec(),
  );
  static const _textureId = 0x6000000000000000;
  Size? _canvas;
  CursorBenchmark? _benchmark;

  @override
  void initState() {
    super.initState();
    final path = widget.benchmarkSocket;
    if (path == null || path.isEmpty) return;
    final benchmark = CursorBenchmark(layout: () => widget.layout);
    _benchmark = benchmark;
    unawaited(
      benchmark.listen(path).catchError((Object error) {
        debugPrint('Cursor benchmark unavailable: $error');
      }),
    );
  }

  @override
  void dispose() {
    _benchmark?.dispose();
    super.dispose();
  }

  void _configure() {
    final canvas = _canvas;
    if (canvas == null || canvas.isEmpty) return;
    _benchmark?.cancel('scene_configuration_changed');
    final theme = widget.theme;
    final roles = <String, Object>{};
    for (final kind in ShellCursorKind.values) {
      final role = theme.roleFor(kind);
      roles[kind.name] = [
        for (final rendition in [null, ...role.renditions])
          {
            'extent': rendition?.extent.toDouble() ?? role.nativeExtent,
            'frames': [
              for (var i = 0; i < role.effectiveFrameCount; ++i)
                {
                  'path': role.relativeFramePath(i, rendition),
                  'hotspot': [
                    (rendition?.hotspot ?? role.hotspotAt(i)).dx,
                    (rendition?.hotspot ?? role.hotspotAt(i)).dy,
                  ],
                  'delay': role.frameDurationAt(i).inMicroseconds,
                },
            ],
          },
      ];
    }
    unawaited(
      _channel.send(
        jsonEncode({
          'root': theme.fileRoot ?? theme.assetRoot,
          'roles': roles,
          'size': widget.size,
          'hidden': widget.hidden,
          'canvas': [canvas.width, canvas.height],
        }),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant StagecraftCursor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.theme != widget.theme ||
        oldWidget.size != widget.size ||
        oldWidget.hidden != widget.hidden) {
      _configure();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_canvas != constraints.biggest) {
        _canvas = constraints.biggest;
        _configure();
      }
      return MouseRegion(
        opaque: false,
        cursor: ShellMouseCursors.normal,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            const IgnorePointer(
              child: ExcludeSemantics(
                child: Texture(
                  textureId: _textureId,
                  filterQuality: FilterQuality.low,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _ShellMouseCursor extends MouseCursor {
  const _ShellMouseCursor(this.kind);

  final ShellCursorKind kind;

  @override
  MouseCursorSession createSession(int device) =>
      _ShellMouseCursorSession(this, device);

  @override
  String get debugDescription => 'Flutter shell ${kind.name} cursor';
}

class _ShellMouseCursorSession extends MouseCursorSession {
  _ShellMouseCursorSession(_ShellMouseCursor super.cursor, super.device);

  @override
  _ShellMouseCursor get cursor => super.cursor as _ShellMouseCursor;

  @override
  Future<void> activate() {
    return SystemChannels.mouseCursor.invokeMethod<void>(
      'activateSystemCursor',
      <String, dynamic>{
        'device': device,
        'kind': _flutterCursorKind(cursor.kind),
      },
    );
  }

  @override
  void dispose() {}
}

String _flutterCursorKind(ShellCursorKind kind) {
  return switch (kind) {
    ShellCursorKind.normal => 'basic',
    ShellCursorKind.help => 'help',
    ShellCursorKind.working => 'progress',
    ShellCursorKind.text => 'text',
    ShellCursorKind.link => 'click',
    ShellCursorKind.busy => 'wait',
    ShellCursorKind.precision => 'precise',
    ShellCursorKind.handwriting => 'handwriting',
    ShellCursorKind.unavailable => 'forbidden',
    ShellCursorKind.verticalResize => 'resizeUpDown',
    ShellCursorKind.horizontalResize => 'resizeLeftRight',
    ShellCursorKind.diagonalNwSeResize => 'resizeUpLeftDownRight',
    ShellCursorKind.diagonalNeSwResize => 'resizeUpRightDownLeft',
    ShellCursorKind.move => 'move',
    ShellCursorKind.alternate => 'alias',
    ShellCursorKind.person => 'person',
    ShellCursorKind.pin => 'pin',
  };
}
