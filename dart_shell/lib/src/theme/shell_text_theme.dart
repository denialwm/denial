import 'package:flutter/widgets.dart';

import 'shell_color_scheme.dart';
import 'tokens.dart';

@immutable
class ShellTextTheme {
  const ShellTextTheme({
    required this.base,
    required this.statusClock,
    required this.systemBarValue,
    required this.systemBarCaption,
    required this.shadeClock,
    required this.shadeDate,
    required this.lockClock,
    required this.lockDate,
    required this.lockStatus,
    required this.lockChip,
    required this.cardTitle,
  });

  factory ShellTextTheme.from(
    ShellColorScheme colors, {
    String fontFamily = '',
  }) {
    TextStyle resolve(TextStyle style, Color color) {
      return style.copyWith(
        color: color,
        fontFamily: fontFamily.isEmpty ? style.fontFamily : fontFamily,
      );
    }

    return ShellTextTheme(
      base: resolve(ShellText.base, colors.textPrimary),
      statusClock: resolve(ShellText.statusClock, colors.textPrimary),
      systemBarValue: resolve(ShellText.systemBarValue, colors.textPrimary),
      systemBarCaption: resolve(
        ShellText.systemBarCaption,
        colors.textSecondary,
      ),
      shadeClock: resolve(ShellText.shadeClock, colors.panelText),
      shadeDate: resolve(ShellText.shadeDate, colors.textSecondary),
      lockClock: resolve(ShellText.lockClock, colors.textPrimary),
      lockDate: resolve(ShellText.lockDate, colors.textSecondary),
      lockStatus: resolve(ShellText.lockStatus, colors.textSecondary),
      lockChip: resolve(ShellText.lockChip, colors.textPrimary),
      cardTitle: resolve(ShellText.cardTitle, colors.textPrimary),
    );
  }

  final TextStyle base;
  final TextStyle statusClock;
  final TextStyle systemBarValue;
  final TextStyle systemBarCaption;
  final TextStyle shadeClock;
  final TextStyle shadeDate;
  final TextStyle lockClock;
  final TextStyle lockDate;
  final TextStyle lockStatus;
  final TextStyle lockChip;
  final TextStyle cardTitle;

  static ShellTextTheme lerp(
    ShellTextTheme first,
    ShellTextTheme second,
    double t,
  ) {
    TextStyle blend(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return ShellTextTheme(
      base: blend(first.base, second.base),
      statusClock: blend(first.statusClock, second.statusClock),
      systemBarValue: blend(first.systemBarValue, second.systemBarValue),
      systemBarCaption: blend(first.systemBarCaption, second.systemBarCaption),
      shadeClock: blend(first.shadeClock, second.shadeClock),
      shadeDate: blend(first.shadeDate, second.shadeDate),
      lockClock: blend(first.lockClock, second.lockClock),
      lockDate: blend(first.lockDate, second.lockDate),
      lockStatus: blend(first.lockStatus, second.lockStatus),
      lockChip: blend(first.lockChip, second.lockChip),
      cardTitle: blend(first.cardTitle, second.cardTitle),
    );
  }
}
