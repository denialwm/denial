import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../services/notification_policy_repository.dart';
import '../../state/desktop_notifications.dart';
import '../../state/shell_controller.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../notification_banner.dart';
import 'notification_shade_list.dart';
import 'shade_backdrop_scene.dart';
import 'shade_dismiss_gesture.dart';

/// A separate scrollable notification stack below the dropdown's handle.
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
          ref.read(shellControllerProvider).lockLayerVisible) {
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(desktopNotificationsProvider);
    final controller = ref.read(desktopNotificationsProvider.notifier);
    final locked = ref.watch(
      shellControllerProvider.select((state) => state.lockLayerVisible),
    );
    final preview = locked ? state.lockPreview : NotificationPreviewMode.full;
    final records = preview == NotificationPreviewMode.hidden
        ? const <DesktopNotificationRecord>[]
        : state.history;
    final indices = <int, int>{
      for (var i = 0; i < records.length; i++) records[i].notification.id: i,
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
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final record = records[index];
                return _HistoryNotification(
                  key: ValueKey(record.notification.id),
                  record: record,
                  preview: preview,
                  interactive: !locked,
                  onDismiss: () =>
                      controller.dismissFromHistory(record.notification.id),
                  onOpen: () {
                    if (controller.invokeDefaultAction(
                      record.notification.id,
                    )) {
                      ref
                          .read(shellControllerProvider.notifier)
                          .closeQuickSettings();
                    }
                  },
                  onAction: (key) =>
                      controller.invokeAction(record.notification.id, key),
                );
              },
              childCount: records.length,
              findChildIndexCallback: (key) =>
                  key is ValueKey<int> && indices.containsKey(key.value)
                  ? indices[key.value]
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    widget.progress.removeListener(_observeProgress);
    _entrance.dispose();
    _scroll.dispose();
    super.dispose();
  }
}

class _HistoryNotification extends StatelessWidget {
  const _HistoryNotification({
    required this.record,
    required this.preview,
    required this.interactive,
    required this.onDismiss,
    required this.onOpen,
    required this.onAction,
    super.key,
  });

  final DesktopNotificationRecord record;
  final NotificationPreviewMode preview;
  final bool interactive;
  final bool Function() onDismiss;
  final VoidCallback onOpen;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final notification = record.notification;
    final padding = MediaQuery.viewPaddingOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        padding.left + MobileNotificationCard.horizontalMargin,
        0,
        padding.right + MobileNotificationCard.horizontalMargin,
        10,
      ),
      child: Dismissible(
        key: ValueKey(notification.id),
        direction: interactive
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
          onDismiss: interactive
              ? () {
                  onDismiss();
                }
              : null,
          child: MobileNotificationCard(
            notification: notification,
            interactive: interactive,
            groupedBackdrop: true,
            previewMode: preview,
            onDefaultAction: record.active ? onOpen : null,
            onAction: record.active ? onAction : null,
            surfaceBuilder: (context, card) {
              final radius = BorderRadius.circular(
                ShellTheme.of(context).panelRadius,
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

class _HistoryButton extends StatelessWidget {
  const _HistoryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.content,
  });

  final Widget? content;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
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
        child:
            content ??
            SizedBox.square(
              dimension: 48,
              child: Icon(
                icon,
                color: context.shellColors.textSecondary,
                size: 22,
              ),
            ),
      ),
    ),
  );
}

class ClearNotificationHistoryButton extends ConsumerWidget {
  const ClearNotificationHistoryButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasHistory = ref.watch(
      desktopNotificationsProvider.select((s) => s.history.isNotEmpty),
    );
    final locked = ref.watch(
      shellControllerProvider.select((s) => s.lockLayerVisible),
    );
    if (!hasHistory || locked) return const SizedBox.shrink();
    return _HistoryButton(
      label: context.l10n.notificationsClearAll,
      icon: Icons.clear_all_rounded,
      onPressed: ref.read(desktopNotificationsProvider.notifier).clearAll,
      content: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  context.l10n.notificationsClearAll,
                  style: ShellText.base.copyWith(fontSize: 16),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.clear_all_rounded,
                size: 24,
                color: context.shellColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
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
