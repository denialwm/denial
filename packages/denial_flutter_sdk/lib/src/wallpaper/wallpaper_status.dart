import 'package:collection/collection.dart';

class WallpaperStatus {
  const WallpaperStatus.unavailable() : available = false, surfaces = const [];
  const WallpaperStatus({required this.available, required this.surfaces});

  factory WallpaperStatus.fromJson(Map<String, Object?> json) {
    if (json['available'] != true || json['surfaces'] is! List) {
      return const WallpaperStatus.unavailable();
    }
    final surfaces = <({int monitorId, String appId})>[];
    for (final value in json['surfaces']! as List) {
      if (value is! Map ||
          value['monitor_id'] is! int ||
          value['app_id'] is! String) {
        return const WallpaperStatus.unavailable();
      }
      surfaces.add((
        monitorId: value['monitor_id'] as int,
        appId: value['app_id'] as String,
      ));
    }
    return WallpaperStatus(
      available: true,
      surfaces: List.unmodifiable(surfaces),
    );
  }

  static const _surfacesEquality =
      ListEquality<({int monitorId, String appId})>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WallpaperStatus &&
          available == other.available &&
          _surfacesEquality.equals(surfaces, other.surfaces);

  @override
  int get hashCode => Object.hash(available, _surfacesEquality.hash(surfaces));

  final bool available;
  final List<({int monitorId, String appId})> surfaces;

  /// Null means unknown, including while display discovery is still loading.
  List<String>? appsForMonitor(int? monitorId) {
    if (!available || monitorId == null) return null;
    return surfaces
        .where((surface) => surface.monitorId == monitorId)
        .map((surface) => surface.appId)
        .toSet()
        .toList(growable: false);
  }
}
