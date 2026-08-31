import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../models/shortcut_configuration.dart';

String settingsShortcutDisplay(BuildContext context, String shortcut) {
  final gesture = switch (shortcut) {
    'ThreeFingerSwipeUp' =>
      context.l10n.settingsShortcutGestureThreeFingerSwipeUp,
    'ThreeFingerSwipeLeft' =>
      context.l10n.settingsShortcutGestureThreeFingerSwipeLeft,
    'ThreeFingerSwipeRight' =>
      context.l10n.settingsShortcutGestureThreeFingerSwipeRight,
    _ => null,
  };
  if (gesture != null) return gesture.toUpperCase();
  return shortcut
      .split('+')
      .map((part) {
        return switch (part) {
          'Super' || 'Ctrl' || 'Alt' || 'Shift' => part.toUpperCase(),
          _ => part,
        };
      })
      .join(' + ');
}

String settingsShortcutActionLabel(
  BuildContext context,
  DenialShortcutAction action,
) {
  final l10n = context.l10n;
  return switch (action) {
    DenialShortcutAction.shutdown => l10n.settingsShortcutActionShutdown,
    DenialShortcutAction.openApplications =>
      l10n.settingsShortcutActionOpenApplications,
    DenialShortcutAction.openDashboard =>
      l10n.settingsShortcutActionOpenDashboard,
    DenialShortcutAction.openOverview =>
      l10n.settingsShortcutActionOpenOverview,
    DenialShortcutAction.toggleVerticalMaximize =>
      l10n.settingsShortcutActionToggleVerticalMaximize,
    DenialShortcutAction.windowSwitcher =>
      l10n.settingsShortcutActionWindowSwitcher,
    DenialShortcutAction.openClipboard =>
      l10n.settingsShortcutActionOpenClipboard,
    DenialShortcutAction.captureRegion =>
      l10n.settingsShortcutActionCaptureRegion,
    DenialShortcutAction.closeWindow => l10n.settingsShortcutActionCloseWindow,
    DenialShortcutAction.minimizeWindow =>
      l10n.settingsShortcutActionMinimizeWindow,
    DenialShortcutAction.minimizeAllWindows =>
      l10n.settingsShortcutActionMinimizeAllWindows,
    DenialShortcutAction.toggleMaximize =>
      l10n.settingsShortcutActionToggleMaximize,
    DenialShortcutAction.toggleFullscreen =>
      l10n.settingsShortcutActionToggleFullscreen,
    DenialShortcutAction.releasePointer =>
      l10n.settingsShortcutActionReleasePointer,
    DenialShortcutAction.lockScreen => l10n.settingsShortcutActionLockScreen,
    DenialShortcutAction.volumeUp => l10n.settingsShortcutActionVolumeUp,
    DenialShortcutAction.volumeDown => l10n.settingsShortcutActionVolumeDown,
    DenialShortcutAction.volumeMute => l10n.settingsShortcutActionVolumeMute,
    DenialShortcutAction.brightnessUp =>
      l10n.settingsShortcutActionBrightnessUp,
    DenialShortcutAction.brightnessDown =>
      l10n.settingsShortcutActionBrightnessDown,
    DenialShortcutAction.nextKeyboardLayout =>
      l10n.settingsShortcutActionNextKeyboardLayout,
    DenialShortcutAction.previousKeyboardLayout =>
      l10n.settingsShortcutActionPreviousKeyboardLayout,
    DenialShortcutAction.openSettings =>
      l10n.settingsShortcutActionOpenSettings,
    DenialShortcutAction.focusLeft => l10n.settingsShortcutActionFocusLeft,
    DenialShortcutAction.focusRight => l10n.settingsShortcutActionFocusRight,
    DenialShortcutAction.focusUp => l10n.settingsShortcutActionFocusUp,
    DenialShortcutAction.focusDown => l10n.settingsShortcutActionFocusDown,
    DenialShortcutAction.swapLeft => l10n.settingsShortcutActionSwapLeft,
    DenialShortcutAction.swapRight => l10n.settingsShortcutActionSwapRight,
    DenialShortcutAction.swapUp => l10n.settingsShortcutActionSwapUp,
    DenialShortcutAction.swapDown => l10n.settingsShortcutActionSwapDown,
  };
}

String settingsShortcutTargetLabel(
  BuildContext context,
  DenialShortcutBinding binding,
) {
  return switch (binding.target) {
    DenialShortcutActionTarget(:final action) => settingsShortcutActionLabel(
      context,
      action,
    ),
    DenialShortcutSpawnTarget(:final command, :final desktopFileId) =>
      desktopFileId == null
          ? command.map(_displayCommandArgument).join(' ')
          : context.l10n.settingsShortcutApplicationTarget(desktopFileId),
    DenialShortcutSpawnShTarget(:final command) => command,
  };
}

IconData settingsShortcutTargetIcon(DenialShortcutBinding binding) {
  return switch (binding.target) {
    DenialShortcutActionTarget(:final action) => settingsShortcutActionIcon(
      action,
    ),
    DenialShortcutSpawnTarget(:final desktopFileId) =>
      desktopFileId == null ? Icons.terminal_rounded : Icons.apps_rounded,
    DenialShortcutSpawnShTarget() => Icons.code_rounded,
  };
}

String _displayCommandArgument(String argument) {
  if (argument.isNotEmpty && !argument.contains(RegExp(r'''[\s'"\\]'''))) {
    return argument;
  }
  return '"${argument.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

IconData settingsShortcutActionIcon(DenialShortcutAction action) {
  return switch (action) {
    DenialShortcutAction.shutdown => Icons.power_settings_new_rounded,
    DenialShortcutAction.openApplications => Icons.apps_rounded,
    DenialShortcutAction.openDashboard => Icons.dashboard_rounded,
    DenialShortcutAction.openOverview => Icons.view_quilt_outlined,
    DenialShortcutAction.toggleVerticalMaximize => Icons.height_rounded,
    DenialShortcutAction.windowSwitcher => Icons.flip_to_front_rounded,
    DenialShortcutAction.openClipboard => Icons.content_paste_rounded,
    DenialShortcutAction.captureRegion => Icons.crop_free_rounded,
    DenialShortcutAction.closeWindow => Icons.close_rounded,
    DenialShortcutAction.minimizeWindow => Icons.minimize_rounded,
    DenialShortcutAction.minimizeAllWindows =>
      Icons.keyboard_double_arrow_down_rounded,
    DenialShortcutAction.toggleMaximize => Icons.crop_square_rounded,
    DenialShortcutAction.toggleFullscreen => Icons.fullscreen_rounded,
    DenialShortcutAction.releasePointer => Icons.mouse_outlined,
    DenialShortcutAction.lockScreen => Icons.lock_outline_rounded,
    DenialShortcutAction.volumeUp => Icons.volume_up_rounded,
    DenialShortcutAction.volumeDown => Icons.volume_down_rounded,
    DenialShortcutAction.volumeMute => Icons.volume_off_rounded,
    DenialShortcutAction.brightnessUp => Icons.brightness_high_rounded,
    DenialShortcutAction.brightnessDown => Icons.brightness_low_rounded,
    DenialShortcutAction.nextKeyboardLayout =>
      Icons.keyboard_arrow_right_rounded,
    DenialShortcutAction.previousKeyboardLayout =>
      Icons.keyboard_arrow_left_rounded,
    DenialShortcutAction.openSettings => Icons.settings_rounded,
    DenialShortcutAction.focusLeft => Icons.keyboard_arrow_left_rounded,
    DenialShortcutAction.focusRight => Icons.keyboard_arrow_right_rounded,
    DenialShortcutAction.focusUp => Icons.keyboard_arrow_up_rounded,
    DenialShortcutAction.focusDown => Icons.keyboard_arrow_down_rounded,
    DenialShortcutAction.swapLeft => Icons.arrow_back_rounded,
    DenialShortcutAction.swapRight => Icons.arrow_forward_rounded,
    DenialShortcutAction.swapUp => Icons.arrow_upward_rounded,
    DenialShortcutAction.swapDown => Icons.arrow_downward_rounded,
  };
}

String settingsShortcutInputCategoryLabel(
  BuildContext context,
  DenialShortcutInputCategory category,
) {
  final l10n = context.l10n;
  return switch (category) {
    DenialShortcutInputCategory.modifier =>
      l10n.settingsShortcutInputCategoryModifier,
    DenialShortcutInputCategory.navigation =>
      l10n.settingsShortcutInputCategoryNavigation,
    DenialShortcutInputCategory.editing =>
      l10n.settingsShortcutInputCategoryEditing,
    DenialShortcutInputCategory.punctuation =>
      l10n.settingsShortcutInputCategoryPunctuation,
    DenialShortcutInputCategory.function =>
      l10n.settingsShortcutInputCategoryFunction,
    DenialShortcutInputCategory.media =>
      l10n.settingsShortcutInputCategoryMedia,
    DenialShortcutInputCategory.hardware =>
      l10n.settingsShortcutInputCategoryHardware,
    DenialShortcutInputCategory.special =>
      l10n.settingsShortcutInputCategorySpecial,
    DenialShortcutInputCategory.gesture =>
      l10n.settingsShortcutInputCategoryGesture,
  };
}
