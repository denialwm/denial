part of 'home_tiles.dart';

class _HomeAppTile extends StatelessWidget {
  const _HomeAppTile({
    required this.name,
    required this.iconPath,
    required this.icon,
    required this.onTap,
  });

  final String name;
  final String? iconPath;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: name,
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
                  child: icon == null
                      ? AppIconImage(iconPath: iconPath)
                      : ExcludeSemantics(
                          child: Icon(
                            icon,
                            size: 72,
                            color: ShellTheme.of(context).accentPalette.primary,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: ShellMediaColors.lightForeground,
                fontSize: 13,
                height: 1.06,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
                shadows: [
                  Shadow(
                    color: ShellMediaColors.shadow,
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

Color _dischargeAccentColor(HomeBatteryDischargePoint? point) {
  final currentMa = point?.currentMa;
  if (currentMa == null || currentMa == 0) {
    return ShellMediaColors.lightForegroundSecondary;
  }
  if (currentMa > 0) {
    return ShellTelemetryColors.charging;
  }
  return ShellTelemetryColors.discharge;
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
