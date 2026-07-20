import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/display_layout.dart';
import '../../theme/tokens.dart';
import '../wallpaper.dart';
import 'wallpaper_controller.dart';

/// Shell theme colors derived from the current wallpaper.
///
/// The accent is the wallpaper's dominant vibrant hue lifted to a tone that
/// stays legible on the shell's dark surfaces. Surfaces that follow the
/// wallpaper blend the accent into their fill instead of adopting it whole,
/// so a neon wallpaper shifts the mood without destroying contrast.
@immutable
class WallpaperAccent {
  const WallpaperAccent(this.color);

  /// The brand accent used until extraction produces a wallpaper color.
  static const WallpaperAccent fallback = WallpaperAccent(ShellColors.accent);

  final Color color;

  /// Translucent card fill for system bar cards: the dark surface tone tinted
  /// toward the accent, letting the wallpaper glow through.
  Color get cardFill =>
      Color.lerp(_cardBase, color, 0.15)!.withValues(alpha: 0.72);

  /// Top stop of the card gradient: [cardFill] nudged further toward the
  /// accent so pills read as softly lit from above.
  Color get cardFillTop =>
      Color.lerp(_cardBase, color, 0.24)!.withValues(alpha: 0.76);

  /// Secondary text inside system bar cards, tinted toward the accent so
  /// captions re-theme with the wallpaper without losing legibility.
  Color get captionColor => Color.lerp(ShellColors.textSecondary, color, 0.35)!;

  static const Color _cardBase = Color(0xff22262d);

  @override
  bool operator ==(Object other) =>
      other is WallpaperAccent && other.color == color;

  @override
  int get hashCode => color.hashCode;
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

final wallpaperAccentProvider =
    StateNotifierProvider<WallpaperAccentController, WallpaperAccent>((ref) {
  final controller = WallpaperAccentController();
  ref.listen<WallpaperResource>(
    _accentSourceWallpaperProvider,
    (previous, next) => unawaited(controller.load(next)),
    fireImmediately: true,
  );
  return controller;
});

class WallpaperAccentController extends StateNotifier<WallpaperAccent> {
  WallpaperAccentController({
    Future<Color?> Function(WallpaperResource resource)? extract,
  })  : _extract = extract ?? _extractFromResource,
        super(WallpaperAccent.fallback);

  /// A frozen accent that never extracts, for widget tests and previews.
  @visibleForTesting
  WallpaperAccentController.preview(WallpaperAccent accent)
      : _extract = _extractFromResource,
        super(accent);

  static const int _maxCacheEntries = 8;

  final Future<Color?> Function(WallpaperResource resource) _extract;
  final Map<String, WallpaperAccent> _cache = <String, WallpaperAccent>{};
  int _generation = 0;

  Future<void> load(WallpaperResource resource) async {
    final key = resource.persistenceValue;
    final cached = _cache[key];
    if (cached != null) {
      state = cached;
      return;
    }
    final generation = ++_generation;
    Color? color;
    try {
      color = await _extract(resource);
    } on Object {
      color = null;
    }
    if (!mounted || generation != _generation) {
      return;
    }
    final accent =
        color == null ? WallpaperAccent.fallback : WallpaperAccent(color);
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

/// Decodes [encoded] at thumbnail size and returns its dominant vibrant hue
/// as a dark-theme-legible color, or null for effectively monochrome images.
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
/// pixels and rebuilds the winning bucket's mean color at a tone that reads
/// on dark shell surfaces. Near-gray, near-black and near-white pixels carry
/// no vote; when nothing votes the image has no usable accent.
@visibleForTesting
Color? dominantVibrantColor(ByteData rgba) {
  const bucketCount = 24;
  const bucketDegrees = 360.0 / bucketCount;
  final weights = Float64List(bucketCount);
  final hueSin = Float64List(bucketCount);
  final hueCos = Float64List(bucketCount);
  final saturations = Float64List(bucketCount);
  final values = Float64List(bucketCount);

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
    values[bucket] += high * weight;
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

  var hue =
      math.atan2(hueSin[best], hueCos[best]) * 180.0 / math.pi;
  if (hue < 0.0) {
    hue += 360.0;
  }
  final saturation =
      (saturations[best] / weights[best]).clamp(0.35, 0.75).toDouble();
  final value = (values[best] / weights[best]).clamp(0.70, 0.95).toDouble();
  return HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();
}
