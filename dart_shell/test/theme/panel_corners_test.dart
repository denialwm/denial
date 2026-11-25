import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a panel takes the window roundness outside, the interface inside', () {
    const theme = ShellThemeData(
      cornerRadiusScale: 1.2,
      windowCornerRadiusScale: 0.5,
    );

    expect(theme.windowRadius, ShellRadii.window * 0.5);
    expect(theme.panelRadius, theme.windowRadius);
    expect(theme.outerRadius(10), 5);
    expect(theme.outerBorderRadius(10), BorderRadius.circular(5));

    expect(theme.nestedPanelRadius, ShellRadii.panel * 1.2);
    expect(theme.tileRadius, ShellRadii.tile * 1.2);
    expect(theme.borderRadius(10), BorderRadius.circular(12));
  });
}
