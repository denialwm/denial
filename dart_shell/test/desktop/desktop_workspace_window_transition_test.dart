import 'package:denial_dart_shell/src/desktop/desktop_shell.dart';
import 'package:denial_dart_shell/src/desktop/desktop_workspace.dart';
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
