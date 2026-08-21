import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../models/display_layout.dart';
import '../../state/display_layout.dart';
import '../../state/shell_controller.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';
import '../state/wallpaper_controller.dart';
import '../wallpaper.dart';
import 'wallpaper_darkness_control.dart';
import 'wallpaper_image.dart';
import 'wallpaper_search_controls.dart';
import 'wallpaper_span_controls.dart';
import 'wallpaper_target_selector.dart';

enum _MobileWallpaperMode { browse, position, preview }

/// A portrait-first wallpaper workflow owned exclusively by the mobile shell.
///
/// The desktop selector deliberately remains a separate surface. Mobile uses
/// a thumbnail rail instead of desktop's tall carousel, edits continuous
/// `BoxFit.cover` alignment against the live wallpaper, and can remove every
/// piece of chrome for an unobstructed preview.
class MobileWallpaperSelectorSurface extends ConsumerStatefulWidget {
  const MobileWallpaperSelectorSurface({
    super.key,
    required this.displaySize,
    required this.onDismiss,
  });

  final Size displaySize;
  final VoidCallback onDismiss;

  @override
  ConsumerState<MobileWallpaperSelectorSurface> createState() =>
      _MobileWallpaperSelectorSurfaceState();
}

class _MobileWallpaperSelectorSurfaceState
    extends ConsumerState<MobileWallpaperSelectorSurface> {
  static const int _selectorImageCacheBytes = 256 * 1024 * 1024;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'mobile-wallpaper-search',
  );
  late final int _previousImageCacheBytes;
  _MobileWallpaperMode _mode = _MobileWallpaperMode.browse;
  _MobileWallpaperMode _modeBeforePreview = _MobileWallpaperMode.browse;

  @override
  void initState() {
    super.initState();
    final imageCache = PaintingBinding.instance.imageCache;
    _previousImageCacheBytes = imageCache.maximumSizeBytes;
    if (_previousImageCacheBytes < _selectorImageCacheBytes) {
      imageCache.maximumSizeBytes = _selectorImageCacheBytes;
    }
    _searchController.addListener(_handleSearchChanged);
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
      revealOriginFraction: Offset(
        widget.displaySize.width <= 0
            ? 0.5
            : (globalOrigin.dx / widget.displaySize.width)
                  .clamp(0.0, 1.0)
                  .toDouble(),
        widget.displaySize.height <= 0
            ? 0.5
            : (globalOrigin.dy / widget.displaySize.height)
                  .clamp(0.0, 1.0)
                  .toDouble(),
      ),
      target: target,
    );
  }

  void _selectTarget(
    WallpaperTarget target,
    List<DisplayOutput> outputs,
    Size? allPixelSize,
  ) {
    var targetPixelSize =
        allPixelSize ??
        widget.displaySize * MediaQuery.devicePixelRatioOf(context);
    final outputName = target.outputName;
    if (outputName != null) {
      for (final output in outputs) {
        if (output.name == outputName) {
          targetPixelSize = output.pixelSize;
          break;
        }
      }
    }
    ref
        .read(wallpaperControllerProvider.notifier)
        .selectTarget(target: target, targetPixelSize: targetPixelSize);
  }

  void _enterPositionMode() {
    _searchFocusNode.unfocus();
    setState(() => _mode = _MobileWallpaperMode.position);
  }

  void _enterPreviewMode() {
    _searchFocusNode.unfocus();
    ref.read(shellControllerProvider.notifier).closeEdgePanel();
    setState(() {
      _modeBeforePreview = _mode;
      _mode = _MobileWallpaperMode.preview;
    });
  }

  void _leavePreviewMode() {
    setState(() => _mode = _modeBeforePreview);
  }

  void _leavePositionMode() {
    setState(() => _mode = _MobileWallpaperMode.browse);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    switch (_mode) {
      case _MobileWallpaperMode.preview:
        _leavePreviewMode();
      case _MobileWallpaperMode.position:
        _leavePositionMode();
      case _MobileWallpaperMode.browse:
        widget.onDismiss();
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    _searchFocusNode.dispose();
    final imageCache = PaintingBinding.instance.imageCache;
    if (imageCache.maximumSizeBytes == _selectorImageCacheBytes) {
      imageCache.maximumSizeBytes = _previousImageCacheBytes;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wallpaperControllerProvider);
    final displayLayout = ref.watch(displayLayoutProvider);
    final outputs = displayLayout?.outputs ?? const <DisplayOutput>[];
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: switch (_mode) {
        _MobileWallpaperMode.preview => _PreviewOnlySurface(
          onRestore: _leavePreviewMode,
        ),
        _MobileWallpaperMode.position => _PositionSurface(
          displaySize: widget.displaySize,
          state: state,
          onBack: _leavePositionMode,
          onPreview: _enterPreviewMode,
        ),
        _MobileWallpaperMode.browse => _BrowseSurface(
          state: state,
          outputs: outputs,
          searchController: _searchController,
          searchFocusNode: _searchFocusNode,
          onDismiss: widget.onDismiss,
          onPreview: _enterPreviewMode,
          onPosition: _enterPositionMode,
          onCandidate: _applyCandidate,
          onTarget: (target) =>
              _selectTarget(target, outputs, displayLayout?.pixelSize),
        ),
      },
    );
  }
}

class _PreviewOnlySurface extends StatelessWidget {
  const _PreviewOnlySurface({required this.onRestore});

  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.l10n.wallpaperMobileShowControls,
      child: GestureDetector(
        key: const ValueKey<String>('mobile-wallpaper-preview-only'),
        behavior: HitTestBehavior.opaque,
        onTap: onRestore,
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _BrowseSurface extends ConsumerWidget {
  const _BrowseSurface({
    required this.state,
    required this.outputs,
    required this.searchController,
    required this.searchFocusNode,
    required this.onDismiss,
    required this.onPreview,
    required this.onPosition,
    required this.onCandidate,
    required this.onTarget,
  });

  final WallpaperExperienceState state;
  final List<DisplayOutput> outputs;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final VoidCallback onDismiss;
  final VoidCallback onPreview;
  final VoidCallback onPosition;
  final void Function(WallpaperCandidate, Offset) onCandidate;
  final ValueChanged<WallpaperTarget> onTarget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final controller = ref.read(wallpaperControllerProvider.notifier);
    return Stack(
      fit: StackFit.expand,
      children: [
        _MobileWallpaperTopBar(
          title: l10n.wallpaperMobileTitle,
          leadingIcon: Icons.close_rounded,
          leadingLabel: l10n.wallpaperCloseSelector,
          onLeading: onDismiss,
          onPreview: onPreview,
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: _MobileWallpaperPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.wallpaperMobileChoose, style: ShellText.cardTitle),
                const SizedBox(height: 10),
                WallpaperSearchField(
                  controller: searchController,
                  focusNode: searchFocusNode,
                  onClear: () {
                    searchController.clear();
                    searchFocusNode.requestFocus();
                  },
                  onSubmit: controller.submitQuery,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 128,
                  child: state.candidates.isEmpty
                      ? WallpaperEmptyState(
                          loading: state.loading,
                          error: state.error,
                        )
                      : ListView.separated(
                          key: const ValueKey<String>(
                            'mobile-wallpaper-candidates',
                          ),
                          scrollDirection: Axis.horizontal,
                          itemCount: state.candidates.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final candidate = state.candidates[index];
                            return _MobileWallpaperCandidateCard(
                              candidate: candidate,
                              current: candidate.resource == state.current,
                              downloading:
                                  state.downloadingKey == candidate.key,
                              downloadProgress: state.downloadProgress,
                              onTapUp: (origin) =>
                                  onCandidate(candidate, origin),
                            );
                          },
                        ),
                ),
                if (outputs.length > 1) ...[
                  const SizedBox(height: 12),
                  WallpaperTargetSelector(
                    outputs: outputs,
                    selected: state.target,
                    onSelected: onTarget,
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _MobileWallpaperActionButton(
                        icon: Icons.open_with_rounded,
                        label: l10n.wallpaperMobilePosition,
                        onPressed: onPosition,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                WallpaperDarknessControl(
                  value: state.assignment.darknessForTarget(state.target),
                  onChanged: controller.setDarkness,
                  onChangeEnd: controller.commitDarkness,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PositionSurface extends ConsumerStatefulWidget {
  const _PositionSurface({
    required this.displaySize,
    required this.state,
    required this.onBack,
    required this.onPreview,
  });

  final Size displaySize;
  final WallpaperExperienceState state;
  final VoidCallback onBack;
  final VoidCallback onPreview;

  @override
  ConsumerState<_PositionSurface> createState() => _PositionSurfaceState();
}

class _PositionSurfaceState extends ConsumerState<_PositionSurface> {
  WallpaperSpanAlignment get _alignment {
    final state = ref.read(wallpaperControllerProvider);
    return state.assignment.alignmentForTarget(state.target);
  }

  WallpaperController get _controller =>
      ref.read(wallpaperControllerProvider.notifier);

  void _preview({double? x, double? y}) {
    final current = _alignment;
    _controller.previewSpanAlignment(
      WallpaperSpanAlignment.precise(
        x: (x ?? current.x).clamp(-1.0, 1.0).toDouble(),
        y: (y ?? current.y).clamp(-1.0, 1.0).toDouble(),
      ),
    );
  }

  void _commit({double? x, double? y}) {
    final current = _alignment;
    _controller.commitSpanAlignment(
      WallpaperSpanAlignment.precise(
        x: (x ?? current.x).clamp(-1.0, 1.0).toDouble(),
        y: (y ?? current.y).clamp(-1.0, 1.0).toDouble(),
      ),
    );
  }

  void _drag(DragUpdateDetails details) {
    final delta = _alignmentDelta(details.delta);
    _preview(x: _alignment.x + delta.dx, y: _alignment.y + delta.dy);
  }

  Offset _alignmentDelta(Offset dragDelta) {
    final candidate = _candidateForCurrentResource();
    final sourceWidth = candidate?.width.toDouble() ?? 0.0;
    final sourceHeight = candidate?.height.toDouble() ?? 0.0;
    final target = widget.displaySize;
    if (sourceWidth <= 0 ||
        sourceHeight <= 0 ||
        target.width <= 0 ||
        target.height <= 0) {
      return Offset(
        target.width <= 0 ? 0 : -2.0 * dragDelta.dx / target.width,
        target.height <= 0 ? 0 : -2.0 * dragDelta.dy / target.height,
      );
    }
    final scale = math.max(
      target.width / sourceWidth,
      target.height / sourceHeight,
    );
    final overflowX = sourceWidth * scale - target.width;
    final overflowY = sourceHeight * scale - target.height;
    return Offset(
      overflowX <= 0.5 ? 0.0 : -2.0 * dragDelta.dx / overflowX,
      overflowY <= 0.5 ? 0.0 : -2.0 * dragDelta.dy / overflowY,
    );
  }

  WallpaperCandidate? _candidateForCurrentResource() {
    for (final candidate in widget.state.candidates) {
      if (candidate.resource == widget.state.current) {
        return candidate;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final alignment = widget.state.assignment.alignmentForTarget(
      widget.state.target,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          key: const ValueKey<String>('mobile-wallpaper-position-gesture'),
          behavior: HitTestBehavior.opaque,
          onPanUpdate: _drag,
          onPanEnd: (_) => _commit(),
          onPanCancel: () => _commit(),
          child: const SizedBox.expand(),
        ),
        _MobileWallpaperTopBar(
          title: l10n.wallpaperMobilePosition,
          leadingIcon: Icons.arrow_back_rounded,
          leadingLabel: l10n.wallpaperMobileBackToSelection,
          onLeading: widget.onBack,
          onPreview: widget.onPreview,
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: _MobileWallpaperPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.wallpaperMobilePositionHint,
                  textAlign: TextAlign.center,
                  style: ShellText.cardTitle.copyWith(
                    color: ShellColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 14),
                WallpaperAlignmentSlider(
                  label: l10n.wallpaperMobileHorizontalPosition,
                  icon: Icons.align_horizontal_center_rounded,
                  value: alignment.x,
                  onChanged: (value) => _preview(x: value),
                  onChangeEnd: (value) => _commit(x: value),
                ),
                const SizedBox(height: 10),
                WallpaperAlignmentSlider(
                  label: l10n.wallpaperMobileVerticalPosition,
                  icon: Icons.align_vertical_center_rounded,
                  value: alignment.y,
                  onChanged: (value) => _preview(y: value),
                  onChangeEnd: (value) => _commit(y: value),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _MobileWallpaperActionButton(
                        icon: Icons.center_focus_strong_rounded,
                        label: l10n.wallpaperMobileCenterPosition,
                        onPressed: () {
                          const centered = WallpaperSpanAlignment();
                          _controller.commitSpanAlignment(centered);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MobileWallpaperActionButton(
                        icon: Icons.check_rounded,
                        label: l10n.wallpaperMobileDone,
                        primary: true,
                        onPressed: widget.onBack,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileWallpaperTopBar extends StatelessWidget {
  const _MobileWallpaperTopBar({
    required this.title,
    required this.leadingIcon,
    required this.leadingLabel,
    required this.onLeading,
    required this.onPreview,
  });

  final String title;
  final IconData leadingIcon;
  final String leadingLabel;
  final VoidCallback onLeading;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final top = math.max(MediaQuery.paddingOf(context).top, 18.0);
    return Positioned(
      top: top,
      left: 18,
      right: 18,
      child: Row(
        children: [
          _MobileWallpaperRoundButton(
            icon: leadingIcon,
            semanticsLabel: leadingLabel,
            onPressed: onLeading,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ShellColors.panelBackground,
                borderRadius: BorderRadius.circular(ShellRadii.chip),
                border: Border.all(color: ShellColors.hairline),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: ShellColors.shadowSoft,
                    blurRadius: 18,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShellText.cardTitle.copyWith(fontSize: 16),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          _MobileWallpaperRoundButton(
            icon: Icons.visibility_off_rounded,
            semanticsLabel: context.l10n.wallpaperMobileHideControls,
            onPressed: onPreview,
          ),
        ],
      ),
    );
  }
}

class _MobileWallpaperPanel extends StatelessWidget {
  const _MobileWallpaperPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottom = math.max(MediaQuery.paddingOf(context).bottom, 16.0);
    final theme = ShellTheme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 14, 14, bottom),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.panelColor(ShellColors.panelBackgroundBottom),
            borderRadius: BorderRadius.circular(theme.panelRadius),
            border: Border.all(color: ShellColors.hairline),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: ShellColors.shadow,
                blurRadius: 30,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }
}

class _MobileWallpaperCandidateCard extends StatelessWidget {
  const _MobileWallpaperCandidateCard({
    required this.candidate,
    required this.current,
    required this.downloading,
    required this.downloadProgress,
    required this.onTapUp,
  });

  final WallpaperCandidate candidate;
  final bool current;
  final bool downloading;
  final double downloadProgress;
  final ValueChanged<Offset> onTapUp;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final image = wallpaperCandidateImageProvider(
      candidate,
      cacheHeight: (128 * MediaQuery.devicePixelRatioOf(context)).ceil(),
    );
    final label = candidate.id == 'default'
        ? context.l10n.wallpaperDefault
        : candidate.width > 0 && candidate.height > 0
        ? context.l10n.wallpaperDimensions(candidate.width, candidate.height)
        : candidate.label;
    return Semantics(
      excludeSemantics: true,
      button: true,
      selected: current,
      label: context.l10n.wallpaperApplyCandidate(label),
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => onTapUp(details.globalPosition),
          child: SizedBox(
            width: 174,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ShellColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: current ? accent.primary : ShellColors.hairline,
                  width: current ? 3 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(current ? 14 : 17),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (image != null)
                      Image(
                        image: image,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.medium,
                        gaplessPlayback: true,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => const ColoredBox(
                          color: ShellColors.surfaceContainerHigh,
                          child: Icon(
                            Icons.broken_image_rounded,
                            color: ShellColors.textTertiary,
                          ),
                        ),
                      )
                    else
                      const ColoredBox(
                        color: ShellColors.surfaceContainerHigh,
                        child: Icon(
                          Icons.image_rounded,
                          color: ShellColors.textTertiary,
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ColoredBox(
                        color: const Color(0xc8000000),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ShellText.cardTitle.copyWith(fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                    if (downloading)
                      ColoredBox(
                        color: ShellColors.overviewScrim,
                        child: Center(
                          child: SizedBox.square(
                            dimension: 38,
                            child: CircularProgressIndicator(
                              value: downloadProgress > 0
                                  ? downloadProgress
                                  : null,
                              color: accent.primary,
                              strokeWidth: 4,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileWallpaperActionButton extends StatelessWidget {
  const _MobileWallpaperActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    return Semantics(
      excludeSemantics: true,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: primary
                ? accent.container
                : ShellColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(ShellRadii.chip),
            border: Border.all(
              color: primary ? accent.primary : ShellColors.hairline,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: primary ? accent.onContainer : ShellColors.textPrimary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.cardTitle.copyWith(
                      color: primary
                          ? accent.onContainer
                          : ShellColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileWallpaperRoundButton extends StatelessWidget {
  const _MobileWallpaperRoundButton({
    required this.icon,
    required this.semanticsLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String semanticsLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      excludeSemantics: true,
      button: true,
      label: semanticsLabel,
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: ShellColors.panelBackground,
              shape: BoxShape.circle,
              border: Border.all(color: ShellColors.hairline),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: ShellColors.shadowSoft,
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: SizedBox.square(
              dimension: 48,
              child: Icon(icon, size: 24, color: ShellColors.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}
