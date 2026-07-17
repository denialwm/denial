import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_controller.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper_provider.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_darkness_control.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_selector_surface.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_span_controls.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_target_selector.dart';
import 'package:denial_dart_shell/src/widgets/shade/range_bar.dart';

void main() {
  testWidgets('only the close control dismisses the selector', (tester) async {
    final temporary = Directory(
      '${Directory.systemTemp.path}/denial-wallpaper-widget-'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    addTearDown(() => temporary.deleteSync(recursive: true));
    final controller = WallpaperController(
      sources: const <WallpaperProvider>[],
      store: WallpaperStore(
        RuntimePaths(
          environment: <String, String>{'HOME': temporary.path},
        ),
      ),
    );
    var dismissed = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          wallpaperControllerProvider.overrideWith((ref) => controller),
        ],
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(800, 700)),
            child: WallpaperSelectorOverlay(
              visible: true,
              displayRect: const Rect.fromLTWH(150, 80, 500, 560),
              onDismiss: () => dismissed = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tapAt(const Offset(30, 30));
    await tester.pump();

    expect(dismissed, isFalse);

    await tester.tap(
      find.bySemanticsLabel('Close wallpaper selector'),
    );
    await tester.pump();

    expect(dismissed, isTrue);
  });

  testWidgets('target controls expose All and every monitor', (tester) async {
    WallpaperTarget? selected;
    final outputs = <DisplayOutput>[
      const DisplayOutput(
        monitorId: 0,
        name: 'DP-4',
        logicalRect: Rect.fromLTWH(2560, 0, 2560, 1440),
        pixelSize: Size(2560, 1440),
        scale: 1,
        refreshRate: 180,
      ),
      const DisplayOutput(
        monitorId: 1,
        name: 'DP-5',
        logicalRect: Rect.fromLTWH(0, 0, 2560, 1440),
        pixelSize: Size(2560, 1440),
        scale: 1,
        refreshRate: 200,
      ),
    ];

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: WallpaperTargetSelector(
          outputs: outputs,
          selected: const WallpaperTarget.all(),
          onSelected: (target) => selected = target,
        ),
      ),
    );

    expect(find.text('All'), findsOneWidget);
    expect(find.text('DP-5'), findsOneWidget);
    expect(find.text('DP-4'), findsOneWidget);

    await tester.tap(find.text('DP-4'));
    await tester.pump();

    expect(selected, const WallpaperTarget.output('DP-4'));
  });

  testWidgets('span alignment controls update both axes', (tester) async {
    var alignment = const WallpaperSpanAlignment();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StatefulBuilder(
          builder: (context, setState) => WallpaperSpanAlignmentSelector(
            value: alignment,
            onChanged: (value) => setState(() => alignment = value),
          ),
        ),
      ),
    );

    await tester.tap(
      find.bySemanticsLabel('Align spanning wallpaper right'),
    );
    await tester.pump();
    await tester.tap(
      find.bySemanticsLabel('Align spanning wallpaper bottom'),
    );
    await tester.pump();

    expect(
      alignment,
      const WallpaperSpanAlignment(
        horizontal: WallpaperHorizontalAlignment.right,
        vertical: WallpaperVerticalAlignment.bottom,
      ),
    );
  });

  testWidgets('darkness control previews, commits, and exposes semantics', (
    tester,
  ) async {
    var value = 0.25;
    var committed = -1.0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(800, 600)),
          child: StatefulBuilder(
            builder: (context, setState) => Center(
              child: SizedBox(
                width: 600,
                child: WallpaperDarknessControl(
                  value: value,
                  onChanged: (next) => setState(() => value = next),
                  onChangeEnd: (next) => committed = next,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Wallpaper darkness'), findsOneWidget);
    final trackRect = tester.getRect(find.byType(RangeBar));
    await tester.tapAt(
      Offset(trackRect.left + trackRect.width * 0.75, trackRect.center.dy),
    );
    await tester.pump();

    expect(value, closeTo(0.75, 0.01));
    expect(committed, closeTo(0.75, 0.01));
    expect(find.text('75%'), findsOneWidget);
  });
}
