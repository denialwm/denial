import '../models/denial_window.dart';

bool desktopWindowBackdropBlurEnabled({
  required DenialWindow window,
  required double shellOpacity,
  required double opacityThreshold,
  bool forceBackdropBlur = false,
  bool localContentTranslucent = false,
}) {
  final effectiveOpacity = (shellOpacity * window.opacity).clamp(0.0, 1.0);
  final threshold = opacityThreshold.clamp(0.0, 1.0);
  if (effectiveOpacity <= 0.0 || effectiveOpacity < threshold) {
    return false;
  }

  return forceBackdropBlur ||
      localContentTranslucent ||
      (!window.isLocalFlutter && window.isContentTranslucent) ||
      shellOpacity < 1.0;
}
