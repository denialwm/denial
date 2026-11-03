import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../shell_theme.dart';

/// Connection and signal-strength glyph shared by mobile and desktop surfaces.
class WifiStatusIcon extends StatelessWidget {
  const WifiStatusIcon({
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
    // Quarters of the strength, like the cellular bars.
    final bars = (strength.clamp(0, 100) / 25).ceil();
    return Icon(
      !active
          ? Icons.wifi_off_rounded
          : switch (bars) {
              0 => Icons.signal_wifi_0_bar_rounded,
              1 => Icons.network_wifi_1_bar_rounded,
              2 => Icons.network_wifi_2_bar_rounded,
              3 => Icons.network_wifi_3_bar_rounded,
              _ => Icons.wifi_rounded,
            },
      color: active ? foreground : foreground.withValues(alpha: 0.35),
      size: size,
    );
  }
}
