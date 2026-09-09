import 'package:denial_dart_shell/src/theme/glass_configuration.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/retained_translation.dart';
import 'package:denial_dart_shell/src/widgets/shade/shade_backdrop_scene.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'blur uses one retained screen-space filter for moving surfaces',
    (tester) async {
      final progress = AnimationController(vsync: tester, value: 1);
      addTearDown(progress.dispose);
      Widget view(ShellTransparencyMode mode) => Directionality(
        textDirection: TextDirection.ltr,
        child: ShellTheme(
          data: ShellThemeData(transparencyMode: mode),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 800,
              child: ShadeBackdropScene(
                progress: progress,
                child: Stack(
                  children: [
                    for (final top in [0.0, 210.0])
                      Positioned(
                        top: top,
                        width: 400,
                        height: 200,
                        child: RetainedTranslation(
                          translation: progress.drive(
                            Tween(
                              begin: const Offset(0, -200),
                              end: Offset.zero,
                            ),
                          ),
                          child: const ShadeBackdropRegion(
                            borderRadius: BorderRadius.all(Radius.circular(24)),
                            child: ColoredBox(color: Color(0x2bffffff)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(view(ShellTransparencyMode.blur));
      final first = tester.layers.whereType<BackdropFilterLayer>().single;
      final mask = tester.layers.whereType<ClipPathLayer>().single.clipPath!;
      expect(mask.contains(const Offset(100, 100)), isTrue);
      expect(mask.contains(const Offset(100, 205)), isFalse);
      expect(mask.contains(const Offset(100, 220)), isTrue);
      for (final value in [0.8, 0.5, 0.1, 1.0]) {
        progress.value = value;
        await tester.pump();
        expect(
          tester.layers.whereType<BackdropFilterLayer>().single,
          same(first),
        );
      }
      await tester.pumpWidget(view(ShellTransparencyMode.glass));
      expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('glass transparency applies equally to panel and card surfaces', () {
    for (final opacity in [0.0, 0.17, 0.5, 1.0]) {
      final theme = ShellThemeData(
        transparencyMode: ShellTransparencyMode.glass,
        panelOpacity: 0.9,
        cardOpacity: 0.8,
        glass: ShellGlassConfiguration(opacity: opacity),
      );
      expect(theme.panelColor(const Color(0xff123456)).a, opacity);
      expect(theme.cardColor(const Color(0xffabcdef)).a, opacity);
      expect(
        theme
            .panelGradient(const Color(0xff123456), const Color(0xffabcdef))
            .colors
            .every((color) => color.a == opacity),
        isTrue,
      );
      expect(
        theme
            .cardGradient(const Color(0xff123456), const Color(0xffabcdef))
            .colors
            .every((color) => color.a == opacity),
        isTrue,
      );
    }
  });

  test('glass backing follows dark and light appearance at shared opacity', () {
    const glass = ShellThemeData(transparencyMode: ShellTransparencyMode.glass);
    final color = glass.panelColor(const Color(0xff123456));
    expect(color.a, closeTo(0.17, 0.0001));
    expect((color.r, color.g, color.b), (0.0, 0.0, 0.0));
    final light = glass.copyWith(
      glass: const ShellGlassConfiguration(
        appearance: ShellGlassAppearance.light,
      ),
    );
    final lightColor = light.panelColor(const Color(0xff123456));
    expect(lightColor.a, color.a);
    expect((lightColor.r, lightColor.g, lightColor.b), (1.0, 1.0, 1.0));
    expect(glass.cardColor(const Color(0xff123456)), color);
    expect(light.cardColor(const Color(0xff123456)), lightColor);
    const blur = ShellThemeData(transparencyMode: ShellTransparencyMode.blur);
    final unchanged = blur.panelColor(const Color(0xff123456));
    expect(unchanged.r, closeTo(0x12 / 255, 0.0001));
    expect(unchanged.a, blur.effectivePanelOpacity);
  });
}
