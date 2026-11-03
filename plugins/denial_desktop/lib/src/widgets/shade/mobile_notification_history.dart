import 'package:denial_desktop/src/state/notification_groups.dart';
import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart'
    show WindowBackdropCache, WindowBackdropMotion;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;

import '../notification_banner.dart';
import '../notification_rows.dart';
import '../mobile_ui_metrics.dart';
import 'notification_shade_list.dart';
import 'shade_backdrop_scene.dart';
import 'shade_dismiss_gesture.dart';

/// A separate scrollable notification stack for the notification page.
/// Only a completed close rearms the staggered entrance, never a drag reversal.
class MobileNotificationHistory extends ConsumerStatefulWidget {
  const MobileNotificationHistory({
    required this.progress,
    required this.closed,
    this.active = true,
    super.key,
  });

  final Animation<double> progress;

  /// The shell is in its closed state (neither open nor actively dragging).
  /// The animation must also reach zero before the next entrance is armed.
  final bool closed;
  final bool active;

  @override
  ConsumerState<MobileNotificationHistory> createState() =>
      _MobileNotificationHistoryState();
}

class _MobileNotificationHistoryState
    extends ConsumerState<MobileNotificationHistory>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  final ScrollController _scroll = ScrollController();
  final _rowMotion = _RowMotion();
  Animation<double>? _motionProgress;
  Listenable? _motion;
  bool _armed = true;
  bool _reducedMotion = false;
  bool _acknowledgeScheduled = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration:
          Motion.notificationHistorySlide +
          Motion.notificationHistoryStagger *
              Motion.notificationHistoryMaxStagger,
    );
    widget.progress.addListener(_observeProgress);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion) _entrance.value = 1;
    _observeProgress();
  }

  @override
  void didUpdateWidget(covariant MobileNotificationHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_observeProgress);
      widget.progress.addListener(_observeProgress);
    }
    _observeProgress();
  }

  void _observeProgress() {
    if (widget.closed && widget.progress.value <= 0) _armed = true;
    if (_armed && widget.progress.value > 0) {
      _armed = false;
      if (_reducedMotion) {
        _entrance.value = 1;
      } else {
        _entrance.forward(from: 0);
      }
    }
    _scheduleAcknowledgement();
  }

  void _scheduleAcknowledgement() {
    if (_acknowledgeScheduled || !widget.active || widget.progress.value <= 0) {
      return;
    }
    _acknowledgeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _acknowledgeScheduled = false;
      if (!mounted ||
          !widget.active ||
          widget.progress.value <= 0 ||
          ref.read(referenceShellProvider).lockLayerVisible) {
        return;
      }
      final state = ref.read(desktopNotificationsProvider);
      final controller = ref.read(desktopNotificationsProvider.notifier);
      // A notification already shown in the drawer must not pop up again
      // when the drawer closes. Its history and active actions remain intact.
      for (final id in state.bannerQueue) {
        controller.hideBanner(id);
      }
      if (widget.progress.value >= 1) controller.markAllRead();
    });
  }

  /// Everything that moves a card on screen without repainting it, for the
  /// cached glass slices: the shade, the entrance, scrolling, and row layout
  /// or dismissal. The same merge while the shade progress is unchanged.
  Listenable _motionFor(Animation<double> progress) {
    if (!identical(progress, _motionProgress)) {
      _motionProgress = progress;
      _motion = Listenable.merge([progress, _entrance, _scroll, _rowMotion]);
    }
    return _motion!;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(desktopNotificationsProvider);
    final cachedGlass =
        context.shellTheme.effectivePanelOpacity < 1 &&
        WindowBackdropCache.maybeOf(context) != null;
    final controller = ref.read(desktopNotificationsProvider.notifier);
    final locked = ref.watch(
      referenceShellProvider.select((state) => state.lockLayerVisible),
    );
    final preview = locked ? state.lockPreview : NotificationPreviewMode.full;
    final groups = preview == NotificationPreviewMode.hidden
        ? const <DesktopNotificationGroup>[]
        : state.groups;
    // Locked, groups stay folded and history only shows.
    final rows = notificationHistoryRows(
      groups,
      locked ? const <String>{} : ref.watch(expandedNotificationGroupsProvider),
    );
    final indices = <Object, int>{
      for (var i = 0; i < rows.length; i++) rows[i].key: i,
    };
    _scheduleAcknowledgement();
    // Clamping physics only installs a scroll drag recognizer when content
    // actually overflows. Otherwise the parent moves the shade with the finger.
    return ShadeDismissGesture(
      progress: widget.progress,
      canDrag: () =>
          _scroll.hasClients &&
          _scroll.position.hasContentDimensions &&
          _scroll.position.maxScrollExtent <= _scroll.position.minScrollExtent,
      child: WindowBackdropMotion(
        motion: _motionFor(widget.progress),
        child: CustomScrollView(
          key: const PageStorageKey('mobile-notification-history'),
          controller: _scroll,
          physics: const _HistoryScrollPhysics(),
          primary: false,
          clipBehavior: Clip.none,
          slivers: [
            NotificationShadeList(
              progress: widget.progress,
              entrance: _entrance,
              opaqueRows: cachedGlass,
              onRowsMoved: _rowMotion.moved,
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index == rows.length) {
                    final padding = MediaQuery.viewPaddingOf(context);
                    final metrics = MobileUiMetrics.of(context);
                    return _ColorOsNotificationReveal(
                      reveal: _revealOf(index),
                      index: index,
                      cachedGlass: cachedGlass,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          padding.left +
                              metrics.visual(
                                MobileNotificationCard.horizontalMargin,
                              ),
                          0,
                          padding.right +
                              metrics.visual(
                                MobileNotificationCard.horizontalMargin,
                              ),
                          metrics.visual(MobileNotificationMetrics.rowSpacing),
                        ),
                        child: Builder(
                          builder: (context) => NotificationReveal.revealed(
                            context,
                            const Align(
                              alignment: Alignment.centerRight,
                              child: ClearNotificationHistoryButton(),
                            ),
                          ),
                        ),
                      ),
                    );
                  }
                  final row = rows[index];
                  final key = ValueKey<Object>(row.key);
                  return _ColorOsNotificationReveal(
                    reveal: _revealOf(index),
                    index: index,
                    cachedGlass: cachedGlass,
                    child: switch (row) {
                      NotificationGroupHeaderRow(:final group) =>
                        _HistoryGroupHeader(
                          key: key,
                          group: group,
                          onCollapse: () => ref
                              .read(expandedNotificationGroupsProvider.notifier)
                              .collapse(group.key),
                        ),
                      NotificationGroupRow(:final group) =>
                        _HistoryNotification(
                          key: key,
                          record: group.newest,
                          group: group,
                          preview: preview,
                          interactive: !locked,
                          onDismiss: () =>
                              controller.dismissGroupFromHistory(group.key),
                          onExpand: () => ref
                              .read(expandedNotificationGroupsProvider.notifier)
                              .expand(group.key),
                        ),
                      NotificationRow(:final record) => _HistoryNotification(
                        key: key,
                        record: record,
                        preview: preview,
                        interactive: !locked,
                        onDismiss: () => controller.dismissFromHistory(
                          record.notification.id,
                        ),
                        onOpen: () {
                          if (openNotification(ref, record.notification.id)) {
                            ref
                                .read(referenceShellProvider.notifier)
                                .closeQuickSettings();
                          }
                        },
                        onAction: (key) => controller.invokeAction(
                          record.notification.id,
                          key,
                        ),
                      ),
                    },
                  );
                },
                childCount: rows.length + (rows.isNotEmpty && !locked ? 1 : 0),
                findChildIndexCallback: (key) =>
                    key is ValueKey && indices.containsKey(key.value)
                    ? indices[key.value]
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Rows past the last stagger share one reveal.
  Animation<double> _revealOf(int index) {
    final stagger = index.clamp(0, Motion.notificationHistoryMaxStagger);
    return _reveals[stagger] ??= _entrance.drive(
      Animatable.fromCallback(
        (entrance) => _ColorOsNotificationReveal.revealAt(entrance, stagger),
      ),
    );
  }

  final _reveals = <int, Animation<double>>{};

  @override
  void dispose() {
    widget.progress.removeListener(_observeProgress);
    _entrance.dispose();
    _scroll.dispose();
    _rowMotion.dispose();
    super.dispose();
  }
}

class _RowMotion extends ChangeNotifier {
  void moved() => notifyListeners();
}

/// Separate notification rows reveal with alpha, scale, and negative vertical
/// spacing. This mirrors ColorOS' NotificationPanelSeparateAnimation instead
/// of treating the notification center as a horizontally sliding drawer.
class _ColorOsNotificationReveal extends StatelessWidget {
  const _ColorOsNotificationReveal({
    required this.reveal,
    required this.index,
    required this.cachedGlass,
    required this.child,
  });

  /// The row's eased reveal: [revealAt] its stagger.
  final Animation<double> reveal;
  final int index;

  /// Over cached glass the row fades through [NotificationReveal], without
  /// an opacity layer, and its text scales as an image.
  final bool cachedGlass;
  final Widget child;

  /// The row's eased reveal at [entrance], after its stagger.
  static double revealAt(double entrance, int index) {
    final staggerIndex = index.clamp(0, Motion.notificationHistoryMaxStagger);
    final duration = Motion.notificationHistorySlide.inMilliseconds;
    final stagger = Motion.notificationHistoryStagger.inMilliseconds;
    final total = duration + stagger * Motion.notificationHistoryMaxStagger;
    final phase = ((entrance * total - staggerIndex * stagger) / duration)
        .clamp(0.0, 1.0)
        .toDouble();
    return Curves.easeOutCubic.transform(phase);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: reveal,
      child: cachedGlass
          ? NotificationReveal(reveal: reveal, child: child)
          : child,
      builder: (context, child) {
        final staggerIndex = index.clamp(
          0,
          Motion.notificationHistoryMaxStagger,
        );
        final value = reveal.value;
        final initialScale = (0.85 - staggerIndex * 0.1)
            .clamp(0.0, 1.0)
            .toDouble();
        final baseSpacing = -30.0 * staggerIndex;
        final initialSpacing =
            baseSpacing - (1 - initialScale) * baseSpacing.abs();
        final moved = Transform.translate(
          offset: Offset(0, initialSpacing * (1 - value)),
          child: Transform.scale(
            scale: initialScale + (1 - initialScale) * value,
            alignment: Alignment.topCenter,
            child: child,
          ),
        );
        return cachedGlass ? moved : Opacity(opacity: value, child: moved);
      },
    );
  }
}

class _HistoryNotification extends StatelessWidget {
  const _HistoryNotification({
    required this.record,
    required this.preview,
    required this.interactive,
    required this.onDismiss,
    this.onOpen,
    this.onAction,
    this.group,
    this.onExpand,
    super.key,
  });

  final DesktopNotificationRecord record;
  final NotificationPreviewMode preview;
  final bool interactive;
  final bool Function() onDismiss;
  final VoidCallback? onOpen;
  final ValueChanged<String>? onAction;

  /// A stacked group this row stands for, collapsed; a tap runs [onExpand].
  final DesktopNotificationGroup? group;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final notification = record.notification;
    final padding = MediaQuery.viewPaddingOf(context);
    final metrics = MobileUiMetrics.of(context);
    final clearable =
        interactive && (group?.clearable ?? notification.clearable);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        padding.left + metrics.visual(MobileNotificationCard.horizontalMargin),
        0,
        padding.right + metrics.visual(MobileNotificationCard.horizontalMargin),
        metrics.visual(MobileNotificationMetrics.rowSpacing),
      ),
      child: Dismissible(
        key: ValueKey(notification.id),
        direction: clearable
            ? DismissDirection.horizontal
            : DismissDirection.none,
        onUpdate: (_) => NotificationShadeList.invalidateOcclusion(context),
        confirmDismiss: (_) async {
          // The controller removes the row only if the request succeeds.
          // Do not leave a dismissed widget in the tree on bridge failure.
          onDismiss();
          return false;
        },
        child: Semantics(
          onDismiss: clearable
              ? () {
                  onDismiss();
                }
              : null,
          child: MobileNotificationCard(
            notification: notification,
            interactive: interactive,
            groupedBackdrop: true,
            cachedBackdrop: true,
            previewMode: preview,
            group: group,
            onExpandGroup: onExpand,
            onDefaultAction: onOpen,
            onAction: onAction,
            surfaceBuilder: (context, card) {
              final radius = BorderRadius.circular(
                metrics.visual(ShellTheme.of(context).panelRadius),
              );
              return NotificationShadeSurface(
                borderRadius: radius,
                child: ShadeBackdropRegion(borderRadius: radius, child: card),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Above an opened group's members: its app and count, and a button that
/// folds it back into one card.
class _HistoryGroupHeader extends StatelessWidget {
  const _HistoryGroupHeader({
    required this.group,
    required this.onCollapse,
    super.key,
  });

  final DesktopNotificationGroup group;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final metrics = MobileUiMetrics.of(context);
    final l10n = context.l10n;
    final appName = notificationAppName(group.newest.notification, l10n);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        padding.left +
            metrics.visual(
              MobileNotificationCard.horizontalMargin +
                  MobileNotificationMetrics.horizontalContentInset,
            ),
        0,
        padding.right + metrics.visual(MobileNotificationCard.horizontalMargin),
        0,
      ),
      child: Builder(
        builder: (context) => NotificationReveal.revealed(
          context,
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.notificationGroupHeader(appName, group.members.length),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShellText.base.copyWith(
                    color: context.shellColors.textSecondary,
                    fontSize: MobileNotificationMetrics.groupHeaderFontSize,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ),
              _HistoryButton(
                label: l10n.notificationGroupCollapse(appName),
                icon: Icons.expand_less_rounded,
                onPressed: onCollapse,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryButton extends StatelessWidget {
  const _HistoryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final metrics = MobileUiMetrics.of(context);
    return Semantics(
      button: true,
      label: label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox.square(
            dimension: metrics.visual(MobileNotificationMetrics.detailsExtent),
            child: Icon(
              icon,
              color: context.shellColors.textSecondary,
              size: metrics.visual(MobileNotificationMetrics.detailsIcon),
            ),
          ),
        ),
      ),
    );
  }
}

class ClearNotificationHistoryButton extends ConsumerWidget {
  const ClearNotificationHistoryButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canClear = ref.watch(
      desktopNotificationsProvider.select(
        (s) => s.history.any((record) => record.notification.clearable),
      ),
    );
    final locked = ref.watch(
      referenceShellProvider.select((s) => s.lockLayerVisible),
    );
    if (!canClear || locked) return const SizedBox.shrink();
    return _HistoryButton(
      label: context.l10n.notificationsClearAll,
      icon: Icons.clear_all_rounded,
      onPressed: ref.read(desktopNotificationsProvider.notifier).clearAll,
    );
  }
}

/// Avoid inheriting an always-scrollable platform physics for a short history.
/// The presence of a vertical scroll recognizer must match actual overflow.
class _HistoryScrollPhysics extends ClampingScrollPhysics {
  const _HistoryScrollPhysics({super.parent});

  @override
  _HistoryScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _HistoryScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      position.maxScrollExtent > position.minScrollExtent;
}
