import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/input/shell_interaction_registry.dart';
import 'package:denial_dart_shell/src/widgets/shell_surface_host.dart';

void main() {
  testWidgets('managed modal owns input through its closing transition', (
    tester,
  ) async {
    final container = ProviderContainer.test();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: ShellSurfaceHost(child: SizedBox.expand()),
        ),
      ),
    );

    final handle = container
        .read(shellSurfaceControllerProvider.notifier)
        .show(
          debugLabel: 'Test modal',
          transitionDuration: const Duration(milliseconds: 200),
          builder: (_, _) => const Center(
            child: SizedBox(key: ValueKey<String>('modal'), width: 120),
          ),
        );

    expect(
      container.read(shellInteractionRegistryProvider).capturesFullScene,
      isTrue,
      reason: 'input ownership is installed by show(), before the next frame',
    );
    expect(
      container.read(shellInteractionRegistryProvider).capturesKeyboard,
      isTrue,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey<String>('modal')), findsOneWidget);

    handle.close();
    await tester.pump();
    expect(
      container.read(shellInteractionRegistryProvider).capturesFullScene,
      isTrue,
      reason: 'closing visuals must retain their native input ownership',
    );

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('modal')), findsNothing);
    expect(container.read(shellInteractionRegistryProvider).surfaces, isEmpty);
  });

  testWidgets('outside click dismisses a managed modal', (tester) async {
    final container = ProviderContainer.test();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: ShellSurfaceHost(child: SizedBox.expand()),
        ),
      ),
    );
    container
        .read(shellSurfaceControllerProvider.notifier)
        .show(
          debugLabel: 'Dismissible modal',
          transitionDuration: Duration.zero,
          builder: (_, _) =>
              const Center(child: SizedBox(width: 100, height: 100)),
        );
    await tester.pump();

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(container.read(shellSurfaceControllerProvider), isEmpty);
    expect(container.read(shellInteractionRegistryProvider).surfaces, isEmpty);
  });
}
