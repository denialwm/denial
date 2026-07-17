import '../input/input_layout.dart';
import '../models/hypr_window.dart';

/// Default tablet aspect (width / height) used when neither a window nor the
/// current view has reported a usable size.
const double kPreviewAspect = 16.0 / 10.0;
const double kMinPreviewAspect = 0.35;
const double kMaxPreviewAspect = 3.20;

/// Aspect ratio (width / height) for a window preview. The wide clamp only
/// guards against transient bogus geometry; real portrait and landscape device
/// ratios pass through unchanged.
double windowAspect(
  HyprWindow window, {
  double fallback = kPreviewAspect,
  double min = kMinPreviewAspect,
  double max = kMaxPreviewAspect,
}) {
  final fallbackAspect = fallback.clamp(min, max).toDouble();
  if (window.width <= 0 || window.height <= 0) {
    return fallbackAspect;
  }
  final frameHeight = ShellMetrics.windowFrameTextureHeight(window);
  if (frameHeight <= 0.0) {
    return fallbackAspect;
  }
  return (window.width / frameHeight).clamp(min, max).toDouble();
}
