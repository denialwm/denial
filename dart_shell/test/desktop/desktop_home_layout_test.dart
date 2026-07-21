import 'package:denial_dart_shell/src/desktop/desktop_home_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('packed desktop items never overlap and stay inside their output', () {
    const bounds = Rect.fromLTWH(2560, 32, 1920, 1048);
    final frames = DesktopHomeLayout.arrange(
      bounds: bounds,
      items: const <DesktopHomeLayoutItem>[
        DesktopHomeLayoutItem(id: 'clock'),
        DesktopHomeLayoutItem(
          id: 'battery',
          preferredAspectRatio: 2,
        ),
        DesktopHomeLayoutItem(
          id: 'window:1',
          contentAspectRatio: 16 / 9,
        ),
        DesktopHomeLayoutItem(
          id: 'window:2',
          contentAspectRatio: 4 / 3,
        ),
        DesktopHomeLayoutItem(
          id: 'window:3',
          contentAspectRatio: 9 / 16,
        ),
      ],
    );

    expect(frames, hasLength(5));
    final rects = frames.values.toList(growable: false);
    for (var index = 0; index < rects.length; index += 1) {
      final rect = rects[index];
      expect(rect.left, greaterThanOrEqualTo(bounds.left));
      expect(rect.top, greaterThanOrEqualTo(bounds.top));
      expect(rect.right, lessThanOrEqualTo(bounds.right));
      expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      for (var other = index + 1; other < rects.length; other += 1) {
        expect(rect.overlaps(rects[other]), isFalse);
      }
    }
  });

  test('dense desktops repack instead of overlapping or overflowing', () {
    const bounds = Rect.fromLTWH(0, 0, 800, 480);
    final frames = DesktopHomeLayout.arrange(
      bounds: bounds,
      items: <DesktopHomeLayoutItem>[
        for (var index = 0; index < 24; index += 1)
          DesktopHomeLayoutItem(
            id: 'window:$index',
            contentAspectRatio: index.isEven ? 16 / 9 : 4 / 3,
          ),
      ],
    );

    expect(frames, hasLength(24));
    final rects = frames.values.toList(growable: false);
    for (var index = 0; index < rects.length; index += 1) {
      final rect = rects[index];
      expect(rect.right, lessThanOrEqualTo(bounds.right));
      expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      for (var other = index + 1; other < rects.length; other += 1) {
        expect(rect.overlaps(rects[other]), isFalse);
      }
    }
  });

  test('packing rebalances an orphaned final window', () {
    final frames = DesktopHomeLayout.arrange(
      bounds: const Rect.fromLTWH(0, 0, 1920, 1080),
      items: <DesktopHomeLayoutItem>[
        for (var index = 0; index < 6; index += 1)
          DesktopHomeLayoutItem(
            id: 'window:$index',
            contentAspectRatio: 16 / 9,
          ),
      ],
    );

    final rows = <double, int>{};
    for (final frame in frames.values) {
      rows.update(frame.top, (count) => count + 1, ifAbsent: () => 1);
    }
    expect(rows.values, <int>[3, 3]);
  });

  test('window content keeps its native aspect ratio while packed', () {
    const decoratedRatio = 16 / 9;
    const portraitRatio = 9 / 16;
    final frames = DesktopHomeLayout.arrange(
      bounds: const Rect.fromLTWH(0, 0, 1280, 720),
      items: const <DesktopHomeLayoutItem>[
        DesktopHomeLayoutItem(
          id: 'decorated',
          contentAspectRatio: decoratedRatio,
          frameInset: 2,
        ),
        DesktopHomeLayoutItem(
          id: 'client-decorated',
          contentAspectRatio: portraitRatio,
        ),
      ],
    );

    final decoratedContent = frames['decorated']!.deflate(2);
    final clientDecorated = frames['client-decorated']!;
    expect(
      decoratedContent.width / decoratedContent.height,
      closeTo(decoratedRatio, 1e-9),
    );
    expect(
      clientDecorated.width / clientDecorated.height,
      closeTo(portraitRatio, 1e-9),
    );
    expect(frames['decorated']!.overlaps(clientDecorated), isFalse);
  });
}
