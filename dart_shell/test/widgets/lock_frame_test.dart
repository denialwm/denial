import 'package:denial_dart_shell/src/core/shell_secure_stage.dart';
import 'package:denial_dart_shell/src/state/lock_frame.dart';
import 'package:denial_dart_shell/src/widgets/output_relative_translation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('channel acknowledges only the current layout token once', (
    tester,
  ) async {
    const channel = BasicMessageChannel<String>(
      'denial/lock_frame',
      StringCodec(),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final sent = <String?>[];
    messenger.setMockDecodedMessageHandler<String>(channel, (message) async {
      sent.add(message);
      return message == 'sync' ? '0' : '';
    });
    addTearDown(
      () => messenger.setMockDecodedMessageHandler<String>(channel, null),
    );
    final container = ProviderContainer.test();
    final controller = container.read(lockFrameRequestProvider.notifier);
    await tester.pump();
    expect(sent, ['sync']);
    await messenger.handlePlatformMessage(
      'denial/lock_frame',
      const StringCodec().encodeMessage('91'),
      null,
    );
    expect(container.read(lockFrameRequestProvider), 91);
    await controller.laidOut(90);
    expect(sent, ['sync']);
    await controller.laidOut(91);
    await controller.laidOut(91);
    expect(sent, ['sync', '91']);
    await messenger.handlePlatformMessage(
      'denial/lock_frame',
      const StringCodec().encodeMessage('92'),
      null,
    );
    await controller.laidOut(91);
    await controller.laidOut(92);
    expect(sent, ['sync', '91', '92']);
    await tester.pump();
  });
  testWidgets(
    'hidden lock settles before acknowledgement and unlock still animates',
    (tester) async {
      final acknowledged = <int>[];
      var completed = 0;
      Widget stage({
        required bool locked,
        int token = 0,
        bool ticking = true,
      }) => Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: TickerMode(
            enabled: ticking,
            child: UnlockTransitionHost(
              locked: locked,
              lockLayerVisible: locked || token != 0 || acknowledged.isNotEmpty,
              animateLock: true,
              lockFrameToken: token,
              onLockFrameLaidOut: acknowledged.add,
              onUnlockComplete: () => completed++,
              scene: const SizedBox.expand(),
              chrome: const SizedBox.shrink(),
              backdrop: const SizedBox.expand(),
              lockLayerBuilder: (_) => const SizedBox.expand(),
            ),
          ),
        ),
      );
      double desktopOffset() => tester
          .widget<OutputRelativeTranslation>(
            find.byKey(const ValueKey<String>('unlock-desktop-stage')),
          )
          .offsetFactor
          .dy;
      await tester.pumpWidget(stage(locked: false));
      expect(desktopOffset(), 0);
      await tester.pumpWidget(stage(locked: true, ticking: false));
      expect(acknowledged, isEmpty);
      await tester.pumpWidget(stage(locked: true, token: 42));
      expect(desktopOffset(), 1);
      expect(acknowledged, [42]);
      await tester.pump(const Duration(milliseconds: 150));
      expect(desktopOffset(), 1);
      expect(acknowledged, [42]);
      await tester.pumpWidget(stage(locked: false));
      expect(desktopOffset(), 1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(desktopOffset(), greaterThan(0));
      expect(desktopOffset(), lessThan(1));
      await tester.pumpAndSettle();
      expect(completed, greaterThanOrEqualTo(1));
      expect(desktopOffset(), 0);
    },
  );

  testWidgets('a request cannot acknowledge an unlocked layout', (
    tester,
  ) async {
    final acknowledged = <int>[];
    Widget stage(bool locked, int token) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: UnlockTransitionHost(
          locked: locked,
          lockLayerVisible: locked,
          lockFrameToken: token,
          onLockFrameLaidOut: acknowledged.add,
          onUnlockComplete: () {},
          scene: const SizedBox.expand(),
          chrome: const SizedBox.shrink(),
          backdrop: const SizedBox.expand(),
          lockLayerBuilder: (_) => const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpWidget(stage(false, 7));
    expect(acknowledged, isEmpty);
    await tester.pumpWidget(stage(true, 8));
    expect(acknowledged, [8]);
    await tester.pumpWidget(stage(true, 9));
    expect(acknowledged, [8, 9]);
    await tester.pumpWidget(stage(true, 9));
    expect(acknowledged, [8, 9]);
  });
}
