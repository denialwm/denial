import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/state.dart';

import 'reference_shell_presentation.dart';
import 'reference_shell_profile.dart';

/// Built-in panels, as the compositor names them.
bool isInternalPanel(String name) =>
    name.startsWith('DSI-') ||
    name.startsWith('eDP-') ||
    name.startsWith('LVDS-');

/// A phone with a monitor plugged in. The built-in panel keeps the mobile
/// shell; every other output is a desk that runs the desktop shell. The
/// compositor applies the same split to windows: a window on the phone fills
/// it, a window on a desk keeps desktop placement.
@immutable
class PhoneDeskLayout {
  const PhoneDeskLayout({required this.phone, required this.desks});

  final DisplayOutput phone;
  final List<DisplayOutput> desks;

  /// The phone's panel in scene coordinates.
  Rect get phoneRect => phone.logicalRect;

  bool isDeskMonitor(int monitorId) =>
      desks.any((desk) => desk.monitorId == monitorId);

  bool onDesk(DenialWindow window) => isDeskMonitor(window.monitorId);

  DisplayOutput? deskAt(Offset point) {
    for (final desk in desks) {
      if (desk.logicalRect.contains(point)) return desk;
    }
    return null;
  }

  /// [layout] as the desktop shell sees it: the desks alone, in scene
  /// coordinates.
  DisplayLayout deskLayout(DisplayLayout layout) {
    final barIds = layout.effectiveSystemBarMonitorIds
        .where(isDeskMonitor)
        .toList(growable: false);
    final ticker = isDeskMonitor(layout.tickerMonitorId)
        ? layout.tickerMonitorId
        : desks.first.monitorId;
    return DisplayLayout(
      epoch: layout.epoch,
      globalOrigin: layout.globalOrigin,
      logicalSize: layout.logicalSize,
      pixelSize: layout.pixelSize,
      engineScale: layout.engineScale,
      tickerMonitorId: ticker,
      systemBarMonitorId: barIds.contains(layout.systemBarMonitorId)
          ? layout.systemBarMonitorId
          : barIds.isEmpty
          ? -1
          : barIds.first,
      systemBarMonitorIds: barIds,
      systemBarSide: layout.systemBarSide,
      systemBarThickness: layout.systemBarThickness,
      maximizePadding: layout.maximizePadding,
      outputs: desks,
    );
  }

  /// [layout] as the mobile shell sees it: the phone alone, at the origin of
  /// its own part of the scene.
  DisplayLayout phoneLayout(DisplayLayout layout) {
    final size = phone.logicalRect.size;
    return DisplayLayout(
      epoch: layout.epoch,
      globalOrigin: layout.globalOrigin + phone.logicalRect.topLeft,
      logicalSize: size,
      pixelSize: phone.pixelSize,
      engineScale: phone.scale,
      tickerMonitorId: phone.monitorId,
      systemBarMonitorId: -1,
      systemBarSide: SystemBarSide.hidden,
      outputs: <DisplayOutput>[
        DisplayOutput(
          monitorId: phone.monitorId,
          name: phone.name,
          logicalRect: Offset.zero & size,
          pixelSize: phone.pixelSize,
          scale: phone.scale,
          refreshRate: phone.refreshRate,
          activeWorkspace: phone.activeWorkspace,
        ),
      ],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PhoneDeskLayout &&
      other.phone.monitorId == phone.monitorId &&
      other.phoneRect == phoneRect &&
      other.desks.length == desks.length &&
      Iterable<int>.generate(desks.length).every(
        (index) =>
            other.desks[index].monitorId == desks[index].monitorId &&
            other.desks[index].logicalRect == desks[index].logicalRect,
      );

  @override
  int get hashCode => Object.hash(
    phone.monitorId,
    phoneRect,
    Object.hashAll(desks.map((desk) => desk.monitorId)),
  );
}

/// The split while the mobile shell shares the session with a desk, else
/// null: the whole session is the phone, or the desktop.
final phoneDeskProvider = Provider<PhoneDeskLayout?>((ref) {
  if (ref.watch(referenceShellPresentationProvider) !=
      ReferenceShellProfile.mobile) {
    return null;
  }
  final outputs =
      ref.watch(displayLayoutProvider)?.outputs ?? const <DisplayOutput>[];
  DisplayOutput? phone;
  final desks = <DisplayOutput>[];
  for (final output in outputs) {
    if (isInternalPanel(output.name)) {
      phone ??= output;
    } else if (!output.inputOnly) {
      desks.add(output);
    }
  }
  if (phone == null || desks.isEmpty) return null;
  return PhoneDeskLayout(
    phone: phone,
    desks: List<DisplayOutput>.unmodifiable(desks),
  );
});

/// Which part of the shell a widget belongs to.
enum ShellPart {
  /// The whole session: no desk beside the phone.
  whole,

  /// The phone's panel, beside a desk.
  phone,

  /// The desks beside the phone.
  desk;

  static ShellPart of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellPartScope>()?.part ??
      ShellPart.whole;
}

class ShellPartScope extends InheritedWidget {
  const ShellPartScope({super.key, required this.part, required super.child});

  final ShellPart part;

  @override
  bool updateShouldNotify(ShellPartScope oldWidget) => part != oldWidget.part;
}

/// The display layout a part of the shell lays itself out in.
final sceneDisplayLayoutProvider = Provider.family<DisplayLayout?, ShellPart>((
  ref,
  part,
) {
  final layout = ref.watch(displayLayoutProvider);
  if (part == ShellPart.whole || layout == null) return layout;
  final split = ref.watch(phoneDeskProvider);
  if (split == null) return layout;
  return part == ShellPart.phone
      ? split.phoneLayout(layout)
      : split.deskLayout(layout);
});

/// The layout the desktop shell's own state works in: the desks while they
/// share the session with the phone.
final deskDisplayLayoutProvider = Provider<DisplayLayout?>(
  (ref) => ref.watch(sceneDisplayLayoutProvider(ShellPart.desk)),
);

/// The part the user last touched or clicked: notifications and level HUDs
/// show there.
final activeShellPartProvider = NotifierProvider<ActiveShellPart, ShellPart>(
  ActiveShellPart.new,
);

class ActiveShellPart extends Notifier<ShellPart> {
  @override
  ShellPart build() => ShellPart.phone;

  void note(ShellPart part) {
    if (part != ShellPart.whole && state != part) state = part;
  }
}

/// Whether a part's own copy of a transient overlay shows: always without a
/// desk, else only in the part the user last used.
bool showsTransientOverlay(BuildContext context, WidgetRef ref) {
  final part = ShellPart.of(context);
  return part == ShellPart.whole || ref.watch(activeShellPartProvider) == part;
}
