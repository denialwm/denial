import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';

import 'reference_shell_controller.dart';
import 'reference_shell_profile.dart';

/// The calls app's window, shown over the phone's lock screen.
///
/// While the phone is locked and a call notification of the calls app the
/// settings name stands, that app's window shows above the lock screen and
/// takes its touches; the keyboard stays with the lock screen. Denial applies
/// the same rule natively: it keeps the window running and routes touch to
/// it only then.
final overLockWindowProvider = Provider<DenialWindow?>((ref) {
  if (ref.watch(referenceShellProfileProvider) !=
      ReferenceShellProfile.mobile) {
    return null;
  }
  if (!ref.watch(referenceShellProvider.select((state) => state.locked))) {
    return null;
  }
  final callsApp = ref.watch(
    shellSettingsProvider.select((settings) => settings.lockScreen.callsApp),
  );
  final calling = ref.watch(
    desktopNotificationsProvider.select(
      (notifications) => notifications.active.values.any(
        (notification) =>
            notification.call && notification.desktopEntry == callsApp,
      ),
    ),
  );
  if (!calling) return null;
  return ref.watch(
    referenceShellProvider.select((state) {
      for (final window in state.windows) {
        if (window.appId == callsApp &&
            window.isUserApp &&
            !window.isLocalFlutter) {
          return window;
        }
      }
      return null;
    }),
  );
});
