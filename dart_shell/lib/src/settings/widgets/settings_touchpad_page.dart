import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../models/input_device_capabilities.dart';
import '../../state/input_device_capabilities.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import 'settings_controls.dart';

const settingsTapToClickToggleKey = Key('settings-touchpad-tap-to-click');
const settingsNaturalScrollToggleKey = Key('settings-touchpad-natural-scroll');
const settingsScrollSpeedSliderKey = Key('settings-touchpad-scroll-speed');
const settingsMouseSpeedSliderKey = Key('settings-mouse-speed');

class SettingsTouchpadPage extends ConsumerStatefulWidget {
  const SettingsTouchpadPage({super.key});

  @override
  ConsumerState<SettingsTouchpadPage> createState() =>
      _SettingsTouchpadPageState();
}

class _SettingsTouchpadPageState extends ConsumerState<SettingsTouchpadPage> {
  double? _draftMouseSpeed;
  var _changingMouseSpeed = false;
  double? _draftScrollSpeedFactor;
  var _changingScrollSpeed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(inputDeviceCapabilitiesProvider);
    final controller = ref.read(inputDeviceCapabilitiesProvider.notifier);
    final capabilities = state.capabilities;
    final mouseControlsEnabled = capabilities.hasMouse && !state.busy;
    final touchpadControlsEnabled = capabilities.hasTouchpad && !state.busy;
    final mouseSpeed = _changingMouseSpeed || state.busy
        ? _draftMouseSpeed ?? capabilities.mouseSpeed
        : capabilities.mouseSpeed;
    final scrollSpeedFactor = _changingScrollSpeed || state.busy
        ? _draftScrollSpeedFactor ?? capabilities.scrollSpeedFactor
        : capabilities.scrollSpeedFactor;
    return SettingsPageLayout(
      icon: Icons.mouse_rounded,
      eyebrow: l10n.settingsTouchpadSection,
      title: l10n.settingsTouchpadTitle,
      children: [
        SettingsCardGroup(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SettingsSlider(
                key: settingsMouseSpeedSliderKey,
                label: l10n.settingsMousePointerSpeed,
                value: mouseSpeed,
                minimum: mouseSpeedMinimum,
                maximum: mouseSpeedMaximum,
                divisions: 40,
                valueLabel: l10n.settingsPercent((mouseSpeed * 100).round()),
                enabled: mouseControlsEnabled,
                onChangeStart: (value) => setState(() {
                  _changingMouseSpeed = true;
                  _draftMouseSpeed = _normalizedMouseSpeed(value);
                }),
                onChanged: (value) => setState(
                  () => _draftMouseSpeed = _normalizedMouseSpeed(value),
                ),
                onChangeEnd: (value) {
                  final speed = _normalizedMouseSpeed(value);
                  setState(() {
                    _changingMouseSpeed = false;
                    _draftMouseSpeed = speed;
                  });
                  controller.setMouseSpeed(speed);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SettingsToggle(
                key: settingsTapToClickToggleKey,
                label: l10n.settingsTouchpadTapToClick,
                description: l10n.settingsTouchpadTapToClickDescription,
                value: capabilities.tapToClickEnabled,
                enabled: touchpadControlsEnabled,
                onChanged: controller.setTapToClick,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SettingsSlider(
                key: settingsScrollSpeedSliderKey,
                label: l10n.settingsTouchpadScrollSpeed,
                value: scrollSpeedFactor,
                minimum: touchpadScrollSpeedFactorMinimum,
                maximum: touchpadScrollSpeedFactorMaximum,
                divisions: 99,
                valueLabel: '${scrollSpeedFactor.toStringAsFixed(2)}×',
                enabled: touchpadControlsEnabled,
                onChangeStart: (value) => setState(() {
                  _changingScrollSpeed = true;
                  _draftScrollSpeedFactor = _normalizedFactor(value);
                }),
                onChanged: (value) => setState(
                  () => _draftScrollSpeedFactor = _normalizedFactor(value),
                ),
                onChangeEnd: (value) {
                  final factor = _normalizedFactor(value);
                  setState(() {
                    _changingScrollSpeed = false;
                    _draftScrollSpeedFactor = factor;
                  });
                  controller.setScrollSpeedFactor(factor);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SettingsToggle(
                key: settingsNaturalScrollToggleKey,
                label: l10n.settingsTouchpadNaturalScroll,
                description: l10n.settingsTouchpadNaturalScrollDescription,
                value: capabilities.naturalScrollEnabled,
                enabled: touchpadControlsEnabled,
                onChanged: controller.setNaturalScroll,
              ),
            ),
          ],
        ),
        if (state.error case final error?)
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: ShellText.base.copyWith(
                color: context.shellColors.performanceBad,
              ),
            ),
          ),
      ],
    );
  }

  double _normalizedMouseSpeed(double value) => ((value * 20).round() / 20)
      .clamp(mouseSpeedMinimum, mouseSpeedMaximum)
      .toDouble();

  double _normalizedFactor(double value) => ((value * 20).round() / 20)
      .clamp(touchpadScrollSpeedFactorMinimum, touchpadScrollSpeedFactorMaximum)
      .toDouble();
}
