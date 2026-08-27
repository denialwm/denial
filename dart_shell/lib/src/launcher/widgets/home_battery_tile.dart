part of 'home_tiles.dart';

class _HomeBatteryDischargeTile extends StatelessWidget {
  const _HomeBatteryDischargeTile({required this.series});

  final HomeBatteryDischargeSeries series;

  @override
  Widget build(BuildContext context) {
    final latest = series.latest;
    final graph = series.graph;
    final avg60 = graph.averageDrawMa ?? series.averageDrawMa60;
    final accent = _dischargeAccentColor(latest);
    final detailParts = <String>[
      ?_formatPowerMw(context.l10n, latest?.powerMw),
      ?_formatVoltageMv(context.l10n, latest?.voltageMv),
    ];
    final capacity = latest?.capacity;
    final stateLabel = latest == null
        ? context.l10n.statusWaiting
        : localizedBatteryState(context.l10n, latest.state, showUnknown: true);
    final stateLine = capacity == null
        ? stateLabel
        : context.l10n.batteryStateAndPercent(stateLabel, capacity);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 210;
        final valueSize = math
            .min(constraints.maxWidth * 0.13, constraints.maxHeight * 0.18)
            .clamp(24.0, 44.0)
            .toDouble();

        return DecoratedBox(
          decoration: BoxDecoration(
            color: ShellMediaColors.glassSurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ShellMediaColors.lightOutline),
            boxShadow: const [
              BoxShadow(
                color: ShellMediaColors.wallpaperScrim,
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
                        context.l10n.batteryTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ShellMediaColors.lightForeground,
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
                        _formatDrawMa(context.l10n, latest?.drawMa),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ShellMediaColors.lightForeground,
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
                            color: ShellMediaColors.lightForegroundSecondary,
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
                if (graph.hasValues) ...[
                  _BatteryDischargeStatsRow(
                    averageDrawMa: avg60,
                    minDrawMa: graph.minPoint?.drawMa,
                    maxDrawMa: graph.maxPoint?.drawMa,
                    compact: compact,
                  ),
                  SizedBox(height: compact ? 6 : 8),
                ],
                Expanded(
                  child: CustomPaint(
                    painter: _BatteryDischargeGraphPainter(
                      graph: graph,
                      accent: accent,
                      l10n: context.l10n,
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
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: _BatteryMetricText(
            label: l10n.metricAverage,
            value: _formatDrawMa(l10n, averageDrawMa),
            fontSize: fontSize,
          ),
        ),
        Expanded(
          child: _BatteryMetricText(
            label: l10n.metricMinimum,
            value: _formatDrawMa(l10n, minDrawMa),
            fontSize: fontSize,
            align: TextAlign.center,
          ),
        ),
        Expanded(
          child: _BatteryMetricText(
            label: l10n.metricMaximum,
            value: _formatDrawMa(l10n, maxDrawMa),
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
              color: ShellMediaColors.lightForegroundTertiary,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              color: ShellMediaColors.lightForeground,
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
    required this.graph,
    required this.accent,
    required this.l10n,
  });

  final HomeBatteryDischargeGraphViewModel graph;
  final Color accent;
  final AppLocalizations l10n;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = ShellMediaColors.lightGrid
      ..strokeWidth = 1;
    final baseline = size.height - 1;
    for (final fraction in [0.0, 0.5, 1.0]) {
      final y = baseline - baseline * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final usable = graph.points;
    if (usable.length < 2) {
      final empty = Paint()
        ..color = ShellMediaColors.lightForeground.withValues(alpha: 0.20)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(0, baseline), Offset(size.width, baseline), empty);
      return;
    }

    final maxMa = graph.scaleMaxMa;
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
        graph.minIndex,
        l10n.metricMinimum,
        ShellTelemetryColors.nominal,
      );
      if (graph.latestIndex != graph.minIndex) {
        _drawMarker(
          canvas,
          size,
          usable,
          maxMa,
          graph.latestIndex,
          l10n.metricNow,
          accent,
        );
      }
    }
  }

  void _drawMarker(
    Canvas canvas,
    Size size,
    List<HomeBatteryDischargePoint> usable,
    double maxMa,
    int index,
    String label,
    Color color,
  ) {
    if (index < 0 || index >= usable.length) {
      return;
    }
    final point = usable[index];
    final drawMa = point.drawMa;
    if (drawMa == null) {
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
        text: l10n.batteryGraphMarker(label, _formatDrawMa(l10n, drawMa)),
        style: TextStyle(
          color: ShellMediaColors.lightForeground,
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
        ..color = ShellMediaColors.glassSurfaceStrong
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
    return oldDelegate.graph != graph ||
        oldDelegate.accent != accent ||
        oldDelegate.l10n.localeName != l10n.localeName;
  }
}

String? _formatPowerMw(AppLocalizations l10n, int? powerMw) {
  if (powerMw == null) {
    return null;
  }
  return l10n.powerWattsDecimal((powerMw / 1000).toStringAsFixed(2));
}

String _formatDrawMa(AppLocalizations l10n, int? currentMa) {
  if (currentMa == null) {
    return l10n.currentMilliampsUnavailable;
  }
  return l10n.currentMilliamps(currentMa.abs());
}

String? _formatVoltageMv(AppLocalizations l10n, int? voltageMv) {
  if (voltageMv == null) {
    return null;
  }
  return l10n.voltageVolts((voltageMv / 1000).toStringAsFixed(2));
}
