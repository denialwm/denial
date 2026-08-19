import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../models/shortcut_configuration.dart';

String settingsShortcutDisplay(BuildContext context, String shortcut) {
  if (shortcut == 'ThreeFingerSwipeUp') {
    return context.l10n.settingsShortcutGestureThreeFingerSwipeUp.toUpperCase();
  }
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
    DenialShortcutSpawnTarget(:final command) =>
      command.map(_displayCommandArgument).join(' '),
    DenialShortcutSpawnShTarget(:final command) => command,
  };
}

IconData settingsShortcutTargetIcon(DenialShortcutBinding binding) {
  return switch (binding.target) {
    DenialShortcutActionTarget(:final action) => settingsShortcutActionIcon(
      action,
    ),
    DenialShortcutSpawnTarget() => Icons.terminal_rounded,
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
    DenialShortcutAction.openOverview => Icons.view_quilt_outlined,
    DenialShortcutAction.toggleVerticalMaximize => Icons.height_rounded,
    DenialShortcutAction.windowSwitcher => Icons.flip_to_front_rounded,
    DenialShortcutAction.openClipboard => Icons.content_paste_rounded,
    DenialShortcutAction.captureRegion => Icons.crop_free_rounded,
    DenialShortcutAction.closeWindow => Icons.close_rounded,
    DenialShortcutAction.minimizeWindow => Icons.minimize_rounded,
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
