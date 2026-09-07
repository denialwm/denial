import 'package:flutter/widgets.dart';

import '../../localization/denial_localizations.dart';
import '../../models/denial_window.dart';
import '../../theme/shell_theme.dart';
import '../window_hero.dart';

/// The retained texture shared by portrait and landscape recents.
class OverviewWindowPreview extends StatelessWidget {
  const OverviewWindowPreview({
    super.key,
    required this.previewKey,
    required this.window,
    required this.size,
  });

  final Key previewKey;
  final DenialWindow window;
  final Size size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: localizedWindowTitle(context, window),
      child: RepaintBoundary(
        child: SizedBox(
          key: previewKey,
          width: size.width,
          height: size.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              context.shellTheme.windowRadius,
            ),
            child: FittedBox(
              fit: BoxFit.fill,
              child: SizedBox.fromSize(
                size: MediaQuery.sizeOf(context),
                child: WindowSurface(window: window),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
