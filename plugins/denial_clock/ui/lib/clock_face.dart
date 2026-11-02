import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';
import 'package:denial_flutter_sdk/applications.dart';

/// The pieces of the clock face, for drawing them on separate layers.
enum HomeClockPart { time, date, status }

class HomeClockWidget extends StatelessWidget {
  const HomeClockWidget({
    super.key,
    required this.clock,
    this.showStatus = true,
    this.timeStretch = 1.0,
    this.detailsAbove = false,
    this.dateColor = ShellMediaColors.lightForegroundSecondary,
    this.caption,
    this.parts = const {
      HomeClockPart.time,
      HomeClockPart.date,
      HomeClockPart.status,
    },
  });

  final HomeClockInfo clock;
  final bool showStatus;

  /// Sets the time this many times taller, growing upward from its baseline.
  /// Layout is unchanged: the bottom of the time stays put.
  final double timeStretch;

  /// Sets the status row and the date above the time, the status row on top,
  /// riding on top of a stretched time.
  final bool detailsAbove;
  final Color dateColor;

  /// A line over the date, part of the date.
  final String? caption;

  /// Parts to paint. The others keep their space, so two faces with
  /// complementary parts stack into one clock.
  final Set<HomeClockPart> parts;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final timeSize = math
            .min(constraints.maxWidth * 0.36, constraints.maxHeight * 0.42)
            .clamp(46.0, 124.0)
            .toDouble();
        final detailScale = (timeSize / 58).clamp(0.9, 1.28).toDouble();
        Widget part(HomeClockPart kind, Widget child) => parts.contains(kind)
            ? child
            : Visibility(
                visible: false,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: child,
              );
        final dateGap = _scaled(7, detailScale, 5, 9);
        Text line(String text, double fontSize) => Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: dateColor,
            fontSize: fontSize,
            height: 1,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
        );
        final dateLine = line(
          localizedLongDate(context, clock.now),
          _scaled(15, detailScale, 13, 19),
        );
        final caption = this.caption;
        final date = part(
          HomeClockPart.date,
          caption == null
              ? dateLine
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    line(caption, _scaled(13, detailScale, 11, 16)),
                    SizedBox(height: dateGap),
                    dateLine,
                  ],
                ),
        );
        final status = showStatus
            ? part(
                HomeClockPart.status,
                _HomeClockStatus(
                  power: clock.power,
                  thermalReadings: clock.thermalReadings,
                  scale: detailScale,
                ),
              )
            : null;
        final horizontalPadding = math.max(2.0, constraints.maxWidth * 0.035);
        return SizedBox.expand(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: math.max(0, constraints.maxHeight * 0.035),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _GrowUp(
                      factor: timeStretch,
                      gap: dateGap,
                      // The details take the column's width: the time's
                      // FittedBox lays its child out unbounded.
                      lead: detailsAbove
                          ? SizedBox(
                              width:
                                  constraints.maxWidth - horizontalPadding * 2,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (status != null) ...[
                                    status,
                                    SizedBox(height: dateGap),
                                  ],
                                  date,
                                ],
                              ),
                            )
                          : null,
                      time: part(
                        HomeClockPart.time,
                        Text(
                          localizedTime(context, clock.now),
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          textAlign: TextAlign.center,
                          style: _timeStyle(timeSize, timeStretch),
                        ),
                      ),
                    ),
                  ),
                  if (!detailsAbove) ...[
                    SizedBox(height: dateGap),
                    date,
                    ?status,
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HomeClockStatus extends StatelessWidget {
  const _HomeClockStatus({
    required this.power,
    required this.thermalReadings,
    required this.scale,
  });

  final HomePowerStatus power;
  final List<HomeThermalReading> thermalReadings;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final displayLine = localizedBatteryLine(
      context.l10n,
      power.state,
      power.capacity,
    );
    if (displayLine.isEmpty && thermalReadings.isEmpty) {
      return const SizedBox.shrink();
    }

    final accentColor = _batteryAccentColor(power);
    return Padding(
      padding: EdgeInsets.only(top: _scaled(8, scale, 5, 9)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (displayLine.isNotEmpty)
            SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _HomeClockBatteryGlyph(
                      power: power,
                      color: accentColor,
                      scale: scale,
                    ),
                    if (power.chargeProtocol != null) ...[
                      SizedBox(width: _scaled(8, scale, 6, 9)),
                      _HomeClockProtocolLabel(
                        power: power,
                        color: accentColor,
                        scale: scale,
                      ),
                    ],
                    SizedBox(width: _scaled(8, scale, 6, 9)),
                    Text(
                      displayLine,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: accentColor.withValues(alpha: 0.95),
                        fontSize: _scaled(14, scale, 12, 17),
                        height: 1,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (thermalReadings.isNotEmpty) ...[
            SizedBox(height: _scaled(6, scale, 4, 7)),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: _scaled(7, scale, 5, 8),
              runSpacing: 3,
              children: [
                for (final reading in thermalReadings)
                  _HomeClockThermalText(reading: reading, scale: scale),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HomeClockBatteryGlyph extends StatelessWidget {
  const _HomeClockBatteryGlyph({
    required this.power,
    required this.color,
    required this.scale,
  });

  final HomePowerStatus power;
  final Color color;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _scaled(42, scale, 36, 50),
      height: _scaled(20, scale, 17, 24),
      child: CustomPaint(
        painter: _HomeClockBatteryPainter(
          level: power.batteryLevel,
          color: color,
          cornerRadiusScale: context.shellTheme.cornerRadiusScale,
        ),
      ),
    );
  }
}

class _HomeClockBatteryPainter extends CustomPainter {
  const _HomeClockBatteryPainter({
    required this.level,
    required this.color,
    required this.cornerRadiusScale,
  });

  final double level;
  final Color color;
  final double cornerRadiusScale;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final fill = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;

    final terminalWidth = size.width * 0.095;
    final gap = size.width * 0.048;
    final bodyWidth = size.width - terminalWidth - gap;
    final bodyTop = size.height * 0.1;
    final bodyHeight = size.height * 0.8;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, bodyTop, bodyWidth, bodyHeight),
      Radius.circular(size.height * 0.2 * cornerRadiusScale),
    );
    canvas.drawRRect(body, stroke);

    final inset = size.height * 0.15;
    final fillWidth = ((bodyWidth - inset * 2) * level)
        .clamp(0.0, bodyWidth - inset * 2)
        .toDouble();
    if (fillWidth > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            inset,
            bodyTop + inset,
            fillWidth,
            bodyHeight - inset * 2,
          ),
          Radius.circular(size.height * 0.1 * cornerRadiusScale),
        ),
        fill,
      );
    }

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          bodyWidth + gap,
          size.height * 0.325,
          terminalWidth,
          size.height * 0.35,
        ),
        Radius.circular(size.height * 0.05 * cornerRadiusScale),
      ),
      fill,
    );
  }

  @override
  bool shouldRepaint(covariant _HomeClockBatteryPainter oldDelegate) {
    return oldDelegate.level != level ||
        oldDelegate.color != color ||
        oldDelegate.cornerRadiusScale != cornerRadiusScale;
  }
}

class _HomeClockProtocolLabel extends StatelessWidget {
  const _HomeClockProtocolLabel({
    required this.power,
    required this.color,
    required this.scale,
  });

  final HomePowerStatus power;
  final Color color;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final protocol = power.chargeProtocol;
    if (protocol == null) {
      return const SizedBox.shrink();
    }
    final watts = power.chargeProtocolWatts;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          localizedChargeProtocol(context.l10n, protocol),
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: color,
            fontSize: _scaled(11, scale, 10, 13),
            height: 1,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (watts != null) ...[
          const SizedBox(width: 4),
          Text(
            context.l10n.powerWatts(watts),
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: ShellMediaColors.lightForeground.withValues(alpha: 0.90),
              fontSize: _scaled(10, scale, 9, 12),
              height: 1,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

class _HomeClockThermalText extends StatelessWidget {
  const _HomeClockThermalText({required this.reading, required this.scale});

  final HomeThermalReading reading;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final color = _temperatureColor(reading.deciC);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          localizedThermalSensor(context.l10n, reading.sensor),
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: ShellMediaColors.lightForegroundSecondary.withValues(
              alpha: 0.78,
            ),
            fontSize: _scaled(9, scale, 8, 10),
            height: 1,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        Text(
          context.l10n.temperatureCelsius((reading.deciC / 10).round()),
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: color,
            fontSize: _scaled(11, scale, 10, 13),
            height: 1,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// A stretched time is set [stretch] times larger in the bundled variable
/// family, narrowed and lightened on its width and weight axes so it keeps the
/// width and stroke the plain size has in that family. The exponents are
/// fitted to Roboto Flex's outlines at display sizes.
TextStyle _timeStyle(double size, double stretch) {
  const style = TextStyle(
    color: ShellMediaColors.lightForeground,
    height: 0.95,
    fontWeight: FontWeight.w300,
    letterSpacing: 0,
  );
  if (stretch == 1.0) {
    return style.copyWith(fontSize: size);
  }
  final fontSize = size * stretch;
  return style.copyWith(
    fontFamily: ShellText.variableFontFamily,
    fontSize: fontSize,
    fontVariations: [
      FontVariation.weight(
        (300 * math.pow(stretch, -0.55)).clamp(100.0, 1000.0).toDouble(),
      ),
      FontVariation.width(
        (100 * math.pow(stretch, -1.09)).clamp(25.0, 151.0).toDouble(),
      ),
      FontVariation.opticalSize(fontSize.clamp(8.0, 144.0).toDouble()),
    ],
  );
}

double _scaled(double value, double scale, double min, double max) {
  return (value * scale).clamp(min, max).toDouble();
}

Color _batteryAccentColor(HomePowerStatus power) {
  if (power.voocCharging) {
    return ShellTelemetryColors.chargingVooc;
  }
  if (power.ppsCharging) {
    return ShellTelemetryColors.chargingPps;
  }
  if (power.pdCharging) {
    return ShellTelemetryColors.chargingPd;
  }
  if (power.fastCharge || power.state == 'charging') {
    return ShellTelemetryColors.charging;
  }
  if (power.state == 'discharging') {
    final capacity = power.capacity;
    if (capacity == null || capacity >= 20) {
      return ShellMediaColors.lightForeground;
    }
    if (capacity >= 15) {
      return ShellTelemetryColors.warning;
    }
    return ShellTelemetryColors.danger;
  }
  return ShellMediaColors.lightForegroundSecondary;
}

Color _temperatureColor(int deciC) {
  if (deciC >= 800) {
    return ShellTelemetryColors.danger;
  }
  if (deciC >= 700) {
    return ShellTelemetryColors.warm;
  }
  if (deciC >= 550) {
    return ShellTelemetryColors.warning;
  }
  return ShellTelemetryColors.nominal;
}

/// Lays [time] out at its own size but takes 1/[factor] of its height, with
/// the baseline scaled to match: type set [factor] times larger lays out like
/// the plain size and grows upward from where it stands, painting above the
/// box. [lead] rides [gap] above the grown time.
class _GrowUp extends MultiChildRenderObjectWidget {
  _GrowUp({
    required this.factor,
    required this.gap,
    required Widget time,
    Widget? lead,
  }) : super(children: [time, ?lead]);

  final double factor;
  final double gap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGrowUp(factor, gap);

  @override
  void updateRenderObject(BuildContext context, _RenderGrowUp renderObject) {
    renderObject
      ..factor = factor
      ..gap = gap;
  }
}

class _GrowUpParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderGrowUp extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _GrowUpParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _GrowUpParentData> {
  _RenderGrowUp(this._factor, this._gap);

  double _factor;
  double _gap;

  set factor(double value) {
    if (value == _factor) {
      return;
    }
    _factor = value;
    markNeedsLayout();
  }

  set gap(double value) {
    if (value == _gap) {
      return;
    }
    _gap = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _GrowUpParentData) {
      child.parentData = _GrowUpParentData();
    }
  }

  BoxConstraints _childConstraints(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: constraints.maxWidth);

  double _widest(double Function(RenderBox child) width) {
    var result = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      result = math.max(result, width(child));
    }
    return result;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _widest((child) => child.getMinIntrinsicWidth(double.infinity));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _widest((child) => child.getMaxIntrinsicWidth(double.infinity));

  @override
  double computeMinIntrinsicHeight(double width) =>
      (firstChild?.getMinIntrinsicHeight(width) ?? 0.0) / _factor;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (firstChild?.getMaxIntrinsicHeight(width) ?? 0.0) / _factor;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final time = firstChild;
    if (time == null) {
      return constraints.smallest;
    }
    final childConstraints = _childConstraints(constraints);
    final size = time.getDryLayout(childConstraints);
    final width = _widest(
      (child) => child.getDryLayout(childConstraints).width,
    );
    return constraints.constrain(Size(width, size.height / _factor));
  }

  @override
  void performLayout() {
    final time = firstChild;
    if (time == null) {
      size = constraints.smallest;
      return;
    }
    final childConstraints = _childConstraints(constraints);
    time.layout(childConstraints, parentUsesSize: true);
    final lead = childAfter(time);
    lead?.layout(childConstraints, parentUsesSize: true);
    size = constraints.constrain(
      Size(
        math.max(time.size.width, lead?.size.width ?? 0.0),
        time.size.height / _factor,
      ),
    );
    final baseline =
        time.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true) ??
        time.size.height;
    final top = baseline / _factor - baseline;
    (time.parentData! as _GrowUpParentData).offset = Offset(
      (size.width - time.size.width) / 2,
      top,
    );
    if (lead != null) {
      (lead.parentData! as _GrowUpParentData).offset = Offset(
        (size.width - lead.size.width) / 2,
        top - _gap - lead.size.height,
      );
    }
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
