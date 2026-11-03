import 'package:denial_flutter_sdk/src/wallpaper/wallpaper_status.dart';
import 'package:test/test.dart';

void main() {
  WallpaperStatus reply({
    bool available = true,
    int monitor = 1,
    String app = 'wallpaper',
  }) => WallpaperStatus.fromJson({
    'available': available,
    'surfaces': [
      {'monitor_id': monitor, 'app_id': app},
    ],
  });

  test(
    'unchanged poll replies compare equal despite fresh JSON collections',
    () {
      final first = reply();
      final next = reply();
      expect(identical(first, next), isFalse);
      expect(identical(first.surfaces, next.surfaces), isFalse);
      expect(next, first);
      expect(next.hashCode, first.hashCode);
      expect({first, next}, hasLength(1));
    },
  );

  test(
    'availability, output, application and surface changes remain observable',
    () {
      final first = reply();
      expect(reply(available: false), isNot(first));
      expect(reply(monitor: 2), isNot(first));
      expect(reply(app: 'other'), isNot(first));
      expect(
        const WallpaperStatus(available: true, surfaces: []),
        isNot(first),
      );
      expect(
        WallpaperStatus(
          available: true,
          surfaces: [...first.surfaces, (monitorId: 2, appId: 'other')],
        ),
        isNot(first),
      );
    },
  );

  test('unknown, known empty and restored wallpaper states stay distinct', () {
    const unknown = WallpaperStatus.unavailable();
    const empty = WallpaperStatus(available: true, surfaces: []);
    final active = reply();
    expect({unknown, empty, active}, hasLength(3));
    expect(unknown.appsForMonitor(1), isNull);
    expect(empty.appsForMonitor(1), isEmpty);
    expect(active.appsForMonitor(1), ['wallpaper']);
    expect(reply(available: false), unknown);
  });
}
