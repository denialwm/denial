import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../localization/denial_localizations.dart';
import '../services/audio_service.dart';
import '../state/audio_devices.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import '../widgets/shell_cursor.dart';

const dashboardAudioDeviceDropdownButtonKey = ValueKey<String>(
  'dashboard-audio-device-dropdown-button',
);

ValueKey<String> dashboardAudioDeviceOptionKey(String deviceName) =>
    ValueKey<String>('dashboard-audio-device-option-$deviceName');

class DashboardAudioDeviceDropdown extends StatefulWidget {
  const DashboardAudioDeviceDropdown({
    required this.state,
    required this.onRefresh,
    required this.onSelected,
    super.key,
  });

  final AudioDevicesState state;
  final VoidCallback onRefresh;
  final ValueChanged<String> onSelected;

  @override
  State<DashboardAudioDeviceDropdown> createState() =>
      _DashboardAudioDeviceDropdownState();
}

class _DashboardAudioDeviceDropdownState
    extends State<DashboardAudioDeviceDropdown> {
  var _expanded = false;
  var _hovered = false;
  var _focused = false;

  void _toggle() {
    if (widget.state.loading || widget.state.changing) {
      return;
    }
    if (_expanded) {
      _close();
      return;
    }
    widget.onRefresh();
    if (widget.state.devices.isNotEmpty) {
      setState(() => _expanded = true);
    }
  }

  void _close() {
    if (_expanded) {
      setState(() => _expanded = false);
    }
  }

  void _select(AudioOutputDevice device) {
    if (!device.available || device.active || widget.state.changing) {
      return;
    }
    _close();
    widget.onSelected(device.name);
  }

  @override
  void didUpdateWidget(covariant DashboardAudioDeviceDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_expanded && widget.state.devices.isEmpty) {
      _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = widget.state;
    final activeDevice = state.activeDevice;
    final enabled = !state.loading && !state.changing;
    final label =
        activeDevice?.description ??
        (state.loading
            ? l10n.desktopLoadingAudioOutputDevices
            : state.error != null
            ? l10n.desktopAudioOutputDevicesUnavailable
            : l10n.desktopNoAudioOutputDevices);
    final accent = ShellTheme.of(context).accentPalette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          button: true,
          enabled: enabled,
          expanded: _expanded,
          label: l10n.desktopSelectAudioOutputDevice,
          value: label,
          child: FocusableActionDetector(
            enabled: enabled,
            mouseCursor: enabled
                ? ShellMouseCursors.link
                : ShellMouseCursors.normal,
            onShowHoverHighlight: (hovered) =>
                setState(() => _hovered = hovered),
            onShowFocusHighlight: (focused) =>
                setState(() => _focused = focused),
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.escape):
                  _CloseAudioDeviceDropdownIntent(),
            },
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  _toggle();
                  return null;
                },
              ),
              _CloseAudioDeviceDropdownIntent:
                  CallbackAction<_CloseAudioDeviceDropdownIntent>(
                    onInvoke: (_) {
                      _close();
                      return null;
                    },
                  ),
            },
            child: GestureDetector(
              key: dashboardAudioDeviceDropdownButtonKey,
              behavior: HitTestBehavior.opaque,
              onTap: enabled ? _toggle : null,
              child: AnimatedContainer(
                duration: Motion.pill,
                curve: Motion.standard,
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: _hovered || _focused || _expanded
                      ? context.shellColors.surfaceContainerHighest
                      : context.shellColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _focused || _expanded
                        ? accent.primary
                        : context.shellColors.hairlineSoft,
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.speaker_rounded,
                      size: 18,
                      color: enabled
                          ? accent.primary
                          : context.shellColors.glyphInactive,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.shellTheme.text.cardTitle.copyWith(
                          color: enabled
                              ? context.shellColors.textSecondary
                              : context.shellColors.textTertiary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (state.loading || state.changing)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent.primary,
                        ),
                      )
                    else
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: Motion.tile,
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 19,
                          color: enabled
                              ? accent.primary
                              : context.shellColors.glyphInactive,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ClipRect(
          child: AnimatedSize(
            duration: Motion.tile,
            curve: Motion.standard,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Focus(
                      onKeyEvent: (_, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.escape) {
                          _close();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: _AudioDeviceOptions(
                        state: state,
                        onSelected: _select,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

class _AudioDeviceOptions extends StatelessWidget {
  const _AudioDeviceOptions({required this.state, required this.onSelected});

  final AudioDevicesState state;
  final ValueChanged<AudioOutputDevice> onSelected;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 190),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.shellColors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.shellColors.hairlineSoft),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: context.shellColors.shadow.withValues(alpha: 0.24),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.all(5),
            itemCount: state.devices.length,
            separatorBuilder: (_, _) => const SizedBox(height: 3),
            itemBuilder: (context, index) {
              final device = state.devices[index];
              return _AudioDeviceOption(
                key: dashboardAudioDeviceOptionKey(device.name),
                device: device,
                changing: state.changing,
                onSelected: () => onSelected(device),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AudioDeviceOption extends StatefulWidget {
  const _AudioDeviceOption({
    required this.device,
    required this.changing,
    required this.onSelected,
    super.key,
  });

  final AudioOutputDevice device;
  final bool changing;
  final VoidCallback onSelected;

  @override
  State<_AudioDeviceOption> createState() => _AudioDeviceOptionState();
}

class _AudioDeviceOptionState extends State<_AudioDeviceOption> {
  var _highlighted = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = ShellTheme.of(context).accentPalette;
    final available = widget.device.available;
    final enabled = available && !widget.device.active && !widget.changing;
    final label = available
        ? widget.device.description
        : '${widget.device.description} '
              '(${l10n.desktopAudioOutputDeviceNotConnected.toLowerCase()})';
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.device.active,
      label: widget.device.description,
      value: available ? null : l10n.desktopAudioOutputDeviceNotConnected,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? ShellMouseCursors.link
            : ShellMouseCursors.normal,
        onShowFocusHighlight: (highlighted) =>
            setState(() => _highlighted = highlighted),
        onShowHoverHighlight: (highlighted) =>
            setState(() => _highlighted = highlighted),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSelected();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? widget.onSelected : null,
          child: AnimatedContainer(
            duration: Motion.tile,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: widget.device.active
                  ? accent.container
                  : _highlighted
                  ? context.shellColors.surfaceContainerHigh
                  : ShellMediaColors.transparentDark,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  available ? Icons.speaker_rounded : Icons.link_off_rounded,
                  size: 18,
                  color: widget.device.active
                      ? accent.onContainer
                      : available
                      ? context.shellColors.textSecondary
                      : context.shellColors.glyphInactive,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.shellTheme.text.cardTitle.copyWith(
                      color: widget.device.active
                          ? accent.onContainer
                          : available
                          ? context.shellColors.textPrimary
                          : context.shellColors.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  widget.device.active
                      ? Icons.check_rounded
                      : available
                      ? Icons.circle_outlined
                      : Icons.block_rounded,
                  size: 18,
                  color: widget.device.active
                      ? accent.onContainer
                      : context.shellColors.glyphInactive,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseAudioDeviceDropdownIntent extends Intent {
  const _CloseAudioDeviceDropdownIntent();
}
