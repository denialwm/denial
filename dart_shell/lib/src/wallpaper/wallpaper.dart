import 'dart:ui';

import 'package:flutter/foundation.dart';

const String defaultShellWallpaperAsset =
    'assets/wallpapers/wallhaven-28ylpg.jpg';

enum WallpaperResourceKind { asset, file }

@immutable
class WallpaperResource {
  const WallpaperResource.asset(this.path) : kind = WallpaperResourceKind.asset;

  const WallpaperResource.file(this.path) : kind = WallpaperResourceKind.file;

  final WallpaperResourceKind kind;
  final String path;

  static const WallpaperResource defaultWallpaper =
      WallpaperResource.asset(defaultShellWallpaperAsset);

  String get persistenceValue => switch (kind) {
        WallpaperResourceKind.asset => 'asset:$path',
        WallpaperResourceKind.file => 'file:$path',
      };

  static WallpaperResource? fromPersistenceValue(String value) {
    if (value.startsWith('asset:')) {
      final path = value.substring('asset:'.length);
      return path.isEmpty ? null : WallpaperResource.asset(path);
    }
    if (value.startsWith('file:')) {
      final path = value.substring('file:'.length);
      return path.isEmpty ? null : WallpaperResource.file(path);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is WallpaperResource && other.kind == kind && other.path == path;

  @override
  int get hashCode => Object.hash(kind, path);
}

@immutable
class WallpaperTarget {
  const WallpaperTarget.all() : outputName = null;

  const WallpaperTarget.output(String outputName)
      : assert(outputName != ''),
        outputName = outputName;

  final String? outputName;

  bool get isAll => outputName == null;

  @override
  bool operator ==(Object other) =>
      other is WallpaperTarget && other.outputName == outputName;

  @override
  int get hashCode => outputName.hashCode;
}

enum WallpaperHorizontalAlignment { left, center, right }

enum WallpaperVerticalAlignment { top, center, bottom }

@immutable
class WallpaperSpanAlignment {
  const WallpaperSpanAlignment({
    this.horizontal = WallpaperHorizontalAlignment.center,
    this.vertical = WallpaperVerticalAlignment.center,
  });

  final WallpaperHorizontalAlignment horizontal;
  final WallpaperVerticalAlignment vertical;

  double get x => switch (horizontal) {
        WallpaperHorizontalAlignment.left => -1.0,
        WallpaperHorizontalAlignment.center => 0.0,
        WallpaperHorizontalAlignment.right => 1.0,
      };

  double get y => switch (vertical) {
        WallpaperVerticalAlignment.top => -1.0,
        WallpaperVerticalAlignment.center => 0.0,
        WallpaperVerticalAlignment.bottom => 1.0,
      };

  WallpaperSpanAlignment copyWith({
    WallpaperHorizontalAlignment? horizontal,
    WallpaperVerticalAlignment? vertical,
  }) {
    return WallpaperSpanAlignment(
      horizontal: horizontal ?? this.horizontal,
      vertical: vertical ?? this.vertical,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is WallpaperSpanAlignment &&
        other.horizontal == horizontal &&
        other.vertical == vertical;
  }

  @override
  int get hashCode => Object.hash(horizontal, vertical);
}

@immutable
class WallpaperAssignment {
  WallpaperAssignment({
    required this.all,
    this.spanAlignment = const WallpaperSpanAlignment(),
    this.allDarkness = 0.0,
    Map<String, WallpaperResource> outputOverrides =
        const <String, WallpaperResource>{},
    Map<String, double> outputDarknessOverrides = const <String, double>{},
  })  : assert(allDarkness >= 0.0 && allDarkness <= 1.0),
        assert(
          outputDarknessOverrides.values.every(
            (value) => value.isFinite && value >= 0.0 && value <= 1.0,
          ),
        ),
        outputOverrides = Map<String, WallpaperResource>.unmodifiable(
          outputOverrides,
        ),
        outputDarknessOverrides = Map<String, double>.unmodifiable(
          outputDarknessOverrides,
        );

  factory WallpaperAssignment.initial() {
    return WallpaperAssignment(all: WallpaperResource.defaultWallpaper);
  }

  final WallpaperResource all;
  final WallpaperSpanAlignment spanAlignment;
  final double allDarkness;
  final Map<String, WallpaperResource> outputOverrides;
  final Map<String, double> outputDarknessOverrides;

  WallpaperResource forOutput(String outputName) {
    return outputOverrides[outputName] ?? all;
  }

  WallpaperResource forTarget(WallpaperTarget target) {
    final outputName = target.outputName;
    return outputName == null ? all : forOutput(outputName);
  }

  double darknessForOutput(String outputName) {
    return outputDarknessOverrides[outputName] ?? allDarkness;
  }

  double darknessForTarget(WallpaperTarget target) {
    final outputName = target.outputName;
    return outputName == null ? allDarkness : darknessForOutput(outputName);
  }

  WallpaperAssignment apply(
    WallpaperTarget target,
    WallpaperResource resource,
  ) {
    final outputName = target.outputName;
    if (outputName == null) {
      return WallpaperAssignment(
        all: resource,
        spanAlignment: spanAlignment,
        allDarkness: allDarkness,
        outputDarknessOverrides: outputDarknessOverrides,
      );
    }
    final updated = Map<String, WallpaperResource>.of(outputOverrides);
    if (resource == all) {
      updated.remove(outputName);
    } else {
      updated[outputName] = resource;
    }
    return WallpaperAssignment(
      all: all,
      spanAlignment: spanAlignment,
      allDarkness: allDarkness,
      outputOverrides: updated,
      outputDarknessOverrides: outputDarknessOverrides,
    );
  }

  WallpaperAssignment withSpanAlignment(WallpaperSpanAlignment alignment) {
    return WallpaperAssignment(
      all: all,
      spanAlignment: alignment,
      allDarkness: allDarkness,
      outputOverrides: outputOverrides,
      outputDarknessOverrides: outputDarknessOverrides,
    );
  }

  WallpaperAssignment withDarkness(
    WallpaperTarget target,
    double darkness,
  ) {
    final safeDarkness =
        darkness.isFinite ? darkness.clamp(0.0, 1.0).toDouble() : 0.0;
    final outputName = target.outputName;
    if (outputName == null) {
      return WallpaperAssignment(
        all: all,
        spanAlignment: spanAlignment,
        allDarkness: safeDarkness,
        outputOverrides: outputOverrides,
      );
    }

    final updated = Map<String, double>.of(outputDarknessOverrides);
    if (safeDarkness == allDarkness) {
      updated.remove(outputName);
    } else {
      updated[outputName] = safeDarkness;
    }
    return WallpaperAssignment(
      all: all,
      spanAlignment: spanAlignment,
      allDarkness: allDarkness,
      outputOverrides: outputOverrides,
      outputDarknessOverrides: updated,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is WallpaperAssignment &&
        other.all == all &&
        other.spanAlignment == spanAlignment &&
        other.allDarkness == allDarkness &&
        mapEquals(other.outputOverrides, outputOverrides) &&
        mapEquals(
          other.outputDarknessOverrides,
          outputDarknessOverrides,
        );
  }

  @override
  int get hashCode {
    final orderedEntries = outputOverrides.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    final orderedDarknessEntries = outputDarknessOverrides.entries
        .toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    return Object.hash(
      all,
      spanAlignment,
      allDarkness,
      Object.hashAll(
        orderedEntries.map((entry) => Object.hash(entry.key, entry.value)),
      ),
      Object.hashAll(
        orderedDarknessEntries.map(
          (entry) => Object.hash(entry.key, entry.value),
        ),
      ),
    );
  }
}

@immutable
class WallpaperCandidate {
  const WallpaperCandidate({
    required this.id,
    required this.providerId,
    required this.label,
    required this.previewUri,
    required this.width,
    required this.height,
    this.resource,
    this.downloadUri,
    this.sourceUri,
  });

  final String id;
  final String providerId;
  final String label;
  final Uri previewUri;
  final int width;
  final int height;
  final WallpaperResource? resource;
  final Uri? downloadUri;
  final Uri? sourceUri;

  double get aspectRatio => height > 0 ? width / height : 1.0;

  String get key => '$providerId:$id';

  WallpaperCandidate copyWith({WallpaperResource? resource}) {
    return WallpaperCandidate(
      id: id,
      providerId: providerId,
      label: label,
      previewUri: previewUri,
      width: width,
      height: height,
      resource: resource ?? this.resource,
      downloadUri: downloadUri,
      sourceUri: sourceUri,
    );
  }
}

@immutable
class WallpaperQuery {
  const WallpaperQuery({
    required this.text,
    required this.page,
    required this.limit,
    required this.targetPixelSize,
  });

  final String text;
  final int page;
  final int limit;
  final Size targetPixelSize;

  double get targetAspectRatio {
    if (targetPixelSize.width <= 0.0 || targetPixelSize.height <= 0.0) {
      return 1.0;
    }
    return targetPixelSize.width / targetPixelSize.height;
  }
}

@immutable
class WallpaperPage {
  const WallpaperPage({
    required this.items,
    required this.page,
    required this.hasMore,
  });

  final List<WallpaperCandidate> items;
  final int page;
  final bool hasMore;
}
