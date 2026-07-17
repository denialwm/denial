import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../../models/hypr_window.dart';
import '../../theme/motion.dart';
import 'overview_geometry.dart';
import 'overview_window_card.dart';

/// The swipeable strip of window previews shown when the overview is open.
class OverviewCarousel extends StatelessWidget {
  const OverviewCarousel({
    super.key,
    required this.windows,
    required this.progress,
    required this.pageController,
    required this.foregroundObjectId,
    required this.onDismissWindow,
    required this.onFocusWindow,
  });

  final List<HyprWindow> windows;
  final double progress;
  final PageController pageController;
  final int? foregroundObjectId;
  final ValueChanged<HyprWindow> onDismissWindow;
  final void Function(HyprWindow window, Rect startRect) onFocusWindow;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewAspect = viewAspectFor(constraints.biggest);
        final cardSize = cardSizeFor(
          constraints: constraints,
          padding: padding,
          aspect: viewAspect,
        );
        final carouselHeight = cardSize.height + 48.0;
        final intro = Motion.standard.transform(progress);

        return Transform.translate(
          offset: Offset(
            lerpDouble(-constraints.maxWidth * 0.6, 0.0, intro)!,
            0.0,
          ),
          child: Opacity(
            opacity: unit(progress * 1.2),
            child: Center(
              child: SizedBox(
                height: carouselHeight,
                child: PageView.builder(
                  controller: pageController,
                  physics: progress < 0.96
                      ? const NeverScrollableScrollPhysics()
                      : const BouncingScrollPhysics(),
                  clipBehavior: Clip.none,
                  itemCount: windows.length,
                  itemBuilder: (context, index) {
                    final window = windows[index];
                    return AnimatedBuilder(
                      animation: pageController,
                      builder: (context, child) {
                        return OverviewWindowCard(
                          key: ValueKey<int>(window.objectId),
                          window: window,
                          index: index,
                          progress: progress,
                          pageOffset: index - _page(pageController),
                          cardSize: cardSize,
                          hidden: foregroundObjectId == window.objectId &&
                              progress < 0.995,
                          onDismiss: onDismissWindow,
                          onFocus: onFocusWindow,
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  double _page(PageController controller) {
    if (!controller.hasClients) {
      return controller.initialPage.toDouble();
    }
    try {
      return controller.page ?? controller.initialPage.toDouble();
    } on AssertionError {
      return controller.initialPage.toDouble();
    }
  }
}
