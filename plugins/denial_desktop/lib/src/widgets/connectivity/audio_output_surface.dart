import 'package:flutter/material.dart' show Icons, TextButton;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart' show AudioOutputDevice;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../../state/quick_settings.dart';

/// Output-device chooser opened from the volume row. Laid out like the Wi-Fi
/// details sheet: identity header, square actions and rounded option cards.
class AudioOutputSurface extends ConsumerWidget {
  const AudioOutputSurface({required this.onClose, super.key});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(audioDevicesProvider);
    final controller = ref.read(audioDevicesProvider.notifier);
    final theme = ShellTheme.of(context);
    final active = state.activeDevice;
    return SafeArea(
      minimum: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540, maxHeight: 720),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.panelColor(context.shellColors.panelBackground),
              borderRadius: BorderRadius.circular(theme.panelRadius),
              border: Border.all(color: context.shellColors.hairline),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.accent.withValues(alpha: .12),
                        ),
                        child: Icon(
                          Icons.volume_up_rounded,
                          size: 19,
                          color: theme.accent,
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.settingsAudioOutputTitle,
                              style: ShellText.statusClock.copyWith(
                                fontSize: 20,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              active == null
                                  ? ''
                                  : l10n.settingsAudioOutputInUse(
                                      active.description,
                                    ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ShellText.base.copyWith(
                                color: context.shellColors.textTertiary,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _SurfaceAction(
                        label: l10n.settingsRefresh,
                        icon: Icons.refresh_rounded,
                        onPressed: state.loading ? null : controller.refresh,
                      ),
                      const SizedBox(width: 7),
                      _SurfaceAction(
                        label: l10n.actionDismiss,
                        icon: Icons.close_rounded,
                        onPressed: onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // The device list takes the leftover height so the sheet
                  // matches the Wi-Fi details sheet instead of hugging its
                  // content.
                  Expanded(
                    child: SingleChildScrollView(
                      child: state.devices.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                state.loading
                                    ? l10n.settingsAudioOutputLoading
                                    : l10n.settingsAudioOutputUnavailable,
                                style: ShellText.base.copyWith(
                                  color: context.shellColors.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            )
                          : Column(
                              children: [
                                for (final (index, device)
                                    in state.devices.indexed) ...[
                                  if (index > 0) const SizedBox(height: 10),
                                  _AudioOutputOption(
                                    device: device,
                                    busy: state.changing,
                                    onSelected: () {
                                      controller.select(device.name);
                                      Future<void>.delayed(
                                        const Duration(milliseconds: 500),
                                        () {
                                          ref
                                              .read(
                                                quickSettingsProvider.notifier,
                                              )
                                              .refreshVolume();
                                        },
                                      );
                                      onClose();
                                    },
                                  ),
                                ],
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      l10n.settingsAudioOutputNote,
                      style: ShellText.base.copyWith(
                        color: context.shellColors.textTertiary,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SurfaceAction extends StatelessWidget {
  const _SurfaceAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: context.shellColors.surfaceContainerHigh,
            borderRadius: context.shellTheme.borderRadius(10),
          ),
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? context.shellColors.panelText
                : context.shellColors.textTertiary,
          ),
        ),
      ),
    );
  }
}

class _AudioOutputOption extends StatelessWidget {
  const _AudioOutputOption({
    required this.device,
    required this.busy,
    required this.onSelected,
  });

  final AudioOutputDevice device;
  final bool busy;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = ShellTheme.of(context).accent;
    final enabled = device.available && !device.active && !busy;
    final status = device.active
        ? l10n.audioOutputActive
        : device.available
        ? l10n.audioOutputReady
        : l10n.settingsAudioOutputUnavailable;
    return Semantics(
      button: true,
      selected: device.active,
      label: device.description,
      child: TextButton(
        onPressed: enabled ? onSelected : null,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 64),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          foregroundColor: context.shellColors.panelText,
          backgroundColor: device.active
              ? accent.withValues(alpha: .12)
              : context.shellColors.surfaceContainerLow,
          alignment: AlignmentDirectional.centerStart,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: device.active
                  ? accent.withValues(alpha: .45)
                  : const Color(0x00000000),
            ),
          ),
        ),
        child: SizedBox(
          height: 64,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.shellColors.surfaceContainerHigh,
                ),
                child: Icon(
                  device.active
                      ? Icons.volume_up_rounded
                      : Icons.speaker_rounded,
                  size: 18,
                  color: device.active
                      ? accent
                      : context.shellColors.textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      device.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ShellText.base.copyWith(
                        color: context.shellColors.panelText,
                        fontSize: 13.5,
                        fontWeight: device.active
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ShellText.base.copyWith(
                        color: context.shellColors.textTertiary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 19,
                height: 19,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: device.active
                      ? context.shellColors.surfaceContainerLow
                      : const Color(0x00000000),
                  border: Border.all(
                    color: device.active
                        ? accent
                        : context.shellColors.textTertiary,
                    width: device.active ? 5.5 : 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
