import 'denial_window.dart';

/// A launcher-owned transition to one specific application window.
///
/// A new launch captures the existing object ids so a refresh cannot satisfy
/// it accidentally. Activating an existing instance instead records that
/// window explicitly, allowing both paths to use the same visual transition.
class AppLaunchRequest {
  AppLaunchRequest({
    required this.requestId,
    required this.appName,
    required this.iconPath,
    required Iterable<String> expectedAppIds,
    required Iterable<int> existingObjectIds,
    this.targetObjectId,
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
  final int? targetObjectId;

  bool matchesWindow(DenialWindow window) {
    if (!window.isUserApp) {
      return false;
    }
    final target = targetObjectId;
    if (target != null) {
      return window.objectId == target;
    }
    if (existingObjectIds.contains(window.objectId)) {
      return false;
    }
    return expectedAppIds.contains(normalizeAppId(window.appId));
  }

  static String normalizeAppId(String value) {
    return value.trim().toLowerCase();
  }
}
