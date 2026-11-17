import 'package:denial_flutter_sdk/models.dart';

/// Names of the outputs that show a client's own wallpaper, such as a live
/// wallpaper: the shell's wallpaper is never seen there.
///
/// The rule is the compositor's (`is_wallpaper_layer`, which Settings shows
/// as the wallpaper status): a background layer surface, or a bottom layer
/// surface at least as large as its output. A surface counts once it has
/// content, so the shell's wallpaper stays until the client's first frame.
Set<String> desktopOutputsCoveredByBackground(
  Iterable<DenialWindow> layerSurfaces,
  DisplayLayout? displayLayout,
) {
  if (displayLayout == null) {
    return const <String>{};
  }
  Set<String>? covered;
  for (final surface in layerSurfaces) {
    final kind = surface.contentKind;
    if ((kind != DenialWindowContentKind.layerShellBackground &&
            kind != DenialWindowContentKind.layerShellBottom) ||
        surface.isHeld ||
        surface.minimized ||
        surface.opacity <= 0.0 ||
        surface.surfaceLayers.isEmpty) {
      continue;
    }
    for (final output in displayLayout.outputs) {
      if (output.monitorId != surface.monitorId) {
        continue;
      }
      final size = output.logicalRect.size;
      if (kind == DenialWindowContentKind.layerShellBackground ||
          (!size.isEmpty &&
              surface.surfaceWidth >= size.width &&
              surface.surfaceHeight >= size.height)) {
        (covered ??= <String>{}).add(output.name);
      }
    }
  }
  return covered ?? const <String>{};
}
