import 'package:denial_dart_shell/src/desktop/desktop_panel_transition.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('retained panel lazily mounts its child only once', (
    tester,
  ) async {
    final visible = ValueNotifier<bool>(false);
    addTearDown(visible.dispose);
    var mounts = 0;
    var disposals = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: SizedBox(
              width: 640,
              height: 480,
              child: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (context, isVisible, child) {
                  return DesktopPanelTransition(
                    inputDebugLabel: 'Retained test panel',
                    visible: isVisible,
                    maintainState: true,
                    child: _LifecycleProbe(
                      onMount: () => mounts += 1,
                      onDispose: () => disposals += 1,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    expect(mounts, 0);
    expect(find.byType(_LifecycleProbe, skipOffstage: false), findsNothing);

    visible.value = true;
    await tester.pumpAndSettle();
    expect(mounts, 1);
    expect(disposals, 0);
    expect(find.byType(_LifecycleProbe), findsOneWidget);

    visible.value = false;
    await tester.pumpAndSettle();
    expect(mounts, 1);
    expect(disposals, 0);
    expect(find.byType(_LifecycleProbe), findsNothing);
    expect(find.byType(_LifecycleProbe, skipOffstage: false), findsOneWidget);

    visible.value = true;
    await tester.pumpAndSettle();
    expect(mounts, 1);
    expect(disposals, 0);
    expect(find.byType(_LifecycleProbe), findsOneWidget);
  });
}

class _LifecycleProbe extends StatefulWidget {
  const _LifecycleProbe({required this.onMount, required this.onDispose});

  final VoidCallback onMount;
  final VoidCallback onDispose;

  @override
  State<_LifecycleProbe> createState() => _LifecycleProbeState();
}

class _LifecycleProbeState extends State<_LifecycleProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
