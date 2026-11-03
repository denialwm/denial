import 'dart:math' as math;

import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/input_deck.dart';
import 'input_deck_surface.dart';

/// Evdev transitions use the same XKB layout and repeat policy as hardware.
///
/// Rows follow laptop proportions: every typing row spans 150 flex points
/// (15 key units), so keys line up in columns across rows, and the function
/// row is shorter than the typing rows.
class InputDeckKeyboard extends ConsumerStatefulWidget {
  const InputDeckKeyboard({required this.bridge, super.key});
  final DenialBridge bridge;

  static const _padding = 10.0;
  static const _gap = 6.0;

  /// Upper width bound for [height]; wider keyboards stretch keys past
  /// laptop proportions, so the deck centers a narrower one instead.
  static double maximumWidth(double height) {
    final row = _cellHeight(height) - _gap;
    return 15 * (math.max(0.0, row) * 1.55 + _gap) + 2 * _padding - _gap;
  }

  /// Height of one typing-row cell, including its share of the row gaps.
  static double _cellHeight(double height) =>
      math.max(0.0, height - 2 * _padding + _gap) *
      _typingRowFlex /
      (_functionRowFlex + 5 * _typingRowFlex);

  static const _functionRowFlex = 7;
  static const _typingRowFlex = 10;

  @override
  ConsumerState<InputDeckKeyboard> createState() => _InputDeckKeyboardState();
}

class _InputDeckKeyboardState extends ConsumerState<InputDeckKeyboard> {
  final _heldModifiers = <int>{};
  static const _modifiers = {29, 42, 54, 56, 97, 100, 125, 126};

  void _transition(int code, bool pressed, {bool cancelled = false}) {
    if (_modifiers.contains(code)) {
      if (pressed) {
        _heldModifiers.add(code);
      } else {
        _heldModifiers.remove(code);
      }
    }
    widget.bridge.inputDeckKey(code, pressed, cancelled: cancelled);
  }

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(
      inputDeckProvider.select((state) => state.keyLabels),
    );
    const gap = InputDeckKeyboard._gap;
    return InputDeckGlass(
      radius: ShellRadii.panel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final metrics = _KeyMetrics(
            InputDeckKeyboard._cellHeight(constraints.maxHeight) - gap,
            context.shellTheme.text.base,
          );
          Widget key(_Key spec, {bool compact = false}) => DeckKeyButton(
            key: ValueKey(spec.code),
            label: spec.kind == _KeyKind.character
                ? labels[spec.code] ?? spec.name
                : spec.name,
            activateOnDown: () =>
                _modifiers.contains(spec.code) || _heldModifiers.isNotEmpty,
            onTransition: (pressed) => _transition(spec.code, pressed),
            onCancelled: () => _transition(spec.code, false, cancelled: true),
            builder: (context, pressed) => _Keycap(
              spec: spec,
              legend: spec.kind == _KeyKind.character
                  ? labels[spec.code] ?? spec.name
                  : spec.legend,
              metrics: metrics,
              compact: compact,
              pressed: pressed,
            ),
          );
          return RepaintBoundary(
            child: Padding(
              padding: const EdgeInsets.all(
                InputDeckKeyboard._padding - gap / 2,
              ),
              child: Column(
                children: [
                  for (final (index, row) in _rows.indexed)
                    Expanded(
                      flex: index == 0
                          ? InputDeckKeyboard._functionRowFlex
                          : InputDeckKeyboard._typingRowFlex,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final cell in row)
                            Expanded(
                              flex: cell.flex,
                              child: switch (cell) {
                                _Gap() => const SizedBox.shrink(),
                                _Key() => Padding(
                                  padding: const EdgeInsets.all(gap / 2),
                                  child: key(cell, compact: index == 0),
                                ),
                                _KeyStack(:final keys) => Padding(
                                  padding: const EdgeInsets.all(gap / 2),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (final (i, spec) in keys.indexed) ...[
                                        if (i > 0) const SizedBox(height: gap),
                                        Expanded(child: key(spec)),
                                      ],
                                    ],
                                  ),
                                ),
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _KeyMetrics {
  _KeyMetrics(double keyHeight, TextStyle base)
    : character = base.copyWith(
        fontSize: (keyHeight * 0.27).clamp(13.0, 26.0),
        fontWeight: FontWeight.w500,
        height: 1,
      ),
      named = base.copyWith(
        fontSize: (keyHeight * 0.155).clamp(10.0, 15.0),
        fontWeight: FontWeight.w500,
        height: 1,
        letterSpacing: 0.3,
      ),
      function = base.copyWith(
        fontSize: (keyHeight * 0.14).clamp(9.5, 13.5),
        fontWeight: FontWeight.w500,
        height: 1,
        letterSpacing: 0.3,
      ),
      icon = (keyHeight * 0.27).clamp(14.0, 26.0),
      inset = (keyHeight * 0.15).clamp(6.0, 13.0);

  final TextStyle character;
  final TextStyle named;
  final TextStyle function;
  final double icon;
  final double inset;
}

/// A keycap on the deck's glass: card backing with a faint top sheen. A
/// press lights it with the accent container, sinks it slightly and glows.
class _Keycap extends StatelessWidget {
  const _Keycap({
    required this.spec,
    required this.legend,
    required this.metrics,
    required this.compact,
    required this.pressed,
  });

  final _Key spec;
  final String? legend;
  final _KeyMetrics metrics;
  final bool compact;
  final Animation<double> pressed;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final accent = theme.accentPalette;
    final radius = theme.borderRadius(12);
    final base = theme.cardColor(colors.surfaceContainerHigh);
    final sheen = Color.alphaBlend(
      ShellMediaColors.contrastLight.withValues(alpha: 0.07),
      base,
    );
    final idle = spec.kind == _KeyKind.character
        ? colors.panelText
        : colors.textSecondary;
    return AnimatedBuilder(
      animation: pressed,
      builder: (context, _) {
        final t = pressed.value;
        return Transform.scale(
          scale: 1 - 0.035 * t,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.lerp(sheen, accent.container, t)!,
                  Color.lerp(base, accent.container, t)!,
                ],
              ),
              borderRadius: radius,
              border: Border.all(
                color: Color.lerp(colors.hairlineSoft, accent.primary, t)!,
              ),
              boxShadow: t == 0
                  ? null
                  : [
                      BoxShadow(
                        color: accent.primary.withValues(alpha: 0.45 * t),
                        blurRadius: 18 * t,
                      ),
                    ],
            ),
            child: _legend(Color.lerp(idle, accent.onContainer, t)!),
          ),
        );
      },
    );
  }

  Widget _legend(Color color) {
    if (spec.kind == _KeyKind.character) {
      return Padding(
        padding: const EdgeInsets.all(4),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              legend ?? '',
              maxLines: 1,
              style: metrics.character.copyWith(color: color),
            ),
          ),
        ),
      );
    }
    final style = (compact ? metrics.function : metrics.named).copyWith(
      color: color,
    );
    final text = legend;
    final icon = spec.icon;
    final glyph = icon == null
        ? null
        : Icon(
            icon,
            size: text == null ? metrics.icon : style.fontSize! * 1.4,
            color: color,
          );
    final label = text == null ? null : Text(text, maxLines: 1, style: style);
    if (glyph == null && label == null) return const SizedBox.expand();
    final parts = spec.edge == _Edge.end ? [?label, ?glyph] : [?glyph, ?label];
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: metrics.inset,
        vertical: metrics.inset * 0.8,
      ),
      child: Align(
        // Text sits on the baseline corner; a lone glyph centers vertically.
        alignment: switch (spec.edge) {
          _Edge.start when label == null => Alignment.centerLeft,
          _Edge.start => Alignment.bottomLeft,
          _Edge.center => Alignment.center,
          _Edge.end when label == null => Alignment.centerRight,
          _Edge.end => Alignment.bottomRight,
        },
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, part) in parts.indexed) ...[
                if (i > 0) const SizedBox(width: 5),
                part,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _KeyKind { character, named }

/// Where a named key's legend sits: wide keys label their outer edge.
enum _Edge { start, center, end }

sealed class _Cell {
  const _Cell(this.flex);
  final int flex;
}

class _Gap extends _Cell {
  const _Gap(super.flex);
}

class _KeyStack extends _Cell {
  const _KeyStack(this.keys, super.flex);
  final List<_Key> keys;
}

class _Key extends _Cell {
  /// A printable key; its legend follows the active XKB layout and modifiers.
  const _Key.char(this.code, this.name, [super.flex = 10])
    : kind = _KeyKind.character,
      legend = null,
      icon = null,
      edge = _Edge.center;

  const _Key(
    this.code,
    this.name, {
    this.legend,
    this.icon,
    this.edge = _Edge.center,
    int flex = 10,
  }) : kind = _KeyKind.named,
       super(flex);

  final int code;

  /// Semantic name, and the fallback legend of a printable key.
  final String name;
  final _KeyKind kind;
  final String? legend;
  final IconData? icon;
  final _Edge edge;
}

const _rows = <List<_Cell>>[
  [
    _Key(1, 'Escape', legend: 'esc', flex: 15),
    _Gap(3),
    _Key(59, 'F1', legend: 'F1'),
    _Key(60, 'F2', legend: 'F2'),
    _Key(61, 'F3', legend: 'F3'),
    _Key(62, 'F4', legend: 'F4'),
    _Gap(2),
    _Key(63, 'F5', legend: 'F5'),
    _Key(64, 'F6', legend: 'F6'),
    _Key(65, 'F7', legend: 'F7'),
    _Key(66, 'F8', legend: 'F8'),
    _Gap(2),
    _Key(67, 'F9', legend: 'F9'),
    _Key(68, 'F10', legend: 'F10'),
    _Key(87, 'F11', legend: 'F11'),
    _Key(88, 'F12', legend: 'F12'),
    _Gap(3),
    _Key(102, 'Home', legend: 'home'),
    _Key(107, 'End', legend: 'end'),
    _Key(104, 'Page Up', legend: 'pg up'),
    _Key(109, 'Page Down', legend: 'pg dn'),
    _Key(111, 'Delete', legend: 'del', flex: 15),
  ],
  [
    _Key.char(41, '`'),
    _Key.char(2, '1'),
    _Key.char(3, '2'),
    _Key.char(4, '3'),
    _Key.char(5, '4'),
    _Key.char(6, '5'),
    _Key.char(7, '6'),
    _Key.char(8, '7'),
    _Key.char(9, '8'),
    _Key.char(10, '9'),
    _Key.char(11, '0'),
    _Key.char(12, '-'),
    _Key.char(13, '='),
    _Key(
      14,
      'Backspace',
      icon: Icons.backspace_outlined,
      edge: _Edge.end,
      flex: 20,
    ),
  ],
  [
    _Key(
      15,
      'Tab',
      legend: 'tab',
      icon: Icons.keyboard_tab_rounded,
      edge: _Edge.start,
      flex: 15,
    ),
    _Key.char(16, 'q'),
    _Key.char(17, 'w'),
    _Key.char(18, 'e'),
    _Key.char(19, 'r'),
    _Key.char(20, 't'),
    _Key.char(21, 'y'),
    _Key.char(22, 'u'),
    _Key.char(23, 'i'),
    _Key.char(24, 'o'),
    _Key.char(25, 'p'),
    _Key.char(26, '['),
    _Key.char(27, ']'),
    _Key.char(43, r'\', 15),
  ],
  [
    _Key(
      58,
      'Caps Lock',
      legend: 'caps lock',
      icon: Icons.keyboard_capslock_rounded,
      edge: _Edge.start,
      flex: 18,
    ),
    _Key.char(30, 'a'),
    _Key.char(31, 's'),
    _Key.char(32, 'd'),
    _Key.char(33, 'f'),
    _Key.char(34, 'g'),
    _Key.char(35, 'h'),
    _Key.char(36, 'j'),
    _Key.char(37, 'k'),
    _Key.char(38, 'l'),
    _Key.char(39, ';'),
    _Key.char(40, "'"),
    _Key(
      28,
      'Enter',
      legend: 'enter',
      icon: Icons.keyboard_return_rounded,
      edge: _Edge.end,
      flex: 22,
    ),
  ],
  [
    _Key(42, 'Shift', legend: 'shift', edge: _Edge.start, flex: 13),
    _Key.char(86, '<'),
    _Key.char(44, 'z'),
    _Key.char(45, 'x'),
    _Key.char(46, 'c'),
    _Key.char(47, 'v'),
    _Key.char(48, 'b'),
    _Key.char(49, 'n'),
    _Key.char(50, 'm'),
    _Key.char(51, ','),
    _Key.char(52, '.'),
    _Key.char(53, '/'),
    _Key(54, 'Shift', legend: 'shift', edge: _Edge.end, flex: 27),
  ],
  [
    _Key(29, 'Ctrl', legend: 'ctrl', edge: _Edge.start, flex: 13),
    _Key(125, 'Super', icon: Icons.apps_rounded, flex: 12),
    _Key(56, 'Alt', legend: 'alt', edge: _Edge.start, flex: 12),
    _Key(57, 'Space', flex: 56),
    _Key(100, 'AltGr', legend: 'alt gr', edge: _Edge.end, flex: 12),
    _Key(97, 'Ctrl', legend: 'ctrl', edge: _Edge.end, flex: 12),
    _Key(105, 'Left', icon: Icons.arrow_left_rounded, flex: 11),
    _KeyStack([
      _Key(103, 'Up', icon: Icons.arrow_drop_up_rounded),
      _Key(108, 'Down', icon: Icons.arrow_drop_down_rounded),
    ], 11),
    _Key(106, 'Right', icon: Icons.arrow_right_rounded, flex: 11),
  ],
];
