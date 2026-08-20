import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../models/display_layout.dart';
import '../../state/display_layout.dart';
import '../../theme/motion.dart';
import '../state/wallpaper_controller.dart';
import '../wallpaper.dart';
import 'wallpaper_carousel_physics.dart';
import 'wallpaper_darkness_control.dart';
import 'wallpaper_image.dart';
import 'wallpaper_search_controls.dart';
import 'wallpaper_span_controls.dart';
import 'wallpaper_strip.dart';
import 'wallpaper_target_selector.dart';

class WallpaperSelectorOverlay extends StatelessWidget {
  const WallpaperSelectorOverlay({
    super.key,
    required this.visible,
    required this.displayRect,
    required this.onDismiss,
  });

  final bool visible;
  final Rect displayRect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSwitcher(
        duration: reduceMotion ? Duration.zero : Motion.wallpaperSelector,
        reverseDuration: reduceMotion
            ? Duration.zero
            : Motion.wallpaperSelector,
        switchInCurve: Motion.md3EmphasizedDecelerate,
        switchOutCurve: Motion.md3EmphasizedAccelerate,
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.965, end: 1.0).animate(animation),
              child: child,
            ),
          );
        },
        child: visible
            ? Stack(
                key: const ValueKey<String>('wallpaper-selector-visible'),
                fit: StackFit.expand,
                children: [
                  Positioned.fromRect(
                    rect: displayRect,
                    child: WallpaperSelectorSurface(
                      displaySize: displayRect.size,
                      onDismiss: onDismiss,
                    ),
                  ),
                ],
              )
            : const SizedBox.expand(
                key: ValueKey<String>('wallpaper-selector-hidden'),
              ),
      ),
    );
  }
}

class WallpaperSelectorSurface extends ConsumerStatefulWidget {
  const WallpaperSelectorSurface({
    super.key,
    required this.displaySize,
    required this.onDismiss,
  });

  final Size displaySize;
  final VoidCallback onDismiss;

  @override
  ConsumerState<WallpaperSelectorSurface> createState() =>
      _WallpaperSelectorSurfaceState();
}

class _WallpaperSelectorSurfaceState
    extends ConsumerState<WallpaperSelectorSurface> {
  static const int _selectorImageCacheBytes = 256 * 1024 * 1024;

  late PageController _pageController;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'wallpaper-search');
  late final int _previousImageCacheBytes;
  var _focusedIndex = 0;
  var _adjustingWallpaper = false;

  @override
  void initState() {
    super.initState();
    final imageCache = PaintingBinding.instance.imageCache;
    _previousImageCacheBytes = imageCache.maximumSizeBytes;
    if (_previousImageCacheBytes < _selectorImageCacheBytes) {
      imageCache.maximumSizeBytes = _selectorImageCacheBytes;
    }
    _pageController = _newPageController();
    _searchController.addListener(_handleSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant WallpaperSelectorSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.displaySize.width - widget.displaySize.width).abs() > 1.0) {
      final oldController = _pageController;
      _pageController = _newPageController(
        initialPage: oldController.hasClients
            ? oldController.page?.round() ?? _focusedIndex
            : _focusedIndex,
      );
      oldController.dispose();
    }
  }

  PageController _newPageController({int initialPage = 0}) {
    final stripWidth = (widget.displaySize.width * 0.14).clamp(104.0, 230.0);
    final viewportFraction = widget.displaySize.width <= 0.0
        ? 0.2
        : (stripWidth / widget.displaySize.width).clamp(0.12, 0.28);
    return PageController(
      initialPage: math.max(0, initialPage),
      viewportFraction: viewportFraction,
    );
  }

  void _handleSearchChanged() {
    ref
        .read(wallpaperControllerProvider.notifier)
        .setQuery(_searchController.text);
    setState(() {});
  }

  Future<void> _applyCandidate(
    WallpaperCandidate candidate,
    Offset globalOrigin,
  ) async {
    final wallpaperState = ref.read(wallpaperControllerProvider);
    final target = wallpaperState.target;
    final targetPixelSize = wallpaperState.targetPixelSize;
    final outputs =
        ref.read(displayLayoutProvider)?.outputs ?? const <DisplayOutput>[];
    final revealOriginFraction = _revealOriginFraction(
      globalOrigin,
      target,
      outputs,
    );
    final controller = ref.read(wallpaperControllerProvider.notifier);
    final resource = await controller.resolveCandidate(candidate);
    if (!mounted || resource == null) {
      return;
    }
    final decodeError = context.l10n.wallpaperDecodeError;
    try {
      await precacheImage(
        wallpaperImageProvider(resource, targetPixelSize: targetPixelSize),
        context,
      );
    } on Object {
      if (mounted) {
        controller.reportError(decodeError);
      }
      return;
    }
    if (!mounted || !ref.read(wallpaperControllerProvider).selectorVisible) {
      return;
    }
    controller.commitCandidate(
      candidate,
      resource,
      revealOriginFraction: revealOriginFraction,
      target: target,
    );
  }

  Offset _revealOriginFraction(
    Offset globalOrigin,
    WallpaperTarget target,
    List<DisplayOutput> outputs,
  ) {
    if (target.isAll && outputs.isNotEmpty) {
      var spanRect = outputs.first.logicalRect;
      for (final output in outputs.skip(1)) {
        spanRect = spanRect.expandToInclude(output.logicalRect);
      }
      return _fractionInRect(globalOrigin, spanRect);
    }
    final renderObject = context.findRenderObject();
    final localOrigin = renderObject is RenderBox
        ? renderObject.globalToLocal(globalOrigin)
        : widget.displaySize.center(Offset.zero);
    return _fractionInRect(localOrigin, Offset.zero & widget.displaySize);
  }

  Offset _fractionInRect(Offset origin, Rect rect) {
    return Offset(
      rect.width <= 0
          ? 0.5
          : ((origin.dx - rect.left) / rect.width).clamp(0.0, 1.0).toDouble(),
      rect.height <= 0
          ? 0.5
          : ((origin.dy - rect.top) / rect.height).clamp(0.0, 1.0).toDouble(),
    );
  }

  void _selectTarget(
    WallpaperTarget target,
    List<DisplayOutput> outputs,
    Size? allPixelSize,
  ) {
    final fallbackSize =
        widget.displaySize * MediaQuery.devicePixelRatioOf(context);
    final targetPixelSize = _targetPixelSize(
      target,
      outputs,
      fallbackSize,
      allPixelSize,
    );
    ref
        .read(wallpaperControllerProvider.notifier)
        .selectTarget(target: target, targetPixelSize: targetPixelSize);
  }

  Size _targetPixelSize(
    WallpaperTarget target,
    List<DisplayOutput> outputs,
    Size fallback,
    Size? allPixelSize,
  ) {
    final outputName = target.outputName;
    if (outputName != null) {
      for (final output in outputs) {
        if (output.name == outputName) {
          return output.pixelSize;
        }
      }
      return fallback;
    }
    if (outputs.isEmpty) {
      return fallback;
    }
    if (allPixelSize != null &&
        allPixelSize.width > 0 &&
        allPixelSize.height > 0) {
      return allPixelSize;
    }
    var spanRect = outputs.first.logicalRect;
    var maximumScale = outputs.first.scale;
    for (final output in outputs.skip(1)) {
      spanRect = spanRect.expandToInclude(output.logicalRect);
      maximumScale = math.max(maximumScale, output.scale);
    }
    return spanRect.size * maximumScale;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _beginWallpaperAdjustment() {
    if (_adjustingWallpaper) {
      return;
    }
    setState(() => _adjustingWallpaper = true);
  }

  void _endWallpaperAdjustment() {
    if (!_adjustingWallpaper) {
      return;
    }
    setState(() => _adjustingWallpaper = false);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    _searchFocusNode.dispose();
    _pageController.dispose();
    final imageCache = PaintingBinding.instance.imageCache;
    if (imageCache.maximumSizeBytes == _selectorImageCacheBytes) {
      imageCache.maximumSizeBytes = _previousImageCacheBytes;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(wallpaperControllerProvider);
    final displayLayout = ref.watch(displayLayoutProvider);
    final outputs = displayLayout?.outputs ?? const <DisplayOutput>[];
    final candidates = state.candidates;
    if (_focusedIndex >= candidates.length && candidates.isNotEmpty) {
      _focusedIndex = candidates.length - 1;
    }
    final carouselTop = math.max(36.0, widget.displaySize.height * 0.10);
    final bottomReserve = widget.displaySize.width >= 580 ? 302.0 : 390.0;
    final maximumCarouselHeight = math.max(
      240.0,
      widget.displaySize.height - carouselTop - bottomReserve,
    );
    final carouselHeight = (widget.displaySize.height * 0.64)
        .clamp(240.0, maximumCarouselHeight)
        .toDouble();

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Stack(
        children: [
          Positioned(
            top: 28,
            right: 28,
            child: WallpaperSelectorCloseButton(onPressed: widget.onDismiss),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: carouselTop,
            height: carouselHeight,
            child: IgnorePointer(
              ignoring: _adjustingWallpaper,
              child: RepaintBoundary(
                child: AnimatedOpacity(
                  key: const ValueKey<String>(
                    'desktop-wallpaper-tiles-opacity',
                  ),
                  opacity: _adjustingWallpaper ? 0.0 : 1.0,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : Motion.wallpaperTilesFade,
                  curve: Motion.wallpaperTilesFadeCurve,
                  child: candidates.isEmpty
                      ? WallpaperEmptyState(
                          loading: state.loading,
                          error: state.error,
                        )
                      : PageView.builder(
                          controller: _pageController,
                          physics: const WallpaperCarouselPhysics(),
                          pageSnapping: false,
                          padEnds: true,
                          allowImplicitScrolling: true,
                          itemCount: candidates.length,
                          onPageChanged: (index) {
                            setState(() => _focusedIndex = index);
                          },
                          itemBuilder: (context, index) {
                            final candidate = candidates[index];
                            final focused = index == _focusedIndex;
                            return AnimatedScale(
                              duration: Motion.cardSettle,
                              curve: Motion.md3EmphasizedDecelerate,
                              scale: focused ? 1.0 : 0.91,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                ),
                                child: WallpaperStrip(
                                  candidate: candidate,
                                  current: candidate.resource == state.current,
                                  downloading:
                                      state.downloadingKey == candidate.key,
                                  downloadProgress: state.downloadProgress,
                                  onTapUp: (origin) =>
                                      _applyCandidate(candidate, origin),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 28,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state.error != null) ...[
                      WallpaperStatusChip(
                        icon: Icons.cloud_off_rounded,
                        label: l10n.wallpaperServiceUnavailable,
                      ),
                      const SizedBox(height: 10),
                    ] else if (state.loading) ...[
                      WallpaperStatusChip(
                        icon: Icons.travel_explore_rounded,
                        label: l10n.wallpaperFinding,
                      ),
                      const SizedBox(height: 10),
                    ],
                    WallpaperTargetSelector(
                      outputs: outputs,
                      selected: state.target,
                      onSelected: (target) => _selectTarget(
                        target,
                        outputs,
                        displayLayout?.pixelSize,
                      ),
                    ),
                    const SizedBox(height: 10),
                    WallpaperDarknessControl(
                      value: state.assignment.darknessForTarget(state.target),
                      onChangeStart: _beginWallpaperAdjustment,
                      onChanged: ref
                          .read(wallpaperControllerProvider.notifier)
                          .setDarkness,
                      onChangeEnd: (value) {
                        ref
                            .read(wallpaperControllerProvider.notifier)
                            .commitDarkness(value);
                        _endWallpaperAdjustment();
                      },
                    ),
                    const SizedBox(height: 10),
                    WallpaperSpanAlignmentSelector(
                      value: state.assignment.alignmentForTarget(state.target),
                      onChangeStart: _beginWallpaperAdjustment,
                      onChanged: ref
                          .read(wallpaperControllerProvider.notifier)
                          .previewSpanAlignment,
                      onChangeEnd: (value) {
                        ref
                            .read(wallpaperControllerProvider.notifier)
                            .commitSpanAlignment(value);
                        _endWallpaperAdjustment();
                      },
                    ),
                    const SizedBox(height: 10),
                    WallpaperSearchField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      onClear: () {
                        _searchController.clear();
                        _searchFocusNode.requestFocus();
                      },
                      onSubmit: ref
                          .read(wallpaperControllerProvider.notifier)
                          .submitQuery,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
