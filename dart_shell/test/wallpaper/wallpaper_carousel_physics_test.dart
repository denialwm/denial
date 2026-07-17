import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_carousel_physics.dart';

void main() {
  test('keeps adjacent strips eligible for implicit preloading', () {
    expect(
      const WallpaperCarouselPhysics().allowImplicitScrolling,
      isTrue,
    );
  });

  test('a fling carries across multiple strips and then settles', () {
    const physics = WallpaperCarouselPhysics();
    final metrics = _metrics(pixels: 400);

    final simulation = physics.createBallisticSimulation(metrics, 1000);

    expect(simulation, isNotNull);
    expect(simulation!.x(10), closeTo(800, 0.5));
  });

  test('a gentle release settles to the nearest strip', () {
    const physics = WallpaperCarouselPhysics();
    final metrics = _metrics(pixels: 450);

    final simulation = physics.createBallisticSimulation(metrics, 0);

    expect(simulation, isNotNull);
    expect(simulation!.x(10), closeTo(400, 0.5));
  });
}

PageMetrics _metrics({required double pixels}) {
  return PageMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 1800,
    pixels: pixels,
    viewportDimension: 1000,
    viewportFraction: 0.2,
    axisDirection: AxisDirection.right,
    devicePixelRatio: 1,
  );
}
