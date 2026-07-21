import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/desktop/desktop_system_bar.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/state/system_status.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_accent.dart';

void main() {
  testWidgets('cards cluster at the trailing edge over a bare strip', (
    tester,
  ) async {
    await _pumpBar(tester, cpuUsage: 0.23);

    // Transparent canvas: nothing paints a full-strip decoration; only the
    // two module cards are decorated.
    expect(find.text('21:47'), findsOneWidget);
    expect(find.text('Dom 19 Lug'), findsOneWidget);
    expect(find.text('23%'), findsOneWidget);
    final decorated = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .length;
    expect(decorated, 2);

    // The clock card sits at the trailing edge, the CPU card to its left.
    final clockRect = tester.getRect(find.text('21:47'));
    final cpuRect = tester.getRect(find.text('23%'));
    expect(clockRect.right, greaterThan(cpuRect.right));
    expect(clockRect.right, closeTo(1280 - 8 - 12, 1.0));
  });

  testWidgets('cards optically center text over a 90%-opaque fill', (
    tester,
  ) async {
    await _pumpBar(tester, cpuUsage: 0.23);

    final clock = tester.widget<Text>(find.text('21:47'));
    final dateStyle = tester.widget<AnimatedDefaultTextStyle>(
      find.ancestor(
        of: find.text('Dom 19 Lug'),
        matching: find.byType(AnimatedDefaultTextStyle),
      ),
    );
    expect(clock.style?.leadingDistribution, TextLeadingDistribution.even);
    expect(dateStyle.style.leadingDistribution, TextLeadingDistribution.even);

    final cards = tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    for (final card in cards) {
      final decoration = card.decoration! as BoxDecoration;
      final gradient = decoration.gradient! as LinearGradient;
      for (final color in gradient.colors) {
        expect(color.a, closeTo(0.90, 1e-6));
      }
    }
  });

  testWidgets('the CPU card waits for a real sample', (tester) async {
    await _pumpBar(tester, cpuUsage: null);

    expect(find.text('21:47'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('the CPU card hosts the load sparkline', (tester) async {
    await _pumpBar(tester, cpuUsage: 0.23);

    expect(_sparklineFinder, findsOneWidget);
    expect(find.text('CPU'), findsOneWidget);
  });

  testWidgets('every autodetected GPU gets a labelled sparkline card', (
    tester,
  ) async {
    await _pumpBar(
      tester,
      cpuUsage: 0.23,
      gpus: const [
        GpuLoad(
          id: 'card2',
          label: 'AMD',
          series: LoadSeries(current: 0.42, history: [0.3, 0.42]),
        ),
        GpuLoad(
          id: 'nvml0',
          label: 'NV',
          series: LoadSeries(current: 0.87, history: [0.9, 0.87]),
        ),
      ],
    );

    expect(_sparklineFinder, findsNWidgets(3));
    expect(find.text('AMD'), findsOneWidget);
    expect(find.text('NV'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('87%'), findsOneWidget);

    // GPU cards sit left of the CPU card, which sits left of the clock.
    final amdRect = tester.getRect(find.text('AMD'));
    final nvRect = tester.getRect(find.text('NV'));
    final cpuRect = tester.getRect(find.text('CPU'));
    final clockRect = tester.getRect(find.text('21:47'));
    expect(amdRect.right, lessThan(nvRect.left));
    expect(nvRect.right, lessThan(cpuRect.left));
    expect(cpuRect.right, lessThan(clockRect.left));
  });

  testWidgets('CPU and GPU temperatures appear only when sensors report them', (
    tester,
  ) async {
    await _pumpBar(
      tester,
      cpuUsage: 0.23,
      cpuTemperatureC: 54.4,
      gpus: const [
        GpuLoad(
          id: 'card2',
          label: 'AMD',
          series: LoadSeries(
            current: 0.42,
            history: [0.3, 0.42],
            temperatureC: 62.5,
          ),
        ),
        GpuLoad(
          id: 'nvml0',
          label: 'NV',
          series: LoadSeries(current: 0.87, history: [0.9, 0.87]),
        ),
      ],
    );

    expect(find.text('54°C', findRichText: true), findsOneWidget);
    expect(find.text('63°C', findRichText: true), findsOneWidget);
    expect(find.textContaining('°C', findRichText: true), findsNWidgets(2));
  });

  group('sparklinePoints', () {
    const size = Size(44, 14);

    test('is empty without history or space', () {
      expect(sparklinePoints(const [], size), isEmpty);
      expect(sparklinePoints(const [0.5], Size.zero), isEmpty);
    });

    test('right-aligns the newest sample', () {
      final points = sparklinePoints(const [0.25, 0.5], size);
      expect(points, hasLength(2));
      expect(points.last.dx, size.width);
      expect(
        points.first.dx,
        size.width - size.width / (LoadSeries.capacity - 1),
      );
    });

    test('maps load onto the vertical axis and clamps wild values', () {
      final points = sparklinePoints(const [0.0, -1.0, 2.0, 1.0], size);
      expect(points[0].dy, size.height);
      expect(points[1].dy, size.height);
      expect(points[2].dy, 0.0);
      expect(points[3].dy, 0.0);
    });

    test('a full history spans the whole width', () {
      final history = List<double>.filled(LoadSeries.capacity, 0.5);
      final points = sparklinePoints(history, size);
      expect(points.first.dx, closeTo(0.0, 1e-9));
      expect(points.last.dx, size.width);
    });
  });

  group('formatSystemBarDate', () {
    test('is locale aware and compact', () {
      final date = DateTime(2026, 7, 19);
      expect(formatSystemBarDate(date, 'it_IT.UTF-8'), 'Dom 19 Lug');
      expect(formatSystemBarDate(date, 'en_US.UTF-8'), 'Sun 19 Jul');
    });
  });

  testWidgets('preview renders a PNG when DENIAL_BAR_PREVIEW_DIR is set', (
    tester,
  ) async {
    final previewDir = Platform.environment['DENIAL_BAR_PREVIEW_DIR'];
    if (previewDir == null || previewDir.isEmpty) {
      return;
    }

    // Load the real bar font so the preview shows glyphs instead of the
    // test-default block font.
    await tester.runAsync(() async {
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        final bytes = await File(
          'assets/fonts/JetBrainsMono-$weight.ttf',
        ).readAsBytes();
        final loader = FontLoader('JetBrainsMono')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
    });

    final wave = List<double>.generate(
      LoadSeries.capacity,
      (i) =>
          0.18 +
          0.55 * (0.5 + 0.5 * math.sin(i / 4.0)) * (i % 7 == 0 ? 1.0 : 0.6),
    );
    List<double> shifted(double phase, double scale) => [
      for (final value in wave) (value * scale + phase).clamp(0.0, 1.0),
    ];
    await _pumpBar(
      tester,
      cpuUsage: 0.23,
      cpuTemperatureC: 54,
      history: wave,
      gpus: [
        GpuLoad(
          id: 'card2',
          label: 'AMD',
          series: LoadSeries(
            current: 0.42,
            history: shifted(0.25, 0.8),
            temperatureC: 63,
          ),
        ),
        GpuLoad(
          id: 'nvml0',
          label: 'NV',
          series: LoadSeries(
            current: 0.87,
            history: shifted(0.05, 1.2),
            temperatureC: 71,
          ),
        ),
      ],
      withWallpaper: true,
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_previewBoundaryKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('$previewDir/system_bar_preview.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  });
}

const _previewBoundaryKey = Key('system-bar-preview');

final Finder _sparklineFinder = find.byWidgetPredicate(
  (widget) =>
      widget is CustomPaint &&
      '${widget.painter.runtimeType}' == '_SparklinePainter',
);

Future<void> _pumpBar(
  WidgetTester tester, {
  required double? cpuUsage,
  double? cpuTemperatureC,
  List<double>? history,
  List<GpuLoad> gpus = const <GpuLoad>[],
  bool withWallpaper = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 120));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final cpuLoad = cpuUsage == null
      ? LoadSeries.empty
      : LoadSeries(
          current: cpuUsage,
          history: history ?? <double>[0.1, 0.4, 0.2, cpuUsage],
          temperatureC: cpuTemperatureC,
        );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        wallpaperAccentProvider.overrideWithBuild(
          (ref, controller) => const WallpaperAccent(Color(0xff64d8cb)),
        ),
        cpuUsageProvider.overrideWithBuild((ref, controller) => cpuLoad),
        gpuUsageProvider.overrideWithBuild((ref, controller) => gpus),
        clockProvider.overrideWith(
          (ref) => Stream<DateTime>.value(DateTime(2026, 7, 19, 21, 47)),
        ),
        clockLocaleProvider.overrideWithValue('it_IT.UTF-8'),
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: _previewBoundaryKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: withWallpaper
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xff0f2350),
                            Color(0xff3b1f5e),
                            Color(0xffb0326a),
                          ],
                        )
                      : null,
                  color: withWallpaper ? null : const Color(0xff101318),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 32,
                child: DesktopSystemBar(side: SystemBarSide.top),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  // Let the entrance stagger, springs and value tweens settle.
  await tester.pumpAndSettle();
}
