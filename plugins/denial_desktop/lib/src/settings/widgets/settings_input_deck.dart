import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/input_deck.dart';
import 'settings_controls.dart';

class SettingsInputDeck extends ConsumerWidget {
  const SettingsInputDeck({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final native = ref.watch(inputDeckProvider);
    final settings = ref.watch(
      shellSettingsProvider.select((settings) => settings.inputDeck),
    );
    final selectedOutput = native.touchOutputs.contains(settings.outputName)
        ? settings.outputName
        : native.touchOutput;
    void save(InputDeckSettings value) =>
        ref.read(shellSettingsProvider.notifier).setInputDeck(value);
    return SettingsCardGroup(
      children: [
        SettingsSection(
          title: context.l10n.inputDeckTitle,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsToggle(
                  label: context.l10n.inputDeckEnable,
                  description: native.touchOutput == null
                      ? context.l10n.inputDeckUnavailable
                      : context.l10n.inputDeckEnableDescription(
                          selectedOutput!,
                        ),
                  value: settings.enabled,
                  enabled: native.touchOutput != null || settings.enabled,
                  onChanged: (enabled) => save(
                    settings.copyWith(
                      enabled: enabled,
                      outputName: selectedOutput ?? settings.outputName,
                    ),
                  ),
                ),
                if (native.touchOutput != null && !native.available)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      context.l10n.inputDeckWaiting,
                      style: TextStyle(
                        color: context.shellColors.textSecondary,
                      ),
                    ),
                  ),
                if (native.touchOutputs.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SettingsSelect<String>(
                      label: context.l10n.inputDeckTouchDisplay,
                      description:
                          context.l10n.inputDeckTouchDisplayDescription,
                      value: selectedOutput!,
                      choices: [
                        for (final name in native.touchOutputs)
                          SettingsChoice(name, name),
                      ],
                      onChanged: (name) =>
                          save(settings.copyWith(outputName: name)),
                    ),
                  ),
                const SizedBox(height: 16),
                SettingsSlider(
                  label: context.l10n.inputDeckKeyboardSize,
                  value: settings.keyboardHeight,
                  minimum: 0.3,
                  maximum: 0.65,
                  valueLabel: '${(settings.keyboardHeight * 100).round()}%',
                  onChanged: (value) =>
                      save(settings.copyWith(keyboardHeight: value)),
                ),
                const SizedBox(height: 12),
                SettingsSlider(
                  label: context.l10n.inputDeckTouchpadWidth,
                  value: settings.touchpadWidth,
                  minimum: 0.35,
                  maximum: 1,
                  valueLabel: '${(settings.touchpadWidth * 100).round()}%',
                  onChanged: (value) =>
                      save(settings.copyWith(touchpadWidth: value)),
                ),
                const SizedBox(height: 12),
                SettingsSlider(
                  label: context.l10n.inputDeckTouchpadHeight,
                  value: settings.touchpadHeight,
                  minimum: 0.35,
                  maximum: 1,
                  valueLabel: '${(settings.touchpadHeight * 100).round()}%',
                  onChanged: (value) =>
                      save(settings.copyWith(touchpadHeight: value)),
                ),
                const SizedBox(height: 12),
                SettingsSlider(
                  label: context.l10n.inputDeckPointerSpeed,
                  value: settings.pointerSpeed,
                  minimum: 0.25,
                  maximum: 4,
                  valueLabel: '${settings.pointerSpeed.toStringAsFixed(2)}×',
                  onChanged: (value) =>
                      save(settings.copyWith(pointerSpeed: value)),
                ),
                const SizedBox(height: 12),
                SettingsToggle(
                  label: context.l10n.inputDeckNaturalScroll,
                  description: context.l10n.inputDeckNaturalScrollDescription,
                  value: settings.naturalScroll,
                  onChanged: (value) =>
                      save(settings.copyWith(naturalScroll: value)),
                ),
                const SizedBox(height: 12),
                SettingsToggle(
                  label: context.l10n.inputDeckCpuChart,
                  description: context.l10n.inputDeckCpuDescription,
                  value: settings.showCpu,
                  onChanged: (value) => save(settings.copyWith(showCpu: value)),
                ),
                const SizedBox(height: 12),
                SettingsToggle(
                  label: context.l10n.inputDeckGpuCharts,
                  description: context.l10n.inputDeckGpuDescription,
                  value: settings.showGpu,
                  onChanged: (value) => save(settings.copyWith(showGpu: value)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
