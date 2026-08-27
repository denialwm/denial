part of 'home_tiles.dart';

class HomeClockWidget extends StatelessWidget {
  const HomeClockWidget({
    super.key,
    required this.clock,
    this.showStatus = true,
  });

  final HomeClockInfo clock;
  final bool showStatus;

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
                      localizedTime(context, clock.now),
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ShellMediaColors.lightForeground,
                        fontSize: timeSize,
                        height: 0.95,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  SizedBox(height: _scaled(7, detailScale, 5, 9)),
                  Text(
                    localizedLongDate(context, clock.now),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ShellMediaColors.lightForegroundSecondary,
                      fontSize: _scaled(15, detailScale, 13, 19),
                      height: 1,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                  if (showStatus)
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
