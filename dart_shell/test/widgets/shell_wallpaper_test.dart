import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper.dart';
import 'package:denial_dart_shell/src/widgets/shell_wallpaper.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('every wallpaper is bounded to its output rectangle', (
    tester,
  ) async {
    const panelWallpaper = WallpaperResource.file('/wallpapers/panel.png');
    final assignment = WallpaperAssignment(
      all: WallpaperResource.defaultWallpaper,
      outputOverrides: const <String, WallpaperResource>{
        'eDP-1': panelWallpaper,
      },
    );

    await tester.pumpWidget(_wallpaperScene(assignment));

    const desktopKey = ValueKey<String>('wallpaper-image-output-DP-4');
    const panelKey = ValueKey<String>('wallpaper-image-output-eDP-1');
    expect(find.byKey(desktopKey), findsOneWidget);
    expect(find.byKey(panelKey), findsOneWidget);
    expect(
      tester.getRect(find.byKey(desktopKey)),
      _stackedOutputs.first.logicalRect,
    );
    expect(
      tester.getRect(find.byKey(panelKey)),
      _stackedOutputs.last.logicalRect,
    );
    expect(
      find.ancestor(
        of: find.byKey(desktopKey),
        matching: find.byType(ClipRect),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(of: find.byKey(panelKey), matching: find.byType(ClipRect)),
      findsNothing,
    );
    expect(assignment.forOutput('DP-4'), WallpaperResource.defaultWallpaper);
    expect(assignment.forOutput('eDP-1'), panelWallpaper);
  });

  testWidgets('All displays paints one bounded copy on every output', (
    tester,
  ) async {
    final assignment = WallpaperAssignment(
      all: WallpaperResource.defaultWallpaper,
    );

    await tester.pumpWidget(_wallpaperScene(assignment));

    expect(
      find.byKey(const ValueKey<String>('wallpaper-image-output-DP-4')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('wallpaper-image-output-eDP-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('wallpaper-image-fallback')),
      findsNothing,
    );
  });

  test('wallpaper reveal clip never crosses the selected output', () {
    const target = Rect.fromLTWH(0, 100, 100, 100);

    final clip = wallpaperRevealClipPath(
      size: const Size(100, 200),
      targetRect: target,
      originFraction: const Offset(0.5, 0.5),
      progress: 0.75,
    );

    expect(clip.getBounds().top, greaterThanOrEqualTo(target.top));
    expect(clip.getBounds().bottom, lessThanOrEqualTo(target.bottom));
    expect(clip.contains(const Offset(50, 98)), isFalse);
    expect(clip.contains(const Offset(50, 202)), isFalse);
  });
}

Widget _wallpaperScene(WallpaperAssignment assignment) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(256, 234)),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 256,
          height: 234,
          child: WallpaperScene(
            assignment: assignment,
            outputs: _stackedOutputs,
            spanRect: const Rect.fromLTWH(0, 0, 256, 234),
            spanPixelSize: const Size(2560, 2340),
          ),
        ),
      ),
    ),
  );
}

const _stackedOutputs = <DisplayOutput>[
  DisplayOutput(
    monitorId: 0,
    name: 'DP-4',
    logicalRect: Rect.fromLTWH(0, 0, 256, 144),
    pixelSize: Size(2560, 1440),
    scale: 1,
    refreshRate: 180,
  ),
  DisplayOutput(
    monitorId: 1,
    name: 'eDP-1',
    logicalRect: Rect.fromLTWH(0, 144, 144, 90),
    pixelSize: Size(1440, 900),
    scale: 1,
    refreshRate: 60,
  ),
];
