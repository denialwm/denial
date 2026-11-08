import 'package:denial_flutter_sdk/materials.dart';
import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/localization.dart';

/// Tells pages how the shell presents navigation. When navigation is hidden
/// behind an overlay, page headers offer a menu button that opens it.
class SettingsShellScope extends InheritedWidget {
  const SettingsShellScope({
    required this.navigationOverlay,
    required this.openNavigation,
    required super.child,
    super.key,
  });

  final bool navigationOverlay;
  final VoidCallback openNavigation;

  static SettingsShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsShellScope>();

  @override
  bool updateShouldNotify(SettingsShellScope oldWidget) =>
      navigationOverlay != oldWidget.navigationOverlay;
}

/// A page command rendered beside the page title. Commands stay reachable
/// without scrolling, matching the flat shell's fixed header.
class SettingsCommand extends StatelessWidget {
  const SettingsCommand({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 16),
    label: Text(label),
    style: TextButton.styleFrom(
      foregroundColor: context.applicationColors.foreground,
      backgroundColor: context.applicationColors.chrome,
      disabledBackgroundColor: context.applicationColors.chrome,
      minimumSize: const Size(0, 36),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      side: BorderSide(color: context.applicationColors.separator),
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
      shape: const StadiumBorder(),
    ),
  );
}

/// Error details open only on request. Dismissal lasts until the error changes
/// or clears, and does not alter the underlying settings operation.
class SettingsErrorNotice extends StatefulWidget {
  const SettingsErrorNotice({
    required this.message,
    this.onRetry,
    this.onDismiss,
    super.key,
  });

  final String? message;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  @override
  State<SettingsErrorNotice> createState() => _SettingsErrorNoticeState();
}

class _SettingsErrorNoticeState extends State<SettingsErrorNotice> {
  bool _dismissed = false;

  @override
  void didUpdateWidget(SettingsErrorNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message != oldWidget.message) _dismissed = false;
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    if (message == null || message.isEmpty || _dismissed) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: DenialMaterial(
        role: DenialMaterialRole.toolbar,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (widget.onRetry != null)
                    TextButton(
                      onPressed: widget.onRetry,
                      child: Text(l10n.commonRetry),
                    ),
                  IconButton(
                    tooltip: l10n.quickSettingsOpenDetails(l10n.commonError),
                    icon: const Icon(Icons.info_outline_rounded),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(l10n.commonError),
                        content: SingleChildScrollView(
                          child: SelectableText(message),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(l10n.actionDismiss),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.actionDismiss,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      setState(() => _dismissed = true);
                      widget.onDismiss?.call();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
