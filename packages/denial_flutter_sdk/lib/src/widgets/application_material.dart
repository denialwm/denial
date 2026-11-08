import 'package:flutter/material.dart';

import '../theme/application_material_policy.dart';
import '../theme/application_theme.dart';
import '../theme/shell_theme.dart';
import 'shell_backdrop_blur.dart';
import 'surface_geometry.dart';
import 'content_switcher.dart';

/// Semantic application material. Functional surfaces filter available app
/// pixels; the compositor supplies glass where the client remains translucent.
/// Foreground controls remain unfiltered.
class DenialMaterial extends StatelessWidget {
  const DenialMaterial({
    required this.role,
    required this.child,
    this.borderRadius,
    this.inset = 0,
    this.floating = false,
    this.preserveGlassEffects = false,
    super.key,
  }) : assert(inset >= 0),
       assert(
         !floating ||
             role == DenialMaterialRole.sidebar ||
             role == DenialMaterialRole.toolbar,
       );

  final DenialMaterialRole role;
  final Widget child;
  final BorderRadius? borderRadius;

  /// Distance from the containing surface, in logical pixels.
  final double inset;
  final bool floating;

  /// Opt in to the saved optical effects without changing existing app chrome.
  /// Welcome uses this for its progress surface.
  final bool preserveGlassEffects;

  @override
  Widget build(BuildContext context) {
    final theme = context.applicationTheme;
    final policy = theme.policy(role);
    final radius =
        borderRadius ??
        (role == DenialMaterialRole.content
            ? BorderRadius.zero
            : DenialSurfaceGeometry.borderRadiusOf(context, inset: inset));
    Widget surface = Material(
      color: theme.background(role),
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    if (policy.backdrop == DenialMaterialBackdrop.content) {
      // App chrome needs a quiet optical profile: preserve the user's blur and
      // window opacity, without magnifying text scrolling behind the controls.
      final glass = theme.shell.glass;
      final backdropTheme = preserveGlassEffects
          ? theme.shell
          : theme.shell.copyWith(
              glass: glass.copyWith(
                edgeStrength: 0,
                lightIntensity: 0,
                refraction: 0,
                dispersion: 0,
              ),
            );
      surface = ShellTheme(
        data: backdropTheme,
        child: ShellBackdropBlur(
          borderRadius: radius,
          separateChild: true,
          child: surface,
        ),
      );
    }
    if (floating) {
      final dark = theme.shell.brightness == Brightness.dark;
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .18 : .08),
              blurRadius: 24,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: theme.colors.foreground.withValues(
                alpha: dark ? .12 : .10,
              ),
              width: .75,
            ),
          ),
          child: surface,
        ),
      );
    }
    return DenialSurfaceGeometry(
      radius: radius.topLeft.x,
      child: Theme(data: theme.materialTheme, child: surface),
    );
  }
}

/// Flat application composition: persistent navigation beside a content area
/// that starts at the window's top edge.
///
/// Unlike [DenialApplicationFrame] there is no reveal gap, no floating sidebar
/// card and no toolbar slot. The navigation supplies its own background and
/// trailing divider, and the page owns its fixed header plus scrolling body.
class DenialFlatApplicationFrame extends StatelessWidget {
  const DenialFlatApplicationFrame({
    required this.navigation,
    required this.content,
    this.navigationWidth = 272,
    super.key,
  });

  final Widget navigation;
  final Widget content;
  final double navigationWidth;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.applicationColors.canvas,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: navigationWidth, child: navigation),
          Expanded(child: content),
        ],
      ),
    );
  }
}

/// Fixed navigation and commands over a scrolling content sheet. The sheet's
/// leading gap reveals Denial; the sheet remains opaque while it scrolls.
class DenialApplicationFrame extends StatelessWidget {
  const DenialApplicationFrame({
    required this.navigation,
    required this.toolbar,
    required this.content,
    this.footer,
    this.compact = false,
    this.navigationWidth = 216,
    this.inset = defaultInset,
    this.separatedCards = false,
    this.horizontalNavigation = false,
    super.key,
  });

  static const double defaultInset = 8;

  final Widget navigation;
  final Widget toolbar;
  final Widget content;
  final Widget? footer;
  final bool compact;
  final double navigationWidth;
  final double inset;

  /// Opt-in compact chrome and glass gutters for opaque, independently grouped
  /// content. The default scrolling-sheet composition remains unchanged.
  final bool separatedCards;

  /// Wizard-style navigation across the revealed upper area, with the same
  /// scrolling sheet and material hierarchy as sidebar applications.
  final bool horizontalNavigation;

  Widget body({required double contentStart, required double leadingExtent}) =>
      LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            Expanded(
              child: _DenialContentLayout(
                contentStart: contentStart,
                leadingExtent: leadingExtent,
                separatedCards: separatedCards,
                child: content,
              ),
            ),
            if (footer != null)
              ColoredBox(
                // Footer padding and its entire width belong to the opaque
                // content surface, including underneath the navigation card.
                color: context.applicationColors.canvas,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(start: contentStart),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight / 2,
                    ),
                    child: SingleChildScrollView(child: footer),
                  ),
                ),
              ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = context.applicationTheme;
    return ColoredBox(
      // The window slider controls this backing, independently of the glass
      // navigation/command panels and the opaque content drawn above it.
      color: theme.background(DenialMaterialRole.window),
      child: separatedCards
          ? Padding(
              padding: EdgeInsets.all(inset),
              child: DenialSurfaceGeometry(
                radius: DenialSurfaceGeometry.nestedRadius(
                  context,
                  inset: inset,
                ),
                child: compact
                    ? Column(
                        children: [
                          navigation,
                          const SizedBox(height: 8),
                          toolbar,
                          const SizedBox(height: 12),
                          Expanded(
                            child: body(contentStart: 0, leadingExtent: 0),
                          ),
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: navigationWidth, child: navigation),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              children: [
                                toolbar,
                                const SizedBox(height: 12),
                                Expanded(
                                  child: body(
                                    contentStart: 0,
                                    leadingExtent: 0,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            )
          : horizontalNavigation
          ? LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  Padding(padding: EdgeInsets.all(inset), child: navigation),
                  toolbar,
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, bodyConstraints) {
                        final chromeHeight =
                            constraints.maxHeight - bodyConstraints.maxHeight;
                        final reveal = (constraints.maxHeight * .42).clamp(
                          180.0,
                          320.0,
                        );
                        return body(
                          contentStart: 0,
                          leadingExtent: (reveal - chromeHeight).clamp(
                            32.0,
                            double.infinity,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            )
          : compact
          ? Column(
              children: [
                Padding(
                  padding: EdgeInsets.all(inset),
                  child: DenialSurfaceGeometry(
                    radius: DenialSurfaceGeometry.nestedRadius(
                      context,
                      inset: inset,
                    ),
                    child: navigation,
                  ),
                ),
                toolbar,
                Expanded(child: body(contentStart: 0, leadingExtent: 24)),
              ],
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final backdropHeight = (constraints.maxHeight * .36).clamp(
                  160.0,
                  280.0,
                );
                final contentStart = navigationWidth + inset;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Column(
                      children: [
                        Padding(
                          padding: EdgeInsetsDirectional.only(
                            start: contentStart,
                          ),
                          child: toolbar,
                        ),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, bodyConstraints) {
                              final toolbarHeight =
                                  constraints.maxHeight -
                                  bodyConstraints.maxHeight;
                              return body(
                                contentStart: contentStart,
                                leadingExtent: (backdropHeight - toolbarHeight)
                                    .clamp(56.0, double.infinity),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    PositionedDirectional(
                      start: inset,
                      top: inset,
                      bottom: inset,
                      width: navigationWidth,
                      child: DenialSurfaceGeometry(
                        radius: DenialSurfaceGeometry.nestedRadius(
                          context,
                          inset: inset,
                        ),
                        child: navigation,
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _DenialContentLayout extends InheritedWidget {
  const _DenialContentLayout({
    required this.contentStart,
    required this.leadingExtent,
    required this.separatedCards,
    required super.child,
  });

  final double contentStart;
  final double leadingExtent;
  final bool separatedCards;

  @override
  bool updateShouldNotify(_DenialContentLayout oldWidget) =>
      contentStart != oldWidget.contentStart ||
      leadingExtent != oldWidget.leadingExtent ||
      separatedCards != oldWidget.separatedCards;
}

/// One viewport owns both the leading backdrop gap and the decorated content
/// slivers. Its opaque background moves with the sheet rather than staying fixed
/// behind an independently scrolling list. Short sheets can also scroll upward.
class DenialContentPane extends StatelessWidget {
  const DenialContentPane({
    required this.sliversBuilder,
    this.cards = false,
    this.leadingOverlap = 0,
    super.key,
  }) : assert(leadingOverlap >= 0);

  /// Only omit the sheet when the caller supplies opaque cards and the frame
  /// explicitly opts into that composition.
  final bool cards;

  /// Raise content into the reveal gap while keeping the sheet edge in place.
  /// The overlap is limited to the available gap and scrolls with the content.
  final double leadingOverlap;

  /// Available width excludes the navigation inset; decoration still spans the
  /// entire frame underneath navigation. The callback returns content slivers.
  final List<Widget> Function(BuildContext context, double width)
  sliversBuilder;

  @override
  Widget build(BuildContext context) {
    final layout = context
        .dependOnInheritedWidgetOfExactType<_DenialContentLayout>();
    final contentStart = layout?.contentStart ?? 0;
    final leadingExtent = layout?.leadingExtent ?? 0;
    final overlap = leadingOverlap.clamp(0.0, leadingExtent);
    final revealExtent = leadingExtent - overlap;
    if (cards && (layout?.separatedCards ?? false)) {
      return LayoutBuilder(
        builder: (context, constraints) => CustomScrollView(
          slivers: sliversBuilder(context, constraints.maxWidth),
        ),
      );
    }
    return DenialSurfaceGeometry(
      radius: 0,
      child: LayoutBuilder(
        builder: (context, constraints) => CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: revealExtent)),
            DecoratedSliver(
              decoration: overlap == 0
                  ? BoxDecoration(color: context.applicationColors.canvas)
                  : _DenialContentSheetDecoration(
                      color: context.applicationColors.canvas,
                      topInset: overlap,
                    ),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverFadeTransition(
                    opacity: DenialContentTransition.opacityOf(context),
                    sliver: SliverPadding(
                      padding: EdgeInsetsDirectional.only(start: contentStart),
                      sliver: SliverMainAxisGroup(
                        slivers: sliversBuilder(
                          context,
                          (constraints.maxWidth - contentStart).clamp(
                            0,
                            double.infinity,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SliverLayoutBuilder(
                    builder: (context, metrics) {
                      // Fill at least a viewport with the sheet itself, excluding
                      // the reveal gap. This keeps short pages scrollable too.
                      final contentExtent =
                          metrics.precedingScrollExtent - revealExtent;
                      final remaining =
                          (metrics.viewportMainAxisExtent +
                                  overlap -
                                  contentExtent)
                              .clamp(0.0, double.infinity);
                      return SliverToBoxAdapter(
                        child: SizedBox(height: remaining),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Leave room above the opaque sheet for content crossing its leading edge.
class _DenialContentSheetDecoration extends Decoration {
  const _DenialContentSheetDecoration({
    required this.color,
    required this.topInset,
  });

  final Color color;
  final double topInset;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _DenialContentSheetPainter(color, topInset);
}

class _DenialContentSheetPainter extends BoxPainter {
  _DenialContentSheetPainter(Color color, this.topInset)
    : _paint = Paint()..color = color;

  final Paint _paint;
  final double topInset;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.height <= topInset) return;
    canvas.drawRect(
      Rect.fromLTWH(
        offset.dx,
        offset.dy + topInset,
        size.width,
        size.height - topInset,
      ),
      _paint,
    );
  }
}
