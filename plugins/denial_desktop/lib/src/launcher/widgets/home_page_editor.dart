import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../home_grid_geometry.dart';
import 'home_grid_page.dart';

/// Home's pages as cards, opened by a long press on home's background: a
/// tap goes to a page, the round button over a card removes it, the last
/// card adds one. Below them, the drawer and the shared bottom row.
class HomePageEditor extends StatelessWidget {
  const HomePageEditor({
    super.key,
    required this.slots,
    required this.geometry,
    required this.pageCount,
    required this.page,
    required this.drawer,
    required this.sharedBottomRow,
    required this.onOpenPage,
    required this.onAddPage,
    required this.onRemovePage,
    required this.onDrawer,
    required this.onSharedBottomRow,
    required this.onDone,
  });

  final List<HomeGridItem?> slots;
  final HomeGridGeometry geometry;
  final int pageCount;
  final int page;
  final bool drawer;
  final bool sharedBottomRow;
  final ValueChanged<int> onOpenPage;
  final VoidCallback onAddPage;
  final ValueChanged<int> onRemovePage;
  final ValueChanged<bool> onDrawer;
  final ValueChanged<bool> onSharedBottomRow;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.viewPaddingOf(context);
    final l10n = context.l10n;
    // Cards keep the grid's shape at about half the screen's height.
    final cardHeight = math.min(size.height * 0.46, 620.0);
    final cardWidth = cardHeight * geometry.width / geometry.height;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDone,
      child: ColoredBox(
        color: ShellMediaColors.darkness.withValues(alpha: 0.38),
        child: Padding(
          padding: EdgeInsets.only(top: padding.top + 56, bottom: 28),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SizedBox(
                    height: cardHeight + _HomePageCard.removeOverhang,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      children: [
                        for (var index = 0; index < pageCount; index++) ...[
                          _HomePageCard(
                            key: ValueKey('home-page-$index'),
                            size: Size(cardWidth, cardHeight),
                            current: index == page,
                            onTap: () => onOpenPage(index),
                            onRemove: pageCount > 1
                                ? () => onRemovePage(index)
                                : null,
                            child: _PageThumbnail(
                              slots: slots,
                              geometry: geometry,
                              page: index,
                            ),
                          ),
                          const SizedBox(width: 24),
                        ],
                        _HomePageCard(
                          size: Size(cardWidth, cardHeight),
                          onTap: onAddPage,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.add_rounded,
                                  size: 48,
                                  color: ShellMediaColors.lightForeground,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  l10n.homeEditorAddPage,
                                  style: ShellText.cardTitle.copyWith(
                                    color: ShellMediaColors.lightForeground,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _HomeEditorSettings(
                drawer: drawer,
                sharedBottomRow: sharedBottomRow,
                onDrawer: onDrawer,
                onSharedBottomRow: onSharedBottomRow,
                onDone: onDone,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A page as home shows it, a shared bottom row included.
class _PageThumbnail extends StatelessWidget {
  const _PageThumbnail({
    required this.slots,
    required this.geometry,
    required this.page,
  });

  final List<HomeGridItem?> slots;
  final HomeGridGeometry geometry;
  final int page;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: FittedBox(
        child: SizedBox(
          width: geometry.width,
          height: geometry.height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              HomeGridPage(slots: slots, page: page, geometry: geometry),
              if (geometry.sharedBottomRow)
                HomeGridPage(
                  slots: slots,
                  page: 0,
                  geometry: geometry,
                  bottomRow: true,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomePageCard extends StatelessWidget {
  const _HomePageCard({
    super.key,
    required this.size,
    required this.onTap,
    required this.child,
    this.current = false,
    this.onRemove,
  });

  /// Room above a card for its remove button.
  static const double removeOverhang = 22;
  static const double _removeSize = 44;

  final Size size;
  final bool current;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final radius = context.shellTheme.borderRadius(28);
    final onRemove = this.onRemove;
    return SizedBox(
      width: size.width,
      height: size.height + removeOverhang,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: removeOverhang,
            height: size.height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: ShellMediaColors.lightForeground.withValues(
                    alpha: 0.08,
                  ),
                  borderRadius: radius,
                  border: Border.all(
                    color: current
                        ? accent.primary
                        : ShellMediaColors.lightForeground.withValues(
                            alpha: 0.32,
                          ),
                    width: current ? 2.5 : 1.5,
                  ),
                ),
                child: Padding(padding: const EdgeInsets.all(14), child: child),
              ),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: removeOverhang - _removeSize / 2,
              left: (size.width - _removeSize) / 2,
              child: Semantics(
                button: true,
                label: context.l10n.homeEditorRemovePage,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onRemove,
                  child: Container(
                    width: _removeSize,
                    height: _removeSize,
                    decoration: BoxDecoration(
                      color: context.shellColors.surfaceContainerHighest,
                      shape: BoxShape.circle,
                      border: Border.all(color: context.shellColors.hairline),
                    ),
                    child: Icon(
                      Icons.remove_rounded,
                      size: 24,
                      color: context.shellColors.panelText,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The drawer and bottom row switches, and Done, on one glass island.
class _HomeEditorSettings extends StatelessWidget {
  const _HomeEditorSettings({
    required this.drawer,
    required this.sharedBottomRow,
    required this.onDrawer,
    required this.onSharedBottomRow,
    required this.onDone,
  });

  final bool drawer;
  final bool sharedBottomRow;
  final ValueChanged<bool> onDrawer;
  final ValueChanged<bool> onSharedBottomRow;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final l10n = context.l10n;
    final radius = BorderRadius.circular(32);
    return GestureDetector(
      // Taps on the island stay on it.
      onTap: () {},
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ShellBackdropBlur(
            separateChild: true,
            blur: theme.effectivePanelOpacity < 1.0,
            borderRadius: radius,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.panelColor(context.shellColors.panelBackground),
                borderRadius: radius,
                border: Border.all(color: context.shellColors.hairline),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _HomeEditorSwitch(
                      icon: Icons.apps_rounded,
                      label: l10n.homeEditorDrawer,
                      detail: l10n.homeEditorDrawerDetail,
                      value: drawer,
                      onChanged: onDrawer,
                    ),
                    _HomeEditorSwitch(
                      icon: Icons.dock_rounded,
                      label: l10n.homeEditorSharedRow,
                      detail: l10n.homeEditorSharedRowDetail,
                      value: sharedBottomRow,
                      onChanged: onSharedBottomRow,
                    ),
                    const SizedBox(height: 10),
                    Semantics(
                      button: true,
                      label: l10n.homeEditorDone,
                      excludeSemantics: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onDone,
                        child: Container(
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: accent.primary,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Text(
                            l10n.homeEditorDone,
                            style: ShellText.cardTitle.copyWith(
                              color: accent.onPrimary,
                            ),
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

class _HomeEditorSwitch extends StatelessWidget {
  const _HomeEditorSwitch({
    required this.icon,
    required this.label,
    required this.detail,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String detail;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final colors = context.shellColors;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.tile;
    return Semantics(
      toggled: value,
      label: label,
      hint: detail,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: value ? accent.container : colors.chip,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: 40,
                  child: Icon(
                    icon,
                    size: 21,
                    color: value ? accent.onContainer : colors.panelText,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: ShellText.cardTitle.copyWith(
                        color: colors.panelText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: ShellText.base.copyWith(
                        color: colors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              AnimatedContainer(
                duration: duration,
                curve: Motion.md3EmphasizedDecelerate,
                width: 52,
                height: 32,
                padding: const EdgeInsets.all(4),
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: value ? accent.primary : colors.chip,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: value ? accent.primary : colors.hairline,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: value ? accent.onPrimary : colors.panelText,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 22),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
