import 'dart:io';
import 'dart:ui' as ui;

import 'package:denial_dart_shell/src/widgets/app_icon.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SVG pixels are shared, retained while moving, and released', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('denial-icon-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/icon.svg')
      ..writeAsStringSync('''
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">
  <path fill="currentColor" d="M0 0H64V64H0Z"/>
</svg>
''');
    await tester.runAsync(() => DesktopAppSvgLoader(file.path).loadBytes(null));

    final live = <ui.Image>{};
    var allocations = 0;
    final onCreate = ui.Image.onCreate;
    final onDispose = ui.Image.onDispose;
    ui.Image.onCreate = (image) {
      live.add(image);
      allocations++;
      onCreate?.call(image);
    };
    ui.Image.onDispose = (image) {
      live.remove(image);
      onDispose?.call(image);
    };
    addTearDown(() {
      ui.Image.onCreate = onCreate;
      ui.Image.onDispose = onDispose;
    });

    Widget icons({int count = 2, double dpr = 2, double x = 0}) {
      return MediaQuery(
        data: MediaQueryData(devicePixelRatio: dpr),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Transform.translate(
              offset: Offset(x, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < count; i++)
                    SizedBox.square(
                      dimension: 85,
                      child: AppIconImage(iconPath: file.path),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(icons());
    await tester.pumpAndSettle();
    expect(live, hasLength(1));
    expect(live.single.width, 170);
    expect(live.single.height, 170);
    final warmAllocations = allocations;
    for (var frame = 1; frame <= 20; frame++) {
      await tester.pumpWidget(icons(x: frame * 0.7));
    }
    expect(allocations, warmAllocations);

    await tester.pumpWidget(icons(count: 1));
    await tester.pumpAndSettle();
    expect(live, hasLength(1));
    expect(allocations, warmAllocations);

    await tester.pumpWidget(icons(count: 1, dpr: 3));
    await tester.pumpAndSettle();
    expect(live, hasLength(1));
    expect(live.single.width, 255);
    expect(live.single.height, 255);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(live, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
