import 'package:flutter/widgets.dart';

/// Provides the stable root overlay expected by Flutter affordances.
///
/// Denial intentionally does not use [WidgetsApp] or a [Navigator]. Keeping a
/// single entry alive lets provider rebuilds update the scene without
/// reconstructing the overlay or invalidating feature-owned overlay entries.
class ShellOverlayHost extends StatefulWidget {
  const ShellOverlayHost({super.key, required this.child});

  final Widget child;

  @override
  State<ShellOverlayHost> createState() => _ShellOverlayHostState();
}

class _ShellOverlayHostState extends State<ShellOverlayHost> {
  late final OverlayEntry _sceneEntry;

  @override
  void initState() {
    super.initState();
    _sceneEntry = OverlayEntry(builder: (_) => widget.child);
  }

  @override
  void didUpdateWidget(covariant ShellOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sceneEntry.markNeedsBuild();
  }

  @override
  void dispose() {
    if (_sceneEntry.mounted) {
      _sceneEntry.remove();
    }
    _sceneEntry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: <OverlayEntry>[_sceneEntry]);
  }
}
