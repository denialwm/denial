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
    expect(AppLocalizations.supportedLocales, const <Locale>[
      Locale('en'),
      Locale('zh'),
    ]);
  });

  testWidgets('Simplified Chinese resolves from a mainland locale', (
    tester,
  ) async {
    late Locale effectiveLocale;
    late String settingsTitle;
    late String date;
    late String displayCount;

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('zh', 'CN'),
        child: Builder(
          builder: (context) {
            effectiveLocale = Localizations.localeOf(context);
            settingsTitle = context.l10n.settingsApplicationTitle;
            date = localizedLongDate(context, DateTime(2026, 8, 8));
            displayCount = context.l10n.settingsSystemBarDisplaysSelected(2);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(effectiveLocale, const Locale('zh'));
    expect(settingsTitle, '设置');
    expect(date, '八月8日 星期六');
    expect(displayCount, '已选择 2 个显示器');
  });
}
