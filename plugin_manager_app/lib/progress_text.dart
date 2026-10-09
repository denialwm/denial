import 'package:denial_flutter_sdk/localization.dart';

import 'localized_feedback.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import 'job_feedback.dart';

/// The clock keeps ticking even while a backend status request is waiting.
/// Announce real phase changes, not a new screen-reader message every second.
class ProgressText extends StatefulWidget {
  const ProgressText({required this.progress, this.style, super.key});
  final OperationProgress progress;
  final TextStyle? style;

  @override
  State<ProgressText> createState() => _ProgressTextState();
}

class _ProgressTextState extends State<ProgressText> {
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.progress.started != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: progressStage(context.l10n, widget.progress),
    excludeSemantics: true,
    child: Text(
      progressDescription(context.l10n, widget.progress, DateTime.now()),
      style: widget.style,
    ),
  );
}
