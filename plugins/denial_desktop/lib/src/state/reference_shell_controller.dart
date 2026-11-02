import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/lifecycle.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart' show ShellSprings;
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/state.dart';

import 'app_deck.dart';
import 'reference_shell_state.dart';
import 'input_deck.dart';
import 'phone_desk.dart';
import 'phone_desk_input.dart';
import 'reference_shell_metrics.dart';
import 'reference_shell_profile.dart';
import 'reference_input_layout_coordinator.dart';

final referenceShellProvider =
    NotifierProvider<ReferenceShellController, ReferenceShellState>(
      ReferenceShellController.new,
    );

/// Owns the reference desktop/mobile presentation over the shared native state.
/// It never registers another native window callback or creates another bridge.
class ReferenceShellController extends Notifier<ReferenceShellState>
    with NotifierLifecycle<ReferenceShellState> {
  late ShellController _platform;

  /// The bottom gesture's visual drag, axis-locked. It changes on every frame
  /// of a swipe, so the layers it moves listen to it directly and the shell
  /// state carries only its [ReferenceShellState.gesture] phase.
  ValueListenable<Offset> get gestureDrag => _gestureDrag;
  final _gestureDrag = ValueNotifier(Offset.zero);

  @override
  ReferenceShellState get state => super.state;

  /// The shade's position under the finger, from 0 closed to 1 open, while
  /// [ReferenceShellState.quickSettingsDragActive]. The shell state carries
  /// only [ReferenceShellState.quickSettingsDragged].
  ValueListenable<double> get quickSettingsDrag => _quickSettingsDrag;
  final _quickSettingsDrag = ValueNotifier(0.0);

  /// The open apps as the bottom gesture, switching and recents move them.
  AppDeck get deck => _deck;
  late AppDeck _deck;

  /// A sideways swipe holds the row of apps.
  bool get holdsRow => _hold == _DeckHold.row;

  @override
  set state(ReferenceShellState value) {
    final previous = stateOrNull;
    final previousForeground = previous?.foregroundObjectId;
    _noteRecent(value);
    super.state = value;
    // However recents is left, its cards leave with it: whatever closes it
    // without moving the deck sends them home.
    if ((previous?.overviewVisible ?? false) &&
        !value.overviewVisible &&
        _deck.open.target > 0 &&
        !_deck.open.held) {
      _deck.homeward.settle(1, ShellSprings.appStrip);
    }
    _arrangeDeck();
    _minimizeLeftApp(previousForeground, value);
    // However a transition ends the gesture, an idle phase has no drag. The
    // drag follows the state, as its moving layers expect.
    if (value.gesture == GestureDragPhase.idle) {
      _gestureDrag.value = Offset.zero;
    }
    if (!value.quickSettingsDragged) {
      _quickSettingsDrag.value = 0.0;
    }
  }

  /// Open apps from the one longest out of front to the one in front, or
  /// last there.
  final List<int> _recent = <int>[];

  void _noteRecent(ReferenceShellState next) {
    final open = next.openAppWindowsByObjectId;
    _recent.removeWhere((id) => !open.containsKey(id));
    final front = next.foregroundObjectId;
    if (front != null &&
        open.containsKey(front) &&
        _recent.lastOrNull != front) {
      _recent
        ..remove(front)
        ..add(front);
    }
  }

  /// The open apps from least to most recently in front. Apps never in
  /// front come first, in the compositor's order.
  List<int> _recencyOrder() {
    final rank = {for (final (index, id) in _recent.indexed) id: index};
    final apps = [for (final window in state.openAppWindows) window.objectId];
    return [
      for (final id in apps)
        if (!rank.containsKey(id)) id,
      for (final id in _recent)
        if (state.openAppWindowsByObjectId.containsKey(id)) id,
    ];
  }

  /// On the phone, an app the user left, by going home or for another app,
  /// is minimized: Denial suspends it, stops its frames and keeps showing its
  /// last one. Recents alone leaves the app in front, as does the lock
  /// screen; focusing it again restores it.
  void _minimizeLeftApp(int? previous, ReferenceShellState next) {
    if (!_automaticSoftwareKeyboard ||
        previous == null ||
        previous == next.foregroundObjectId) {
      return;
    }
    final window = next.openAppWindowsByObjectId[previous];
    if (window == null || window.minimized) return;
    _bridge.minimizeWindow(window);
  }

  @override
  ReferenceShellState build() {
    _bridge = ref.watch(denialBridgeProvider);
    final platform = ref.read(shellControllerProvider);
    _platform = ref.read(shellControllerProvider.notifier);
    _deck = ref.read(appDeckProvider);
    _deck.presenting.addListener(_deckPresentingChanged);
    _resetBuildFields();
    _automaticSoftwareKeyboard =
        ref.watch(referenceShellProfileProvider) ==
        ReferenceShellProfile.mobile;
    _buildGeneration = beginBuildGeneration();
    final generation = _buildGeneration;
    ref.listen<bool>(
      inputDeckProvider.select((deck) => deck.activeOutput != null),
      (_, active) {
        if (active && !state.locked) closeEdgePanel();
      },
    );
    ref.listen<ShellState>(shellControllerProvider, (_, next) {
      if (isBuildGenerationActive(generation)) _synchronizePlatform(next);
    });
    ref.listen<PhoneDeskLayout?>(phoneDeskProvider, (_, _) {
      if (isBuildGenerationActive(generation)) {
        _inputLayoutCoordinator.invalidate();
        _synchronizePlatform(ref.read(shellControllerProvider));
      }
    });
    _textInputStateSubscription = _bridge.textInputStates.listen((input) {
      if (isBuildGenerationActive(generation)) _handleTextInputState(input);
    });
    ref.onDispose(() {
      _deck.presenting.removeListener(_deckPresentingChanged);
      _automaticSoftwareKeyboardCloseTimer?.cancel();
      _automaticSoftwareKeyboardCloseTimer = null;
      _launchRequestTimer?.cancel();
      _launchRequestTimer = null;
      _appSwitchOrderTimer?.cancel();
      _appSwitchOrderTimer = null;
      unawaited(_textInputStateSubscription?.cancel());
      _textInputStateSubscription = null;
    });
    final initial = ReferenceShellState.initial(platform);
    final (phone, desk) = _splitByScreen(
      platform,
      previousPhone: platform,
      previousDesk: platform,
    );
    return initial.copyWith(platform: phone, desk: desk);
  }

  /// Splits the native windows between the phone and the desks while they
  /// share the session; otherwise both see them all. The phone keeps its own
  /// foreground while a desk window has the native focus, and a desk shows
  /// none while the phone has it.
  (ShellState, ShellState) _splitByScreen(
    ShellState next, {
    required ShellState previousPhone,
    required ShellState previousDesk,
  }) {
    final split = ref.read(phoneDeskProvider);
    if (split == null) return (next, next);
    final phoneWindows = <DenialWindow>[];
    final deskWindows = <DenialWindow>[];
    for (final window in next.windows) {
      (split.onDesk(window) ? deskWindows : phoneWindows).add(window);
    }
    final phoneLayers = <DenialWindow>[];
    final deskLayers = <DenialWindow>[];
    for (final surface in next.layerSurfaces) {
      (split.onDesk(surface) ? deskLayers : phoneLayers).add(surface);
    }
    final foreground = next.windowByObjectId(next.foregroundObjectId);
    final foregroundOnDesk = foreground != null && split.onDesk(foreground);
    // The phone's own app, while it is still on the phone.
    final phoneForeground =
        phoneWindows.any(
          (window) => window.objectId == previousPhone.foregroundObjectId,
        )
        ? previousPhone.foregroundObjectId
        : null;
    final phone = next.copyWith(
      windows: _sameWindows(previousPhone.windows, phoneWindows),
      layerSurfaces: _sameWindows(previousPhone.layerSurfaces, phoneLayers),
      foregroundObjectId: foregroundOnDesk
          ? phoneForeground
          : next.foregroundObjectId,
      clearForegroundObjectId: foregroundOnDesk && phoneForeground == null,
      // A desk window's activation is not the phone's.
      activationRevision: foregroundOnDesk
          ? previousPhone.activationRevision
          : next.activationRevision,
    );
    final desk = next.copyWith(
      windows: _sameWindows(previousDesk.windows, deskWindows),
      layerSurfaces: _sameWindows(previousDesk.layerSurfaces, deskLayers),
      clearForegroundObjectId: !foregroundOnDesk,
    );
    return (phone, desk);
  }

  /// [next], or [previous] when it holds the same windows, so listeners
  /// comparing identity see no change.
  static List<DenialWindow> _sameWindows(
    List<DenialWindow> previous,
    List<DenialWindow> next,
  ) {
    if (previous.length != next.length) return next;
    for (var index = 0; index < next.length; index++) {
      if (!identical(previous[index], next[index])) return next;
    }
    return previous;
  }

  /// Whether [window] sits on a desk beside the phone.
  bool _onDesk(DenialWindow window) =>
      ref.read(phoneDeskProvider)?.onDesk(window) ?? false;

  // Large enough that the vertical swipe tracks the finger across the whole
  // screen (the home/recents hero needs the real travel, not a capped value).
  static const double _gestureVisualDistance = 1600.0;
  static const double _gestureHorizontalVisualDistance = 4096.0;
  static const double _gestureAxisLockDistance = 14.0;
  static const double _gestureAxisLockRatio = 1.18;
  static const double _switchDistance = 82.0;
  static const double _switchFlickVelocity = 720.0;
  static const double _quickSettingsOpenDistance = 126.0;
  static const double _quickSettingsFlickVelocity = 520.0;
  static const double _edgePanelFlickVelocity = 520.0;
  static const Duration _launchRequestTimeout = Duration(seconds: 15);

  /// How long a quick-switch order outlives its last switch, as on Android.
  static const Duration _appSwitchOrderHold = Duration(seconds: 5);
  static const Duration _automaticSoftwareKeyboardCloseGrace = Duration(
    milliseconds: 24,
  );

  late DenialBridge _bridge;
  late int _buildGeneration;
  late ReferenceInputLayoutCoordinator _inputLayoutCoordinator;
  Offset _rawGestureDrag = Offset.zero;
  Offset _gestureLockOrigin = Offset.zero;
  _GestureAxis _gestureAxis = _GestureAxis.undecided;

  /// What the bottom gesture's finger holds of the deck.
  _DeckHold _hold = _DeckHold.none;

  /// The held lift began on an app, not on home.
  bool _holdFromApp = false;

  /// The row's ends for the finger that holds it.
  double _rowLow = 0;
  double _rowHigh = 0;

  /// The held lift caught the apps in visible motion, such as a card still
  /// opening or a switch still sliding: recents then opens around the app
  /// they were heading for.
  bool _liftCaught = false;

  /// Apps dismissed from recents whose windows have not closed yet.
  final Set<int> _dismissedIds = <int>{};
  bool _quickSettingsDragStartedOpen = false;
  bool _quickSettingsDragMoved = false;
  double _quickSettingsReleaseVelocity = 0;

  /// Vertical velocity, in logical pixels per second, with which the last
  /// open or close of the shade was released; zero when nothing was flung.
  /// The shade continues its settle spring from it.
  double get quickSettingsReleaseVelocity => _quickSettingsReleaseVelocity;

  bool _shadeOpensNotifications = false;

  /// Whether the shade opening now asked for its notification page; asking
  /// clears it.
  bool takeNotificationPageRequest() {
    final requested = _shadeOpensNotifications;
    _shadeOpensNotifications = false;
    return requested;
  }

  double _gestureReleaseVelocity = 0;

  /// Vertical velocity, in logical pixels per second, with which the bottom
  /// gesture last opened recents or was cancelled; zero for other changes.
  /// Recents continues its settle spring from it.
  double get gestureReleaseVelocity => _gestureReleaseVelocity;
  bool _edgePanelDragStartedOpen = false;
  bool _edgePanelDragMoved = false;
  int? _edgePanelDismissalSerial;
  DenialTextInputState? _lastTextInput;
  int _nextLaunchRequestId = 1;
  Timer? _launchRequestTimer;
  Timer? _appSwitchOrderTimer;
  bool _automaticSoftwareKeyboard = false;
  final Set<String> _legacyTextInputAppIds = <String>{};
  final Set<String> _backgroundLaunchAppIds = <String>{};
  Timer? _automaticSoftwareKeyboardCloseTimer;
  StreamSubscription<DenialTextInputState>? _textInputStateSubscription;

  void _resetBuildFields() {
    _lastTextInput = null;
    _edgePanelDismissalSerial = null;
    _automaticSoftwareKeyboardCloseTimer?.cancel();
    _automaticSoftwareKeyboardCloseTimer = null;
    unawaited(_textInputStateSubscription?.cancel());
    _textInputStateSubscription = null;
    _inputLayoutCoordinator = ReferenceInputLayoutCoordinator(_bridge);
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
    _hold = _DeckHold.none;
    _liftCaught = false;
    _dismissedIds.clear();
    _recent.clear();
    _quickSettingsDragStartedOpen = false;
    _quickSettingsDragMoved = false;
    _edgePanelDragStartedOpen = false;
    _edgePanelDragMoved = false;
    _nextLaunchRequestId = 1;
    _launchRequestTimer = null;
    _appSwitchOrderTimer?.cancel();
    _appSwitchOrderTimer = null;
    _legacyTextInputAppIds.clear();
    _backgroundLaunchAppIds.clear();
  }

  void _handleTextInputState(DenialTextInputState input) {
    _lastTextInput = input;
    if (!_automaticSoftwareKeyboard) {
      return;
    }
    // Text fields on a desk take the desk's keyboard, never the phone's.
    if (state.desk.foregroundObjectId != null &&
        ref.read(phoneDeskProvider) != null) {
      return;
    }
    if (input.inputPanelVisible) {
      final foregroundAppId = AppLaunchRequest.normalizeAppId(
        state.foregroundWindow?.appId ?? '',
      );
      if (input.legacy && !_legacyTextInputAppIds.contains(foregroundAppId)) {
        closeEdgePanel();
        return;
      }
      _automaticSoftwareKeyboardCloseTimer?.cancel();
      _automaticSoftwareKeyboardCloseTimer = null;
      openEdgePanel();
    } else {
      // Flutter retires the old TextInputClient just before registering the
      // next one during a field-to-field focus transfer. Preserve the panel
      // across that short protocol gap; a replacement editor cancels this
      // close before any visible keyboard motion begins.
      _automaticSoftwareKeyboardCloseTimer?.cancel();
      final generation = _buildGeneration;
      _automaticSoftwareKeyboardCloseTimer = Timer(
        _automaticSoftwareKeyboardCloseGrace,
        () {
          _automaticSoftwareKeyboardCloseTimer = null;
          if (isBuildGenerationActive(generation)) {
            closeEdgePanel();
          }
        },
      );
    }
  }

  void registerLegacyTextInputAppIds(Iterable<String> appIds) {
    _legacyTextInputAppIds.addAll(
      appIds
          .map(AppLaunchRequest.normalizeAppId)
          .where((identity) => identity.isNotEmpty),
    );
  }

  void lock() {
    _platform.lock();
  }

  /// Secures the session first, then asks the compositor to blank its outputs.
  /// Both commands use Denial's native channels; no external power daemon is
  /// involved.
  void lockAndBlankDisplays() {
    _platform.lockAndBlankDisplays();
  }

  void requestUnlock() {
    _platform.requestUnlock();
  }

  /// Moves an app from the phone to the first desk. It leaves the phone's
  /// deck; recents stays open for the next one.
  void moveToDesk(DenialWindow window) {
    final split = ref.read(phoneDeskProvider);
    if (split == null) return;
    _bridge.moveWindowToOutput(window, monitorId: split.desks.first.monitorId);
  }

  /// Brings an app from a desk to the phone, in front.
  void sendToPhone(DenialWindow window) {
    final split = ref.read(phoneDeskProvider);
    if (split == null) return;
    _bridge.moveWindowToOutput(window, monitorId: split.phone.monitorId);
  }

  void completeUnlockTransition() {
    if (state.locked || !state.lockLayerVisible) {
      return;
    }

    _inputLayoutCoordinator.invalidate();
    state = state.copyWith(lockLayerVisible: false);
  }

  void _resetSecurePresentation() {
    _endFingerGesture();
    _deck.halt();
    _quickSettingsDragStartedOpen = false;
    _quickSettingsDragMoved = false;
    _edgePanelDragStartedOpen = false;
    _edgePanelDragMoved = false;
    _launchRequestTimer?.cancel();
    _launchRequestTimer = null;
    _appSwitchOrderTimer?.cancel();
    _appSwitchOrderTimer = null;

    state = state.copyWith(
      lockLayerVisible: true,
      appSwitchOrder: const <int>[],
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      edgePanelViewportScroll: 0.0,
      homeTransitionActive: false,
      clearLaunchingObjectId: true,
      clearLaunchRequest: true,
    );
  }

  void _synchronizePlatform(ShellState native) {
    final previous = state.platform;
    final (platform, desk) = _splitByScreen(
      native,
      previousPhone: previous,
      previousDesk: state.desk,
    );
    final windowsChanged =
        !identical(previous.windows, platform.windows) ||
        !identical(previous.layerSurfaces, platform.layerSurfaces);
    state = state.copyWith(platform: platform, desk: desk);
    if (previous.locked != platform.locked) _resetSecurePresentation();
    if (windowsChanged) _reconcileWindowSnapshot();
    if (previous.activationRevision != platform.activationRevision) {
      final window = platform.foregroundWindow;
      if (window != null) _handleNativeWindowActivated(window.windowId);
    }
  }

  void _reconcileWindowSnapshot() {
    final open = state.openAppWindowsByObjectId;
    _dismissedIds.removeWhere((id) => !open.containsKey(id));
    if (_deck.presenting.value) {
      _deck.reorder(_presentedOrder(), ShellSprings.appStrip);
    }
    if (!_appSwitchOrderMatchesOpenApps()) _releaseAppSwitchOrder();
    final request = state.launchRequest;
    final launchWindow = request == null
        ? null
        : _matchingLaunchWindow(state.windows, request);
    if (launchWindow != null) {
      final shouldActivate = state.launchingObjectId != launchWindow.objectId;
      // A gesture holding the opening card keeps holding it.
      state = state.copyWith(
        overviewVisible: false,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
        foregroundObjectId: launchWindow.objectId,
        launchingObjectId: launchWindow.objectId,
      );
      if (shouldActivate) _platform.focusWindow(launchWindow);
      return;
    }
    state = state.copyWith(
      clearForegroundObjectId:
          state.windowByObjectId(state.foregroundObjectId) == null,
      clearLaunchingObjectId:
          state.windowByObjectId(state.launchingObjectId) == null,
    );
  }

  DenialWindow? _matchingLaunchWindow(
    List<DenialWindow> windows,
    AppLaunchRequest request,
  ) {
    final boundObjectId = state.launchingObjectId;
    if (boundObjectId != null) {
      for (final window in windows) {
        if (window.objectId == boundObjectId && request.matchesWindow(window)) {
          return window;
        }
      }
    }

    for (final window in windows) {
      if (request.matchesWindow(window)) {
        return window;
      }
    }
    return null;
  }

  int? beginAppLaunch({
    required String appName,
    required String? iconPath,
    required Iterable<String> expectedAppIds,
    Rect? sourceRect,
    String? sourceItemId,
  }) {
    return _beginLauncherTransition(
      appName: appName,
      iconPath: iconPath,
      expectedAppIds: expectedAppIds,
      sourceRect: sourceRect,
      sourceItemId: sourceItemId,
    );
  }

  /// Focuses an already-open application through the same coherent launcher
  /// transition used for a newly-created application window.
  int? activateAppFromLauncher({
    required DenialWindow window,
    required String appName,
    required String? iconPath,
    Rect? sourceRect,
    String? sourceItemId,
  }) {
    if (!window.isUserApp) {
      return null;
    }
    return _beginLauncherTransition(
      appName: appName,
      iconPath: iconPath,
      expectedAppIds: <String>[window.appId],
      targetWindow: window,
      sourceRect: sourceRect,
      sourceItemId: sourceItemId,
    );
  }

  int? _beginLauncherTransition({
    required String appName,
    required String? iconPath,
    required Iterable<String> expectedAppIds,
    DenialWindow? targetWindow,
    Rect? sourceRect,
    String? sourceItemId,
  }) {
    if (state.lockLayerVisible || state.launchRequest != null) {
      return null;
    }

    final requestId = _nextLaunchRequestId++;
    final request = AppLaunchRequest(
      requestId: requestId,
      appName: appName,
      iconPath: iconPath,
      expectedAppIds: expectedAppIds,
      existingObjectIds: state.openAppWindows.map((window) => window.objectId),
      targetObjectId: targetWindow?.objectId,
      sourceRect: sourceRect,
      sourceItemId: sourceItemId,
    );

    _endFingerGesture();
    _releaseAppSwitchOrder();
    _launchRequestTimer?.cancel();
    final generation = _buildGeneration;
    _launchRequestTimer = Timer(_launchRequestTimeout, () {
      if (isBuildGenerationActive(generation)) {
        failAppLaunch(requestId);
      }
    });

    state = state.copyWith(
      launchRequest: request,
      foregroundObjectId: targetWindow?.objectId,
      launchingObjectId: targetWindow?.objectId,
      clearLaunchingObjectId: targetWindow == null,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      homeTransitionActive: false,
    );
    if (targetWindow != null) {
      _backgroundLaunchAppIds.remove(
        AppLaunchRequest.normalizeAppId(targetWindow.appId),
      );
      _platform.focusWindow(targetWindow);
    }
    return requestId;
  }

  void failAppLaunch(int requestId) {
    if (state.launchRequest?.requestId != requestId) {
      return;
    }
    _launchRequestTimer?.cancel();
    _launchRequestTimer = null;
    state = state.copyWith(
      clearLaunchRequest: true,
      clearLaunchingObjectId: true,
    );
  }

  /// Opens recents, continuing [releaseVelocity] (logical pixels per second,
  /// negative upward). Out of an app, the app settles into its card and the
  /// previous app comes to the centre; from home, the cards slide in from
  /// beside the screen.
  void openOverview({double releaseVelocity = 0}) {
    _releaseAppSwitchOrder();
    if (state.overviewVisible) {
      resetGestureDrag(releaseVelocity: releaseVelocity);
    } else {
      _gestureReleaseVelocity = releaseVelocity;
      final rate = _openRate(releaseVelocity);
      if (_hold == _DeckHold.none) _finishNearRest();
      final caught = _hold == _DeckHold.open
          ? _liftCaught
          : _deck.presenting.value;
      final front = _deck.indexOf(state.foregroundWindow?.objectId);
      _endFingerGesture();
      if (front == null) _takeFromHome(lift: true);
      if (front == null && !_deck.presenting.value) _deck.enterFromHome();
      // Velocity away from the target would first carry the cards back.
      final toward = rate > 0 ? rate : 0.0;
      // From home recents slides in; out of an app the app shrinks into it.
      final slides = _deck.homeward.value > 0;
      _deck.open.settle(
        1,
        ShellSprings.recentsOpen,
        velocity: slides ? 0 : toward,
      );
      _deck.homeward.settle(
        0,
        ShellSprings.recentsOpen,
        velocity: slides ? -toward : 0,
      );
      _deck.attached.settle(1, ShellSprings.appStrip);
      // Out of an app the previous app comes to the middle; otherwise the
      // row settles on the card nearest, never on home.
      final last = _deck.length - 1;
      final row = _deck.row;
      final target = front != null && !caught
          ? (front > 0 ? front - 1 : math.min(last, front + 1))
          : row.target.round().clamp(0, math.max(0, last));
      if (last >= 0 && row.target != target) {
        row.settle(target.toDouble(), ShellSprings.recentsOpen);
      }
      state = state.copyWith(
        overviewVisible: true,
        homeTransitionActive: false,
        gesture: GestureDragPhase.idle,
        quickSettingsVisible: false,
        quickSettingsDragged: false,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
      );
    }
  }

  /// Begins the transition home. The app in front flies from wherever the
  /// deck has it into its home icon, continuing [releaseVelocity] (logical
  /// pixels per second, negative upward), and the flight then calls
  /// [completeHomeTransition]. A launch still in progress shrinks back into
  /// its icon instead.
  void goHome({double releaseVelocity = 0}) {
    if (state.homeTransitionActive) {
      resetGestureDrag(releaseVelocity: releaseVelocity);
      return;
    }
    _gestureReleaseVelocity = releaseVelocity;
    _releaseAppSwitchOrder();
    // A flick too quick for the deck to follow still leaves at its speed.
    final rate = _hold == _DeckHold.open || !_deck.open.moving
        ? _openRate(releaseVelocity)
        : _deck.open.velocity;
    _endFingerGesture();
    final launchRequest = state.launchRequest;
    if (launchRequest != null) {
      _launchRequestTimer?.cancel();
      _launchRequestTimer = null;
      _backgroundLaunchAppIds.addAll(launchRequest.expectedAppIds);
      state = state.copyWith(
        clearLaunchRequest: true,
        clearLaunchingObjectId: true,
        clearForegroundObjectId: true,
        homeTransitionActive: false,
        overviewVisible: false,
        gesture: GestureDragPhase.idle,
        quickSettingsVisible: false,
        quickSettingsDragged: false,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
      );
      return;
    }
    // The app in front flies into its icon from wherever the deck has it;
    // the rest of the deck settles away.
    final front = state.foregroundWindow?.objectId;
    if (front != null) _deck.sendHome(front, openRate: rate);
    _deck.open.settle(
      0,
      ShellSprings.recentsClose,
      velocity: rate < 0 ? rate : 0,
    );
    // Clear the foreground now so home shows immediately beneath the flying
    // app.
    state = state.copyWith(
      homeTransitionActive: true,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      clearForegroundObjectId: true,
    );
  }

  void completeHomeTransition() {
    if (!state.homeTransitionActive) {
      return;
    }
    state = state.copyWith(homeTransitionActive: false);
  }

  /// Closes recents for home: the cards slide out beside the screen.
  void closeOverview() {
    if (state.overviewVisible) {
      _endFingerGesture();
      _deck.homeward.settle(1, ShellSprings.appStrip);
      state = state.copyWith(
        overviewVisible: false,
        gesture: GestureDragPhase.idle,
        quickSettingsDragActive: false,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
        clearForegroundObjectId: true,
      );
    }
  }

  /// Performs the system Back action on [ReferenceShellState.backTarget].
  /// Returns false when nothing can go back.
  bool navigateBack() {
    switch (state.backTarget) {
      case MobileBackTarget.none:
        return false;
      case MobileBackTarget.keyboard:
        // A user dismissal, as when the keyboard is dragged closed: the
        // application learns its editor's panel was dismissed.
        final input = _lastTextInput;
        if (input != null && input.active) {
          _bridge.dismissKeyboardPanel(input.activationSerial);
        }
        closeEdgePanel();
      case MobileBackTarget.shade:
        closeQuickSettings();
      case MobileBackTarget.overview:
        closeOverview();
      case MobileBackTarget.app:
        final window = state.primaryWindow;
        if (window == null) return false;
        _platform.navigateBack(window);
    }
    return true;
  }

  void closeWindow(DenialWindow window) {
    if (state.overviewVisible && state.openAppWindowCount <= 1) {
      closeOverview();
    }
    _platform.closeWindow(window);
  }

  /// A card swiped away in recents: the row closes its gap at once, and the
  /// app closes. Recents with no app left closes for home.
  void dismissFromRecents(DenialWindow window) {
    _dismissedIds.add(window.objectId);
    _deck.reorder(_presentedOrder(), ShellSprings.appStrip);
    if (_deck.length == 0) closeOverview();
    _platform.closeWindow(window);
  }

  /// A card tapped in recents: recents closes around it as the row brings it
  /// to the centre, each continuing whatever motion it has. A swipe up takes
  /// it back.
  void openFromRecents(DenialWindow window) {
    final index = _deck.indexOf(window.objectId);
    if (index == null || !window.isUserApp) return;
    focusWindow(window);
  }

  void focusWindow(DenialWindow window) {
    if (!window.isUserApp) {
      return;
    }
    // A desk window takes the native focus; the phone shows what it showed.
    if (_onDesk(window)) {
      _platform.focusWindow(window);
      return;
    }

    _backgroundLaunchAppIds.remove(
      AppLaunchRequest.normalizeAppId(window.appId),
    );
    _releaseAppSwitchOrder();
    _activateWindowInShell(window);
    _platform.focusWindow(window);
  }

  /// Mirrors the compositor dropping keyboard focus after this window is
  /// minimized. A later native activation remains authoritative.
  void releaseWindowFocus(DenialWindow window) {
    _platform.releaseWindowFocus(window);
    if (state.foregroundObjectId != window.objectId) {
      return;
    }
    state = state.copyWith(clearForegroundObjectId: true);
  }

  void _activateWindowInShell(DenialWindow window) {
    _endFingerGesture();
    // A deck in motion brings the app to fill the screen from where it is.
    final index = _deck.indexOf(window.objectId);
    if (_deck.presenting.value && index != null) {
      _deck.row.settle(index.toDouble(), ShellSprings.appStrip);
      _deck.open.settle(0, ShellSprings.recentsClose);
      _deck.homeward.settle(0, ShellSprings.appStrip);
    }
    state = state.copyWith(
      foregroundObjectId: window.objectId,
      homeTransitionActive: false,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
    );
  }

  void _handleNativeWindowActivated(int windowId) {
    // Closing the native focused window can activate its neighbor. Recents
    // keeps ownership of presentation until the user selects a card or leaves;
    // an automatic focus fallback must not interrupt the removal reflow.
    if (state.overviewVisible) {
      return;
    }
    for (final window in state.windows) {
      if (window.windowId == windowId && window.isUserApp) {
        final appId = AppLaunchRequest.normalizeAppId(window.appId);
        if (_backgroundLaunchAppIds.remove(appId)) {
          return;
        }
        // Activation of the switch target confirms it and changes nothing
        // on screen, even while a swipe moves it. Any other app taking focus
        // ends the switch sequence.
        if (window.objectId != state.foregroundObjectId) {
          _releaseAppSwitchOrder();
          _activateWindowInShell(window);
        }
        return;
      }
    }
  }

  /// Lets go of the row of apps, continuing [velocity] in logical pixels per
  /// second, rightward positive. A flick goes on to the next app in its
  /// direction; a slower release goes to the app it was pulled toward far
  /// enough, or back. The app it settles on comes to the front at once.
  void releaseRow(double velocity) {
    final geometry = _deck.geometry;
    final row = _deck.row;
    final holding = _hold == _DeckHold.row;
    // The row is let go below. A lift the swipe began with, before it
    // turned into a sideways flick, falls back with the gesture's end.
    if (holding) _hold = _DeckHold.none;
    if (_deck.length == 0 || geometry.isEmpty) {
      resetGestureDrag();
      return;
    }
    if (!holding) _takeRowEnds();
    final start = (holding ? row.grabbedAt : row.target).roundToDouble();
    final position = row.value;
    final rate = geometry.rowDelta(velocity, _deck.open.value);
    var target = velocity.abs() > _switchFlickVelocity
        ? (rate > 0
              ? position.floorToDouble() + 1
              : position.ceilToDouble() - 1)
        : (geometry.rowTravel(position - start, _deck.open.value)).abs() >
              _switchDistance
        ? start + (position - start).sign
        : start;
    target = target.clamp(_rowLow, _rowHigh);
    row.settle(target, ShellSprings.appStrip, velocity: rate);
    resetGestureDrag();
    _showRowApp(target.round());
  }

  /// The finger takes the deck where it is, along the axis it moves on: a
  /// lift takes how far recents is open, a sideways swipe the row.
  void _takeDeck() {
    final current = state;
    if (current.launchTransitionActive ||
        current.overviewVisible ||
        current.lockLayerVisible ||
        _deck.geometry.isEmpty) {
      return;
    }
    final fromApp = current.foregroundWindow != null;
    final lift = _gestureAxis == _GestureAxis.vertical;
    _finishNearRest();
    if (!fromApp) _takeFromHome(lift: lift);
    if (lift) {
      _holdFromApp = fromApp;
      _liftCaught = _deck.presenting.value;
      if (fromApp && !_deck.presenting.value) {
        // A lift takes the apps in the order they were last used, not in
        // a quick switch's; the others wait aside until recents arms.
        _releaseAppSwitchOrder();
        _deck.attached.jump(0);
      }
      if (!fromApp && !_deck.presenting.value) _deck.enterFromHome();
      // From home the finger slides recents in, or catches it sliding out;
      // otherwise it shrinks the apps into recents.
      if (!fromApp && _deck.homeward.value > 0) {
        _deck.homeward.grab();
        _hold = _DeckHold.homeward;
      } else {
        _deck.open.grab();
        _hold = _DeckHold.open;
      }
    } else if (_deck.length > 0) {
      _deck.attached.settle(1, ShellSprings.appStrip);
      _deck.row.grab();
      _takeRowEnds();
      _hold = _DeckHold.row;
    }
  }

  /// A motion that looks finished is: a new gesture starts from rest, with
  /// the apps in the order they were last used.
  void _finishNearRest() {
    if (_deck.presenting.value && _deck.nearRest) _deck.finish();
  }

  /// The lift has pulled far enough to open recents on release: the other
  /// apps come in beside the lifted one, and leave again if it drops back.
  void armRecents(bool armed) {
    if (_hold != _DeckHold.open || !_holdFromApp) return;
    _deck.attached.settle(armed ? 1 : 0, ShellSprings.appStrip);
  }

  /// Home takes the deck back from an app still flying into its icon, or a
  /// sideways swipe takes it from recents leaving for home: the flight ends
  /// where it is, and the deck starts over from home. A lift catches
  /// leaving recents and brings it back.
  void _takeFromHome({required bool lift}) {
    final leaving = _deck.homeward.target == 1;
    final flew = _deck.flying != null || _deck.hidden != null;
    if (!flew && (lift || !leaving)) return;
    _deck.recallFlight();
    // At rest the deck lays itself out on home again.
    _deck.finish();
  }

  /// One app either way from where the row was, and home past the newest
  /// app only from home.
  void _takeRowEnds() {
    final start = _deck.row.target.roundToDouble();
    if (state.foregroundWindow == null) _deck.homeInRow = true;
    final last = _deck.homeInRow ? _deck.length.toDouble() : _deck.length - 1.0;
    _rowLow = math.max(0.0, start - 1);
    _rowHigh = math.max(_rowLow, math.min(last, start + 1));
  }

  void _moveDeck(Offset visualDrag) {
    final geometry = _deck.geometry;
    switch (_hold) {
      case _DeckHold.none:
        return;
      case _DeckHold.open:
        final lift =
            -visualDrag.dy / geometry.liftTravel(fromApp: _holdFromApp);
        _deck.open.hold((_deck.open.grabbedAt + lift).clamp(0.0, 1.0));
      case _DeckHold.homeward:
        final lift = -visualDrag.dy / geometry.liftTravel(fromApp: false);
        _deck.homeward.hold((_deck.homeward.grabbedAt - lift).clamp(0.0, 1.0));
      case _DeckHold.row:
        final open = _deck.open.value;
        final position =
            _deck.row.grabbedAt + geometry.rowDelta(visualDrag.dx, open);
        _deck.row.hold(_stretchRow(position, geometry.strideAt(open)));
    }
  }

  /// Past its ends the row stretches elastically: ever smaller steps toward
  /// one more screen width.
  double _stretchRow(double position, double stride) {
    final edge = position.clamp(_rowLow, _rowHigh).toDouble();
    final past = (position - edge) * stride;
    final extent = _deck.geometry.size.width;
    if (past == 0 || extent <= 0 || stride <= 0) return edge;
    const resistance = 0.55;
    final stretch = 1 - 1 / (past.abs() * resistance / extent + 1);
    return edge + past.sign * stretch * extent / stride;
  }

  /// Progress per second toward recents for a finger released at
  /// [velocity], in logical pixels per second, negative upward.
  double _openRate(double velocity) {
    final fromApp = switch (_hold) {
      _DeckHold.open => _holdFromApp,
      _DeckHold.homeward => false,
      _ => state.foregroundWindow != null,
    };
    return (-velocity / _deck.geometry.liftTravel(fromApp: fromApp)).clamp(
      -6.0,
      6.0,
    );
  }

  /// The row heads for the app at [index], or home one past the newest app:
  /// it comes to the front now, while the row is still on its way.
  void _showRowApp(int index) {
    final id = index >= 0 && index < _deck.length ? _deck.order[index] : null;
    if (id == state.foregroundObjectId) return;
    if (id == null) {
      state = state.copyWith(clearForegroundObjectId: true);
      return;
    }
    final window = state.openAppWindowsByObjectId[id];
    if (window == null) return;
    _backgroundLaunchAppIds.remove(
      AppLaunchRequest.normalizeAppId(window.appId),
    );
    final order = _deck.order;
    final open = state.openAppWindowsByObjectId;
    state = state.copyWith(
      // Raising each app the row reaches must not reorder the row.
      appSwitchOrder:
          order.length == open.length && order.every(open.containsKey)
          ? order
          : null,
      foregroundObjectId: id,
      clearLaunchingObjectId: true,
    );
    _holdAppSwitchOrder();
    _platform.focusWindow(window);
  }

  /// The deck at rest: the row is the frozen switch order while it lasts,
  /// else the stacking order, and the screen is on the app in front, or on
  /// home past the newest app.
  void _arrangeDeck() {
    if (_deck.presenting.value) return;
    final current = state;
    final open = current.openAppWindowsByObjectId;
    final source =
        _appSwitchOrderMatchesOpenApps() && current.appSwitchOrder.isNotEmpty
        ? current.appSwitchOrder
        : _recencyOrder();
    final order = [
      for (final id in source)
        if (open.containsKey(id) && !_dismissedIds.contains(id)) id,
    ];
    final front = order.indexOf(current.foregroundObjectId ?? -1);
    _deck.arrange(order, rowAt: (front < 0 ? order.length : front).toDouble());
  }

  /// The row while the deck presents: its own order, without the apps that
  /// closed, and new apps at the end.
  List<int> _presentedOrder() {
    final open = state.openAppWindowsByObjectId;
    final kept = [
      for (final id in _deck.order)
        if (open.containsKey(id) && !_dismissedIds.contains(id)) id,
    ];
    return [
      ...kept,
      for (final window in state.openAppWindows)
        if (!kept.contains(window.objectId) &&
            !_dismissedIds.contains(window.objectId))
          window.objectId,
    ];
  }

  void _deckPresentingChanged() {
    if (_deck.presenting.value) return;
    _arrangeDeck();
  }

  /// Keeps the frozen order while switches follow one another. Input to the
  /// app does not pass through the shell, so only a quiet period ends the
  /// sequence; the current app then counts as the most recent.
  void _holdAppSwitchOrder() {
    _appSwitchOrderTimer?.cancel();
    final generation = _buildGeneration;
    _appSwitchOrderTimer = Timer(_appSwitchOrderHold, () {
      _appSwitchOrderTimer = null;
      if (!isBuildGenerationActive(generation)) return;
      // A swipe in progress keeps the order its target came from.
      if (state.gesture != GestureDragPhase.idle ||
          _hold != _DeckHold.none ||
          _deck.presenting.value) {
        _holdAppSwitchOrder();
      } else {
        _releaseAppSwitchOrder();
      }
    });
  }

  void _releaseAppSwitchOrder() {
    _appSwitchOrderTimer?.cancel();
    _appSwitchOrderTimer = null;
    if (state.appSwitchOrder.isNotEmpty) {
      state = state.copyWith(appSwitchOrder: const <int>[]);
    }
  }

  bool _appSwitchOrderMatchesOpenApps() {
    final order = state.appSwitchOrder;
    final open = state.openAppWindowsByObjectId;
    return order.length == open.length && order.every(open.containsKey);
  }

  void completeLaunchTransition(int requestId, int objectId) {
    if (state.launchRequest?.requestId != requestId ||
        state.launchingObjectId != objectId) {
      return;
    }

    _launchRequestTimer?.cancel();
    _launchRequestTimer = null;
    state = state.copyWith(
      clearLaunchRequest: true,
      clearLaunchingObjectId: true,
    );
  }

  void updateGestureDrag(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }

    _rawGestureDrag += delta;
    final undecided = _gestureAxis == _GestureAxis.undecided;
    _lockGestureAxis();
    if (undecided && _gestureAxis != _GestureAxis.undecided) _takeDeck();
    final visual = _visualGestureDrag(_rawGestureDrag);
    _moveDeck(visual);
    _moveGesture(visual);
  }

  /// Ends the bottom gesture without a decision: whatever its finger holds
  /// returns, continuing [releaseVelocity] (logical pixels per second).
  void resetGestureDrag({double releaseVelocity = 0}) {
    _gestureReleaseVelocity = releaseVelocity;
    _endFingerGesture(releaseVelocity: releaseVelocity);
    _moveGesture(Offset.zero);
  }

  /// Forgets the finger. A lift it still holds closes back into the app, a
  /// row it holds settles back on the app it came from. This is the only
  /// place a hold ends: whatever the gesture became, nothing stays held.
  void _endFingerGesture({double releaseVelocity = 0}) {
    switch (_hold) {
      case _DeckHold.none:
        break;
      case _DeckHold.open:
        final rate = _openRate(releaseVelocity);
        _deck.open.settle(
          0,
          ShellSprings.recentsClose,
          velocity: rate < 0 ? rate : 0,
        );
      case _DeckHold.homeward:
        final rate = _openRate(releaseVelocity);
        _deck.homeward.settle(
          1,
          ShellSprings.recentsClose,
          velocity: rate < 0 ? -rate : 0,
        );
      case _DeckHold.row:
        _deck.row.settle(
          _deck.row.grabbedAt.roundToDouble(),
          ShellSprings.appStrip,
        );
    }
    _hold = _DeckHold.none;
    _rawGestureDrag = Offset.zero;
    _gestureLockOrigin = Offset.zero;
    _gestureAxis = _GestureAxis.undecided;
  }

  /// Commits a phase change to the state before moving the layers, so a
  /// layer that a new phase mounts starts from the new drag.
  void _moveGesture(Offset visualDrag) {
    final phase = GestureDragPhase.of(visualDrag);
    if (phase != state.gesture) {
      state = state.copyWith(gesture: phase);
    }
    _gestureDrag.value = visualDrag;
  }

  void openQuickSettings({double releaseVelocity = 0}) {
    if (state.quickSettingsVisible &&
        !state.quickSettingsDragged &&
        !state.quickSettingsDragActive) {
      return;
    }

    _quickSettingsReleaseVelocity = releaseVelocity;
    _endFingerGesture();
    // Recents stays open beneath the shade, as on Android.
    state = state.copyWith(
      quickSettingsVisible: true,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
      gesture: GestureDragPhase.idle,
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
    );
  }

  /// Opens the shade on its notification page.
  void openNotificationShade() {
    _shadeOpensNotifications = true;
    openQuickSettings();
  }

  void closeQuickSettings({double releaseVelocity = 0}) {
    if (!state.quickSettingsVisible &&
        !state.quickSettingsDragged &&
        !state.quickSettingsDragActive) {
      return;
    }

    _quickSettingsReleaseVelocity = releaseVelocity;
    state = state.copyWith(
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
    );
  }

  void startQuickSettingsDrag({double? progress}) {
    // A drag can interrupt the settling spring. Continue from the painted
    // position supplied by the shade rather than jumping to its target state.
    final initialProgress =
        (progress ??
                (state.quickSettingsVisible ? 1.0 : _quickSettingsDrag.value))
            .clamp(0.0, 1.0)
            .toDouble();
    _quickSettingsDragStartedOpen = initialProgress >= 1.0;
    _quickSettingsDragMoved = false;
    // The shade follows the drag from its first frame.
    _quickSettingsDrag.value = initialProgress;
    state = state.copyWith(
      quickSettingsDragged: initialProgress > 0.0,
      quickSettingsVisible: false,
      quickSettingsDragActive: true,
    );
  }

  void updateQuickSettingsDrag(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }

    _quickSettingsDragMoved = true;
    const distance = ReferenceShellMetrics.quickSettingsDragDistance;
    final current = state.quickSettingsVisible
        ? distance
        : _quickSettingsDrag.value * distance;
    final dy = (current + delta.dy).clamp(0.0, distance).toDouble();
    if (dy == current && !state.quickSettingsVisible) {
      return;
    }

    _quickSettingsDrag.value = dy / distance;
    // The shell state changes only when the drag takes over or crosses
    // closed, never on every frame of it.
    final dragged = dy > 0.0;
    final shell = state;
    if (shell.quickSettingsVisible ||
        shell.quickSettingsDragged != dragged ||
        !shell.quickSettingsDragActive ||
        shell.gesture != GestureDragPhase.idle ||
        shell.edgePanelVisible ||
        shell.edgePanelDrag != Offset.zero ||
        shell.edgePanelDragActive) {
      state = shell.copyWith(
        quickSettingsVisible: false,
        quickSettingsDragged: dragged,
        quickSettingsDragActive: true,
        gesture: GestureDragPhase.idle,
        edgePanelVisible: false,
        edgePanelDrag: Offset.zero,
        edgePanelDragActive: false,
      );
    }
  }

  void endQuickSettingsDrag(double velocity) {
    final drag = state.quickSettingsVisible && !_quickSettingsDragMoved
        ? ReferenceShellMetrics.quickSettingsDragDistance
        : _quickSettingsDrag.value *
              ReferenceShellMetrics.quickSettingsDragDistance;
    final flickOpen = velocity >= _quickSettingsFlickVelocity;
    final flickClose = velocity <= -_quickSettingsFlickVelocity;
    final shouldOpen =
        !flickClose &&
        ((_quickSettingsDragStartedOpen && !_quickSettingsDragMoved) ||
            drag >= _quickSettingsOpenDistance ||
            flickOpen);
    _quickSettingsDragStartedOpen = false;
    _quickSettingsDragMoved = false;
    if (shouldOpen) {
      openQuickSettings(releaseVelocity: velocity);
    } else {
      closeQuickSettings(releaseVelocity: velocity);
    }
  }

  void openEdgePanel() {
    if (!state.locked && ref.read(inputDeckProvider).activeOutput != null) {
      return;
    }
    if (state.edgePanelVisible &&
        state.edgePanelDrag == Offset.zero &&
        !state.edgePanelDragActive) {
      return;
    }

    _endFingerGesture();
    state = state.copyWith(
      edgePanelVisible: true,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
    );
  }

  void closeEdgePanel() {
    if (!state.edgePanelVisible &&
        state.edgePanelDrag == Offset.zero &&
        !state.edgePanelDragActive) {
      return;
    }

    state = state.copyWith(
      edgePanelVisible: false,
      edgePanelDrag: Offset.zero,
      edgePanelDragActive: false,
    );
  }

  void updateEdgePanelViewportScroll(double delta, double maxScroll) {
    if (!state.edgePanelVisible || delta == 0.0 || maxScroll <= 0.0) {
      return;
    }

    final next = (state.edgePanelViewportScroll + delta)
        .clamp(0.0, maxScroll)
        .toDouble();
    if (next == state.edgePanelViewportScroll) {
      return;
    }

    state = state.copyWith(edgePanelViewportScroll: next);
  }

  void startEdgePanelDrag() {
    _edgePanelDismissalSerial = _lastTextInput?.active == true
        ? _lastTextInput!.activationSerial
        : null;
    _edgePanelDragStartedOpen =
        state.edgePanelVisible || state.edgePanelDragProgress >= 1.0;
    _edgePanelDragMoved = false;
    state = state.copyWith(
      edgePanelDrag: Offset.zero,
      edgePanelVisible: state.edgePanelVisible,
      edgePanelDragActive: true,
    );
  }

  void updateEdgePanelDrag(Offset delta) {
    if (delta == Offset.zero) {
      return;
    }

    _edgePanelDragMoved = true;
    final current = state.edgePanelVisible
        ? ReferenceShellMetrics.edgePanelDragDistance
        : state.edgePanelDrag.dy;
    final dy = (current - delta.dy)
        .clamp(0.0, ReferenceShellMetrics.edgePanelDragDistance)
        .toDouble();
    if (dy == state.edgePanelDrag.dy) {
      return;
    }

    state = state.copyWith(
      edgePanelVisible: false,
      edgePanelDrag: Offset(0.0, dy),
      edgePanelDragActive: true,
      overviewVisible: false,
      gesture: GestureDragPhase.idle,
      quickSettingsVisible: false,
      quickSettingsDragged: false,
      quickSettingsDragActive: false,
    );
  }

  void endEdgePanelDrag(double velocity) {
    final drag = state.edgePanelVisible && !_edgePanelDragMoved
        ? ReferenceShellMetrics.edgePanelDragDistance
        : state.edgePanelDrag.dy;
    final flickOpen = velocity <= -_edgePanelFlickVelocity;
    final flickClose = velocity >= _edgePanelFlickVelocity;
    final shouldOpen =
        !flickClose &&
        ((_edgePanelDragStartedOpen && !_edgePanelDragMoved) ||
            drag >= ReferenceShellMetrics.edgePanelOpenDistance ||
            flickOpen);
    // Only a completed user dismissal sends feedback. Automatic hides and
    // animation frames must not ask the application to dismiss another editor.
    if (!shouldOpen &&
        _edgePanelDragStartedOpen &&
        _edgePanelDismissalSerial != null) {
      _bridge.dismissKeyboardPanel(_edgePanelDismissalSerial!);
    }
    _edgePanelDismissalSerial = null;
    _edgePanelDragStartedOpen = false;
    _edgePanelDragMoved = false;
    if (shouldOpen) {
      openEdgePanel();
    } else {
      closeEdgePanel();
    }
  }

  Offset _visualGestureDrag(Offset rawDrag) {
    return switch (_gestureAxis) {
      _GestureAxis.horizontal => Offset(
        (rawDrag.dx - _gestureLockOrigin.dx)
            .clamp(
              -_gestureHorizontalVisualDistance,
              _gestureHorizontalVisualDistance,
            )
            .toDouble(),
        0.0,
      ),
      _GestureAxis.vertical => Offset(
        0.0,
        rawDrag.dy
            .clamp(-_gestureVisualDistance, _gestureVisualDistance)
            .toDouble(),
      ),
      _GestureAxis.undecided => Offset.zero,
    };
  }

  void _lockGestureAxis() {
    if (_gestureAxis != _GestureAxis.undecided) {
      return;
    }

    if (state.overviewVisible) {
      _gestureAxis = _GestureAxis.vertical;
      return;
    }

    final dx = _rawGestureDrag.dx.abs();
    final dy = _rawGestureDrag.dy.abs();
    if (dx < _gestureAxisLockDistance && dy < _gestureAxisLockDistance) {
      return;
    }

    if (dx > dy * _gestureAxisLockRatio) {
      _gestureAxis = _GestureAxis.horizontal;
      _gestureLockOrigin = _rawGestureDrag;
    } else if (dy > dx * _gestureAxisLockRatio) {
      _gestureAxis = _GestureAxis.vertical;
    }
  }

  void publishInputLayout(
    Size viewSize,
    ShellInteractionSnapshot interactions, {
    double topInset = 0.0,
    bool force = false,
  }) {
    if (force) _inputLayoutCoordinator.invalidate();
    final split = ref.read(phoneDeskProvider);
    _inputLayoutCoordinator.publish(
      state: state,
      viewSize: viewSize,
      interactions: interactions,
      topInset: topInset,
      appsMoving: _deck.presenting.value,
      sceneOrigin: split?.phoneRect.topLeft ?? Offset.zero,
      composer: split == null ? null : ref.read(phoneDeskInputComposerProvider),
    );
  }
}

enum _GestureAxis { undecided, horizontal, vertical }

enum _DeckHold { none, open, homeward, row }
