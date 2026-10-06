import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/widgets.dart';

Widget mobileMotionHarness(Widget child, {Size size = const Size(400, 800)}) =>
    DenialLocalizationScope(
      locale: const Locale('en'),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(size: size),
          child: ShellTheme(
            data: const ShellThemeData(),
            child: DefaultTextStyle(
              style: const TextStyle(fontSize: 14),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox.fromSize(size: size, child: child),
              ),
            ),
          ),
        ),
      ),
    );

DenialWindow motionWindow(int id, {String appId = 'test'}) => DenialWindow(
  objectId: id,
  objectKind: 'xdg_toplevel',
  surfaceId: id,
  windowId: id,
  textureId: id,
  title: 'App $id',
  appId: appId,
  width: 400,
  height: 800,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 400,
  surfaceHeight: 800,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 400,
  textureSourceHeight: 800,
  geometryX: 0,
  geometryY: 0,
  geometryWidth: 400,
  geometryHeight: 800,
  monitorId: 1,
  transform: 0,
  scale120: 120,
);
