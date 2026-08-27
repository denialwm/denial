import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../models/battery_status.dart';
import '../../localization/denial_localizations.dart';
import '../../theme/shell_theme.dart';

/// Battery pictogram with a level fill and a percentage label.
class BatteryMark extends StatelessWidget {
  const BatteryMark({
    super.key,
    required this.status,
    this.scale = 1.0,
    this.color,
  });

  final BatteryStatus status;
  final double scale;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final level = ((status.capacity ?? 64) / 100.0).clamp(0.0, 1.0);
    final foreground = color ?? context.shellColors.textPrimary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 24 * scale,
          height: 12 * scale,
          child: Stack(
            children: [
              Positioned.fill(
                right: 3 * scale,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: foreground, width: 1.4 * scale),
                    borderRadius: context.shellTheme.borderRadius(3 * scale),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 4 * scale,
                width: 2 * scale,
                height: 4 * scale,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: foreground,
                    borderRadius: context.shellTheme.borderRadius(1 * scale),
                  ),
                ),
              ),
              Positioned(
                left: 2 * scale,
                top: 2 * scale,
                bottom: 2 * scale,
                width: 17 * scale * level,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: foreground,
                    borderRadius: context.shellTheme.borderRadius(2 * scale),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: 5 * scale),
        Text(
          status.capacity == null
              ? context.l10n.batteryCapacityUnavailable
              : context.l10n.percentCompact(status.capacity!),
          style: TextStyle(
            color: foreground,
            fontSize: 12 * scale,
            height: 1,
            fontWeight: FontWeight.w800,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }
}

class BatteryIconMark extends StatelessWidget {
  const BatteryIconMark({
    super.key,
    required this.status,
    this.scale = 1.0,
    this.color,
  });

  final BatteryStatus status;
  final double scale;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final level = ((status.capacity ?? 64) / 100.0).clamp(0.0, 1.0);
    final foreground = color ?? context.shellColors.textPrimary;

    return SizedBox(
      width: 24 * scale,
      height: 12 * scale,
      child: Stack(
        children: [
          Positioned.fill(
            right: 3 * scale,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: foreground, width: 1.4 * scale),
                borderRadius: context.shellTheme.borderRadius(3 * scale),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 4 * scale,
            width: 2 * scale,
            height: 4 * scale,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: foreground,
                borderRadius: context.shellTheme.borderRadius(1 * scale),
              ),
            ),
          ),
          Positioned(
            left: 2 * scale,
            top: 2 * scale,
            bottom: 2 * scale,
            width: 17 * scale * level,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: foreground,
                borderRadius: context.shellTheme.borderRadius(2 * scale),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wi-Fi status icon.
class WifiMark extends StatelessWidget {
  const WifiMark({super.key, required this.active, this.size = 17, this.color});

  final bool active;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? context.shellColors.textPrimary;
    return Icon(
      Icons.wifi_rounded,
      color: active ? foreground : foreground.withValues(alpha: 0.42),
      size: size,
    );
  }
}

/// Four ascending signal bars.
class SignalGlyph extends StatelessWidget {
  const SignalGlyph({
    super.key,
    required this.active,
    this.scale = 1.0,
    this.color,
  });

  final bool active;
  final double scale;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? context.shellColors.textPrimary;
    final glyphColor = active ? foreground : foreground.withValues(alpha: 0.42);
    return SizedBox(
      width: 18 * scale,
      height: 12 * scale,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 4; i++) ...[
            Container(
              width: 3 * scale,
              height: (4.0 + i * 2.2) * scale,
              decoration: BoxDecoration(
                color: glyphColor,
                borderRadius: context.shellTheme.borderRadius(1.5 * scale),
              ),
            ),
            if (i != 3) SizedBox(width: 2 * scale),
          ],
        ],
      ),
    );
  }
}

/// The compact status cluster (signal · wifi · battery) shared by the status
/// bar and the shade header.
class StatusCluster extends StatelessWidget {
  const StatusCluster({super.key, required this.battery, this.color});

  final BatteryStatus battery;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SignalGlyph(active: true, scale: 1.25, color: color),
        const SizedBox(width: 10),
        WifiMark(active: true, size: 21, color: color),
        const SizedBox(width: 11),
        BatteryMark(status: battery, scale: 1.18, color: color),
      ],
    );
  }
}

class StatusIconCluster extends StatelessWidget {
  const StatusIconCluster({super.key, required this.battery, this.color});

  final BatteryStatus battery;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SignalGlyph(active: true, scale: 1.2, color: color),
        const SizedBox(width: 10),
        WifiMark(active: true, size: 20, color: color),
        const SizedBox(width: 11),
        BatteryIconMark(status: battery, scale: 1.18, color: color),
      ],
    );
  }
}
