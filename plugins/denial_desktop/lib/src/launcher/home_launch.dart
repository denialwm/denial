import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';

import '../state/reference_shell_controller.dart';
import '../state/reference_shell_metrics.dart';
import '../state/phone_desk.dart';

/// Opens home's [app] from its icon at [iconRect], in global coordinates,
/// through the shell's launch transition. A running app grows out of the
/// icon as it is; a new one grows as a placeholder its window fills.
Future<void> launchHomeApp(
  BuildContext context,
  WidgetRef ref,
  HomeGridItem app,
  Rect iconRect,
) async {
  final shell = ref.read(referenceShellProvider.notifier);
  final local = app.localApp;
  if (local != null) {
    _launchLocal(context, ref, app, local, iconRect);
    return;
  }
  final desktop = app.app;
  if (desktop == null) return;

  ref
      .read(applicationRecentsProvider.notifier)
      .record(desktopApplicationRecentId(desktop.id));
  final launcher = ref.read(appLauncherProvider);
  final expectedAppIds = launcher.expectedWindowAppIds(desktop);
  if (launcher.usesLegacyTextInput(desktop)) {
    shell.registerLegacyTextInputAppIds(expectedAppIds);
  }
  final running = launcher.findOpenWindow(
    desktop,
    ref.read(referenceShellProvider).openAppWindows,
  );
  // Opened from the phone, an app running on a desk comes to the phone.
  final onDesk = running == null && ref.read(phoneDeskProvider) != null
      ? launcher.findOpenWindow(
          desktop,
          ref.read(referenceShellProvider).desk.openAppWindows,
        )
      : null;
  if (onDesk != null) {
    shell.sendToPhone(onDesk);
    return;
  }
  if (running != null) {
    shell.activateAppFromLauncher(
      window: running,
      appName: desktop.name,
      iconPath: desktop.iconPath,
      sourceRect: iconRect,
      sourceItemId: app.id,
    );
    return;
  }
  final requestId = shell.beginAppLaunch(
    appName: desktop.name,
    iconPath: desktop.iconPath,
    expectedAppIds: expectedAppIds,
    sourceRect: iconRect,
    sourceItemId: app.id,
  );
  if (requestId == null) return;
  final started = await launcher.launch(desktop, launchRequestId: requestId);
  if (!started) shell.failAppLaunch(requestId);
}

void _launchLocal(
  BuildContext context,
  WidgetRef ref,
  HomeGridItem item,
  LocalFlutterApplication app,
  Rect iconRect,
) {
  ref
      .read(applicationRecentsProvider.notifier)
      .record(localApplicationRecentId(app.id));
  final displayLayout = ref.read(
    sceneDisplayLayoutProvider(ShellPart.of(context)),
  );
  final mainOutput = displayLayout?.mainOutput;
  final availableBounds = mainOutput == null
      ? Offset.zero & MediaQuery.sizeOf(context)
      : displayLayout!.workAreaOf(mainOutput);
  final statusBarHeight =
      MediaQuery.paddingOf(context).top +
      ReferenceShellMetrics.appStatusInset(MediaQuery.sizeOf(context));
  final geometry = Rect.fromLTWH(
    availableBounds.left,
    availableBounds.top + statusBarHeight,
    availableBounds.width,
    math.max(64.0, availableBounds.height - statusBarHeight),
  );
  final title = app.titleFor(context);
  final launcher = ref.read(localFlutterApplicationLauncherProvider);
  bool launch() => launcher.launch(
    app.id,
    availableBounds: availableBounds,
    geometry: geometry,
    title: title,
  );

  final shell = ref.read(referenceShellProvider.notifier);
  for (final window in ref.read(referenceShellProvider).windows) {
    if (window.isLocalFlutter && window.appId == app.id) {
      shell.activateAppFromLauncher(
        window: window,
        appName: title,
        iconPath: null,
        sourceRect: iconRect,
        sourceItemId: item.id,
      );
      launch();
      return;
    }
  }

  final requestId = shell.beginAppLaunch(
    appName: title,
    iconPath: null,
    expectedAppIds: <String>[app.id],
    sourceRect: iconRect,
    sourceItemId: item.id,
  );
  if (requestId != null && !launch()) {
    shell.failAppLaunch(requestId);
  }
}
