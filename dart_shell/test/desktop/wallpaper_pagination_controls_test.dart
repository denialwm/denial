import 'package:denial_desktop/src/wallpaper/widgets/wallpaper_pagination_controls.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('catalog controls label pages and refuse invalid navigation', (
    tester,
  ) async {
    var previous = 0;
    var next = 0;
    Future<void> show(int page, {bool loading = false, bool hasMore = true}) =>
        tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: WallpaperPaginationControls(
                page: page,
                lastPage: 3,
                loading: loading,
                hasMore: hasMore,
                hasError: false,
                onPrevious: () => previous++,
                onNext: () => next++,
                onRetry: () {},
              ),
            ),
          ),
        );
    await show(1);
    expect(find.text('Page 1 of 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wallpaper-previous-page')));
    expect(previous, 0);
    await tester.tap(find.byKey(const ValueKey('wallpaper-next-page')));
    expect(next, 1);
    await show(2, loading: true);
    await tester.tap(find.byKey(const ValueKey('wallpaper-previous-page')));
    await tester.tap(find.byKey(const ValueKey('wallpaper-next-page')));
    expect(previous, 0);
    expect(next, 1);
    await show(3, hasMore: false);
    await tester.tap(find.byKey(const ValueKey('wallpaper-next-page')));
    await tester.tap(find.byKey(const ValueKey('wallpaper-previous-page')));
    expect(next, 1);
    expect(previous, 1);
  });

  testWidgets('unknown totals do not invent a count and errors have Retry', (
    tester,
  ) async {
    var retried = 0;
    var advanced = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: WallpaperPaginationControls(
            page: 2,
            lastPage: null,
            loading: false,
            hasMore: true,
            hasError: true,
            onPrevious: () {},
            onNext: () => advanced++,
            onRetry: () => retried++,
          ),
        ),
      ),
    );
    expect(find.text('Page 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wallpaper-next-page')));
    expect(advanced, 0);
    await tester.tap(find.byKey(const ValueKey('wallpaper-retry-page')));
    expect(retried, 1);
    expect(tester.takeException(), isNull);
  });
}
