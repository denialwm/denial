import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/localization.dart';

/// The name of a finger as fprintd calls it.
String fingerprintLabel(BuildContext context, String finger) {
  final l10n = context.l10n;
  return switch (finger) {
    'left-thumb' => l10n.fingerprintLeftThumb,
    'left-index-finger' => l10n.fingerprintLeftIndex,
    'left-middle-finger' => l10n.fingerprintLeftMiddle,
    'left-ring-finger' => l10n.fingerprintLeftRing,
    'left-little-finger' => l10n.fingerprintLeftLittle,
    'right-thumb' => l10n.fingerprintRightThumb,
    'right-index-finger' => l10n.fingerprintRightIndex,
    'right-middle-finger' => l10n.fingerprintRightMiddle,
    'right-ring-finger' => l10n.fingerprintRightRing,
    'right-little-finger' => l10n.fingerprintRightLittle,
    _ => finger,
  };
}

/// What a fingerprint session's status says to the person.
String fingerprintStatus(
  BuildContext context,
  String status, {
  int retryMilliseconds = 0,
}) {
  final l10n = context.l10n;
  return switch (status) {
    'pin-not-configured' => l10n.fingerprintPinNotSet,
    'wrong-pin' => l10n.lockWrongPin,
    'rate-limited' => l10n.lockRetryInSeconds(
      (retryMilliseconds / 1000).ceil(),
    ),
    'expired' => l10n.fingerprintExpired,
    'preparing' => l10n.fingerprintPreparing,
    'started' || 'enroll-stage-passed' => l10n.fingerprintTouchSensor,
    'enroll-completed' => l10n.fingerprintEnrolled,
    'cancelled' => l10n.fingerprintCancelled,
    'enroll-duplicate' || 'already-enrolled' => l10n.fingerprintDuplicate,
    'enroll-retry-scan' ||
    'enroll-swipe-too-short' ||
    'enroll-too-fast' ||
    'enroll-finger-not-centered' ||
    'enroll-remove-and-retry' => l10n.fingerprintRetry,
    _ => l10n.fingerprintUnavailable,
  };
}

/// Whether a status is a failure rather than an enrollment prompt, which
/// stays beside the sensor's progress.
bool isFingerprintError(String status) => !const {
  'preparing',
  'started',
  'enroll-stage-passed',
  'enroll-completed',
  'cancelled',
  'enroll-retry-scan',
  'enroll-swipe-too-short',
  'enroll-too-fast',
  'enroll-finger-not-centered',
  'enroll-remove-and-retry',
}.contains(status);
