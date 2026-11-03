import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:test/test.dart';

void main() {
  test('legacy shared opacity seeds three independent settings', () {
    final legacy = ShellGlassConfiguration.fromJson({'opacity': .4});
    expect(legacy.opacity, .4);
    expect(legacy.windowOpacity, .4);
    expect(legacy.appPanelOpacity, .4);

    final shellChanged = legacy.copyWith(opacity: .7);
    expect(shellChanged.windowOpacity, .4);
    expect(shellChanged.appPanelOpacity, .4);
    final windowChanged = shellChanged.copyWith(windowOpacity: .2);
    expect(windowChanged.opacity, .7);
    expect(windowChanged.appPanelOpacity, .4);
    final appChanged = windowChanged.copyWith(appPanelOpacity: .6);
    expect(appChanged.opacity, .7);
    expect(appChanged.windowOpacity, .2);
    expect(appChanged.appPanelOpacity, .6);
    expect(ShellGlassConfiguration.fromJson(appChanged.toJson()), appChanged);
  });

  test(
    'two-slider settings migrate app panels from their previous shell value',
    () {
      final migrated = ShellGlassConfiguration.fromJson({
        'opacity': .25,
        'windowOpacity': .8,
      });
      expect(migrated.appPanelOpacity, .25);
      final saved = migrated.copyWith(appPanelOpacity: .55).toJson();
      saved['opacity'] = .9;
      saved['windowOpacity'] = .1;
      final restored = ShellGlassConfiguration.fromJson(saved);
      expect(restored.appPanelOpacity, .55);
      expect(restored.opacity, .9);
      expect(restored.windowOpacity, .1);
    },
  );

  test('new and malformed values remain finite, bounded and independent', () {
    final parsed = ShellGlassConfiguration.fromJson({
      'opacity': .4,
      'windowOpacity': 2,
      'appPanelOpacity': -1,
    });
    expect(parsed.opacity, .4);
    expect(parsed.windowOpacity, 1);
    expect(parsed.appPanelOpacity, 0);
    for (final invalid in [null, 'bad', double.nan, double.infinity]) {
      final result = ShellGlassConfiguration.fromJson({
        'opacity': .4,
        'windowOpacity': invalid,
        'appPanelOpacity': invalid,
      });
      expect(result.windowOpacity, .4);
      expect(result.appPanelOpacity, .4);
    }
    expect(
      ShellGlassConfiguration.fromJson({'windowOpacity': -1}).windowOpacity,
      0,
    );
    expect(
      ShellGlassConfiguration.fromJson({'appPanelOpacity': 2}).appPanelOpacity,
      1,
    );
    const defaults = ShellGlassConfiguration(
      opacity: .3,
      windowOpacity: .8,
      appPanelOpacity: .6,
    );
    expect(ShellGlassConfiguration.fromJson(null, defaults), defaults);
    expect(ShellGlassConfiguration.fromJson({}, defaults), defaults);
  });

  test('the phone app-panel floor follows the appearance, not the value', () {
    const dark = ShellGlassConfiguration(appPanelOpacity: .1);
    expect(dark.mobileAppPanelFloor, .30);
    final light = dark.copyWith(appearance: ShellGlassAppearance.light);
    expect(light.mobileAppPanelFloor, .50);
    expect(light.appPanelOpacity, .1);
  });

  test('theme transitions interpolate all three values independently', () {
    const first = ShellGlassConfiguration(
      opacity: .2,
      windowOpacity: .8,
      appPanelOpacity: .1,
    );
    const last = ShellGlassConfiguration(
      opacity: .6,
      windowOpacity: .4,
      appPanelOpacity: .3,
    );
    final middle = ShellGlassConfiguration.lerp(first, last, .5);
    expect(middle.opacity, closeTo(.4, 1e-12));
    expect(middle.windowOpacity, closeTo(.6, 1e-12));
    expect(middle.appPanelOpacity, closeTo(.2, 1e-12));
    expect(middle.blurSigma, first.blurSigma);
  });

  test('app panel changes participate in equality and collection identity', () {
    const first = ShellGlassConfiguration(appPanelOpacity: .2);
    final changed = first.copyWith(appPanelOpacity: .8);
    final restored = ShellGlassConfiguration.fromJson(first.toJson());
    expect(first, isNot(changed));
    expect({first, changed, restored}, hasLength(2));
    expect(restored.hashCode, first.hashCode);
  });
}
