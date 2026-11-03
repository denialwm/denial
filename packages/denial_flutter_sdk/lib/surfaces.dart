/// Plugin-owned placement and visibility in the desktop scene.
library;

import 'dart:async';

import 'package:denial_sdk/composition.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import 'panels.dart';
import 'src/models/display_layout.dart' show DisplayOutput;
import 'services.dart';
import 'settings.dart';

export 'panels.dart' show PanelEdge;
export 'services.dart' show ShellServices;
export 'settings.dart' show ShellLayoutSettings, ShellSettings;
export 'src/models/display_layout.dart' show DisplayOutput;

/// All planes remain below the secure session and platform overlays.
enum ShellSurfaceLayer {
  /// Behind application windows and their minimized previews.
  desktop,

  /// Above the overview dismissal barrier, below application windows.
  desktopControls,

  /// Above application windows, below secure/platform overlays.
  aboveWindows,
}

/// How a surface applies the opacity supplied by [ShellSurfacePresentation].
enum ShellSurfaceFade {
  /// The SDK applies one opacity transition to the widget subtree.
  automatic,

  /// The plugin applies the supplied opacity itself, for example separately to
  /// glass and foreground. The SDK still manages input and retained lifetime.
  custom,
}

/// Immutable facts, not host visibility decisions. Recomputed on output,
/// workspace, fullscreen, overview, desktop, lock and settings changes.
@immutable
final class ShellSurfaceEnvironment {
  const ShellSurfaceEnvironment({
    required this.output,
    required this.workArea,
    required this.isMainOutput,
    required this.workspaceId,
    required this.fullscreen,
    required this.overview,
    required this.desktopVisible,
    required this.wallpaperSelectorVisible,
    required this.locked,
    required this.settings,
    required this.defaultOutputSelected,
    this.inputOnlyOutputNames = const <String>[],
  });
  final DisplayOutput output;
  final List<String> inputOnlyOutputNames;
  final Rect workArea;
  final bool isMainOutput;
  final int workspaceId;
  final bool fullscreen;
  final bool overview;
  final bool desktopVisible;
  final bool wallpaperSelectorVisible;
  final bool locked;
  final ShellSettings settings;

  /// Whether this output belongs to the compositor's configured default set.
  /// It is a fact, not a requirement to place a surface here.
  final bool defaultOutputSelected;

  /// Convenience for plugins choosing to honor an output-name preference.
  /// An empty preference uses [defaultOutputSelected].
  bool outputSelected(Iterable<String> names) {
    if (output.inputOnly) return false;
    final desktopNames = names.where(
      (name) => !inputOnlyOutputNames.contains(name),
    );
    return desktopNames.isEmpty
        ? defaultOutputSelected
        : desktopNames.contains(output.name);
  }

  // Compare the output's values, not its wire snapshot identity. A newly decoded
  // but unchanged output must not restart plugin timers or produce false events.
  Object get _outputValues => (
    output.monitorId,
    output.name,
    output.logicalRect,
    output.pixelSize,
    output.scale,
    output.refreshRate,
    output.activeWorkspace,
    output.inputOnly,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShellSurfaceEnvironment &&
          _outputValues == other._outputValues &&
          listEquals(inputOnlyOutputNames, other.inputOnlyOutputNames) &&
          workArea == other.workArea &&
          isMainOutput == other.isMainOutput &&
          workspaceId == other.workspaceId &&
          fullscreen == other.fullscreen &&
          overview == other.overview &&
          desktopVisible == other.desktopVisible &&
          wallpaperSelectorVisible == other.wallpaperSelectorVisible &&
          locked == other.locked &&
          settings == other.settings &&
          defaultOutputSelected == other.defaultOutputSelected;

  @override
  int get hashCode => Object.hash(
    _outputValues,
    Object.hashAll(inputOnlyOutputNames),
    workArea,
    isMainOutput,
    workspaceId,
    fullscreen,
    overview,
    desktopVisible,
    wallpaperSelectorVisible,
    locked,
    settings,
    defaultOutputSelected,
  );
}

@immutable
final class ShellSurfacePlacement {
  const ShellSurfacePlacement({
    required this.bounds,
    this.visible = true,
    this.occupiesDesktop = false,
    this.fade = ShellSurfaceFade.automatic,
  });

  /// Logical coordinates in the global Flutter scene, clipped to this output.
  final Rect bounds;

  /// False retains widget state while fading out and suppressing input.
  final bool visible;

  /// Keep minimized desktop window previews out of these bounds.
  final bool occupiesDesktop;

  /// Explicit ownership of the visibility fade, independent of plugin type.
  final ShellSurfaceFade fade;

  /// Builds an edge strip in scene coordinates. [PanelEdge.hidden] is not an
  /// edge; return null from [ShellSurface.place] to omit an output instead.
  static Rect edgeBounds(Rect output, PanelEdge edge, double thickness) {
    if (!output.isFinite || output.isEmpty) {
      throw ArgumentError.value(
        output,
        'output',
        'Must be finite and nonempty',
      );
    }
    if (!thickness.isFinite || thickness <= 0) {
      throw ArgumentError.value(
        thickness,
        'thickness',
        'Must be finite and positive',
      );
    }
    return switch (edge) {
      PanelEdge.top => Rect.fromLTWH(
        output.left,
        output.top,
        output.width,
        thickness,
      ),
      PanelEdge.bottom => Rect.fromLTWH(
        output.left,
        output.bottom - thickness,
        output.width,
        thickness,
      ),
      PanelEdge.left => Rect.fromLTWH(
        output.left,
        output.top,
        thickness,
        output.height,
      ),
      PanelEdge.right => Rect.fromLTWH(
        output.right - thickness,
        output.top,
        thickness,
        output.height,
      ),
      PanelEdge.hidden => throw ArgumentError.value(
        edge,
        'edge',
        'Choose a visible edge',
      ),
    };
  }
}

/// Snapshot for building plus updates for timers/side effects. Read the initial
/// [environment], subscribe once to [events] in your widget's initState, and
/// cancel on dispose. The SDK owns the stream; plugins must not close it.
@immutable
final class ShellSurfaceContext {
  const ShellSurfaceContext({
    required this.environment,
    required this.events,
    required this.services,
  });
  final ShellSurfaceEnvironment environment;

  /// Stable, asynchronous broadcast stream for this surface/output instance.
  /// Emits only when the environment changes; it does not replay the initial
  /// snapshot. Closing/removing the instance closes the stream. Hidden retained
  /// instances continue to receive changes.
  final Stream<ShellSurfaceEnvironment> events;
  final ShellServices services;
}

@ExtensionPoint(cardinality: ContributionCardinality.zeroOrMore)
abstract interface class ShellSurface {
  /// Unique, package-qualified identity. Keep it stable for the widget lifetime.
  String get id;

  /// Stable scene plane. Runtime state belongs in placement, not in this getter.
  ShellSurfaceLayer get layer;

  /// A pure function of the current environment.
  /// Null opts out of this output and disposes its instance. To temporarily hide
  /// an existing instance return a placement with visible:false instead.
  ShellSurfacePlacement? place(ShellSurfaceEnvironment environment);
  Widget build(BuildContext context, {required ShellSurfaceContext surface});
}

/// Native work-area reservation is distinct from widget placement. The current
/// native protocol supports ONE shared edge/thickness/output selection. A second
/// provider is a composition error, before compilation/activation.
@ExtensionPoint(cardinality: ContributionCardinality.zeroOrOne)
abstract interface class ShellWorkArea {
  ShellWorkAreaReservation? reserve(ShellLayoutSettings settings);
}

@immutable
final class ShellWorkAreaReservation {
  ShellWorkAreaReservation({
    required this.edge,
    required this.thickness,
    Iterable<String> outputNames = const [],
  }) : outputNames = List.unmodifiable(outputNames) {
    if (edge == PanelEdge.hidden) {
      throw ArgumentError.value(edge, 'edge', 'Return null for no reservation');
    }
    if (!thickness.isFinite || thickness <= 0) {
      throw ArgumentError.value(
        thickness,
        'thickness',
        'Must be finite and positive',
      );
    }
  }

  final PanelEdge edge;
  final double thickness;

  /// Empty uses the compositor's configured default output selection.
  final List<String> outputNames;
}

/// Effective visibility and animated opacity inside an SDK-mounted surface.
/// Read this from the build context, including in owned transient overlays.
class ShellSurfacePresentation extends InheritedWidget {
  const ShellSurfacePresentation({
    required this.visible,
    required this.opacity,
    required super.child,
    super.key,
  });
  final bool visible;
  final Animation<double> opacity;
  static bool visibleOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ShellSurfacePresentation>()
          ?.visible ??
      true;
  static Animation<double> opacityOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ShellSurfacePresentation>()
          ?.opacity ??
      const AlwaysStoppedAnimation(1);
  @override
  bool updateShouldNotify(ShellSurfacePresentation oldWidget) =>
      visible != oldWidget.visible || opacity != oldWidget.opacity;
}
