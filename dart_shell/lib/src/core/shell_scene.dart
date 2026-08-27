import 'package:flutter/widgets.dart';

/// The feature-owned part of a Denial shell profile.
///
/// [content] is the application scene, [chrome] is profile UI that should move
/// with the scene during an unlock transition, and [overlays] are transient
/// feature layers such as notifications and heads-up displays. Compositor
/// plumbing is deliberately absent: the Denial shell host installs it
/// automatically.
@immutable
class DenialShellScene {
  const DenialShellScene({
    required this.content,
    this.chrome = const SizedBox.shrink(),
    this.overlays = const <Widget>[],
  });

  final Widget content;
  final Widget chrome;
  final List<Widget> overlays;
}
