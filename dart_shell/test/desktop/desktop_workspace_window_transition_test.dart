import 'package:denial_dart_shell/src/desktop/desktop_shell.dart';
import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/widgets/desktop_window_reveal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const placement = DesktopWindowPlacement(
    objectId: 1,
    frame: Rect.fromLTWH(0, 0, 320, 240),
    z: 1,
    monitorId: 7,
    workspaceId: 1,
  );
  const transition = DesktopWorkspaceTransition(
    monitorId: 7,
    fromWorkspace: 1,
    toWorkspace: 2,
    serial: 1,
  );

  test('desktop navigation never becomes a window entrance', () {
    expect(
      desktopWindowSuppressesInitialReveal(
        overview: true,
        switching: false,
        minimized: false,
        hasWorkspaceTransition: false,
      ),
      isTrue,
    );
    expect(
      desktopWindowSuppressesInitialReveal(
        overview: false,
        switching: true,
        minimized: false,
        hasWorkspaceTransition: false,
      ),
      isTrue,
    );
    expect(
      desktopWindowSuppressesInitialReveal(
        overview: false,
        switching: false,
        minimized: false,
        hasWorkspaceTransition: false,
      ),
      isFalse,
    );
  });

  testWidgets('workspace motion does not remount its window subtree', (
    tester,
  ) async {
    var mounts = 0;

    Widget build(DesktopWorkspaceTransition? activeTransition) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 1920,
          height: 1080,
          child: DesktopWorkspaceWindowTransition(
            placement: placement,
            transition: activeTransition,
            orientation: WorkspaceSwitchingOrientation.horizontal,
            outputRect: const Rect.fromLTWH(0, 0, 1920, 1080),
            duration: Duration.zero,
            child: _MountProbe(onMount: () => mounts++),
          ),
        ),
      );
    }

    await tester.pumpWidget(build(null));
    await tester.pumpWidget(build(transition));
    await tester.pumpWidget(build(null));

    expect(mounts, 1);
  });

  testWidgets('workspace-remounted window never replays its entrance', (
    tester,
  ) async {
    Widget build({required bool suppressInitialAnimation}) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: DesktopWindowReveal(
          enabled: true,
          suppressInitialAnimation: suppressInitialAnimation,
          child: const SizedBox(width: 320, height: 240),
        ),
      );
    }

    await tester.pumpWidget(build(suppressInitialAnimation: true));
    expect(tester.widget<ClipPath>(find.byType(ClipPath)).clipper, isNull);

    await tester.pumpWidget(build(suppressInitialAnimation: false));
    await tester.pump();

    expect(tester.widget<ClipPath>(find.byType(ClipPath)).clipper, isNull);
  });

  for (final navigationMode in <String>['overview', 'switcher']) {
    testWidgets('$navigationMode exit remount never replays window entrance', (
      tester,
    ) async {
      final registry = DesktopWindowRevealMountRegistry();

      Widget build({required bool mounted, required bool navigating}) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: mounted
              ? TrackedDesktopWindowReveal(
                  key: const ValueKey<String>('window-1'),
                  registry: registry,
                  objectId: 1,
                  suppressInitialAnimation: navigationMode == 'overview'
                      ? desktopWindowSuppressesInitialReveal(
                          overview: navigating,
                          switching: false,
                          minimized: false,
                          hasWorkspaceTransition: false,
                        )
                      : desktopWindowSuppressesInitialReveal(
                          overview: false,
                          switching: navigating,
                          minimized: false,
                          hasWorkspaceTransition: false,
                        ),
                  child: const SizedBox(width: 320, height: 240),
                )
              : const SizedBox.shrink(),
        );
      }

      await tester.pumpWidget(build(mounted: true, navigating: false));
      expect(tester.widget<ClipPath>(find.byType(ClipPath)).clipper, isNotNull);

      await tester.pumpWidget(build(mounted: false, navigating: true));
      await tester.pumpWidget(build(mounted: true, navigating: true));
      expect(tester.widget<ClipPath>(find.byType(ClipPath)).clipper, isNull);

      await tester.pumpWidget(build(mounted: false, navigating: false));
      await tester.pumpWidget(build(mounted: true, navigating: false));
      await tester.pump();

      expect(tester.widget<ClipPath>(find.byType(ClipPath)).clipper, isNull);
    });
  }
}

class _MountProbe extends StatefulWidget {
  const _MountProbe({required this.onMount});

  final VoidCallback onMount;

  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
