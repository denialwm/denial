import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';

enum ShellOskKeyAction { text, key, space, backspace, enter }

class ShellOskKeyIntent {
  const ShellOskKeyIntent._({
    required this.action,
    this.text,
    this.key,
    this.ctrl = false,
  });

  const ShellOskKeyIntent.text(String value)
    : this._(action: ShellOskKeyAction.text, text: value);

  const ShellOskKeyIntent.key(String value, {bool ctrl = false})
    : this._(action: ShellOskKeyAction.key, key: value, ctrl: ctrl);

  const ShellOskKeyIntent.space({bool ctrl = false})
    : this._(
        action: ShellOskKeyAction.space,
        text: ' ',
        key: 'space',
        ctrl: ctrl,
      );

  const ShellOskKeyIntent.backspace({bool ctrl = false})
    : this._(action: ShellOskKeyAction.backspace, key: 'BackSpace', ctrl: ctrl);

  const ShellOskKeyIntent.enter({bool ctrl = false})
    : this._(action: ShellOskKeyAction.enter, key: 'Return', ctrl: ctrl);

  final ShellOskKeyAction action;
  final String? text;
  final String? key;
  final bool ctrl;
}

class ShellOskPanel extends StatefulWidget {
  const ShellOskPanel({super.key, this.onKey, this.onKeyTap});

  final ValueChanged<ShellOskKeyIntent>? onKey;
  final VoidCallback? onKeyTap;

  @override
  State<ShellOskPanel> createState() => _ShellOskPanelState();
}

class _ShellOskPanelState extends State<ShellOskPanel> {
  _OskLayer _layer = _OskLayer.letters;
  bool _shiftEnabled = false;
  bool _ctrlArmed = false;

  @override
  Widget build(BuildContext context) {
    final rows = _rowsForCurrentLayer();
    final bottomPadding = math.max(MediaQuery.paddingOf(context).bottom, 12.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 560 || constraints.maxHeight < 390;
        final horizontalPadding = compact ? 8.0 : 12.0;
        final topPadding = compact ? 10.0 : 14.0;
        final keyGap = compact ? 5.0 : 6.0;
        final rowGap = compact ? 6.0 : 7.0;
        final availableHeight =
            constraints.maxHeight -
            topPadding -
            bottomPadding -
            rowGap * (rows.length - 1);
        final maxRowHeight = rows.length <= 4
            ? (compact ? 78.0 : 88.0)
            : (compact ? 70.0 : 76.0);
        final rowHeight = (availableHeight / rows.length)
            .clamp(48.0, maxRowHeight)
            .toDouble();

        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            topPadding,
            horizontalPadding,
            bottomPadding,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              for (var index = 0; index < rows.length; index++) ...[
                _OskRow(
                  row: rows[index],
                  keyGap: keyGap,
                  rowHeight: rowHeight,
                  shiftEnabled: _shiftEnabled,
                  ctrlArmed: _ctrlArmed,
                  onKey: _handleKey,
                  onKeyLongPress: _handleKeyLongPress,
                ),
                if (index != rows.length - 1) SizedBox(height: rowGap),
              ],
            ],
          ),
        );
      },
    );
  }

  List<_OskRowData> _rowsForCurrentLayer() {
    return switch (_layer) {
      _OskLayer.letters => _letterRows,
      _OskLayer.numbers => _numberRows,
      _OskLayer.symbols => _extraSymbolRows,
    };
  }

  void _handleKey(_OskKeySpec spec) {
    widget.onKeyTap?.call();

    final control = spec.control;
    if (control != null) {
      _handleControl(control);
      return;
    }

    if (_ctrlArmed) {
      final key = spec.namedKey(shiftEnabled: _shiftEnabled);
      if (key != null) {
        widget.onKey?.call(ShellOskKeyIntent.key(key, ctrl: true));
        setState(() {
          _ctrlArmed = false;
          if (_layer == _OskLayer.letters && _shiftEnabled && spec.isLetter) {
            _shiftEnabled = false;
          }
        });
        return;
      }
    }

    final text = spec.outputText(shiftEnabled: _shiftEnabled);
    widget.onKey?.call(ShellOskKeyIntent.text(text));
    if (_layer == _OskLayer.letters && _shiftEnabled && spec.isLetter) {
      setState(() => _shiftEnabled = false);
    }
  }

  void _handleControl(_OskControl control) {
    switch (control) {
      case _OskControl.shift:
        setState(() => _shiftEnabled = !_shiftEnabled);
      case _OskControl.symbols:
        setState(() {
          _layer = _OskLayer.numbers;
          _shiftEnabled = false;
          _ctrlArmed = false;
        });
      case _OskControl.extraSymbols:
        setState(() {
          _layer = _OskLayer.symbols;
          _shiftEnabled = false;
          _ctrlArmed = false;
        });
      case _OskControl.letters:
        setState(() {
          _layer = _OskLayer.letters;
          _shiftEnabled = false;
          _ctrlArmed = false;
        });
      case _OskControl.space:
        _sendKeyOrText(
          textIntent: ShellOskKeyIntent.space(ctrl: _ctrlArmed),
          key: 'space',
        );
      case _OskControl.backspace:
        _sendKey(ShellOskKeyIntent.backspace(ctrl: _ctrlArmed));
      case _OskControl.enter:
        _sendKey(ShellOskKeyIntent.enter(ctrl: _ctrlArmed));
      case _OskControl.arrowUp:
        _sendKey(ShellOskKeyIntent.key('Up', ctrl: _ctrlArmed));
      case _OskControl.arrowDown:
        _sendKey(ShellOskKeyIntent.key('Down', ctrl: _ctrlArmed));
    }
  }

  void _handleKeyLongPress(_OskKeySpec spec) {
    if (spec.control != _OskControl.symbols) {
      return;
    }
    widget.onKeyTap?.call();
    setState(() {
      _ctrlArmed = true;
      _shiftEnabled = false;
    });
  }

  void _sendKey(ShellOskKeyIntent intent) {
    widget.onKey?.call(intent);
    _consumeCtrl();
  }

  void _sendKeyOrText({
    required ShellOskKeyIntent textIntent,
    required String key,
  }) {
    if (_ctrlArmed) {
      widget.onKey?.call(ShellOskKeyIntent.key(key, ctrl: true));
      _consumeCtrl();
      return;
    }
    widget.onKey?.call(textIntent);
  }

  void _consumeCtrl() {
    if (!_ctrlArmed) {
      return;
    }
    setState(() => _ctrlArmed = false);
  }
}

class _OskRow extends StatelessWidget {
  const _OskRow({
    required this.row,
    required this.keyGap,
    required this.rowHeight,
    required this.shiftEnabled,
    required this.ctrlArmed,
    required this.onKey,
    required this.onKeyLongPress,
  });

  final _OskRowData row;
  final double keyGap;
  final double rowHeight;
  final bool shiftEnabled;
  final bool ctrlArmed;
  final ValueChanged<_OskKeySpec> onKey;
  final ValueChanged<_OskKeySpec> onKeyLongPress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: rowHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inset = math.min(row.sideInset, constraints.maxWidth * 0.08);
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < row.keys.length; index++) ...[
                  Expanded(
                    flex: row.keys[index].flex,
                    child: _OskKeyButton(
                      key: ValueKey<String>(row.keys[index].animationKey),
                      spec: row.keys[index],
                      selected: row.keys[index].isSelected(
                        shiftEnabled: shiftEnabled,
                        ctrlArmed: ctrlArmed,
                      ),
                      shiftEnabled: shiftEnabled,
                      ctrlArmed: ctrlArmed,
                      onPressed: () => onKey(row.keys[index]),
                      onLongPress: () => onKeyLongPress(row.keys[index]),
                    ),
                  ),
                  if (index != row.keys.length - 1) SizedBox(width: keyGap),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _OskKeyButton extends StatefulWidget {
  const _OskKeyButton({
    super.key,
    required this.spec,
    required this.selected,
    required this.shiftEnabled,
    required this.ctrlArmed,
    required this.onPressed,
    required this.onLongPress,
  });

  final _OskKeySpec spec;
  final bool selected;
  final bool shiftEnabled;
  final bool ctrlArmed;
  final VoidCallback onPressed;
  final VoidCallback onLongPress;

  @override
  State<_OskKeyButton> createState() => _OskKeyButtonState();
}

class _OskKeyButtonState extends State<_OskKeyButton>
    with SingleTickerProviderStateMixin {
  static const Duration _minimumVisibleDuration = Duration(milliseconds: 180);
  static const Duration _fadeOutDuration = Duration(milliseconds: 360);

  late final AnimationController _glow = AnimationController(
    vsync: this,
    value: 0,
  );
  DateTime? _lastPressStartedAt;
  bool _pressed = false;

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final control = widget.spec.control;
    final accent = ShellTheme.of(context).accent;
    final background = _backgroundFor(widget.spec, widget.selected);
    final baseBorder = widget.selected ? accent : ShellColors.hairlineSoft;
    final baseForeground = widget.selected
        ? ShellColors.onPrimaryContainer
        : control == null
        ? ShellColors.panelText
        : ShellColors.textSecondary;

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.spec.semanticLabel(
        shiftEnabled: widget.shiftEnabled,
        l10n: context.l10n,
      ),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _startGlow(),
        onPointerUp: (_) => _releaseGlow(),
        onPointerCancel: (_) => _releaseGlow(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          onLongPress: widget.onLongPress,
          child: AnimatedBuilder(
            animation: _glow,
            builder: (context, child) {
              final glow = _glow.value;
              final foreground = Color.lerp(
                baseForeground,
                ShellColors.panelText,
                glow * 0.55,
              )!;
              final border = Color.lerp(baseBorder, accent, glow)!;
              final glowAlpha = (132 * glow).round().clamp(0, 255);

              return DecoratedBox(
                decoration: BoxDecoration(
                  color: Color.lerp(
                    background,
                    widget.selected ? ShellColors.onPrimaryContainer : accent,
                    glow * 0.48,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: border),
                  boxShadow: glowAlpha <= 0
                      ? const []
                      : [
                          BoxShadow(
                            color: accent.withAlpha(glowAlpha),
                            blurRadius: 22 * glow,
                            spreadRadius: 1.2 * glow,
                          ),
                        ],
                ),
                child: Center(
                  child: widget.spec.icon == null
                      ? _OskKeyLabel(
                          label: widget.spec.labelText(
                            shiftEnabled: widget.shiftEnabled,
                            ctrlArmed: widget.ctrlArmed,
                            l10n: context.l10n,
                          ),
                          color: foreground,
                          isWide: widget.spec.flex >= 28,
                        )
                      : Icon(widget.spec.icon, color: foreground, size: 24),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _startGlow() {
    _pressed = true;
    _lastPressStartedAt = DateTime.now();
    _glow.stop();
    _glow.value = 1;
  }

  void _releaseGlow() {
    _pressed = false;
    final startedAt = _lastPressStartedAt;
    if (startedAt == null) {
      _fadeOut();
      return;
    }

    final elapsed = DateTime.now().difference(startedAt);
    final remaining = _minimumVisibleDuration - elapsed;
    if (remaining <= Duration.zero) {
      _fadeOut();
      return;
    }

    Future<void>.delayed(remaining, () {
      if (!mounted || _pressed || _lastPressStartedAt != startedAt) {
        return;
      }
      _fadeOut();
    });
  }

  void _fadeOut() {
    _glow.animateTo(0, duration: _fadeOutDuration, curve: Curves.linear);
  }

  Color _backgroundFor(_OskKeySpec spec, bool selected) {
    final control = spec.control;
    if (selected) {
      return ShellColors.primaryContainer;
    }
    if (control == _OskControl.space) {
      return ShellColors.surfaceContainerHighest;
    }
    if (control != null) {
      return ShellColors.surfaceContainer;
    }
    return ShellColors.surfaceContainerHigh;
  }
}

class _OskKeyLabel extends StatelessWidget {
  const _OskKeyLabel({
    required this.label,
    required this.color,
    required this.isWide,
  });

  final String label;
  final Color color;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final style = ShellText.cardTitle.copyWith(
      color: color,
      fontSize: isWide ? 18 : 20,
      fontWeight: isWide ? FontWeight.w700 : FontWeight.w600,
      height: 1,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label, softWrap: false, style: style),
      ),
    );
  }
}

enum _OskLayer { letters, numbers, symbols }

enum _OskControl {
  shift,
  symbols,
  extraSymbols,
  letters,
  space,
  backspace,
  enter,
  arrowUp,
  arrowDown,
}

class _OskRowData {
  const _OskRowData(this.keys, {this.sideInset = 0});

  final List<_OskKeySpec> keys;
  final double sideInset;
}

class _OskKeySpec {
  const _OskKeySpec.text(this.value, {this.flex = 10})
    : control = null,
      label = null,
      icon = null;

  const _OskKeySpec.control(
    this.control, {
    this.label,
    this.icon,
    this.flex = 14,
  }) : value = null;

  final String? value;
  final _OskControl? control;
  final String? label;
  final IconData? icon;
  final int flex;

  bool get isLetter {
    final text = value;
    if (text == null || text.length != 1) {
      return false;
    }
    final code = text.codeUnitAt(0);
    return code >= 97 && code <= 122;
  }

  String outputText({required bool shiftEnabled}) {
    final text = value ?? '';
    return shiftEnabled && isLetter ? text.toUpperCase() : text;
  }

  String labelText({
    required bool shiftEnabled,
    required bool ctrlArmed,
    required AppLocalizations l10n,
  }) {
    if (control == _OskControl.symbols && ctrlArmed) {
      return l10n.oskControlKey;
    }
    if (control == _OskControl.symbols) {
      return l10n.oskNumbersAndSymbolsKey;
    }
    if (control == _OskControl.extraSymbols) {
      return l10n.oskMoreSymbolsKey;
    }
    if (control == _OskControl.letters) {
      return l10n.oskLettersKey;
    }
    if (label != null) {
      return label!;
    }
    return outputText(shiftEnabled: shiftEnabled);
  }

  String semanticLabel({
    required bool shiftEnabled,
    required AppLocalizations l10n,
  }) {
    return switch (control) {
      _OskControl.shift => l10n.oskShift,
      _OskControl.symbols => l10n.oskNumbersAndSymbols,
      _OskControl.extraSymbols => l10n.oskMoreSymbols,
      _OskControl.letters => l10n.oskLetters,
      _OskControl.space => l10n.oskSpace,
      _OskControl.backspace => l10n.oskBackspace,
      _OskControl.enter => l10n.oskEnter,
      _OskControl.arrowUp => l10n.oskArrowUp,
      _OskControl.arrowDown => l10n.oskArrowDown,
      null => labelText(
        shiftEnabled: shiftEnabled,
        ctrlArmed: false,
        l10n: l10n,
      ),
    };
  }

  String? namedKey({required bool shiftEnabled}) {
    final control = this.control;
    if (control != null) {
      return switch (control) {
        _OskControl.space => 'space',
        _OskControl.backspace => 'BackSpace',
        _OskControl.enter => 'Return',
        _OskControl.arrowUp => 'Up',
        _OskControl.arrowDown => 'Down',
        _ => null,
      };
    }

    final text = value;
    if (text == null || text.isEmpty) {
      return null;
    }
    if (isLetter) {
      return text.toLowerCase();
    }
    return switch (text) {
      ',' => 'comma',
      '.' => 'period',
      '/' => 'slash',
      r'\' => 'backslash',
      '-' => 'minus',
      '=' => 'equal',
      "'" => 'apostrophe',
      ';' => 'semicolon',
      ':' => 'colon',
      '[' => 'bracketleft',
      ']' => 'bracketright',
      _ => shiftEnabled ? outputText(shiftEnabled: true) : text,
    };
  }

  String get animationKey {
    final control = this.control;
    if (control == null) {
      return 'text:$value:$flex';
    }
    return 'control:${control.name}:${label ?? ''}:${icon?.codePoint ?? 0}:$flex';
  }

  bool isSelected({required bool shiftEnabled, required bool ctrlArmed}) {
    return (control == _OskControl.shift && shiftEnabled) ||
        (control == _OskControl.symbols && ctrlArmed);
  }
}

const _letterRows = [
  _OskRowData([
    _OskKeySpec.text('q'),
    _OskKeySpec.text('w'),
    _OskKeySpec.text('e'),
    _OskKeySpec.text('r'),
    _OskKeySpec.text('t'),
    _OskKeySpec.text('y'),
    _OskKeySpec.text('u'),
    _OskKeySpec.text('i'),
    _OskKeySpec.text('o'),
    _OskKeySpec.text('p'),
  ]),
  _OskRowData([
    _OskKeySpec.text('a'),
    _OskKeySpec.text('s'),
    _OskKeySpec.text('d'),
    _OskKeySpec.text('f'),
    _OskKeySpec.text('g'),
    _OskKeySpec.text('h'),
    _OskKeySpec.text('j'),
    _OskKeySpec.text('k'),
    _OskKeySpec.text('l'),
  ], sideInset: 28),
  _OskRowData([
    _OskKeySpec.control(
      _OskControl.shift,
      icon: Icons.keyboard_arrow_up_rounded,
      flex: 15,
    ),
    _OskKeySpec.text('z'),
    _OskKeySpec.text('x'),
    _OskKeySpec.text('c'),
    _OskKeySpec.text('v'),
    _OskKeySpec.text('b'),
    _OskKeySpec.text('n'),
    _OskKeySpec.text('m'),
    _OskKeySpec.control(
      _OskControl.backspace,
      icon: Icons.backspace_rounded,
      flex: 15,
    ),
  ]),
  _OskRowData([
    _OskKeySpec.control(_OskControl.symbols, flex: 17),
    _OskKeySpec.text(',', flex: 10),
    _OskKeySpec.control(
      _OskControl.space,
      icon: Icons.space_bar_rounded,
      flex: 46,
    ),
    _OskKeySpec.text('.', flex: 10),
    _OskKeySpec.control(
      _OskControl.enter,
      icon: Icons.keyboard_return_rounded,
      flex: 17,
    ),
  ]),
];

const _numberRows = [
  _OskRowData([
    _OskKeySpec.text('1'),
    _OskKeySpec.text('2'),
    _OskKeySpec.text('3'),
    _OskKeySpec.text('4'),
    _OskKeySpec.text('5'),
    _OskKeySpec.text('6'),
    _OskKeySpec.text('7'),
    _OskKeySpec.text('8'),
    _OskKeySpec.text('9'),
    _OskKeySpec.text('0'),
  ]),
  _OskRowData([
    _OskKeySpec.text('@'),
    _OskKeySpec.text('#'),
    _OskKeySpec.text(r'$'),
    _OskKeySpec.text('_'),
    _OskKeySpec.text('&'),
    _OskKeySpec.text('-'),
    _OskKeySpec.text('+'),
    _OskKeySpec.text('('),
    _OskKeySpec.text(')'),
  ], sideInset: 28),
  _OskRowData([
    _OskKeySpec.control(_OskControl.extraSymbols, flex: 15),
    _OskKeySpec.text('*'),
    _OskKeySpec.text('"'),
    _OskKeySpec.text("'"),
    _OskKeySpec.text(':'),
    _OskKeySpec.text(';'),
    _OskKeySpec.text('/'),
    _OskKeySpec.text(r'\'),
    _OskKeySpec.text('!'),
    _OskKeySpec.text('?'),
    _OskKeySpec.control(
      _OskControl.backspace,
      icon: Icons.backspace_rounded,
      flex: 15,
    ),
  ]),
  _OskRowData([
    _OskKeySpec.control(_OskControl.letters, flex: 17),
    _OskKeySpec.control(
      _OskControl.arrowUp,
      icon: Icons.keyboard_arrow_up_rounded,
      flex: 10,
    ),
    _OskKeySpec.control(
      _OskControl.space,
      icon: Icons.space_bar_rounded,
      flex: 46,
    ),
    _OskKeySpec.control(
      _OskControl.arrowDown,
      icon: Icons.keyboard_arrow_down_rounded,
      flex: 10,
    ),
    _OskKeySpec.control(
      _OskControl.enter,
      icon: Icons.keyboard_return_rounded,
      flex: 17,
    ),
  ]),
];

const _extraSymbolRows = [
  _OskRowData([
    _OskKeySpec.text('~'),
    _OskKeySpec.text('`'),
    _OskKeySpec.text('|'),
    _OskKeySpec.text('^'),
    _OskKeySpec.text('%'),
  ], sideInset: 86),
  _OskRowData([
    _OskKeySpec.text('='),
    _OskKeySpec.text('<'),
    _OskKeySpec.text('>'),
    _OskKeySpec.text('['),
    _OskKeySpec.text(']'),
  ], sideInset: 86),
  _OskRowData([
    _OskKeySpec.control(_OskControl.symbols, flex: 17),
    _OskKeySpec.text('{'),
    _OskKeySpec.text('}'),
    _OskKeySpec.control(
      _OskControl.backspace,
      icon: Icons.backspace_rounded,
      flex: 17,
    ),
  ]),
  _OskRowData([
    _OskKeySpec.control(_OskControl.letters, flex: 17),
    _OskKeySpec.text(',', flex: 10),
    _OskKeySpec.control(
      _OskControl.space,
      icon: Icons.space_bar_rounded,
      flex: 46,
    ),
    _OskKeySpec.text('.', flex: 10),
    _OskKeySpec.control(
      _OskControl.enter,
      icon: Icons.keyboard_return_rounded,
      flex: 17,
    ),
  ]),
];
