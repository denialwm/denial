import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_profile.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/system_services.dart';

/// "Later" on the SIM keypad: the lock screen stops asking until the SIM
/// leaves its locked state, so a modem restart that locks it again asks again.
final simPinDeferralProvider = NotifierProvider<SimPinDeferral, bool>(
  SimPinDeferral.new,
);

class SimPinDeferral extends Notifier<bool> {
  @override
  bool build() {
    ref.listen<bool>(
      mobileNetworkProvider.select((network) => network.value?.locked ?? false),
      (_, locked) {
        if (!locked) state = false;
      },
    );
    return false;
  }

  void defer() => state = true;
}

/// The mobile shell owes the modem a SIM PIN: the session stays on the lock
/// screen, which shows the SIM keypad before any device credential.
final simPinPendingProvider = Provider<bool>((ref) {
  if (ref.watch(referenceShellProfileProvider) !=
      ReferenceShellProfile.mobile) {
    return false;
  }
  final network = ref.watch(mobileNetworkProvider).value;
  return network != null &&
      network.locked &&
      network.simPath != null &&
      !ref.watch(simPinDeferralProvider);
});

/// Locks the session whenever a SIM PIN is pending, including after a native
/// fingerprint unlock: device authentication never answers or defers a SIM.
/// Unlocking the SIM never unlocks the session either.
class MobileSimLockGuard extends ConsumerStatefulWidget {
  const MobileSimLockGuard({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<MobileSimLockGuard> createState() => _MobileSimLockGuardState();
}

final _simLockDueProvider = Provider<bool>(
  (ref) =>
      ref.watch(simPinPendingProvider) &&
      !ref.watch(referenceShellProvider.select((state) => state.locked)),
);

class _MobileSimLockGuardState extends ConsumerState<MobileSimLockGuard> {
  @override
  void initState() {
    super.initState();
    ref.listenManual<bool>(_simLockDueProvider, (_, due) {
      if (due) ref.read(referenceShellProvider.notifier).lock();
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
