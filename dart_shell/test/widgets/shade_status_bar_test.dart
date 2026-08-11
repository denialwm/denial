import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/battery_status.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:denial_dart_shell/src/state/system_status.dart';
import 'package:denial_dart_shell/src/widgets/shade/status_bar.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mobile status bar displays the time without a LIVE label', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellControllerProvider.overrideWith(_TestShellController.new),
          clockProvider.overrideWith(
            (ref) => Stream<DateTime>.value(DateTime(2026, 8, 10, 9, 7)),
          ),
          batteryProvider.overrideWith(_TestBatteryController.new),
        ],
        child: const DenialLocalizationScope(
          locale: Locale('en'),
          child: SizedBox(
            width: 400,
            height: 120,
            child: Stack(children: [ShadeStatusBar()]),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('09:07'), findsOneWidget);
    expect(find.textContaining('LIVE'), findsNothing);
  });
}

class _TestShellController extends ShellController {
  @override
  ShellState build() => ShellState.initial(locked: false);
}

class _TestBatteryController extends BatteryController {
  @override
  BatteryStatus build() => BatteryStatus.unknown;
}
