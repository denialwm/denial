import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/state.dart';

import 'phone_desk.dart';

/// Joins the phone's and the desks' input layouts while they share the
/// session. The mobile shell lays the phone out from its own origin and the
/// desktop shell lays the desks out in scene coordinates; the compositor
/// routes by one snapshot in scene coordinates. The phone paints above the
/// desks, so its regions come first.
class PhoneDeskInputComposer {
  PhoneDeskInputComposer(this._bridge);

  final DenialBridge _bridge;
  InputLayoutSnapshot? _phone;
  Offset _phoneOrigin = Offset.zero;
  InputLayoutSnapshot? _desk;
  InputLayoutSnapshot? _last;
  int _epoch = 0;

  /// The phone's layout, in coordinates from [origin].
  bool publishPhone(InputLayoutSnapshot snapshot, Offset origin) {
    _phone = snapshot;
    _phoneOrigin = origin;
    return _publish();
  }

  /// The desks' layout, in scene coordinates.
  bool publishDesk(InputLayoutSnapshot snapshot) {
    _desk = snapshot;
    return _publish();
  }

  /// The split changed: the next layout goes out even if it routes the same.
  /// Each part publishes again with the change.
  void reset() {
    _last = null;
  }

  bool _publish() {
    final phone = _phone;
    final desk = _desk;
    // Until both parts have laid out, the last full layout keeps routing.
    if (phone == null || desk == null) return true;
    final origin = _phoneOrigin;
    // The wire wants one strictly descending z order. Each part keeps its
    // own order; every phone region outranks every desk region.
    final ordered = <InputWindowRegion>[
      ..._topmostFirst(phone.windows),
      ..._topmostFirst(desk.windows),
    ];
    final windows = <InputWindowRegion>[
      for (var index = 0; index < ordered.length; index++)
        _region(
          ordered[index],
          z: ordered.length - 1 - index,
          shift: index < phone.windows.length ? origin : Offset.zero,
        ),
    ];
    final snapshot = InputLayoutSnapshot(
      epoch: _epoch + 1,
      shellRegions: <Rect>[
        for (final rect in phone.shellRegions) rect.shift(origin),
        ...desk.shellRegions,
      ],
      windows: windows,
      softwareKeyboardRegions: <Rect>[
        for (final rect in phone.softwareKeyboardRegions) rect.shift(origin),
      ],
      edgeSwipeRegions: <InputEdgeSwipeRegion>[
        for (final region in phone.edgeSwipeRegions)
          InputEdgeSwipeRegion(
            rect: region.rect.shift(origin),
            edge: region.edge,
          ),
      ],
      visibleSurfaceIds: <int>{
        ...phone.visibleSurfaceIds,
        ...desk.visibleSurfaceIds,
      }.toList(growable: false),
      keyboardCapture: phone.keyboardCapture || desk.keyboardCapture,
      exclusiveShellMode: phone.exclusiveShellMode || desk.exclusiveShellMode,
      observeClientPointerPresses:
          phone.observeClientPointerPresses || desk.observeClientPointerPresses,
      mobilePresentation: true,
    );
    if (_last?.hasSameRoutingAs(snapshot) ?? false) return true;
    if (!_bridge.publishInputLayout(snapshot)) return false;
    _epoch = snapshot.epoch;
    _last = snapshot;
    return true;
  }

  static List<InputWindowRegion> _topmostFirst(List<InputWindowRegion> list) =>
      List<InputWindowRegion>.of(list)..sort((left, right) {
        final z = right.z.compareTo(left.z);
        return z != 0
            ? z
            : right.targetSurfaceId.compareTo(left.targetSurfaceId);
      });

  static InputWindowRegion _region(
    InputWindowRegion region, {
    required int z,
    required Offset shift,
  }) => InputWindowRegion(
    window: region.window,
    rect: region.rect.shift(shift),
    sourceRect: region.sourceRect,
    z: z,
    surfaceId: region.surfaceId,
    visible: region.visible,
    hitTest: region.hitTest,
    geometryLocked: region.geometryLocked,
  );
}

final phoneDeskInputComposerProvider = Provider<PhoneDeskInputComposer>((ref) {
  final composer = PhoneDeskInputComposer(ref.read(denialBridgeProvider));
  ref.listen(phoneDeskProvider, (_, _) => composer.reset());
  return composer;
});
