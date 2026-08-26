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

  factory ShellTextTheme.from(ShellColorScheme colors) {
    return ShellTextTheme(
      base: ShellText.base.copyWith(color: colors.textPrimary),
      statusClock: ShellText.statusClock.copyWith(color: colors.textPrimary),
      systemBarValue: ShellText.systemBarValue.copyWith(
        color: colors.textPrimary,
      ),
      systemBarCaption: ShellText.systemBarCaption.copyWith(
        color: colors.textSecondary,
      ),
      shadeClock: ShellText.shadeClock.copyWith(color: colors.panelText),
      shadeDate: ShellText.shadeDate.copyWith(color: colors.textSecondary),
      lockClock: ShellText.lockClock.copyWith(color: colors.textPrimary),
      lockDate: ShellText.lockDate.copyWith(color: colors.textSecondary),
      lockStatus: ShellText.lockStatus.copyWith(color: colors.textSecondary),
      lockChip: ShellText.lockChip.copyWith(color: colors.textPrimary),
      cardTitle: ShellText.cardTitle.copyWith(color: colors.textPrimary),
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
