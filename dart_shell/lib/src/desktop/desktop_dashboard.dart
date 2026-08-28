part of 'desktop_shell.dart';

class _DesktopDashboard extends StatelessWidget {
  const _DesktopDashboard({
    required this.onEnter,
    required this.onExit,
    required this.onOpenWallpaper,
    required this.onOpenAppVolumeManager,
    required this.onOpenSettings,
  });

  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onOpenWallpaper;
  final VoidCallback onOpenAppVolumeManager;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);

    return MouseRegion(
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: FocusTraversalGroup(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.panelColor(context.shellColors.panelBackground),
            borderRadius: BorderRadius.circular(theme.panelRadius),
            border: Border.all(color: context.shellColors.hairline),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DashboardHeader(
                  onOpenSettings: onOpenSettings,
                  onOpenWallpaper: onOpenWallpaper,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: DesktopDashboardCardLayout(
                    volume: _DashboardVolumeCard(
                      onOpenAppVolumeManager: onOpenAppVolumeManager,
                    ),
                    powerModes: const DesktopPowerModesSection(),
                    bluetooth: const _DashboardBluetoothCard(),
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

class DesktopDashboardCardLayout extends StatelessWidget {
  const DesktopDashboardCardLayout({
    required this.volume,
    required this.powerModes,
    required this.bluetooth,
    super.key,
  });

  final Widget volume;
  final Widget powerModes;
  final Widget bluetooth;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        volume,
        const SizedBox(height: 12),
        powerModes,
        Flexible(
          fit: FlexFit.loose,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: desktopDashboardBluetoothMaxHeight,
            ),
            child: SizedBox(width: double.infinity, child: bluetooth),
          ),
        ),
      ],
    );
  }
}

class _DashboardHeader extends ConsumerWidget {
  const _DashboardHeader({
    required this.onOpenSettings,
    required this.onOpenWallpaper,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback onOpenWallpaper;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCount = ref.watch(
      desktopNotificationsProvider.select((state) => state.unreadCount),
    );
    final l10n = context.l10n;

    void openNotifications() {
      ref
          .read(shellSurfaceControllerProvider.notifier)
          .show(
            keyName: 'desktop-notification-center',
            debugLabel: 'Notification center',
            builder: (context, handle) =>
                _DesktopNotificationCenterDialog(handle: handle),
          );
    }

    return Row(
      children: [
        Expanded(
          child: Text(
            l10n.desktopDashboardTitle,
            style: context.shellTheme.text.statusClock.copyWith(fontSize: 22),
          ),
        ),
        _DashboardIconButton(
          semanticLabel: unreadCount == 0
              ? l10n.desktopOpenNotificationCenter
              : l10n.desktopOpenNotificationCenterUnread(unreadCount),
          icon: unreadCount == 0
              ? Icons.notifications_none_rounded
              : Icons.notifications_active_rounded,
          active: unreadCount > 0,
          onTap: openNotifications,
        ),
        const SizedBox(width: 7),
        _DashboardIconButton(
          semanticLabel: l10n.settingsApplicationSemanticsLabel,
          icon: Icons.settings_rounded,
          onTap: onOpenSettings,
        ),
        const SizedBox(width: 7),
        _DashboardIconButton(
          semanticLabel: l10n.desktopOpenPowerControls,
          icon: Icons.power_settings_new_rounded,
          onTap: () => showPowerSessionSurface(ref),
        ),
        const SizedBox(width: 7),
        _DashboardIconButton(
          semanticLabel: l10n.desktopChooseWallpaper,
          icon: Icons.wallpaper_rounded,
          onTap: onOpenWallpaper,
        ),
      ],
    );
  }
}

class _DashboardVolumeCard extends ConsumerWidget {
  const _DashboardVolumeCard({required this.onOpenAppVolumeManager});

  final VoidCallback onOpenAppVolumeManager;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(
      quickSettingsProvider.select((state) => state.volume),
    );
    final devices = ref.watch(audioDevicesProvider);
    final controller = ref.read(quickSettingsProvider.notifier);
    final deviceController = ref.read(audioDevicesProvider.notifier);
    final l10n = context.l10n;
    final accent = ShellTheme.of(context).accent;
    return _DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.volume_up_rounded, size: 21, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.commonVolume,
                  style: context.shellTheme.text.cardTitle,
                ),
              ),
              _DashboardValueButton(
                semanticLabel: l10n.desktopOpenApplicationAudio,
                label: l10n.settingsPercent((volume * 100).round()),
                icon: Icons.tune_rounded,
                onTap: onOpenAppVolumeManager,
              ),
            ],
          ),
          const SizedBox(height: 10),
          DashboardAudioDeviceDropdown(
            state: devices,
            onRefresh: deviceController.refresh,
            onSelected: deviceController.select,
          ),
          const SizedBox(height: 10),
          RangeBar(
            icon: volume <= 0.01
                ? Icons.volume_off_rounded
                : Icons.volume_up_rounded,
            value: volume,
            activeColor: accent,
            inactiveColor: context.shellColors.volumeTrack,
            onChangeStart: controller.beginVolumeInteraction,
            onChanged: controller.setDashboardVolume,
            onChangeEnd: controller.commitDashboardVolume,
            height: 48,
          ),
        ],
      ),
    );
  }
}

class _DashboardBluetoothCard extends ConsumerWidget {
  const _DashboardBluetoothCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bluetooth = ref.watch(bluetoothProvider);
    final controller = ref.read(bluetoothProvider.notifier);
    final l10n = context.l10n;
    final accent = ShellTheme.of(context).accent;
    return _DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bluetooth_rounded, size: 21, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.commonBluetooth,
                  style: context.shellTheme.text.cardTitle,
                ),
              ),
              _DashboardIconButton(
                semanticLabel: bluetooth.powered
                    ? l10n.desktopTurnBluetoothOff
                    : l10n.desktopTurnBluetoothOn,
                icon: Icons.power_settings_new_rounded,
                active: bluetooth.powered,
                busy: bluetooth.powerChanging,
                onTap: controller.togglePower,
              ),
              const SizedBox(width: 7),
              _DashboardIconButton(
                semanticLabel: l10n.desktopScanBluetooth,
                icon: Icons.bluetooth_searching_rounded,
                active: bluetooth.scanning || bluetooth.discovering,
                busy: bluetooth.scanning,
                enabled: bluetooth.powered,
                onTap: controller.scan,
              ),
              const SizedBox(width: 7),
              _DashboardIconButton(
                semanticLabel: l10n.desktopRefreshBluetooth,
                icon: Icons.refresh_rounded,
                busy: bluetooth.refreshing,
                onTap: controller.refresh,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (bluetooth.error != null) ...[
            Text(
              l10n.settingsBluetoothUnavailable,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.shellTheme.text.cardTitle.copyWith(
                color: context.shellColors.performanceBad,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Expanded(
            child: _BluetoothDeviceList(
              state: bluetooth,
              onToggleConnection: controller.toggleConnection,
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopNotificationCenterDialog extends StatelessWidget {
  const _DesktopNotificationCenterDialog({required this.handle});

  final ShellSurfaceHandle handle;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final l10n = context.l10n;
    return MainOutputCenteredSurface(
      builder: (context, constraints) {
        final panelWidth = math.min(520.0, constraints.maxWidth);
        final panelHeight = math.min(720.0, constraints.maxHeight);
        return SizedBox(
          width: panelWidth,
          height: panelHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.panelColor(context.shellColors.panelBackground),
              borderRadius: BorderRadius.circular(theme.panelRadius),
              border: Border.all(color: context.shellColors.hairline),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.notificationsTitle,
                          style: context.shellTheme.text.statusClock.copyWith(
                            fontSize: 22,
                          ),
                        ),
                      ),
                      _DashboardIconButton(
                        semanticLabel: l10n.notificationsCloseCenter,
                        icon: Icons.close_rounded,
                        onTap: handle.close,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Expanded(child: NotificationCenter(showTitle: false)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellTheme.cardColor(
          context.shellColors.surfaceContainerLow,
        ),
        borderRadius: context.shellTheme.borderRadius(20),
        border: Border.all(color: context.shellColors.hairlineSoft),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}
