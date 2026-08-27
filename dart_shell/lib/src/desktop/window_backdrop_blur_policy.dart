import '../models/denial_window.dart';

bool desktopWindowNeedsBackdropTexture({
  required DenialWindow window,
  required double shellOpacity,
  bool localContentTranslucent = false,
}) {
  if (shellOpacity <= 0.0) {
    return false;
  }

  if (window.isLocalFlutter) {
    return localContentTranslucent || shellOpacity < 1.0;
  }
  return !window.isOpaque || shellOpacity < 1.0;
}
