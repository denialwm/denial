import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/app_icon.dart';
import '../controllers/home_grid_controller.dart';
import '../models/home_battery_discharge_info.dart';
import '../models/desktop_app.dart';
import '../models/home_clock_info.dart';
import '../models/home_grid_item.dart';

class HomeGridItemCard extends ConsumerWidget {
  const HomeGridItemCard({
    super.key,
    required this.item,
    this.launchEnabled = true,
    required this.onLaunch,
  });

  final HomeGridItem item;
  final bool launchEnabled;
  final ValueChanged<DesktopApp> onLaunch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (item.type) {
      HomeGridItemType.clock => _HomeClockTile(
        clock: ref.watch(homeClockProvider),
      ),
      HomeGridItemType.batteryDischarge => _HomeBatteryDischargeTile(
        series:
            ref.watch(homeBatteryDischargeProvider).asData?.value ??
            HomeBatteryDischargeSeries.empty,
      ),
      HomeGridItemType.app => _HomeAppTile(
        app: item.app!,
        onTap: launchEnabled ? () => onLaunch(item.app!) : null,
      ),
    };
  }
}

class _HomeClockTile extends StatelessWidget {
  const _HomeClockTile({required this.clock});

  final HomeClockInfo clock;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final timeSize = math
            .min(constraints.maxWidth * 0.36, constraints.maxHeight * 0.42)
            .clamp(46.0, 124.0)
            .toDouble();
        final detailScale = (timeSize / 58).clamp(0.9, 1.28).toDouble();
        return SizedBox.expand(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: math.max(2, constraints.maxWidth * 0.035),
              vertical: math.max(0, constraints.maxHeight * 0.035),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      clock.timeLine,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: const Color(0xfff7f7f8),
                        fontSize: timeSize,
                        height: 0.95,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  SizedBox(height: _scaled(7, detailScale, 5, 9)),
                  Text(
                    clock.dateLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: const Color(0xffc7c9d1),
                      fontSize: _scaled(15, detailScale, 13, 19),
                      height: 1,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                  _HomeClockStatus(
                    power: clock.power,
                    thermalReadings: clock.thermalReadings,
                    scale: detailScale,
                  ),
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
    final displayLine = power.displayLine;
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
                    if (power.protocolLabel.isNotEmpty) ...[
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
        ),
      ),
    );
  }
}

class _HomeClockBatteryPainter extends CustomPainter {
  const _HomeClockBatteryPainter({required this.level, required this.color});

  final double level;
  final Color color;

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
      Radius.circular(size.height * 0.2),
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
          Radius.circular(size.height * 0.1),
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
        Radius.circular(size.height * 0.05),
      ),
      fill,
    );
  }

  @override
  bool shouldRepaint(covariant _HomeClockBatteryPainter oldDelegate) {
    return oldDelegate.level != level || oldDelegate.color != color;
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
    final detail = power.protocolDetail;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          power.protocolLabel,
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
        if (detail.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(
            detail,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: const Color(0xe6f7f7f8),
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
          reading.label,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: const Color(0xc7c7c9d1),
            fontSize: _scaled(9, scale, 8, 10),
            height: 1,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        Text(
          reading.value,
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

class _HomeBatteryDischargeTile extends StatelessWidget {
  const _HomeBatteryDischargeTile({required this.series});

  final HomeBatteryDischargeSeries series;

  @override
  Widget build(BuildContext context) {
    final latest = series.latest;
    final graphPoints = series.graphPoints().toList(growable: false);
    final stats = _BatteryDischargeStats.fromPoints(graphPoints);
    final avg60 = stats.averageDrawMa ?? series.averageDrawMa();
    final accent = _dischargeAccentColor(latest);
    final detailParts = <String>[
      ?formatPowerMw(latest?.powerMw),
      ?formatVoltageMv(latest?.voltageMv),
    ];
    final capacity = latest?.capacity;
    final stateLine = [
      latest?.displayState ?? 'Waiting',
      if (capacity != null) '$capacity%',
    ].join(' ');

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 210;
        final valueSize = math
            .min(constraints.maxWidth * 0.13, constraints.maxHeight * 0.18)
            .clamp(24.0, 44.0)
            .toDouble();

        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x28070910),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0x26ffffff)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x24000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 16,
              compact ? 11 : 14,
              compact ? 12 : 16,
              compact ? 11 : 14,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    CustomPaint(
                      size: const Size(28, 15),
                      painter: _MiniBatteryPainter(
                        level: ((capacity ?? 0) / 100)
                            .clamp(0.0, 1.0)
                            .toDouble(),
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'Battery',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xfff7f7f8),
                          fontSize: 14,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    Text(
                      stateLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: accent.withValues(alpha: 0.95),
                        fontSize: 12,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 7 : 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Text(
                        formatDrawMa(latest?.drawMa),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xfff7f7f8),
                          fontSize: valueSize,
                          height: 0.95,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    if (detailParts.isNotEmpty)
                      Flexible(
                        child: Text(
                          detailParts.join('  '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: Color(0xffc7c9d1),
                            fontSize: 11,
                            height: 1.15,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: compact ? 7 : 12),
                if (stats.hasValues) ...[
                  _BatteryDischargeStatsRow(
                    averageDrawMa: avg60,
                    minDrawMa: stats.minPoint?.drawMa,
                    maxDrawMa: stats.maxPoint?.drawMa,
                    compact: compact,
                  ),
                  SizedBox(height: compact ? 6 : 8),
                ],
                Expanded(
                  child: CustomPaint(
                    painter: _BatteryDischargeGraphPainter(
                      points: graphPoints,
                      accent: accent,
                      minPoint: stats.minPoint,
                      latestPoint: stats.latestPoint,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BatteryDischargeStats {
  const _BatteryDischargeStats({
    required this.minPoint,
    required this.maxPoint,
    required this.latestPoint,
    required this.averageDrawMa,
  });

  factory _BatteryDischargeStats.fromPoints(
    List<HomeBatteryDischargePoint> points,
  ) {
    HomeBatteryDischargePoint? minPoint;
    HomeBatteryDischargePoint? maxPoint;
    HomeBatteryDischargePoint? latestPoint;
    var sum = 0;
    var count = 0;

    for (final point in points) {
      final drawMa = point.drawMa;
      if (drawMa == null) {
        continue;
      }
      sum += drawMa;
      count += 1;
      latestPoint = point;
      if (minPoint == null || drawMa < minPoint.drawMa!) {
        minPoint = point;
      }
      if (maxPoint == null || drawMa > maxPoint.drawMa!) {
        maxPoint = point;
      }
    }

    return _BatteryDischargeStats(
      minPoint: minPoint,
      maxPoint: maxPoint,
      latestPoint: latestPoint,
      averageDrawMa: count == 0 ? null : sum ~/ count,
    );
  }

  final HomeBatteryDischargePoint? minPoint;
  final HomeBatteryDischargePoint? maxPoint;
  final HomeBatteryDischargePoint? latestPoint;
  final int? averageDrawMa;

  bool get hasValues => latestPoint != null;
}

class _BatteryDischargeStatsRow extends StatelessWidget {
  const _BatteryDischargeStatsRow({
    required this.averageDrawMa,
    required this.minDrawMa,
    required this.maxDrawMa,
    required this.compact,
  });

  final int? averageDrawMa;
  final int? minDrawMa;
  final int? maxDrawMa;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? 10.0 : 11.0;
    return Row(
      children: [
        Expanded(
          child: _BatteryMetricText(
            label: 'avg',
            value: formatDrawMa(averageDrawMa),
            fontSize: fontSize,
          ),
        ),
        Expanded(
          child: _BatteryMetricText(
            label: 'min',
            value: formatDrawMa(minDrawMa),
            fontSize: fontSize,
            align: TextAlign.center,
          ),
        ),
        Expanded(
          child: _BatteryMetricText(
            label: 'max',
            value: formatDrawMa(maxDrawMa),
            fontSize: fontSize,
            align: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _BatteryMetricText extends StatelessWidget {
  const _BatteryMetricText({
    required this.label,
    required this.value,
    required this.fontSize,
    this.align = TextAlign.left,
  });

  final String label;
  final String value;
  final double fontSize;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: const TextStyle(
              color: Color(0xff8f96a3),
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              color: Color(0xfff7f7f8),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      softWrap: false,
      style: TextStyle(
        fontSize: fontSize,
        height: 1,
        letterSpacing: 0,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _MiniBatteryPainter extends CustomPainter {
  const _MiniBatteryPainter({required this.level, required this.color});

  final double level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final fill = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    final terminalWidth = size.width * 0.1;
    final gap = size.width * 0.04;
    final bodyWidth = size.width - terminalWidth - gap;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, bodyWidth, size.height),
      Radius.circular(size.height * 0.22),
    );
    canvas.drawRRect(body, stroke);
    final inset = size.height * 0.18;
    final fillWidth = ((bodyWidth - inset * 2) * level)
        .clamp(0.0, bodyWidth - inset * 2)
        .toDouble();
    if (fillWidth > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(inset, inset, fillWidth, size.height - inset * 2),
          Radius.circular(size.height * 0.1),
        ),
        fill,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          bodyWidth + gap,
          size.height * 0.31,
          terminalWidth,
          size.height * 0.38,
        ),
        Radius.circular(size.height * 0.06),
      ),
      fill,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniBatteryPainter oldDelegate) {
    return oldDelegate.level != level || oldDelegate.color != color;
  }
}

class _BatteryDischargeGraphPainter extends CustomPainter {
  const _BatteryDischargeGraphPainter({
    required this.points,
    required this.accent,
    required this.minPoint,
    required this.latestPoint,
  });

  final List<HomeBatteryDischargePoint> points;
  final Color accent;
  final HomeBatteryDischargePoint? minPoint;
  final HomeBatteryDischargePoint? latestPoint;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0x24ffffff)
      ..strokeWidth = 1;
    final baseline = size.height - 1;
    for (final fraction in [0.0, 0.5, 1.0]) {
      final y = baseline - baseline * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final usable = points.where((point) => point.drawMa != null).toList();
    if (usable.length < 2) {
      final empty = Paint()
        ..color = const Color(0x33f7f7f8)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(0, baseline), Offset(size.width, baseline), empty);
      return;
    }

    final maxMa = usable
        .map((point) => point.drawMa!)
        .reduce(math.max)
        .clamp(50, 2000)
        .toDouble();
    final stepX = size.width / (usable.length - 1);
    final line = Path();
    final fill = Path();

    for (var index = 0; index < usable.length; index += 1) {
      final point = usable[index];
      final x = index * stepX;
      final y =
          baseline -
          ((point.drawMa! / maxMa).clamp(0.0, 1.0).toDouble() * baseline);
      if (index == 0) {
        line.moveTo(x, y);
        fill
          ..moveTo(x, baseline)
          ..lineTo(x, y);
      } else {
        line.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill
      ..lineTo(size.width, baseline)
      ..close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: 0.22),
            accent.withValues(alpha: 0.02),
          ],
        ).createShader(Offset.zero & size)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    if (size.height >= 44 && size.width >= 120) {
      _drawMarker(
        canvas,
        size,
        usable,
        maxMa,
        minPoint,
        'min',
        const Color(0xff8ee6c1),
      );
      if (latestPoint?.wallMs != minPoint?.wallMs) {
        _drawMarker(canvas, size, usable, maxMa, latestPoint, 'now', accent);
      }
    }
  }

  void _drawMarker(
    Canvas canvas,
    Size size,
    List<HomeBatteryDischargePoint> usable,
    double maxMa,
    HomeBatteryDischargePoint? point,
    String label,
    Color color,
  ) {
    final drawMa = point?.drawMa;
    if (point == null || drawMa == null) {
      return;
    }

    final index = usable.indexWhere((candidate) {
      return candidate.wallMs == point.wallMs && candidate.drawMa == drawMa;
    });
    if (index < 0) {
      return;
    }

    final baseline = size.height - 1;
    final stepX = size.width / (usable.length - 1);
    final x = index * stepX;
    final y = baseline - ((drawMa / maxMa).clamp(0.0, 1.0) * baseline);
    final dot = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final halo = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    canvas
      ..drawCircle(Offset(x, y), 6, halo)
      ..drawCircle(Offset(x, y), 3.2, dot);

    final textPainter = TextPainter(
      text: TextSpan(
        text: '$label ${formatDrawMa(drawMa)}',
        style: TextStyle(
          color: const Color(0xfff7f7f8),
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    final labelWidth = textPainter.width + 10;
    final labelHeight = textPainter.height + 7;
    final labelLeft = (x - labelWidth / 2)
        .clamp(0.0, math.max(0.0, size.width - labelWidth))
        .toDouble();
    final preferredTop = y - labelHeight - 7;
    final labelTop = preferredTop < 0 ? y + 7 : preferredTop;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(labelLeft, labelTop, labelWidth, labelHeight),
      const Radius.circular(6),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = const Color(0xdd070910)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: 0.42)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    textPainter.paint(canvas, Offset(labelLeft + 5, labelTop + 4));
  }

  @override
  bool shouldRepaint(covariant _BatteryDischargeGraphPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.accent != accent ||
        oldDelegate.minPoint != minPoint ||
        oldDelegate.latestPoint != latestPoint;
  }
}

class _HomeAppTile extends StatelessWidget {
  const _HomeAppTile({required this.app, required this.onTap});

  final DesktopApp app;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: app.name,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            SizedBox.square(
              dimension: 92,
              child: Center(
                child: SizedBox.square(
                  dimension: 85,
                  child: AppIconImage(iconPath: app.iconPath),
                ),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              app.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xfff7f7f8),
                fontSize: 13,
                height: 1.06,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
                shadows: [
                  Shadow(
                    color: Color(0x80000000),
                    blurRadius: 8,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double _scaled(double value, double scale, double min, double max) {
  return (value * scale).clamp(min, max).toDouble();
}

Color _batteryAccentColor(HomePowerStatus power) {
  if (power.voocCharging) {
    return const Color(0xff5ff38a);
  }
  if (power.ppsCharging) {
    return const Color(0xffbd8cff);
  }
  if (power.pdCharging) {
    return const Color(0xff7aa8ff);
  }
  if (power.fastCharge || power.state == 'charging') {
    return const Color(0xff78dce8);
  }
  if (power.state == 'discharging') {
    final capacity = power.capacity;
    if (capacity == null || capacity >= 20) {
      return const Color(0xfff7f7f8);
    }
    if (capacity >= 15) {
      return const Color(0xffffd166);
    }
    return const Color(0xffff6b6b);
  }
  return const Color(0xffc7c9d1);
}

Color _dischargeAccentColor(HomeBatteryDischargePoint? point) {
  final currentMa = point?.currentMa;
  if (currentMa == null || currentMa == 0) {
    return const Color(0xffc7c9d1);
  }
  if (currentMa > 0) {
    return const Color(0xff78dce8);
  }
  return const Color(0xffffa657);
}

Color _temperatureColor(int deciC) {
  if (deciC >= 800) {
    return const Color(0xffff6b6b);
  }
  if (deciC >= 700) {
    return const Color(0xffffb86b);
  }
  if (deciC >= 550) {
    return const Color(0xffffd166);
  }
  return const Color(0xff8ee6c1);
}
