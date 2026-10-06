import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../color_format.dart';

const settingsColorInputRgbKey = ValueKey<String>('settings-color-input-rgb');
const settingsColorInputHslKey = ValueKey<String>('settings-color-input-hsl');
const settingsColorInputHexKey = ValueKey<String>('settings-color-input-hex');
const settingsColorInputRedFieldKey = ValueKey<String>(
  'settings-color-input-red-field',
);
const settingsColorInputGreenFieldKey = ValueKey<String>(
  'settings-color-input-green-field',
);
const settingsColorInputBlueFieldKey = ValueKey<String>(
  'settings-color-input-blue-field',
);
const settingsColorInputHueFieldKey = ValueKey<String>(
  'settings-color-input-hue-field',
);
const settingsColorInputSaturationFieldKey = ValueKey<String>(
  'settings-color-input-saturation-field',
);
const settingsColorInputLightnessFieldKey = ValueKey<String>(
  'settings-color-input-lightness-field',
);
const settingsColorInputHexFieldKey = ValueKey<String>(
  'settings-color-input-hex-field',
);

enum _ColorValueMode { rgb, hsl, hex }

class SettingsColorValueEditor extends StatefulWidget {
  const SettingsColorValueEditor({
    required this.color,
    required this.onChanged,
    super.key,
  });

  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  State<SettingsColorValueEditor> createState() =>
      _SettingsColorValueEditorState();
}

class _SettingsColorValueEditorState extends State<SettingsColorValueEditor> {
  final _redController = TextEditingController();
  final _greenController = TextEditingController();
  final _blueController = TextEditingController();
  final _hueController = TextEditingController();
  final _saturationController = TextEditingController();
  final _lightnessController = TextEditingController();
  final _hexController = TextEditingController();

  var _mode = _ColorValueMode.rgb;
  var _invalid = false;
  Color? _pendingEmission;

  @override
  void initState() {
    super.initState();
    _synchronize(widget.color);
  }

  @override
  void didUpdateWidget(covariant SettingsColorValueEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color == widget.color) {
      return;
    }
    if (_pendingEmission == widget.color) {
      _pendingEmission = null;
      return;
    }
    _pendingEmission = null;
    _synchronize(widget.color);
  }

  @override
  void dispose() {
    _redController.dispose();
    _greenController.dispose();
    _blueController.dispose();
    _hueController.dispose();
    _saturationController.dispose();
    _lightnessController.dispose();
    _hexController.dispose();
    super.dispose();
  }

  void _synchronize(Color color) {
    final rgb = opaqueColorRgb(color);
    final hsl = HSLColor.fromColor(color);
    _replaceText(_redController, '${rgb.red}');
    _replaceText(_greenController, '${rgb.green}');
    _replaceText(_blueController, '${rgb.blue}');
    _replaceText(_hueController, '${hsl.hue.round() % 360}');
    _replaceText(_saturationController, '${(hsl.saturation * 100).round()}');
    _replaceText(_lightnessController, '${(hsl.lightness * 100).round()}');
    _replaceText(_hexController, formatOpaqueColorHex(color));
  }

  void _replaceText(TextEditingController controller, String text) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _selectMode(_ColorValueMode mode) {
    if (mode == _mode) {
      return;
    }
    _synchronize(widget.color);
    setState(() {
      _mode = mode;
      _invalid = false;
    });
  }

  void _emit(Color color) {
    final opaque = color.withAlpha(0xff);
    _pendingEmission = opaque;
    widget.onChanged(opaque);
  }

  void _setInvalid(bool invalid) {
    if (_invalid != invalid) {
      setState(() => _invalid = invalid);
    }
  }

  bool _commitRgb({bool showError = false}) {
    final red = int.tryParse(_redController.text);
    final green = int.tryParse(_greenController.text);
    final blue = int.tryParse(_blueController.text);
    final valid =
        red != null &&
        green != null &&
        blue != null &&
        red >= 0 &&
        red <= 255 &&
        green >= 0 &&
        green <= 255 &&
        blue >= 0 &&
        blue <= 255;
    _setInvalid(!valid && (showError || _invalid));
    if (!valid) {
      return false;
    }
    _setInvalid(false);
    _emit(Color.fromARGB(0xff, red, green, blue));
    return true;
  }

  bool _commitHsl({bool showError = false}) {
    final hue = int.tryParse(_hueController.text);
    final saturation = int.tryParse(_saturationController.text);
    final lightness = int.tryParse(_lightnessController.text);
    final valid =
        hue != null &&
        saturation != null &&
        lightness != null &&
        hue >= 0 &&
        hue <= 360 &&
        saturation >= 0 &&
        saturation <= 100 &&
        lightness >= 0 &&
        lightness <= 100;
    _setInvalid(!valid && (showError || _invalid));
    if (!valid) {
      return false;
    }
    _setInvalid(false);
    _emit(
      HSLColor.fromAHSL(
        1,
        hue == 360 ? 0 : hue.toDouble(),
        saturation / 100,
        lightness / 100,
      ).toColor(),
    );
    return true;
  }

  bool _commitHex({bool showError = false}) {
    final color = parseOpaqueColorHex(_hexController.text);
    _setInvalid(color == null && (showError || _invalid));
    if (color == null) {
      return false;
    }
    _setInvalid(false);
    _emit(color);
    return true;
  }

  void _commitActive({bool showError = false}) {
    switch (_mode) {
      case _ColorValueMode.rgb:
        _commitRgb(showError: showError);
        return;
      case _ColorValueMode.hsl:
        _commitHsl(showError: showError);
        return;
      case _ColorValueMode.hex:
        _commitHex(showError: showError);
        return;
    }
  }

  void _nudge(
    TextEditingController controller, {
    required int minimum,
    required int maximum,
    required int direction,
  }) {
    final current = int.tryParse(controller.text) ?? minimum;
    final step = HardwareKeyboard.instance.isShiftPressed ? 10 : 1;
    final next = (current + direction * step).clamp(minimum, maximum);
    _replaceText(controller, '$next');
    _commitActive(showError: true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Motion.tile,
      curve: Motion.standard,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 9),
      decoration: BoxDecoration(
        color: context.shellColors.surfaceContainer,
        borderRadius: context.shellTheme.borderRadius(16),
        border: Border.all(
          color: _invalid
              ? context.shellColors.performanceBad
              : context.shellColors.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHeader(context),
          const SizedBox(height: 9),
          _buildAnimatedFields(context),
          const SizedBox(height: 7),
          _buildHelper(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            context.l10n.settingsColorInputTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ShellText.cardTitle.copyWith(fontSize: 11),
          ),
        ),
        _ColorModeTabs(mode: _mode, onChanged: _selectMode),
      ],
    );
  }

  Widget _buildAnimatedFields(BuildContext context) {
    return AnimatedSwitcher(
      duration: Motion.tile,
      switchInCurve: Motion.md3EmphasizedDecelerate,
      switchOutCurve: Motion.md3EmphasizedAccelerate,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(sizeFactor: animation, child: child),
      ),
      child: _buildFields(context),
    );
  }

  Widget _buildHelper(BuildContext context) {
    return Semantics(
      liveRegion: _invalid,
      child: Text(
        _helperText(context.l10n),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ShellText.base.copyWith(
          color: _invalid
              ? context.shellColors.performanceBad
              : context.shellColors.textTertiary,
          fontSize: 9,
          height: 1.2,
        ),
      ),
    );
  }

  Widget _buildFields(BuildContext context) {
    final l10n = context.l10n;
    switch (_mode) {
      case _ColorValueMode.rgb:
        return Row(
          key: const ValueKey<String>('settings-color-rgb-fields'),
          children: <Widget>[
            Expanded(
              child: _channelField(
                key: settingsColorInputRedFieldKey,
                controller: _redController,
                label: l10n.settingsColorInputRed,
                maximum: 255,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _channelField(
                key: settingsColorInputGreenFieldKey,
                controller: _greenController,
                label: l10n.settingsColorInputGreen,
                maximum: 255,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _channelField(
                key: settingsColorInputBlueFieldKey,
                controller: _blueController,
                label: l10n.settingsColorInputBlue,
                maximum: 255,
              ),
            ),
          ],
        );
      case _ColorValueMode.hsl:
        return Row(
          key: const ValueKey<String>('settings-color-hsl-fields'),
          children: <Widget>[
            Expanded(
              child: _channelField(
                key: settingsColorInputHueFieldKey,
                controller: _hueController,
                label: l10n.settingsColorInputHue,
                maximum: 360,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _channelField(
                key: settingsColorInputSaturationFieldKey,
                controller: _saturationController,
                label: l10n.settingsColorInputSaturation,
                maximum: 100,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _channelField(
                key: settingsColorInputLightnessFieldKey,
                controller: _lightnessController,
                label: l10n.settingsColorInputLightness,
                maximum: 100,
              ),
            ),
          ],
        );
      case _ColorValueMode.hex:
        return _labeledField(
          context,
          label: l10n.settingsColorInputHexValue,
          child: TextField(
            key: settingsColorInputHexFieldKey,
            controller: _hexController,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#xX]')),
              LengthLimitingTextInputFormatter(8),
            ],
            onChanged: (_) => _commitHex(),
            onSubmitted: (_) => _commitHex(showError: true),
            onTapOutside: (_) => _commitHex(showError: true),
            style: _fieldTextStyle(context),
            decoration: _fieldDecoration(context),
          ),
        );
    }
  }

  Widget _channelField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required int maximum,
  }) {
    return Focus(
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _nudge(controller, minimum: 0, maximum: maximum, direction: 1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _nudge(controller, minimum: 0, maximum: maximum, direction: -1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) => _labeledField(
          context,
          label: label,
          child: TextField(
            key: key,
            controller: controller,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            textAlign: TextAlign.center,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
            onChanged: (_) => _commitActive(),
            onSubmitted: (_) => _commitActive(showError: true),
            onTapOutside: (_) => _commitActive(showError: true),
            style: _fieldTextStyle(context),
            decoration: _fieldDecoration(context),
          ),
        ),
      ),
    );
  }

  Widget _labeledField(
    BuildContext context, {
    required String label,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: ExcludeSemantics(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.base.copyWith(
                color: context.shellColors.textTertiary,
                fontSize: 10,
                height: 1,
              ),
            ),
          ),
        ),
        Semantics(label: label, child: child),
      ],
    );
  }

  TextStyle _fieldTextStyle(BuildContext context) {
    return ShellText.base.copyWith(
      color: context.shellColors.textPrimary,
      fontFamily: ShellText.systemBarFontFamily,
      fontSize: 12,
      fontWeight: FontWeight.w700,
    );
  }

  InputDecoration _fieldDecoration(BuildContext context) {
    final borderRadius = context.shellTheme.borderRadius(10);
    final border = OutlineInputBorder(
      borderRadius: borderRadius,
      borderSide: BorderSide(color: context.shellColors.hairline),
    );
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: context.shellColors.surfaceContainerHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: ShellTheme.of(context).accent),
      ),
    );
  }

  String _helperText(AppLocalizations l10n) {
    if (!_invalid) {
      return l10n.settingsColorInputNudgeHint;
    }
    return switch (_mode) {
      _ColorValueMode.rgb => l10n.settingsColorInputRgbError,
      _ColorValueMode.hsl => l10n.settingsColorInputHslError,
      _ColorValueMode.hex => l10n.settingsColorInputHexError,
    };
  }
}

class _ColorModeTabs extends StatelessWidget {
  const _ColorModeTabs({required this.mode, required this.onChanged});

  final _ColorValueMode mode;
  final ValueChanged<_ColorValueMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellColors.surfaceContainerHigh,
        borderRadius: context.shellTheme.borderRadius(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _ColorModeTab(
              key: settingsColorInputRgbKey,
              label: l10n.settingsColorInputRgb,
              selected: mode == _ColorValueMode.rgb,
              onPressed: () => onChanged(_ColorValueMode.rgb),
            ),
            _ColorModeTab(
              key: settingsColorInputHslKey,
              label: l10n.settingsColorInputHsl,
              selected: mode == _ColorValueMode.hsl,
              onPressed: () => onChanged(_ColorValueMode.hsl),
            ),
            _ColorModeTab(
              key: settingsColorInputHexKey,
              label: l10n.settingsColorInputHex,
              selected: mode == _ColorValueMode.hex,
              onPressed: () => onChanged(_ColorValueMode.hex),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorModeTab extends StatelessWidget {
  const _ColorModeTab({
    required this.label,
    required this.selected,
    required this.onPressed,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      child: TextButton(
        onPressed: onPressed,
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(42, 26)),
          visualDensity: VisualDensity.compact,
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: 8),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: WidgetStatePropertyAll<Color>(
            selected
                ? ShellTheme.of(context).accent.withAlpha(36)
                : ShellMediaColors.transparentLight,
          ),
          foregroundColor: WidgetStatePropertyAll<Color>(
            selected
                ? ShellTheme.of(context).accent
                : context.shellColors.textTertiary,
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: context.shellTheme.borderRadius(10),
            ),
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(
            ShellText.base.copyWith(
              fontFamily: ShellText.systemBarFontFamily,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        child: Text(label),
      ),
    );
  }
}
