import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

enum ShellOskKeyAction { text, key, space, backspace, enter, replace }

class ShellOskKeyIntent {
  const ShellOskKeyIntent._({
    required this.action,
    this.text,
    this.key,
    this.ctrl = false,
    this.replaced,
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

  /// Replaces [replaced], the text just before the cursor, with [text].
  const ShellOskKeyIntent.replace(String replaced, String text)
    : this._(action: ShellOskKeyAction.replace, text: text, replaced: replaced);

  final ShellOskKeyAction action;
  final String? text;
  final String? key;
  final bool ctrl;
  final String? replaced;
}

/// The word being typed, for suggestions.
class ShellOskWordRequest {
  const ShellOskWordRequest({
    required this.serial,
    required this.word,
    required this.touchX,
    required this.touchY,
    required this.manualCapital,
  });

  final int serial;
  final String word;

  /// Where each letter's key was touched, in key pitches from its center;
  /// NaN when unknown. One per character, or both empty.
  final List<double> touchX;
  final List<double> touchY;

  /// The user capitalized the first letter, not automatic capitals.
  final bool manualCapital;
}

/// The software keyboard's keys.
///
/// One recognizer takes every touch on the panel and maps it to the key
/// whose square band contains it, gaps and margins included. A key types
/// when its finger lifts, or when the next finger lands first. Shift and
/// Backspace act as soon as they are touched.
///
/// With [predictions] the panel shows suggestions for the word being typed
/// above the keys, corrects a mistyped word when a space or punctuation
/// follows it, and undoes that correction on the next Backspace.
class ShellOskPanel extends StatefulWidget {
  const ShellOskPanel({
    super.key,
    this.onKey,
    this.onKeyDown,
    this.textInputStates,
    this.predictions,
    this.onPredict,
  });

  final ValueChanged<ShellOskKeyIntent>? onKey;

  /// A finger landed on a key.
  final VoidCallback? onKeyDown;

  /// The focused editor's state; its content type drives automatic
  /// capitals and the first layer.
  final Stream<DenialTextInputState>? textInputStates;

  /// Answers to [onPredict]. Without them the panel has no strip.
  final Stream<DenialTextPrediction>? predictions;
  final ValueChanged<ShellOskWordRequest>? onPredict;

  @override
  State<ShellOskPanel> createState() => _ShellOskPanelState();
}

enum _Shift { off, once, locked }

enum _AutoCapitals { none, sentences, words }

/// zwp_text_input_v3 content hints and purposes the panel acts on.
abstract final class _ContentType {
  static const hintCompletion = 0x1;
  static const hintSpellcheck = 0x2;
  static const hintAutoCapitalization = 0x4;
  static const hintLowercase = 0x8;
  static const hintUppercase = 0x10;
  static const hintTitlecase = 0x20;
  static const hintHidden = 0x40;
  static const hintSensitive = 0x80;

  static const purposeNormal = 0;
  static const purposeAlpha = 1;
  static const purposeName = 7;
  static const numericPurposes = {2, 3, 4, 9};
}

class _Touch {
  _Touch(this.key, this.position);

  _PlacedKey key;
  Offset position;
  final Stopwatch held = Stopwatch()..start();

  /// The key already acted; lifting the finger only releases it.
  bool done = false;
  Timer? longPress;

  /// Accented letters a long press opened, and the one under the finger.
  List<String>? accents;
  int accent = 0;
}

/// A correction the next Backspace takes back.
class _Autocorrection {
  const _Autocorrection(this.typed, this.correction, this.separator);

  final String typed;
  final String correction;
  final String separator;
}

/// Accented letters a long press offers, per language.
const _accents = <String, Map<String, List<String>>>{
  'it': {
    'a': ['à'],
    'e': ['è', 'é'],
    'i': ['ì'],
    'o': ['ò'],
    'u': ['ù'],
  },
};

/// Every row but the bottom one is this much taller than it.
const _tallRow = 1.067;

const _separators = ' \n.,!?;:';

class _ShellOskPanelState extends State<ShellOskPanel> {
  static const _shiftDoubleTap = Duration(milliseconds: 350);
  static const _longPress = Duration(milliseconds: 450);
  static const _repeatDelay = Duration(milliseconds: 400);
  static const _repeatInterval = Duration(milliseconds: 55);

  late final _OskTouchRecognizer _recognizer = _OskTouchRecognizer(this);
  final _pressed = _PressedKeys();
  final _popup = ValueNotifier<_Bubble?>(null);
  final _touches = <int, _Touch>{};
  _OskGeometry? _geometry;
  bool _visible = true;

  _OskLayer _layer = _OskLayer.letters;
  _Shift _shift = _Shift.off;

  /// Shift was set by automatic capitals, which may also clear it.
  bool _shiftAutomatic = false;
  bool _ctrlArmed = false;
  Duration? _lastShiftDown;
  Timer? _repeat;

  StreamSubscription<DenialTextInputState>? _inputSubscription;
  DenialTextInputState? _input;

  /// The end of what was typed into the focused editor, as far as the panel
  /// knows, and whether it reaches back to the editor's activation.
  String _typed = '';
  bool _typedFromStart = false;

  StreamSubscription<DenialTextPrediction>? _predictionSubscription;
  final _strip = ValueNotifier<List<String>>(const []);
  int _predictionSerial = 0;

  /// The word last asked about, and its answer once it came.
  String? _requestedWord;
  DenialTextPrediction? _prediction;

  /// Where each letter of the current word was touched; see
  /// [ShellOskWordRequest.touchX].
  final _wordTouches = <Offset>[];
  bool _wordManualCapital = false;
  Set<String> _languages = const {};
  _Autocorrection? _undo;

  @override
  void initState() {
    super.initState();
    _inputSubscription = widget.textInputStates?.listen(_handleInput);
    _listenPredictions();
  }

  @override
  void didUpdateWidget(ShellOskPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textInputStates != widget.textInputStates) {
      unawaited(_inputSubscription?.cancel());
      _inputSubscription = widget.textInputStates?.listen(_handleInput);
    }
    if (oldWidget.predictions != widget.predictions) {
      unawaited(_predictionSubscription?.cancel());
      _listenPredictions();
    }
  }

  void _listenPredictions() {
    _predictionSubscription = widget.predictions?.listen(_handlePrediction);
    // An empty word tells which languages are installed.
    widget.onPredict?.call(
      ShellOskWordRequest(
        serial: ++_predictionSerial,
        word: '',
        touchX: const [],
        touchY: const [],
        manualCapital: false,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _visible) return;
    _visible = visible;
    // The mobile sheet is retained while hidden: each showing starts fresh.
    _releaseAll();
    _beginEditor();
  }

  @override
  void dispose() {
    unawaited(_inputSubscription?.cancel());
    unawaited(_predictionSubscription?.cancel());
    _releaseAll();
    _recognizer.dispose();
    _pressed.dispose();
    _popup.dispose();
    _strip.dispose();
    super.dispose();
  }

  void _handleInput(DenialTextInputState input) {
    final previous = _input;
    _input = input;
    final begins =
        input.active &&
        (previous == null ||
            !previous.active ||
            previous.activationSerial != input.activationSerial ||
            previous.contentPurpose != input.contentPurpose ||
            previous.contentHint != input.contentHint);
    if (begins) setState(_beginEditor);
  }

  void _beginEditor() {
    final input = _input;
    final active = input != null && input.active;
    _typed = '';
    _typedFromStart = true;
    _ctrlArmed = false;
    _undo = null;
    _wordTouches.clear();
    _wordManualCapital = false;
    _requestedWord = null;
    _prediction = null;
    _strip.value = const [];
    _layer =
        active && _ContentType.numericPurposes.contains(input.contentPurpose)
        ? _OskLayer.numbers
        : _OskLayer.letters;
    _shiftAutomatic = false;
    _shift = active && input.contentHint & _ContentType.hintUppercase != 0
        ? _Shift.locked
        : _Shift.off;
    _updateAutoShift();
  }

  _AutoCapitals get _autoCapitals {
    final input = _input;
    if (input == null || !input.active) return _AutoCapitals.none;
    final hint = input.contentHint;
    const refused =
        _ContentType.hintLowercase |
        _ContentType.hintHidden |
        _ContentType.hintSensitive;
    if (hint & refused != 0) return _AutoCapitals.none;
    if (hint & _ContentType.hintTitlecase != 0 ||
        input.contentPurpose == _ContentType.purposeName) {
      return _AutoCapitals.words;
    }
    if (hint & _ContentType.hintAutoCapitalization != 0) {
      return _AutoCapitals.sentences;
    }
    // An editor that states hints without capitals does not want them.
    if (hint != 0 || input.legacy) return _AutoCapitals.none;
    return input.contentPurpose == _ContentType.purposeNormal ||
            input.contentPurpose == _ContentType.purposeAlpha
        ? _AutoCapitals.sentences
        : _AutoCapitals.none;
  }

  bool get _wantsCapital {
    final mode = _autoCapitals;
    if (mode == _AutoCapitals.none || _layer != _OskLayer.letters) {
      return false;
    }
    if (_typed.isEmpty) return _typedFromStart;
    final last = _typed[_typed.length - 1];
    if (last == '\n') return true;
    if (last != ' ') return false;
    if (mode == _AutoCapitals.words) return true;
    final sentence = _typed.trimRight();
    if (sentence.isEmpty) return _typedFromStart;
    return '.!?'.contains(sentence[sentence.length - 1]);
  }

  /// Turns automatic Shift on where a capital is due and off where it is
  /// no longer, leaving a Shift the user chose alone.
  void _updateAutoShift() {
    if (_shift == _Shift.locked) return;
    final wanted = _wantsCapital;
    if (wanted && _shift == _Shift.off) {
      _shift = _Shift.once;
      _shiftAutomatic = true;
    } else if (!wanted && _shift == _Shift.once && _shiftAutomatic) {
      _shift = _Shift.off;
      _shiftAutomatic = false;
    }
  }

  void _remember(String text) {
    _typed += text;
    if (_typed.length > 64) {
      _typed = _typed.substring(_typed.length - 32);
      _typedFromStart = false;
    }
  }

  /// The cursor moved or text changed in a way the panel cannot follow.
  void _forgetTyped() {
    _typed = '';
    _typedFromStart = false;
  }

  void _replaceTyped(String replaced, String text) {
    if (_typed.endsWith(replaced)) {
      _typed = _typed.substring(0, _typed.length - replaced.length) + text;
    } else {
      _forgetTyped();
    }
  }

  // Words.

  static bool _isWordCharacter(String character) =>
      character == "'" || character.toLowerCase() != character.toUpperCase();

  /// The word just before the cursor.
  String get _word {
    var start = _typed.length;
    while (start > 0 && _isWordCharacter(_typed[start - 1])) {
      start--;
    }
    while (start < _typed.length && _typed[start] == "'") {
      start++;
    }
    return _typed.substring(start);
  }

  /// Suggestions suit the editor.
  bool get _predicts {
    final input = _input;
    if (widget.onPredict == null || input == null || !input.active) {
      return false;
    }
    if (input.legacy ||
        input.contentHint &
                (_ContentType.hintHidden | _ContentType.hintSensitive) !=
            0) {
      return false;
    }
    return input.contentPurpose == _ContentType.purposeNormal ||
        input.contentPurpose == _ContentType.purposeAlpha ||
        input.contentPurpose == _ContentType.purposeName;
  }

  /// Corrections suit the editor: not names, and not an editor that
  /// states hints without asking for spellchecking or completion.
  bool get _autocorrects {
    final input = _input;
    if (!_predicts || input!.contentPurpose == _ContentType.purposeName) {
      return false;
    }
    final hint = input.contentHint;
    return hint == 0 ||
        hint & (_ContentType.hintSpellcheck | _ContentType.hintCompletion) != 0;
  }

  static const _unknownTouch = Offset(double.nan, double.nan);

  /// Keeps the word's touches in step with [_typed] and asks about a
  /// changed word.
  void _wordChanged() {
    final word = _word;
    final length = word.runes.length;
    if (_wordTouches.length > length) {
      _wordTouches.removeRange(length, _wordTouches.length);
    }
    while (_wordTouches.length < length) {
      // A word Backspace returned to: where it was touched is gone.
      _wordTouches.insert(0, _unknownTouch);
    }
    if (length == 0) _wordManualCapital = false;
    if (word == _requestedWord) return;
    _requestedWord = word;
    _prediction = null;
    if (word.isEmpty || !_predicts) {
      _strip.value = const [];
      return;
    }
    widget.onPredict?.call(
      ShellOskWordRequest(
        serial: ++_predictionSerial,
        word: word,
        touchX: [for (final touch in _wordTouches) touch.dx],
        touchY: [for (final touch in _wordTouches) touch.dy],
        manualCapital: _wordManualCapital,
      ),
    );
  }

  void _handlePrediction(DenialTextPrediction prediction) {
    _languages = prediction.languages.toSet();
    final word = prediction.word;
    if (prediction.serial != _predictionSerial ||
        word.isEmpty ||
        word != _requestedWord) {
      return;
    }
    _prediction = prediction;
    final correction = prediction.correction;
    final committed = _autocorrects ? correction : null;
    _strip.value = [
      committed ?? word,
      if (committed != null) word else ?correction,
      ...prediction.suggestions,
    ].take(3).toList(growable: false);
  }

  /// A space or punctuation mark that replaces a mistyped word with its
  /// correction, the mark included: one replacement, never a replacement
  /// and a key, which an editor may apply in either order. Enter types
  /// as it is; it may submit.
  _Autocorrection? _correctWord(String separator) {
    final word = _word;
    final correction = _prediction?.correction;
    if (!_autocorrects ||
        separator == '\n' ||
        correction == null ||
        word.isEmpty ||
        word != _requestedWord) {
      return null;
    }
    widget.onKey?.call(ShellOskKeyIntent.replace(word, correction + separator));
    _replaceTyped(word, correction + separator);
    return _Autocorrection(word, correction, separator);
  }

  void _pickSuggestion(String choice) {
    final word = _word;
    if (word.isEmpty) return;
    widget.onKeyDown?.call();
    _update(() {
      if (choice == word) {
        widget.onKey?.call(const ShellOskKeyIntent.space());
      } else {
        widget.onKey?.call(ShellOskKeyIntent.replace(word, '$choice '));
      }
      _replaceTyped(word, '$choice ');
    });
  }

  List<String> _accentsFor(_OskKeySpec spec) {
    if (!spec.isLetter) return const [];
    return {
      for (final language in _languages) ...?_accents[language]?[spec.value],
    }.toList(growable: false);
  }

  Offset _touchOffset(_Touch touch) {
    final geometry = _geometry;
    if (geometry == null) return _unknownTouch;
    final center = touch.key.rect.center;
    return Offset(
      (touch.position.dx - center.dx) / geometry.pitch,
      (touch.position.dy - center.dy) / geometry.rowPitch,
    );
  }

  // Touches, called by the recognizer.

  bool _touchDown(int pointer, Offset position, Duration time) {
    final key = _geometry?.keyAt(position);
    if (!_visible || key == null) return false;
    // A finger that lands commits the keys still held: fast typists touch
    // the next key before lifting the last.
    for (final MapEntry(key: other, value: touch)
        in _touches.entries.toList()) {
      if (!touch.done && touch.key.spec.rollsOver) {
        _recognizer.claim(other);
        touch.done = true;
        touch.longPress?.cancel();
        _commit(touch.key.spec, touch: touch);
      }
    }
    final touch = _Touch(key, position);
    _touches[pointer] = touch;
    widget.onKeyDown?.call();
    _pressed.press(key.spec);
    _popup.value = key.spec.showsPopup ? _Bubble(key) : null;
    if (_accentsFor(key.spec).isNotEmpty) {
      touch.longPress = Timer(_longPress, () => _openAccents(touch));
    }
    switch (key.spec.control) {
      case _OskControl.shift:
        touch.done = true;
        _tapShift(time);
      case _OskControl.backspace:
        touch.done = true;
        final repeat = !_ctrlArmed;
        _backspace();
        if (repeat) {
          _repeat?.cancel();
          _repeat = Timer(_repeatDelay, () {
            _repeat = Timer.periodic(_repeatInterval, (_) => _backspace());
          });
        }
      case _OskControl.symbols:
        touch.longPress = Timer(_longPress, () => _armCtrl(touch));
      default:
        break;
    }
    return true;
  }

  void _touchMove(int pointer, Offset position) {
    final touch = _touches[pointer];
    final geometry = _geometry;
    if (touch == null || touch.done || geometry == null) return;
    final accents = touch.accents;
    if (accents != null) {
      final bubble = _Bubble(touch.key, accents, 0);
      final cell = bubble.cellWidth;
      final left = bubble.left(geometry.size.width);
      final index = ((position.dx - left) / cell).floor().clamp(
        0,
        accents.length - 1,
      );
      if (index != touch.accent) {
        touch.accent = index;
        _popup.value = _Bubble(touch.key, accents, index);
      }
      return;
    }
    touch.position = position;
    if (touch.key.hit.inflate(geometry.slideMargin).contains(position)) return;
    final next = geometry.keyAt(position);
    if (next == null || next.spec == touch.key.spec) return;
    // The finger slid to another key: it types that one instead.
    touch.longPress?.cancel();
    touch.longPress = null;
    _pressed.lift(touch.key.spec, heldFor: _PressedKeys.minimum);
    touch.key = next;
    _pressed.press(next.spec);
    _popup.value = next.spec.showsPopup ? _Bubble(next) : null;
    if (_accentsFor(next.spec).isNotEmpty) {
      touch.longPress = Timer(_longPress, () => _openAccents(touch));
    }
  }

  void _openAccents(_Touch touch) {
    touch.longPress = null;
    final accents = _accentsFor(touch.key.spec);
    if (touch.done || accents.isEmpty) return;
    touch.accents = accents;
    touch.accent = 0;
    widget.onKeyDown?.call();
    _popup.value = _Bubble(touch.key, accents, 0);
  }

  void _touchUp(int pointer) {
    final touch = _touches.remove(pointer);
    if (touch == null) return;
    if (!touch.done) _commit(touch.key.spec, touch: touch);
    _release(touch);
  }

  void _touchCancel(int pointer) {
    final touch = _touches.remove(pointer);
    if (touch != null) _release(touch);
  }

  void _release(_Touch touch) {
    touch.longPress?.cancel();
    if (touch.key.spec.control == _OskControl.backspace) {
      _repeat?.cancel();
      _repeat = null;
    }
    _pressed.lift(touch.key.spec, heldFor: touch.held.elapsed);
    if (_popup.value?.placed.spec == touch.key.spec) _popup.value = null;
  }

  void _releaseAll() {
    for (final touch in _touches.values) {
      touch.longPress?.cancel();
    }
    _touches.clear();
    _repeat?.cancel();
    _repeat = null;
    _pressed.clear();
    _popup.value = null;
  }

  // Key actions.

  /// Applies [change], then automatic capitals, and rebuilds only when
  /// the keys look different.
  /// A correction survives only until the next action.
  void _update(VoidCallback change) {
    final before = (_layer, _shift, _ctrlArmed);
    final undo = _undo;
    change();
    if (identical(_undo, undo)) _undo = null;
    _updateAutoShift();
    _wordChanged();
    if ((_layer, _shift, _ctrlArmed) != before) setState(() {});
  }

  void _commit(_OskKeySpec spec, {_Touch? touch}) {
    final control = spec.control;
    if (control != null) {
      _handleControl(control);
      return;
    }
    final capital = _shift != _Shift.off;
    final named = _ctrlArmed ? spec.namedKey(capital: capital) : null;
    if (named != null) {
      widget.onKey?.call(ShellOskKeyIntent.key(named, ctrl: true));
      _update(() {
        _ctrlArmed = false;
        _forgetTyped();
      });
      return;
    }
    final accents = touch?.accents;
    final plain = accents?[touch!.accent] ?? spec.value ?? '';
    final text = capital && spec.isLetter ? plain.toUpperCase() : plain;
    if (text.isNotEmpty && _separators.contains(text)) {
      _sendSeparator(ShellOskKeyIntent.text(text), text);
      return;
    }
    widget.onKey?.call(ShellOskKeyIntent.text(text));
    _update(() {
      if (_isWordCharacter(text)) {
        if (_word.isEmpty) {
          _wordManualCapital = capital && !_shiftAutomatic;
        }
        _wordTouches.add(
          touch == null || !spec.isLetter ? _unknownTouch : _touchOffset(touch),
        );
      }
      _remember(text);
      if (_shift == _Shift.once && spec.isLetter) {
        _shift = _Shift.off;
        _shiftAutomatic = false;
      }
    });
  }

  /// A space, newline or punctuation mark, after correcting the word
  /// before it.
  void _sendSeparator(ShellOskKeyIntent intent, String text) {
    _update(() {
      final correction = _correctWord(text);
      if (correction == null) {
        widget.onKey?.call(intent);
        _remember(text);
      } else {
        _undo = correction;
      }
    });
  }

  void _handleControl(_OskControl control) {
    switch (control) {
      case _OskControl.shift:
        _tapShift(null);
      case _OskControl.symbols:
        _setLayer(_OskLayer.numbers);
      case _OskControl.extraSymbols:
        _setLayer(_OskLayer.symbols);
      case _OskControl.letters:
        _setLayer(_OskLayer.letters);
      case _OskControl.space:
        _sendTyped(const ShellOskKeyIntent.space(), ' ');
      case _OskControl.backspace:
        _backspace();
      case _OskControl.enter:
        _sendTyped(const ShellOskKeyIntent.enter(), '\n');
      case _OskControl.arrowUp:
        _sendCursorKey(ShellOskKeyIntent.key('Up', ctrl: _ctrlArmed));
      case _OskControl.arrowDown:
        _sendCursorKey(ShellOskKeyIntent.key('Down', ctrl: _ctrlArmed));
    }
  }

  void _tapShift(Duration? time) {
    final last = _lastShiftDown;
    final quick = time != null && last != null && time - last < _shiftDoubleTap;
    _lastShiftDown = time;
    setState(() {
      _shiftAutomatic = false;
      _shift = switch (_shift) {
        _Shift.off => quick ? _Shift.locked : _Shift.once,
        _Shift.once => quick ? _Shift.locked : _Shift.off,
        _Shift.locked => _Shift.off,
      };
    });
  }

  void _backspace() {
    if (_ctrlArmed) {
      _sendCursorKey(const ShellOskKeyIntent.backspace(ctrl: true));
      return;
    }
    final undo = _undo;
    if (undo != null) {
      final corrected = undo.correction + undo.separator;
      final typed = undo.typed + undo.separator;
      widget.onKey?.call(ShellOskKeyIntent.replace(corrected, typed));
      _update(() => _replaceTyped(corrected, typed));
      return;
    }
    widget.onKey?.call(const ShellOskKeyIntent.backspace());
    _update(() {
      if (_typed.isNotEmpty) _typed = _typed.substring(0, _typed.length - 1);
    });
  }

  void _armCtrl(_Touch touch) {
    touch.longPress = null;
    if (touch.done) return;
    touch.done = true;
    widget.onKeyDown?.call();
    setState(() {
      _ctrlArmed = true;
      _shift = _Shift.off;
      _shiftAutomatic = false;
    });
  }

  void _setLayer(_OskLayer layer) {
    _update(() {
      _layer = layer;
      _shift = _Shift.off;
      _shiftAutomatic = false;
      _ctrlArmed = false;
    });
  }

  /// Space or Enter: typed text, or a Ctrl shortcut while Ctrl is armed.
  void _sendTyped(ShellOskKeyIntent intent, String text) {
    if (_ctrlArmed) {
      _sendCursorKey(
        intent.action == ShellOskKeyAction.space
            ? const ShellOskKeyIntent.space(ctrl: true)
            : const ShellOskKeyIntent.enter(ctrl: true),
      );
      return;
    }
    _sendSeparator(intent, text);
  }

  /// A key after which the panel no longer knows what precedes the cursor.
  void _sendCursorKey(ShellOskKeyIntent intent) {
    widget.onKey?.call(intent);
    _update(() {
      _ctrlArmed = false;
      _forgetTyped();
    });
  }

  // Layout.

  List<_OskRowData> get _rows => switch (_layer) {
    _OskLayer.letters => _letterRows,
    _OskLayer.numbers => _numberRows,
    _OskLayer.symbols => _extraSymbolRows,
  };

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final suggestions = widget.predictions == null ? null : _strip;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 560 || constraints.maxHeight < 390;
        final stripHeight = suggestions == null
            ? 0.0
            : ReferenceShellMetrics.oskSuggestionStripHeight;
        final horizontalPadding = compact ? 8.0 : 12.0;
        final padding = EdgeInsets.fromLTRB(
          horizontalPadding,
          suggestions != null ? 2.0 : (compact ? 10.0 : 14.0),
          horizontalPadding,
          math.max(safeBottom + 6, compact ? 22.0 : 26.0),
        );
        final keyGap = compact ? 5.0 : 6.0;
        final rowGap = compact ? 6.0 : 7.0;
        final size = Size(
          constraints.maxWidth,
          math.max(0, constraints.maxHeight - stripHeight),
        );
        final maxRowHeight = rows.length <= 4
            ? (compact ? 78.0 : 88.0)
            : (compact ? 70.0 : 76.0);
        // Rows always fit the panel, however short a landscape view makes it.
        final rowHeight =
            ((size.height - padding.vertical - rowGap * (rows.length - 1)) /
                    (rows.length + (rows.length - 1) * (_tallRow - 1)))
                .clamp(0.0, maxRowHeight)
                .toDouble();
        final geometry = _geometry = _OskGeometry.layout(
          rows,
          size: size,
          padding: padding,
          keyGap: keyGap,
          rowGap: rowGap,
          rowHeight: rowHeight,
        );

        final keys = Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _recognizer.addPointer,
          child: SizedBox.fromSize(
            size: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: ListenableBuilder(
                      listenable: _pressed,
                      builder: (context, _) => Stack(
                        children: [
                          for (final key in geometry.keys)
                            Positioned.fromRect(
                              rect: key.rect,
                              child: _OskKeyCap(
                                spec: key.spec,
                                shift: _shift,
                                ctrlArmed: _ctrlArmed,
                                pressed: _pressed.contains(key.spec),
                                onActivate: () => _commit(key.spec),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                ValueListenableBuilder<_Bubble?>(
                  valueListenable: _popup,
                  builder: (context, bubble, _) => bubble == null
                      ? const Positioned(left: 0, top: 0, child: SizedBox())
                      : _KeyPopup(
                          bubble: bubble,
                          capital: _shift != _Shift.off,
                          width: size.width,
                        ),
                ),
              ],
            ),
          ),
        );
        if (suggestions == null) return keys;
        return Column(
          children: [
            SizedBox(
              height: stripHeight,
              child: ValueListenableBuilder<List<String>>(
                valueListenable: suggestions,
                builder: (context, words, _) =>
                    _SuggestionStrip(words: words, onSelected: _pickSuggestion),
              ),
            ),
            keys,
          ],
        );
      },
    );
  }
}

/// Takes the panel's touches in the gesture arena. A key types only once
/// this recognizer owns its touch, so a sheet drag that wins first cancels
/// the key instead of typing it.
class _OskTouchRecognizer extends OneSequenceGestureRecognizer {
  _OskTouchRecognizer(this._panel) : super(debugOwner: _panel);

  final _ShellOskPanelState _panel;

  void claim(int pointer) =>
      resolvePointer(pointer, GestureDisposition.accepted);

  @override
  void handleEvent(PointerEvent event) {
    switch (event) {
      case PointerDownEvent():
        if (!_panel._touchDown(
          event.pointer,
          event.localPosition,
          event.timeStamp,
        )) {
          resolvePointer(event.pointer, GestureDisposition.rejected);
        }
      case PointerMoveEvent():
        _panel._touchMove(event.pointer, event.localPosition);
      case PointerUpEvent():
        claim(event.pointer);
        _panel._touchUp(event.pointer);
      case PointerCancelEvent():
        resolvePointer(event.pointer, GestureDisposition.rejected);
        _panel._touchCancel(event.pointer);
      default:
        break;
    }
    stopTrackingIfPointerNoLongerDown(event);
  }

  @override
  void rejectGesture(int pointer) {
    _panel._touchCancel(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'keyboard keys';
}

/// Keys under a finger, and keys just released that stay lit a moment so
/// a quick tap still shows.
class _PressedKeys extends ChangeNotifier {
  static const minimum = Duration(milliseconds: 90);

  final _held = <_OskKeySpec, int>{};
  final _lingering = <_OskKeySpec, Timer>{};

  bool contains(_OskKeySpec spec) =>
      _held.containsKey(spec) || _lingering.containsKey(spec);

  void press(_OskKeySpec spec) {
    _lingering.remove(spec)?.cancel();
    _held.update(spec, (count) => count + 1, ifAbsent: () => 1);
    notifyListeners();
  }

  void lift(_OskKeySpec spec, {required Duration heldFor}) {
    final count = _held[spec];
    if (count == null) return;
    if (count > 1) {
      _held[spec] = count - 1;
      return;
    }
    _held.remove(spec);
    final remaining = minimum - heldFor;
    if (remaining > Duration.zero) {
      _lingering[spec] = Timer(remaining, () {
        _lingering.remove(spec);
        notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  void clear() {
    for (final timer in _lingering.values) {
      timer.cancel();
    }
    _lingering.clear();
    _held.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final timer in _lingering.values) {
      timer.cancel();
    }
    super.dispose();
  }
}

class _PlacedKey {
  const _PlacedKey(this.spec, this.rect, this.hit);

  final _OskKeySpec spec;

  /// Where the key is drawn.
  final Rect rect;

  /// Where a touch reaches it: the key with half of each gap around it,
  /// out to the panel's edges for the outer keys.
  final Rect hit;
}

class _OskGeometry {
  const _OskGeometry._(
    this.rows,
    this.slideMargin,
    this.size,
    this.pitch,
    this.rowPitch,
  );

  factory _OskGeometry.layout(
    List<_OskRowData> data, {
    required Size size,
    required EdgeInsets padding,
    required double keyGap,
    required double rowGap,
    required double rowHeight,
  }) {
    final count = data.length;
    double heightOf(int index) =>
        index == count - 1 ? rowHeight : rowHeight * _tallRow;
    var y =
        size.height -
        padding.bottom -
        rowGap * (count - 1) -
        List.generate(count, heightOf).fold(0.0, (sum, h) => sum + h);
    final inner = size.width - padding.horizontal;
    final rows = <List<_PlacedKey>>[];
    for (var index = 0; index < count; index++) {
      final row = data[index];
      final height = heightOf(index);
      final hitTop = index == 0 ? 0.0 : y - rowGap / 2;
      final hitBottom = index == count - 1
          ? size.height
          : y + height + rowGap / 2;
      final inset = math.min(row.sideInset, inner * 0.08);
      final flex = row.keys.fold<int>(0, (sum, key) => sum + key.flex);
      final unit = (inner - 2 * inset - keyGap * (row.keys.length - 1)) / flex;
      var x = padding.left + inset;
      final placed = <_PlacedKey>[];
      for (var column = 0; column < row.keys.length; column++) {
        final spec = row.keys[column];
        final width = unit * spec.flex;
        placed.add(
          _PlacedKey(
            spec,
            Rect.fromLTWH(x, y, width, height),
            Rect.fromLTRB(
              column == 0 ? 0.0 : x - keyGap / 2,
              hitTop,
              column == row.keys.length - 1
                  ? size.width
                  : x + width + keyGap / 2,
              hitBottom,
            ),
          ),
        );
        x += width + keyGap;
      }
      rows.add(placed);
      y += height + rowGap;
    }
    // A finger must leave its key by a quarter key before it slides on.
    final slideMargin = rows.isEmpty || rows.first.isEmpty
        ? 0.0
        : rows.first.first.rect.width * 0.25;
    final first = rows.isEmpty ? const <_PlacedKey>[] : rows.first;
    final pitch = first.length < 2
        ? 1.0
        : first[1].rect.left - first[0].rect.left;
    final rowPitch = rows.length < 2 || rows[1].isEmpty || rows[0].isEmpty
        ? rowHeight + rowGap
        : rows[1].first.rect.top - rows[0].first.rect.top;
    return _OskGeometry._(rows, slideMargin, size, pitch, rowPitch);
  }

  final List<List<_PlacedKey>> rows;
  final double slideMargin;
  final Size size;

  /// From one letter's center to the next, and from row to row.
  final double pitch;
  final double rowPitch;

  Iterable<_PlacedKey> get keys => rows.expand((row) => row);

  _PlacedKey? keyAt(Offset position) {
    for (final row in rows) {
      if (row.isEmpty) continue;
      final band = row.first.hit;
      if (position.dy < band.top || position.dy >= band.bottom) continue;
      for (final key in row) {
        if (position.dx >= key.hit.left && position.dx < key.hit.right) {
          return key;
        }
      }
    }
    return null;
  }
}

class _OskKeyCap extends StatelessWidget {
  const _OskKeyCap({
    required this.spec,
    required this.shift,
    required this.ctrlArmed,
    required this.pressed,
    required this.onActivate,
  });

  final _OskKeySpec spec;
  final _Shift shift;
  final bool ctrlArmed;
  final bool pressed;

  /// Types the key for assistive technology, which has no touch.
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final control = spec.control;
    final theme = context.shellTheme;
    final accent = ShellTheme.of(context).accent;
    final selected = spec.isSelected(shift: shift, ctrlArmed: ctrlArmed);
    final capital = shift != _Shift.off;
    var background = selected
        ? theme.accentPalette.container
        : control == _OskControl.space
        ? context.shellColors.surfaceContainerHighest
        : control != null
        ? context.shellColors.surfaceContainer
        : context.shellColors.surfaceContainerHigh;
    if (pressed) {
      background = Color.lerp(
        background,
        selected ? theme.accentPalette.onContainer : accent,
        0.4,
      )!;
    }
    final foreground = selected
        ? theme.accentPalette.onContainer
        : control == null || pressed
        ? context.shellColors.panelText
        : context.shellColors.textSecondary;
    final icon = control == _OskControl.shift && shift == _Shift.locked
        ? Icons.keyboard_capslock_rounded
        : spec.icon;

    return Semantics(
      button: true,
      selected: selected,
      label: spec.semanticLabel(shift: shift, l10n: context.l10n),
      onTap: onActivate,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: theme.borderRadius(12),
          border: Border.all(
            color: selected || pressed
                ? accent
                : context.shellColors.hairlineSoft,
          ),
        ),
        child: Center(
          child: icon == null
              ? _OskKeyLabel(
                  label: spec.labelText(
                    capital: capital,
                    ctrlArmed: ctrlArmed,
                    l10n: context.l10n,
                  ),
                  color: foreground,
                  isWide: spec.flex >= 28,
                )
              : Icon(icon, color: foreground, size: 30),
        ),
      ),
    );
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
      fontSize: isWide ? 22.5 : 25,
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

/// What shows above a held key: its character, or the accented letters
/// a long press offered with the chosen one lit.
class _Bubble {
  const _Bubble(this.placed, [this.choices, this.selected = 0]);

  final _PlacedKey placed;
  final List<String>? choices;
  final int selected;

  int get _count => choices?.length ?? 1;

  double get cellWidth => math.max(placed.rect.width + 12, 48.0);

  double get width => cellWidth * _count;

  double left(double panelWidth) => (placed.rect.center.dx - cellWidth / 2)
      .clamp(0.0, math.max(0.0, panelWidth - width))
      .toDouble();
}

class _KeyPopup extends StatelessWidget {
  const _KeyPopup({
    required this.bubble,
    required this.capital,
    required this.width,
  });

  final _Bubble bubble;
  final bool capital;
  final double width;

  @override
  Widget build(BuildContext context) {
    final rect = bubble.placed.rect;
    final popupHeight = rect.height * 1.15;
    final choices = bubble.choices;
    String shown(String text) => capital ? text.toUpperCase() : text;
    final labels = choices == null
        ? [bubble.placed.spec.outputText(capital: capital)]
        : [for (final choice in choices) shown(choice)];
    final style = ShellText.cardTitle.copyWith(
      color: context.shellColors.panelText,
      fontSize: 37.5,
      fontWeight: FontWeight.w600,
      height: 1,
    );
    return Positioned(
      left: bubble.left(width),
      top: rect.top - popupHeight - 6,
      width: bubble.width,
      height: popupHeight,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.shellColors.surfaceContainerHighest,
            borderRadius: context.shellTheme.borderRadius(14),
            border: Border.all(color: context.shellColors.hairline),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 12,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              for (var index = 0; index < labels.length; index++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: choices != null && index == bubble.selected
                            ? context.shellTheme.accentPalette.container
                            : null,
                        borderRadius: context.shellTheme.borderRadius(10),
                      ),
                      child: Center(
                        child: Text(
                          labels[index],
                          softWrap: false,
                          style: choices != null && index == bubble.selected
                              ? style.copyWith(
                                  color: context
                                      .shellTheme
                                      .accentPalette
                                      .onContainer,
                                )
                              : style,
                        ),
                      ),
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

/// Three suggestions, the one a space commits in the middle.
class _SuggestionStrip extends StatelessWidget {
  const _SuggestionStrip({required this.words, required this.onSelected});

  final List<String> words;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    String? at(int index) => index < words.length ? words[index] : null;
    final slots = [at(1), at(0), at(2)];
    final divider = SizedBox(
      width: 1,
      height: 26,
      child: ColoredBox(color: context.shellColors.hairline),
    );
    return Row(
      children: [
        for (var index = 0; index < slots.length; index++) ...[
          if (index > 0) divider,
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: slots[index] == null || onSelected == null
                  ? null
                  : () => onSelected!(slots[index]!),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    slots[index] ?? '',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.cardTitle.copyWith(
                      color: context.shellColors.panelText,
                      // The letter keys' label size.
                      fontSize: 25,
                      fontWeight: FontWeight.w400,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
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
      icon = null;

  const _OskKeySpec.control(this.control, {this.icon, this.flex = 14})
    : value = null;

  final String? value;
  final _OskControl? control;
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

  bool get showsPopup => control == null;

  /// Types when the next finger lands, without waiting for its own lift.
  bool get rollsOver => control == null || control == _OskControl.space;

  String outputText({required bool capital}) {
    final text = value ?? '';
    return capital && isLetter ? text.toUpperCase() : text;
  }

  String labelText({
    required bool capital,
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
    return outputText(capital: capital);
  }

  String semanticLabel({
    required _Shift shift,
    required AppLocalizations l10n,
  }) {
    return switch (control) {
      _OskControl.shift =>
        shift == _Shift.locked ? l10n.oskCapsLock : l10n.oskShift,
      _OskControl.symbols => l10n.oskNumbersAndSymbols,
      _OskControl.extraSymbols => l10n.oskMoreSymbols,
      _OskControl.letters => l10n.oskLetters,
      _OskControl.space => l10n.oskSpace,
      _OskControl.backspace => l10n.oskBackspace,
      _OskControl.enter => l10n.oskEnter,
      _OskControl.arrowUp => l10n.oskArrowUp,
      _OskControl.arrowDown => l10n.oskArrowDown,
      null => labelText(
        capital: shift != _Shift.off,
        ctrlArmed: false,
        l10n: l10n,
      ),
    };
  }

  String? namedKey({required bool capital}) {
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
      _ => capital ? outputText(capital: true) : text,
    };
  }

  bool isSelected({required _Shift shift, required bool ctrlArmed}) {
    return (control == _OskControl.shift && shift != _Shift.off) ||
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
