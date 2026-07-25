import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show SemanticsRole;

import 'package:denial_dart_shell/src/input/shell_interaction_registry.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/desktop_notification.dart';
import 'package:denial_dart_shell/src/services/notification_policy_repository.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:denial_dart_shell/src/widgets/notification_banner.dart';
import 'package:denial_dart_shell/src/widgets/notification_media.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'cards stack, animate, replace, and publish precise input regions',
    (tester) async {
      final container = ProviderContainer.test();

      await tester.pumpWidget(_host(const [], container: container));
      expect(find.text('Build finished'), findsNothing);

      await tester.pumpWidget(
        _host([
          _notification(42, 'Build finished'),
          _notification(43, 'Message received'),
        ], container: container),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('Test application'), findsNWidgets(2));
      expect(find.text('Build finished'), findsOneWidget);
      expect(find.text('Message received'), findsOneWidget);
      expect(find.text('Everything is bold & ready.'), findsNWidgets(2));
      final slide = tester.widget<SlideTransition>(
        find
            .ancestor(
              of: find.text('Build finished'),
              matching: find.byType(SlideTransition),
            )
            .first,
      );
      expect(slide.position.value.dx, lessThan(0));
      expect(slide.position.value.dy, lessThan(0));

      await tester.pump(Motion.notificationBanner);
      await tester.pump();

      expect(slide.position.value, Offset.zero);
      expect(
        tester.getTopLeft(find.text('Message received')).dy,
        greaterThan(tester.getTopLeft(find.text('Build finished')).dy),
      );
      expect(
        container.read(shellInteractionRegistryProvider).childRegions,
        hasLength(2),
      );
      for (final region
          in container.read(shellInteractionRegistryProvider).childRegions) {
        expect(region.width, lessThanOrEqualTo(360));
        expect(region.width, lessThan(800));
      }
      expect(
        find.bySemanticsLabel(
          'Test application: Build finished. '
          'Everything is bold & ready.',
        ),
        findsOneWidget,
      );
      final statusSemantics = tester.widget<Semantics>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label?.contains('Build finished') == true,
        ),
      );
      expect(statusSemantics.properties.role, SemanticsRole.status);

      await tester.pumpWidget(
        _host([_notification(43, 'Replacement text')], container: container),
      );
      await tester.pump(Motion.notificationBanner);

      expect(find.text('Build finished'), findsNothing);
      expect(find.text('Message received'), findsNothing);
      expect(find.text('Replacement text'), findsOneWidget);
    },
  );

  testWidgets('critical banners expose the alert semantics role', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _notification(
          42,
          'Action required',
          urgency: DesktopNotificationUrgency.critical,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    final semantics = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label?.contains('Action required') == true,
      ),
    );
    expect(semantics.properties.role, SemanticsRole.alert);
  });

  testWidgets('visible burst is capped at three newest cards', (tester) async {
    await tester.pumpWidget(
      _host([for (var id = 8; id >= 1; id -= 1) _notification(id, 'Item $id')]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NotificationCard), findsNWidgets(3));
    expect(find.text('Item 8'), findsOneWidget);
    expect(find.text('Item 6'), findsOneWidget);
    expect(find.text('Item 5'), findsNothing);
  });

  testWidgets('rapid replacements keep animated remnants bounded', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([for (var id = 1; id <= 3; id += 1) _notification(id, 'Item $id')]),
    );
    await tester.pumpAndSettle();

    for (var generation = 1; generation <= 8; generation += 1) {
      final firstId = generation * 3 + 1;
      await tester.pumpWidget(
        _host([
          for (var id = firstId; id < firstId + 3; id += 1)
            _notification(id, 'Item $id'),
        ]),
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        find.byType(NotificationCard).evaluate().length,
        lessThanOrEqualTo(6),
      );
    }

    await tester.pump(Motion.notificationBanner);
    await tester.pump();
    expect(find.byType(NotificationCard), findsNWidgets(3));
  });

  testWidgets('default, named, and dismiss controls are interactive', (
    tester,
  ) async {
    final defaults = <int>[];
    final actions = <(int, String)>[];
    final dismissals = <int>[];
    await tester.pumpWidget(
      _host(
        [_notification(42, 'Actionable')],
        onDefaultAction: (id) {
          defaults.add(id);
          return true;
        },
        onAction: (id, key) {
          actions.add((id, key));
          return true;
        },
        onDismiss: (id) {
          dismissals.add(id);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept'));
    expect(actions, <(int, String)>[(42, 'accept')]);

    await tester.tap(find.text('Actionable'));
    expect(defaults, <int>[42]);

    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(dismissals, <int>[42]);
  });

  testWidgets('application-only lock preview hides content and actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _notification(42, 'Private subject'),
      ], previewMode: NotificationPreviewMode.applicationOnly),
    );
    await tester.pumpAndSettle();

    expect(find.text('New notification'), findsOneWidget);
    expect(find.text('Private subject'), findsNothing);
    expect(find.text('Everything is bold & ready.'), findsNothing);
    expect(find.text('Accept'), findsNothing);
  });

  testWidgets('static image data and progress render within a bounded card', (
    tester,
  ) async {
    final image = DesktopNotificationImageData(
      width: 2,
      height: 2,
      rowStride: 8,
      hasAlpha: true,
      bitsPerSample: 8,
      channels: 4,
      data: Uint8List.fromList(<int>[
        255,
        0,
        0,
        255,
        0,
        255,
        0,
        255,
        0,
        0,
        255,
        255,
        255,
        255,
        255,
        255,
      ]),
    );
    await tester.pumpWidget(
      _host([
        _notification(
          42,
          'Image',
          imageData: image,
          hasProgress: true,
          progress: 65,
        ),
      ]),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    expect(find.byType(RawImage), findsOneWidget);
    expect(find.bySemanticsLabel('Progress: 65%'), findsOneWidget);
    expect(
      tester.getSize(find.byType(NotificationCard)).width,
      lessThanOrEqualTo(360),
    );
  });

  testWidgets('static image paths are read and decoded through a byte bound', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'denial-notification-image-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final imageFile = File('${directory.path}/one-pixel.png');
    imageFile.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      flush: true,
    );

    await tester.pumpWidget(
      _host([_notification(42, 'File image', imagePath: imageFile.path)]),
    );
    await tester.pump(Motion.notificationBanner);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);

    final oversized = File('${directory.path}/too-large.png');
    oversized.writeAsBytesSync(
      Uint8List(maxNotificationStaticImageBytes + 1),
      flush: true,
    );
    expect(loadBoundedNotificationImage(oversized.path), isNull);
  });
}

Widget _host(
  List<DesktopNotification> notifications, {
  ProviderContainer? container,
  NotificationPreviewMode previewMode = NotificationPreviewMode.full,
  bool Function(int)? onDismiss,
  bool Function(int)? onDefaultAction,
  bool Function(int, String)? onAction,
}) {
  final content = DenialLocalizationScope(
    child: MediaQuery(
      data: const MediaQueryData(size: Size(800, 600)),
      child: DefaultTextStyle(
        style: ShellText.base,
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: NotificationBannerView(
              notifications: notifications,
              previewMode: previewMode,
              onDismiss: onDismiss,
              onDefaultAction: onDefaultAction,
              onAction: onAction,
            ),
          ),
        ),
      ),
    ),
  );
  return container == null
      ? ProviderScope(child: content)
      : UncontrolledProviderScope(container: container, child: content);
}

DesktopNotification _notification(
  int id,
  String summary, {
  DesktopNotificationUrgency urgency = .normal,
  DesktopNotificationImageData? imageData,
  bool hasProgress = false,
  int progress = 0,
  String imagePath = '',
}) {
  return DesktopNotification(
    id: id,
    sender: ':1.42',
    appName: 'Test application',
    appIcon: '',
    summary: summary,
    body: 'Everything is <b>bold</b> &amp; ready.',
    actions: const <DesktopNotificationAction>[
      DesktopNotificationAction(key: 'default', label: 'Open'),
      DesktopNotificationAction(key: 'accept', label: 'Accept'),
    ],
    urgency: urgency,
    category: 'test',
    desktopEntry: '',
    imagePath: imagePath,
    imageData: imageData,
    resident: false,
    transient: false,
    suppressSound: false,
    actionIcons: false,
    soundName: '',
    soundFile: '',
    x: 0,
    y: 0,
    hasPosition: false,
    progress: progress,
    hasProgress: hasProgress,
    expireTimeoutMs: 6000,
  );
}
