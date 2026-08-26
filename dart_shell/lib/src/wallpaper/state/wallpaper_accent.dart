import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../../settings/shell_settings.dart';
import '../../state/display_layout.dart';
import '../../state/notifier_lifecycle.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../wallpaper.dart';
import 'wallpaper_controller.dart';

/// Shell theme colors derived from the current wallpaper.
///
/// [color] is a seed carrying the wallpaper's dominant hue and chroma. The
/// active [ShellThemeData] resolves that seed into brightness-safe roles.
@immutable
class WallpaperAccent {
  const WallpaperAccent(this.color, {this.isResolved = true});

  /// The brand accent used until extraction produces a wallpaper color.
  static const WallpaperAccent fallback = WallpaperAccent(
    ShellBrandColors.defaultAccent,
    isResolved: false,
  );

  /// The same brand color after extraction established that the wallpaper has
  /// no useful chroma. This may be published; the temporary fallback may not.
  static const WallpaperAccent resolvedFallback = WallpaperAccent(
    ShellBrandColors.defaultAccent,
  );

  final Color color;
  final bool isResolved;

  /// Card fill for system bar cards. The shell theme supplies the shared
  /// frosted-surface opacity at the point of use.
  Color cardFill(ShellThemeData theme) =>
      Color.lerp(theme.colors.surfaceContainer, theme.accent, 0.15)!;

  /// Top stop of the card gradient: [cardFill] nudged further toward the
  /// accent so pills read as softly lit from above.
  Color cardFillTop(ShellThemeData theme) =>
      Color.lerp(theme.colors.surfaceContainer, theme.accent, 0.24)!;

  /// Secondary text inside system bar cards, tinted toward the accent so
  /// captions re-theme with the wallpaper without losing legibility.
  Color captionColor(ShellThemeData theme) =>
      Color.lerp(theme.colors.textSecondary, theme.accent, 0.35)!;

  @override
  bool operator ==(Object other) =>
      other is WallpaperAccent &&
      other.color == color &&
      other.isResolved == isResolved;

  @override
  int get hashCode => Object.hash(color, isResolved);
}

/// The wallpaper resource whose colors theme the shell chrome. The system
/// bar's output is authoritative because that is where the themed chrome
/// lives; without a display layout the shared wallpaper decides.
final _accentSourceWallpaperProvider = Provider<WallpaperResource>((ref) {
  final assignment = ref.watch(
    wallpaperControllerProvider.select((state) => state.assignment),
  );
  final outputName = ref.watch(
    displayLayoutProvider.select((layout) => layout?.systemBarOutput?.name),
  );
  return outputName == null ? assignment.all : assignment.forOutput(outputName);
});

typedef WallpaperAccentExtractor =
    Future<Color?> Function(WallpaperResource resource);

final wallpaperAccentExtractorProvider = Provider<WallpaperAccentExtractor>(
  (ref) => _extractFromResource,
);

final wallpaperAccentProvider =
    NotifierProvider<WallpaperAccentController, WallpaperAccent>(
      WallpaperAccentController.new,
    );

/// Effective shell accent after applying the user's source preference.
///
/// Wallpaper extraction remains independently cached so toggling between a
/// custom color and the wallpaper never decodes the image again.
final shellAccentProvider = Provider<WallpaperAccent>((ref) {
  final appearance = ref.watch(
    shellSettingsProvider.select((settings) => settings.appearance),
  );
  if (appearance.accentSource == ShellAccentSource.custom) {
    return WallpaperAccent(appearance.customAccentColor);
  }
  return ref.watch(wallpaperAccentProvider);
});

class WallpaperAccentController extends Notifier<WallpaperAccent>
    with NotifierLifecycle<WallpaperAccent> {
  @override
  WallpaperAccent build() {
    _extract = ref.watch(wallpaperAccentExtractorProvider);
    _cache.clear();
    _loadGeneration = 0;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    ref.listen<WallpaperResource>(_accentSourceWallpaperProvider, (
      previous,
      next,
    ) {
      if (isBuildGenerationActive(generation)) {
        unawaited(_load(next, generation));
      }
    }, fireImmediately: true);
    return WallpaperAccent.fallback;
  }

  static const int _maxCacheEntries = 8;

  late WallpaperAccentExtractor _extract;
  final Map<String, WallpaperAccent> _cache = <String, WallpaperAccent>{};
  late int _buildGeneration;
  int _loadGeneration = 0;

  Future<void> load(WallpaperResource resource) =>
      _load(resource, _buildGeneration);

  Future<void> _load(WallpaperResource resource, int buildGeneration) async {
    final key = resource.persistenceValue;
    final cached = _cache[key];
    if (cached != null) {
      state = cached;
      return;
    }
    final generation = ++_loadGeneration;
    Color? color;
    try {
      color = await _extract(resource);
    } on Object {
      color = null;
    }
    if (!isBuildGenerationActive(buildGeneration) ||
        generation != _loadGeneration) {
      return;
    }
    final accent = color == null
        ? WallpaperAccent.resolvedFallback
        : WallpaperAccent(color);
    if (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = accent;
    state = accent;
  }
}

Future<Color?> _extractFromResource(WallpaperResource resource) async {
  final Uint8List encoded;
  switch (resource.kind) {
    case WallpaperResourceKind.asset:
      encoded = (await rootBundle.load(resource.path)).buffer.asUint8List();
    case WallpaperResourceKind.file:
      encoded = await File(resource.path).readAsBytes();
  }
  return extractWallpaperAccent(encoded);
}

/// Decodes [encoded] at thumbnail size and returns its dominant vibrant seed,
/// or null for effectively monochrome images.
Future<Color?> extractWallpaperAccent(Uint8List encoded) async {
  final codec = await ui.instantiateImageCodec(
    encoded,
    targetWidth: 64,
    allowUpscaling: false,
  );
  final ui.Image image;
  try {
    image = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      return null;
    }
    return dominantVibrantColor(data);
  } finally {
    image.dispose();
  }
}

/// Scores 15-degree hue buckets by chroma-weighted frequency over raw RGBA
/// pixels and rebuilds the winning bucket as a canonical seed. The fixed seed
/// tone is not rendered directly; [ShellAccentPalette] chooses suitable role
/// tones for the active brightness. Near-gray and near-black pixels carry no
/// vote; when nothing votes the image has no usable accent.
@visibleForTesting
Color? dominantVibrantColor(ByteData rgba) {
  const bucketCount = 24;
  const bucketDegrees = 360.0 / bucketCount;
  final weights = Float64List(bucketCount);
  final hueSin = Float64List(bucketCount);
  final hueCos = Float64List(bucketCount);
  final saturations = Float64List(bucketCount);

  final pixelCount = rgba.lengthInBytes ~/ 4;
  for (var index = 0; index < pixelCount; index += 1) {
    final offset = index * 4;
    final r = rgba.getUint8(offset) / 255.0;
    final g = rgba.getUint8(offset + 1) / 255.0;
    final b = rgba.getUint8(offset + 2) / 255.0;
    final high = math.max(r, math.max(g, b));
    final low = math.min(r, math.min(g, b));
    final chroma = high - low;
    final saturation = high == 0.0 ? 0.0 : chroma / high;
    if (saturation < 0.15 || high < 0.12) {
      continue;
    }

    var hue = 0.0;
    if (chroma > 0.0) {
      if (high == r) {
        hue = 60.0 * (((g - b) / chroma) % 6.0);
      } else if (high == g) {
        hue = 60.0 * (((b - r) / chroma) + 2.0);
      } else {
        hue = 60.0 * (((r - g) / chroma) + 4.0);
      }
    }
    if (hue < 0.0) {
      hue += 360.0;
    }

    final weight = saturation * saturation * high;
    final bucket = (hue / bucketDegrees).floor() % bucketCount;
    final radians = hue * math.pi / 180.0;
    weights[bucket] += weight;
    hueSin[bucket] += math.sin(radians) * weight;
    hueCos[bucket] += math.cos(radians) * weight;
    saturations[bucket] += saturation * weight;
  }

  var best = 0;
  for (var bucket = 1; bucket < bucketCount; bucket += 1) {
    if (weights[bucket] > weights[best]) {
      best = bucket;
    }
  }
  // A vibrant accent needs a real constituency; a handful of stray colored
  // pixels in a gray image must not theme the whole shell.
  if (pixelCount == 0 || weights[best] < pixelCount * 0.002) {
    return null;
  }

  var hue = math.atan2(hueSin[best], hueCos[best]) * 180.0 / math.pi;
  if (hue < 0.0) {
    hue += 360.0;
  }
  final saturation = (saturations[best] / weights[best])
      // Keep a small quantization margin: HSVColor.toColor() rounds channels,
      // which can otherwise reconstruct just above the canonical 0.75 cap.
      .clamp(0.35, 0.74)
      .toDouble();
  return HSVColor.fromAHSV(1.0, hue, saturation, 0.65).toColor();
}
