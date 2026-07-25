import 'package:denial_dart_shell/l10n/generated/app_localizations.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unsupported locales resolve through the English catalog', (
    tester,
  ) async {
    late Locale effectiveLocale;
    late TextDirection textDirection;
    late String settingsTitle;

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('zz', 'ZZ'),
        child: Builder(
          builder: (context) {
            effectiveLocale = Localizations.localeOf(context);
            textDirection = Directionality.of(context);
            settingsTitle = context.l10n.settingsApplicationTitle;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(effectiveLocale, const Locale('en'));
    expect(textDirection, TextDirection.ltr);
    expect(settingsTitle, 'Settings');
    expect(AppLocalizations.supportedLocales, const <Locale>[Locale('en')]);
  });
}
