import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/network_connectivity.dart';
import '../../services/mobile_network_service.dart';

import '../../models/battery_status.dart';
import '../../localization/denial_localizations.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';

/// iOS-style rounded battery capsule with a level fill, charge nub, and an
/// optional centered charging bolt.
class _BatteryCapsule extends StatelessWidget {
  const _BatteryCapsule({
    required this.level,
    required this.fill,
    required this.charging,
    required this.scale,
    required this.foreground,
  });

  final double level;
  final Color fill;
  final bool charging;
  final double scale;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    const width = 25.0;
    const height = 13.0;
    final outline = foreground.withValues(alpha: 0.48);
    return SizedBox(
      width: width * s,
      height: height * s,
      child: Stack(
        children: [
          Positioned.fill(
            right: 3.4 * s,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: outline, width: 1.3 * s),
                borderRadius: context.shellTheme.borderRadius(height * s / 2),
              ),
            ),
          ),
          Positioned(
            right: 0.4 * s,
            top: height * s / 2 - 2.3 * s,
            width: 1.8 * s,
            height: 4.6 * s,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: outline,
                borderRadius: context.shellTheme.borderRadius(0.9 * s),
              ),
            ),
          ),
          Positioned(
            left: 2.7 * s,
            top: 2.7 * s,
            bottom: 2.7 * s,
            width: (width - 2.7 - 4.8) * s * level,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: context.shellTheme.borderRadius(3.8 * s),
              ),
            ),
          ),
          if (charging)
            Positioned.fill(
              right: 3.4 * s,
              child: Center(
                child: Icon(
                  Icons.bolt_rounded,
                  size: 11 * s,
                  color: ShellMediaColors.contrastLight,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Color _batteryFill(BatteryStatus status, Color foreground) {
  if (status.charging) {
    return ShellTelemetryColors.chargingVooc;
  }
  final capacity = status.capacity;
  if (capacity != null && capacity <= 15) {
    return ShellTelemetryColors.danger;
  }
  return foreground;
}

bool _batteryLow(BatteryStatus status) =>
    !status.charging && status.capacity != null && status.capacity! <= 15;

/// Battery percentage label beside a rounded level capsule.
class BatteryMark extends StatelessWidget {
  const BatteryMark({
    super.key,
    required this.status,
    this.scale = 1.0,
    this.textScale,
    this.color,
  });

  final BatteryStatus status;
  final double scale;
  final double? textScale;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final level = ((status.capacity ?? 64) / 100.0).clamp(0.0, 1.0);
    final foreground = color ?? context.shellColors.textPrimary;
    final low = _batteryLow(status);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          status.capacity == null
              ? context.l10n.batteryCapacityUnavailable
              : context.l10n.percentCompact(status.capacity!),
          style: TextStyle(
            color: low ? ShellTelemetryColors.danger : foreground,
            fontSize: 12.5 * (textScale ?? scale),
            height: 1,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            decoration: TextDecoration.none,
          ),
        ),
        SizedBox(width: 4.5 * scale),
        _BatteryCapsule(
          level: level,
          fill: _batteryFill(status, foreground),
          charging: status.charging,
          scale: scale,
          foreground: foreground,
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

    return _BatteryCapsule(
      level: level,
      fill: _batteryFill(status, foreground),
      charging: status.charging,
      scale: scale,
      foreground: foreground,
    );
  }
}

/// Wi-Fi status icon.
class WifiMark extends StatelessWidget {
  const WifiMark({
    super.key,
    required this.active,
    this.strength = 0,
    this.size = 17,
    this.color,
  });

  final bool active;
  final int strength;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? context.shellColors.textPrimary;
    return Icon(
      !active
          ? Icons.wifi_off_rounded
          : strength == 0
          ? Icons.signal_wifi_0_bar
          : strength < 34
          ? Icons.network_wifi_1_bar
          : strength < 67
          ? Icons.network_wifi_2_bar
          : Icons.wifi_rounded,
      color: active ? foreground : foreground.withValues(alpha: 0.35),
      size: size,
    );
  }
}

/// Four ascending pill bars.
class SignalGlyph extends StatelessWidget {
  const SignalGlyph({
    super.key,
    required this.active,
    this.strength = 0,
    this.scale = 1.0,
    this.color,
  });

  final bool active;
  final int strength;
  final double scale;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? context.shellColors.textPrimary;
    final bars = active ? (strength.clamp(0, 100) / 25).ceil() : 0;
    return SizedBox(
      width: 20 * scale,
      height: 11 * scale,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 4; i++) ...[
            Container(
              width: 3.2 * scale,
              height: (4.4 + i * 2.2) * scale,
              decoration: BoxDecoration(
                color: i < bars
                    ? foreground
                    : foreground.withValues(alpha: 0.28),
                borderRadius: context.shellTheme.borderRadius(1.6 * scale),
              ),
            ),
            if (i != 3) SizedBox(width: 2.4 * scale),
          ],
        ],
      ),
    );
  }
}

/// The compact status cluster (signal · wifi · battery) shared by the status
/// bar and the shade header.
class StatusCluster extends StatelessWidget {
  const StatusCluster({
    super.key,
    required this.battery,
    this.color,
    this.scale = 1,
  });

  final BatteryStatus battery;
  final Color? color;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MobileConnectivityMarks(color: color, scale: scale),
        SizedBox(width: 12 * scale),
        BatteryMark(
          status: battery,
          scale: 1.18 * scale,
          textScale: 1.18,
          color: color,
        ),
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
        MobileConnectivityMarks(color: color),
        const SizedBox(width: 12),
        BatteryIconMark(status: battery, scale: 1.18, color: color),
      ],
    );
  }
}

class MobileConnectivityMarks extends ConsumerWidget {
  const MobileConnectivityMarks({super.key, this.color, this.scale = 1});
  final Color? color;
  final double scale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wifi = ref
        .watch(networkConnectivityProvider)
        .snapshot
        .connectedNetwork;
    final mobile =
        ref.watch(mobileNetworkProvider).value ?? const MobileNetworkSnapshot();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: mobile.connected
              ? context.l10n.mobileConnected
              : context.l10n.mobileDisconnected,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SignalGlyph(
                active: mobile.registered,
                strength: mobile.strength,
                scale: 1.25 * scale,
                color: color,
              ),
              if (!mobile.connected)
                Icon(
                  Icons.priority_high_rounded,
                  size: 12 * scale,
                  color: color,
                ),
            ],
          ),
        ),
        SizedBox(width: 7 * scale),
        WifiMark(
          active: wifi != null,
          strength: wifi?.strength ?? 0,
          size: 20 * scale,
          color: color,
        ),
      ],
    );
  }
}
