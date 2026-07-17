import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/input/shell_interaction_registry.dart';

void main() {
  test('interaction snapshot derives routing policy from registered surfaces',
      () {
    final registry = ShellInteractionRegistry();
    addTearDown(registry.dispose);
    final regionId = registry.reserveSurfaceId();
    final modalId = registry.reserveSurfaceId();

    registry.upsert(ShellInteractionSurface(
      id: regionId,
      debugLabel: 'Dashboard',
      pointerPolicy: ShellPointerPolicy.childBounds,
      keyboardPolicy: ShellKeyboardPolicy.none,
      compositorPolicy: ShellCompositorPolicy.normal,
      bounds: const Rect.fromLTWH(10, 20, 300, 200),
    ));
    expect(
      registry.state.childRegions,
      const <Rect>[Rect.fromLTWH(10, 20, 300, 200)],
    );
    expect(registry.state.capturesFullScene, isFalse);

    registry.upsert(ShellInteractionSurface(
      id: modalId,
      debugLabel: 'Modal',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.exclusive,
    ));
    expect(registry.state.capturesFullScene, isTrue);
    expect(registry.state.capturesKeyboard, isTrue);
    expect(registry.state.compositorExclusive, isTrue);

    registry.remove(modalId);
    expect(registry.state.capturesFullScene, isFalse);
    expect(registry.state.capturesKeyboard, isFalse);
  });

  testWidgets('child-bound input regions report transformed render geometry',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Transform.translate(
              offset: const Offset(24, 36),
              child: const ShellInputRegion(
                debugLabel: 'Measured surface',
                child: SizedBox(width: 180, height: 96),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      container.read(shellInteractionRegistryProvider).childRegions,
      const <Rect>[Rect.fromLTWH(24, 36, 180, 96)],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
    expect(
      container.read(shellInteractionRegistryProvider).surfaces,
      isEmpty,
    );
  });
}
