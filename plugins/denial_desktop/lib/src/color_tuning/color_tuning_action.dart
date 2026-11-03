import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_flutter_sdk/localization.dart';

/// Opens or closes the color tuning editor. deniald runs it for
/// `denialctl color tune`, and again once a shell restarted to ready the
/// desktop; shortcuts can bind it too.
final class ColorTuningAction implements ShellAction {
  const ColorTuningAction(this._toggle);

  /// deniald's name for it, `COLOR_TUNING_ACTION`.
  static const String actionId = 'denial_desktop.colorTuning';

  final VoidCallback _toggle;

  @override
  String get id => actionId;

  @override
  String get provider => 'Desktop';

  @override
  String label(BuildContext context) => context.l10n.colorTuningAction;

  @override
  String description(BuildContext context) => '';

  @override
  FutureOr<void> invoke(ShellActionContext context) {
    _toggle();
  }
}
