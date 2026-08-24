import 'package:denial_dart_shell/src/theme/backdrop_blur_level.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/shell_backdrop_blur.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'uses a full-backdrop, tightly clipped blur at the configured level',
    (tester) async {
      await tester.pumpWidget(
        _BlurHarness(
          theme: const ShellThemeData(
            backdropBlurLevel: ShellBackdropBlurLevel.shitty,
          ),
          child: ShellBackdropBlur(
            borderRadius: BorderRadius.circular(18),
            child: const SizedBox(width: 160, height: 90),
          ),
        ),
      );

      final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(
        filter.filterConfig.toString(),
        'ImageFilterConfig.blur(6.0, 6.0, clamp, unbounded, downsample: 0.25)',
      );
      expect(filter.blendMode, BlendMode.src);
      expect(find.byType(ClipRRect), findsOneWidget);
    },
  );

  testWidgets('disabled blur avoids creating a backdrop filter', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _BlurHarness(
        theme: ShellThemeData(backdropBlurEnabled: false),
        child: ShellBackdropBlur(child: SizedBox(width: 160, height: 90)),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ClipRect), findsNothing);
  });

  testWidgets('known opaque content takes the same zero-cost path', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _BlurHarness(
        theme: ShellThemeData(),
        child: ShellBackdropBlur(
          blur: false,
          child: SizedBox(width: 160, height: 90),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('grouped blur shares the nearest backdrop input', (tester) async {
    await tester.pumpWidget(
      _BlurHarness(
        theme: const ShellThemeData(),
        child: BackdropGroup(
          child: const ShellBackdropBlur(
            grouped: true,
            child: SizedBox(width: 160, height: 90),
          ),
        ),
      ),
    );

    final renderObject = tester.renderObject<RenderBackdropFilter>(
      find.byType(BackdropFilter),
    );
    expect(renderObject.backdropKey, isNotNull);
  });
}

class _BlurHarness extends StatelessWidget {
  const _BlurHarness({required this.theme, required this.child});

  final ShellThemeData theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ShellTheme(
        data: theme,
        child: Center(
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              const ColoredBox(
                color: Color(0xff336699),
                child: SizedBox(width: 240, height: 160),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}
