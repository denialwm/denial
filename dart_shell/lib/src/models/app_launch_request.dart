import 'denial_window.dart';

/// A launcher-owned request waiting for one specific app to create a window.
///
/// Existing object ids are captured when the icon is tapped, so reordering or
/// refreshing an already-open window cannot accidentally satisfy the request.
class AppLaunchRequest {
  AppLaunchRequest({
    required this.requestId,
    required this.appName,
    required this.iconPath,
    required Iterable<String> expectedAppIds,
    required Iterable<int> existingObjectIds,
  }) : expectedAppIds = Set<String>.unmodifiable(
         expectedAppIds
             .map(normalizeAppId)
             .where((identity) => identity.isNotEmpty),
       ),
       existingObjectIds = Set<int>.unmodifiable(existingObjectIds);

  final int requestId;
  final String appName;
  final String? iconPath;
  final Set<String> expectedAppIds;
  final Set<int> existingObjectIds;

  bool matchesNewWindow(DenialWindow window) {
    if (!window.isUserApp || existingObjectIds.contains(window.objectId)) {
      return false;
    }
    return expectedAppIds.contains(normalizeAppId(window.appId));
  }

  static String normalizeAppId(String value) {
    return value.trim().toLowerCase();
  }
}
