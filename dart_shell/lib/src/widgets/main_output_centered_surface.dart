import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/display_layout.dart';

typedef MainOutputSurfaceBuilder = Widget Function(
  BuildContext context,
  BoxConstraints constraints,
);

/// Centers a transient shell surface inside the configured main output.
///
/// Denial's Flutter view spans the complete output atlas, so a plain [Center]
/// lands between monitors. This widget scopes layout to the authoritative main
/// output and falls back to the complete canvas until display state arrives.
class MainOutputCenteredSurface extends ConsumerWidget {
  const MainOutputCenteredSurface({
    required this.builder,
    this.padding = const EdgeInsets.all(24),
    super.key,
  });

  final MainOutputSurfaceBuilder builder;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canvas = Offset.zero & MediaQuery.sizeOf(context);
    final requestedOutput = ref
        .watch(displayLayoutProvider)
        ?.mainOutput
        ?.logicalRect
        .intersect(canvas);
    final outputRect = requestedOutput == null || requestedOutput.isEmpty
        ? canvas
        : requestedOutput;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fromRect(
          rect: outputRect,
          child: Padding(
            padding: padding,
            child: LayoutBuilder(
              builder: (context, constraints) => Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: builder(context, constraints),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
