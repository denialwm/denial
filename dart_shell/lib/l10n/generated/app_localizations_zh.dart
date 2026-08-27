// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get actionCancel => '取消';

  @override
  String get actionDismiss => '关闭';

  @override
  String get screenshotSelectionHint => '拖动以选择区域 · 按 Esc 取消';

  @override
  String get anchorBottomCenter => '底部居中';

  @override
  String get anchorBottomLeft => '左下';

  @override
  String get anchorBottomRight => '右下';

  @override
  String get anchorCenter => '居中';

  @override
  String get anchorCenterLeft => '左侧居中';

  @override
  String get anchorCenterRight => '右侧居中';

  @override
  String get anchorTopCenter => '顶部居中';

  @override
  String get anchorTopLeft => '左上';

  @override
  String get anchorTopRight => '右上';

  @override
  String get batteryCapacityUnavailable => '--';

  @override
  String get batteryCharging => '正在充电';

  @override
  String get batteryDischarging => '正在放电';

  @override
  String batteryGraphMarker(String label, String value) {
    return '$label $value';
  }

  @override
  String get batteryIdle => '空闲';

  @override
  String batteryStateAndPercent(String state, int percent) {
    return '$state $percent%';
  }

  @override
  String get batteryTitle => '电池';

  @override
  String get bluetoothAllow => '允许';

  @override
  String bluetoothAllowPairing(String deviceName) {
    return '允许 $deviceName 配对吗？';
  }

  @override
  String get bluetoothAllowService => '允许蓝牙服务吗？';

  @override
  String bluetoothAvailableSignal(int signal) {
    return '可用 · $signal dBm';
  }

  @override
  String get bluetoothBlocked => '已阻止';

  @override
  String get bluetoothCloseDetails => '关闭蓝牙详情';

  @override
  String get bluetoothCodeDisplayed => '已显示代码';

  @override
  String bluetoothConfirmCode(String code) {
    return '请确认两台设备均显示 $code。';
  }

  @override
  String bluetoothConfirmDevice(String deviceName) {
    return '确认 $deviceName';
  }

  @override
  String bluetoothConnectDeviceStatus(String deviceName, String status) {
    return '连接 $deviceName，$status';
  }

  @override
  String get bluetoothConnectedConfiguring => '已连接 · 正在配置服务';

  @override
  String bluetoothDevicesConnected(int count) {
    return '已连接设备：$count';
  }

  @override
  String get bluetoothDismissError => '关闭蓝牙错误';

  @override
  String bluetoothEnterPasskey(String deviceName) {
    return '输入 $deviceName 的配对密钥';
  }

  @override
  String bluetoothEnterPasskeyOnDevice(String deviceName) {
    return '在 $deviceName 上输入此配对密钥';
  }

  @override
  String bluetoothEnterPin(String deviceName) {
    return '输入 $deviceName 的 PIN';
  }

  @override
  String bluetoothEnterPinOnDevice(String deviceName) {
    return '在 $deviceName 上输入此 PIN';
  }

  @override
  String get bluetoothLoadingService => '正在加载蓝牙服务…';

  @override
  String get bluetoothNoAdapter => '没有蓝牙适配器';

  @override
  String get bluetoothNoAdapterDescription => '检测到适配器后，Denial 将启用这些控件。';

  @override
  String get bluetoothNoAdapterShort => '无适配器';

  @override
  String get bluetoothNoDevices => '未找到设备';

  @override
  String get bluetoothNoDevicesDescription => '开始扫描，并将另一台设备设为可发现。';

  @override
  String get bluetoothOff => '蓝牙已关闭';

  @override
  String get bluetoothOffDescription => '开启蓝牙以查看已配对和附近的设备。';

  @override
  String get bluetoothOperationFailed => '蓝牙无法完成请求。';

  @override
  String bluetoothPairDevice(String deviceName) {
    return '与 $deviceName 配对';
  }

  @override
  String get bluetoothPairedTrusted => '已配对 · 已信任';

  @override
  String get bluetoothPasskey => '蓝牙配对密钥';

  @override
  String get bluetoothPasskeyPrivacy => '配对密钥仅发送一次给 BlueZ，Denial 不会保留。';

  @override
  String bluetoothPasskeyProgress(String code, int enteredDigits) {
    return '$code · 已输入 6 位中的 $enteredDigits 位。';
  }

  @override
  String get bluetoothPasskeyRequirements => '请输入最多 6 位的数字配对密钥。';

  @override
  String get bluetoothPinCode => '蓝牙 PIN 码';

  @override
  String get bluetoothPinPrivacy => 'PIN 仅发送一次给 BlueZ，Denial 不会保留。';

  @override
  String get bluetoothPinRequirements => '请输入包含 1–16 个字符的 PIN。';

  @override
  String get bluetoothRecognizeDevice => '仅在你确认认识此设备时继续。';

  @override
  String get bluetoothReject => '拒绝';

  @override
  String bluetoothRemoveDevice(String deviceName) {
    return '移除 $deviceName';
  }

  @override
  String get bluetoothSameCode => '相同代码';

  @override
  String get bluetoothScanningDescription => '附近的设备将自动出现。';

  @override
  String get bluetoothServiceUnavailable => 'BlueZ 不可用';

  @override
  String get bluetoothServiceUnavailableDescription => '服务启动后，蓝牙控件将恢复。';

  @override
  String get bluetoothServiceUnavailableShort => '蓝牙不可用';

  @override
  String get bluetoothStopScanning => '停止扫描蓝牙设备';

  @override
  String bluetoothStopTrustingDevice(String deviceName) {
    return '不再信任 $deviceName';
  }

  @override
  String get bluetoothSubmit => '提交';

  @override
  String bluetoothTrustDevice(String deviceName) {
    return '信任 $deviceName';
  }

  @override
  String bluetoothTrustServiceDevice(String deviceName) {
    return '仅在你信任 $deviceName 时继续。';
  }

  @override
  String bluetoothWaitingForDevice(String code) {
    return '$code · 正在等待另一台设备。';
  }

  @override
  String get brightnessTitle => '亮度';

  @override
  String get celsiusUnit => '°C';

  @override
  String get chargeProtocolFast => '快速';

  @override
  String get chargeProtocolPowerDelivery => 'PD';

  @override
  String get chargeProtocolPps => 'PPS';

  @override
  String get chargeProtocolVooc => 'VOOC';

  @override
  String get clipboardCloseHistory => '关闭剪贴板历史';

  @override
  String get clipboardClearAll => '全部清除';

  @override
  String get clipboardDelete => '删除';

  @override
  String get clipboardDeleteItem => '删除剪贴板项目';

  @override
  String get clipboardDragToClose => '将剪贴板托盘拖向屏幕边缘以关闭';

  @override
  String get clipboardEmptyDescription => '复制文本、图像或文件后，它们会出现在这里。';

  @override
  String get clipboardEmptyTitle => '尚未捕获任何内容';

  @override
  String get clipboardFileSelection => '文件选择';

  @override
  String get clipboardHistoryLockedDescription => '会话锁定时，剪贴板内容会保持隐藏。';

  @override
  String get clipboardHistoryLockedTitle => '历史记录已封存';

  @override
  String get clipboardImageFileThumbnail => '图像文件缩略图';

  @override
  String get clipboardImagePreview => '剪贴板图像预览';

  @override
  String get clipboardItemHint => '激活以粘贴到当前应用。拖动以投放。';

  @override
  String clipboardItemSemantics(String type, String preview) {
    return '$type剪贴板项目。$preview';
  }

  @override
  String get clipboardPin => '固定';

  @override
  String get clipboardPinItem => '固定剪贴板项目';

  @override
  String get clipboardNoSearchResultsDescription => '请尝试其他词语、文件类型或应用。';

  @override
  String get clipboardNoSearchResultsTitle => '未找到匹配项';

  @override
  String get clipboardPreviewUnavailable => '预览不可用';

  @override
  String get clipboardTypeFiles => '文件';

  @override
  String get clipboardTypeImage => '图像';

  @override
  String get clipboardTypeText => '文本';

  @override
  String get clipboardUnpin => '取消固定';

  @override
  String get clipboardUnpinItem => '取消固定剪贴板项目';

  @override
  String get clipboardUnavailableDescription => '原生历史记录服务没有响应。';

  @override
  String get clipboardUnavailableTitle => '剪贴板桥接不可用';

  @override
  String get commonBluetooth => '蓝牙';

  @override
  String get commonCancel => '取消';

  @override
  String get commonChecking => '正在检查…';

  @override
  String get commonConnecting => '正在连接…';

  @override
  String get commonError => '错误';

  @override
  String get commonLimited => '受限';

  @override
  String get commonLoading => '正在加载…';

  @override
  String get commonNotConnected => '未连接';

  @override
  String get commonOff => '关闭';

  @override
  String get commonOn => '开启';

  @override
  String get commonOnline => '在线';

  @override
  String get commonOpening => '正在打开…';

  @override
  String get commonRetry => '重试';

  @override
  String get commonScanning => '正在扫描…';

  @override
  String commonTitleAndBody(String title, String body) {
    return '$title。$body';
  }

  @override
  String commonTitleAndSubtitle(String title, String subtitle) {
    return '$title，$subtitle';
  }

  @override
  String get commonUnavailable => '不可用';

  @override
  String get commonVolume => '音量';

  @override
  String get commonWifi => 'Wi-Fi';

  @override
  String currentMilliamps(int value) {
    return '$value mA';
  }

  @override
  String get currentMilliampsUnavailable => '-- mA';

  @override
  String desktopActivateWindow(String windowTitle) {
    return '激活 $windowTitle';
  }

  @override
  String get desktopAudioOutputDevicesDescription => '选择桌面音频的播放位置。';

  @override
  String get desktopAudioOutputDevicesTitle => '输出设备';

  @override
  String get desktopAudioOutputDevicesUnavailable => '音频输出设备不可用。';

  @override
  String get desktopAudioOutputDeviceNotConnected => '未连接';

  @override
  String get desktopApplicationAudioUnavailable => '应用音频不可用。';

  @override
  String desktopApplicationSearchResults(int visible, int total) {
    return '共 $total 个应用，显示 $visible 个';
  }

  @override
  String get desktopApplicationSuggestionsTitle => '建议';

  @override
  String get desktopApplicationVolumeDescription => '分别调节各个应用的音频。';

  @override
  String get desktopApplicationVolumeTitle => '应用音量';

  @override
  String get desktopApplicationsTitle => '应用';

  @override
  String get desktopChooseWallpaper => '选择壁纸';

  @override
  String get desktopClearApplicationSearch => '清除应用搜索';

  @override
  String get desktopCloseApplicationAudio => '关闭应用音量';

  @override
  String get desktopCloseAudioOutputDevices => '关闭输出设备';

  @override
  String desktopConnectDevice(String deviceName) {
    return '连接 $deviceName';
  }

  @override
  String get desktopDashboardTitle => '仪表板';

  @override
  String desktopDisconnectDevice(String deviceName) {
    return '断开 $deviceName';
  }

  @override
  String get desktopLoadingAudioOutputDevices => '正在加载输出设备…';

  @override
  String get desktopEnableBluetoothForDevices => '开启蓝牙以查看设备。';

  @override
  String desktopFeatureAvailability(String feature, String availability) {
    return '$feature：$availability';
  }

  @override
  String get desktopGpuLabel => 'GPU';

  @override
  String get desktopGpuPresetAutomatic => '自动';

  @override
  String get desktopGpuPresetHigh => '高';

  @override
  String get desktopGpuPresetLow => '低';

  @override
  String desktopInstalledApplications(int count) {
    return '已安装应用：$count';
  }

  @override
  String desktopLaunchApplication(String applicationName) {
    return '启动 $applicationName';
  }

  @override
  String get desktopLoadingApplications => '正在加载应用…';

  @override
  String get desktopNoApplicationAudio => '没有应用正在播放音频。';

  @override
  String get desktopNoAudioOutputDevices => '未找到音频输出设备。';

  @override
  String get desktopNoApplicationsFound => '未找到应用';

  @override
  String get desktopOpenApplicationAudio => '打开应用音量';

  @override
  String get desktopOpenNotificationCenter => '打开通知中心';

  @override
  String desktopOpenNotificationCenterUnread(int count) {
    return '打开通知中心 · $count 条未读';
  }

  @override
  String get desktopOpenPowerControls => '打开电源控件';

  @override
  String get desktopPboBalanced => '均衡';

  @override
  String get desktopPboLabel => 'PBO';

  @override
  String get desktopPboPerformance => '性能';

  @override
  String get desktopPboSilent => '静音';

  @override
  String get desktopPowerModesTitle => '电源模式';

  @override
  String get desktopPowerModesUnavailable => '电源模式不可用。';

  @override
  String get desktopRefreshApplicationAudio => '刷新应用音频';

  @override
  String get desktopRefreshAudioOutputDevices => '刷新输出设备';

  @override
  String get desktopRefreshBluetooth => '刷新蓝牙设备';

  @override
  String get desktopRefreshPowerModes => '刷新电源模式';

  @override
  String desktopRestoreWindow(String windowTitle) {
    return '还原 $windowTitle';
  }

  @override
  String get desktopScanBluetooth => '扫描蓝牙设备';

  @override
  String get desktopSelectAudioOutputDevice => '选择音频输出设备';

  @override
  String get desktopScanningBluetoothDevices => '正在扫描蓝牙设备…';

  @override
  String get desktopSearchApplications => '搜索应用';

  @override
  String get desktopSystemProfile => '系统配置';

  @override
  String get desktopSystemProfileBalanced => '均衡';

  @override
  String get desktopSystemProfilePerformance => '性能';

  @override
  String get desktopSystemProfilePowerSaver => '节能';

  @override
  String get desktopTurnBluetoothOff => '关闭蓝牙';

  @override
  String get desktopTurnBluetoothOn => '开启蓝牙';

  @override
  String desktopVolumeForApplication(String applicationName) {
    return '$applicationName 的音量';
  }

  @override
  String frameAppRendering(String title) {
    return '应用 · $title · 渲染';
  }

  @override
  String frameAppWaiting(String title) {
    return '应用 · $title · 等待';
  }

  @override
  String frameImportedStats(
    String average,
    String maximum,
    int overBudget,
    int samples,
  ) {
    return '平均 $average  最大 $maximum  超预算 $overBudget  样本 $samples';
  }

  @override
  String get frameImportedStatsUnavailable => '平均 --.-  最大 --.-  超预算 -  样本 -';

  @override
  String frameMilliseconds(String value) {
    return '约 $value 毫秒';
  }

  @override
  String get frameMillisecondsUnavailable => '--.- 毫秒';

  @override
  String frameShellPhases(String build, String raster, String gap) {
    return 'UI $build  光栅 $raster  间隔 $gap';
  }

  @override
  String frameShellRendering(int refreshRate) {
    return 'SHELL · $refreshRate HZ · 渲染';
  }

  @override
  String frameShellStats(String average, String maximum, int overBudget) {
    return '平均 $average  最大 $maximum  超预算 $overBudget';
  }

  @override
  String get frameShellWaiting => 'SHELL · 等待';

  @override
  String launchOpeningApplication(String applicationName) {
    return '正在打开 $applicationName';
  }

  @override
  String localApplicationNotRegistered(String appId) {
    return '本地应用“$appId”未注册。';
  }

  @override
  String get lockAuthenticating => '正在验证…';

  @override
  String get lockAuthenticationResponse => '验证响应';

  @override
  String get lockAuthenticationUnavailable => '验证不可用。';

  @override
  String get lockCpuLabel => 'CPU';

  @override
  String get lockDesktopPromptDescription => '输入密码以解锁此桌面会话。';

  @override
  String get lockHideOnScreenKeyboard => '隐藏屏幕键盘';

  @override
  String get lockKeyboardBackspace => '退格';

  @override
  String get lockKeyboardLetters => '字母';

  @override
  String get lockKeyboardShift => 'Shift';

  @override
  String get lockKeyboardSpace => '空格';

  @override
  String get lockKeyboardSymbols => '符号';

  @override
  String get lockMetricUnavailable => '--';

  @override
  String get lockOnScreenKeyboard => '屏幕键盘';

  @override
  String get lockPamVerified => '身份已验证';

  @override
  String get lockPasswordObscured => '密码，已隐藏';

  @override
  String lockPerformanceMetric(String label, String value) {
    return '$label：$value';
  }

  @override
  String get lockPerformanceStatusLabel => '桌面性能状态';

  @override
  String get lockPleaseWait => '请稍候…';

  @override
  String get lockPressEnter => '按 Enter 解锁';

  @override
  String lockRetryInSeconds(int seconds) {
    return '请在 $seconds 秒后重试';
  }

  @override
  String get lockScreenSemanticsLabel => '桌面锁屏';

  @override
  String get lockShowOnScreenKeyboard => '显示屏幕键盘';

  @override
  String get lockSignInSemantics => '登录 Denial';

  @override
  String lockTemperature(int temperature) {
    return '$temperature°C';
  }

  @override
  String get lockTryAgain => '重试';

  @override
  String get lockUnlock => '解锁';

  @override
  String get lockUnlockDenial => '解锁 Denial';

  @override
  String get lockWaitingForAuthentication => '正在等待验证…';

  @override
  String get lockWelcomeBack => '欢迎回来';

  @override
  String longDate(String weekday, int day, String month) {
    return '$month$day日 $weekday';
  }

  @override
  String get mediaControls => '媒体控件';

  @override
  String get mediaNext => '下一首';

  @override
  String get mediaNowPlaying => '正在播放';

  @override
  String get mediaPause => '暂停';

  @override
  String get mediaPlay => '播放';

  @override
  String get mediaPrevious => '上一首';

  @override
  String get metricAverage => '平均';

  @override
  String get metricCpu => 'CPU';

  @override
  String get metricMaximum => '最大';

  @override
  String get metricMinimum => '最小';

  @override
  String get metricNow => '当前';

  @override
  String get monthApril => '四月';

  @override
  String get monthAugust => '八月';

  @override
  String get monthDecember => '十二月';

  @override
  String get monthFebruary => '二月';

  @override
  String get monthJanuary => '一月';

  @override
  String get monthJuly => '七月';

  @override
  String get monthJune => '六月';

  @override
  String get monthMarch => '三月';

  @override
  String get monthMay => '五月';

  @override
  String get monthNovember => '十一月';

  @override
  String get monthOctober => '十月';

  @override
  String get monthSeptember => '九月';

  @override
  String get notificationDismiss => '关闭通知';

  @override
  String get notificationGeneric => '通知';

  @override
  String get notificationNew => '新通知';

  @override
  String notificationOpen(String summary) {
    return '打开 $summary';
  }

  @override
  String notificationProgress(int percent) {
    return '进度：$percent%';
  }

  @override
  String notificationSemantics(String applicationName, String summary) {
    return '$applicationName：$summary';
  }

  @override
  String notificationSemanticsWithBody(
    String applicationName,
    String summary,
    String body,
  ) {
    return '$applicationName：$summary。$body';
  }

  @override
  String get notificationsAllQuiet => '一切安静';

  @override
  String get notificationsClearAll => '清除所有通知';

  @override
  String get notificationsCloseCenter => '关闭通知中心';

  @override
  String get notificationsClosed => '已关闭';

  @override
  String get notificationsClosedByApplication => '已由应用关闭';

  @override
  String get notificationsDisableDoNotDisturb => '关闭免打扰';

  @override
  String get notificationsDismissed => '已忽略';

  @override
  String get notificationsDoNotDisturbSemantics => '免打扰已开启。普通横幅将保持静默，重要通知仍可显示。';

  @override
  String get notificationsEmptyDescription => '新通知会出现在这里。';

  @override
  String get notificationsEnableDoNotDisturb => '开启免打扰';

  @override
  String get notificationsExpired => '已过期';

  @override
  String get notificationsLoadingPolicy => '正在加载免打扰策略';

  @override
  String get notificationsLockPrivacy => '锁屏通知隐私';

  @override
  String get notificationsNone => '没有通知';

  @override
  String get notificationsOnLockScreen => '锁屏上';

  @override
  String get notificationsPreviewApplicationOnly => '仅应用';

  @override
  String get notificationsPreviewFull => '完整';

  @override
  String get notificationsPreviewHidden => '隐藏';

  @override
  String notificationsPreviewModeSemantics(String mode) {
    return '$mode锁屏预览';
  }

  @override
  String get notificationsQuietMode => '静默模式 · 重要提醒可以绕过';

  @override
  String get notificationsTitle => '通知';

  @override
  String notificationsUnread(int count) {
    return '未读通知：$count';
  }

  @override
  String numberValue(int value) {
    return '$value';
  }

  @override
  String get oskArrowDown => '下';

  @override
  String get oskArrowUp => '上';

  @override
  String get oskBackspace => '退格';

  @override
  String get oskControlKey => 'CTRL';

  @override
  String get oskEnter => 'Enter';

  @override
  String get oskLetters => '字母';

  @override
  String get oskLettersKey => 'ABC';

  @override
  String get oskMoreSymbols => '更多符号';

  @override
  String get oskMoreSymbolsKey => '=<';

  @override
  String get oskNumbersAndSymbols => '数字和符号';

  @override
  String get oskNumbersAndSymbolsKey => '?123';

  @override
  String get oskShift => 'Shift';

  @override
  String get oskSpace => '空格';

  @override
  String outputBrightnessSemantics(String outputName) {
    return '$outputName 亮度';
  }

  @override
  String get outputVolumeSemantics => '输出音量';

  @override
  String get overviewNoWindows => '没有窗口';

  @override
  String percentCompact(int percent) {
    return '$percent%';
  }

  @override
  String get percentSign => '%';

  @override
  String percentValue(int percent) {
    return '百分之 $percent';
  }

  @override
  String get powerActionHibernate => '休眠';

  @override
  String get powerActionHibernateDescription => '将会话保存到磁盘';

  @override
  String get powerActionLock => '锁定';

  @override
  String get powerActionLockDescription => '立即保护会话';

  @override
  String get powerActionLogOut => '注销';

  @override
  String get powerActionLogOutDescription => '关闭 Denial 会话';

  @override
  String get powerActionPowerOff => '关机';

  @override
  String get powerActionPowerOffDescription => '关闭计算机';

  @override
  String get powerActionRestart => '重启';

  @override
  String get powerActionRestartDescription => '重新启动计算机';

  @override
  String get powerActionSuspend => '挂起';

  @override
  String get powerActionSuspendDescription => '在内存中保留会话';

  @override
  String powerAuthenticationRequired(String description) {
    return '需要验证 · $description';
  }

  @override
  String powerBlockedBy(String blocker) {
    return '某个应用正在阻止此操作：$blocker';
  }

  @override
  String get powerConfirmLogOutBody => '图形会话将结束。继续前请保存已打开应用中的工作。';

  @override
  String get powerConfirmLogOutTitle => '注销 Denial？';

  @override
  String get powerConfirmPowerOffBody => '所有应用将关闭，计算机将关机。';

  @override
  String get powerConfirmPowerOffTitle => '关闭计算机？';

  @override
  String get powerConfirmRestartBody => '所有应用将关闭，操作系统将重新启动。';

  @override
  String get powerConfirmRestartTitle => '重新启动计算机？';

  @override
  String powerDelayNotice(String details) {
    return '某个应用可能会短暂延迟睡眠或关机：$details';
  }

  @override
  String get powerPermissionDenied => '未获此会话授权';

  @override
  String get powerPermissionUnavailable => '会话服务不可用';

  @override
  String get powerPermissionUnsupported => '此系统不支持';

  @override
  String get powerSessionBusy => '正在完成系统请求…';

  @override
  String get powerSessionClose => '关闭电源和会话控件';

  @override
  String get powerSessionDescription => '选择 Denial 要执行的操作';

  @override
  String get powerSessionLoading => '正在读取系统能力和阻止项…';

  @override
  String get powerSessionRefresh => '刷新电源能力';

  @override
  String get powerSessionRequestError => '系统无法完成请求。';

  @override
  String get powerSessionSemantics => '电源和会话控件';

  @override
  String get powerSessionTitle => '电源与会话';

  @override
  String get powerSessionUnavailable => '系统电源控件不可用。锁定和注销仍由 Denial 本地处理。';

  @override
  String powerWatts(int watts) {
    return '$watts W';
  }

  @override
  String powerWattsDecimal(String watts) {
    return '$watts W';
  }

  @override
  String get quickSettingsAutomatic => '自动';

  @override
  String get quickSettingsBalanced => '均衡';

  @override
  String get quickSettingsBatterySaver => '省电';

  @override
  String get quickSettingsClose => '关闭快速设置';

  @override
  String get quickSettingsControls => '控件';

  @override
  String quickSettingsDate(String weekday, int day) {
    return '$weekday $day日';
  }

  @override
  String get quickSettingsHighPerformance => '高性能';

  @override
  String get quickSettingsKeyboard => '键盘';

  @override
  String get quickSettingsLocked => '已锁定';

  @override
  String get quickSettingsNormal => '正常';

  @override
  String quickSettingsNotificationsCount(int count) {
    return '通知 · $count';
  }

  @override
  String get quickSettingsOneAppActive => '1 个应用正在活动';

  @override
  String quickSettingsOpenDetails(String title) {
    return '打开$title详情';
  }

  @override
  String get quickSettingsOpenOnScreen => '打开屏幕键盘';

  @override
  String get quickSettingsPerformance => '性能';

  @override
  String get quickSettingsRotation => '旋转';

  @override
  String get quickSettingsSettingsUnavailable => '设置不可用。';

  @override
  String get quickSettingsSilent => '静音';

  @override
  String get settingsAboutArchitecture =>
      'Flutter 不是覆盖在另一个合成器之上的界面，而是合成器基础的一部分。';

  @override
  String get settingsAboutBelief => '起源不必决定用途。';

  @override
  String get settingsAboutCollaboration => '与 OpenAI Codex 持续协作构建。';

  @override
  String get settingsAboutCreditLabel => '构思、指导与测试';

  @override
  String get settingsAboutCreditName => 'Doctor Logix';

  @override
  String get settingsAboutDescription =>
      'Denial 赋予 Flutter 不同的生命。它掌管桌面场景本身：Shell、动效以及 Wayland 应用的合成。';

  @override
  String get settingsAboutLogoSemanticsLabel => 'Denial 文字标志';

  @override
  String get settingsAboutPageSemanticsLabel => '关于 Denial';

  @override
  String get settingsAboutTagline => 'Flutter 原生 Wayland 合成器。';

  @override
  String get settingsAccentPickerRouteLabel => 'Shell 强调色选择器';

  @override
  String get settingsAccentPickerWheelLabel => 'Shell 强调色';

  @override
  String get settingsAnimateLockScreen => '锁屏动画';

  @override
  String get settingsAnimateLockScreenDescription => '使用简短的桌面进入动画，同时让安全输入立即可用。';

  @override
  String get settingsAnimationSpeed => '动画速度';

  @override
  String settingsAnimationSpeedValue(int percent) {
    return '$percent% 速度';
  }

  @override
  String get settingsAnimationsDescription => '选择关闭效果并调整 Shell 界面的移动速度。';

  @override
  String get settingsAnimationsSection => '动画';

  @override
  String get settingsAnimationsTitle => '与桌面相配的动效。';

  @override
  String get settingsAppearanceDescription => '此处所做的更改会实时反映到整个桌面。';

  @override
  String get settingsAppearanceSection => '外观';

  @override
  String get settingsAppearanceTitle => '让桌面更合你的心意。';

  @override
  String get settingsApplicationAudioDescription => '分别调节活动音频流。';

  @override
  String get settingsApplicationAudioTitle => '应用音频';

  @override
  String get settingsApplicationCategoryAppearance => '外观';

  @override
  String get settingsApplicationCategoryPreferences => '偏好';

  @override
  String get settingsApplicationCategorySystem => '系统';

  @override
  String get settingsApplicationSemanticsLabel => 'Denial 设置';

  @override
  String get settingsApplicationTitle => '设置';

  @override
  String get settingsAudioDescription => '控制主输出和各个应用的音频流。';

  @override
  String get settingsAudioSection => '音频';

  @override
  String get settingsAudioTitle => '整个桌面的音频。';

  @override
  String get settingsAudioUnavailable => '应用音频不可用。';

  @override
  String get settingsAutomaticDisplayPowerDescription => '在一段时间无活动后关闭显示器。';

  @override
  String get settingsAutomaticDisplayPowerTitle => '自动关闭显示器';

  @override
  String get settingsAutomaticDisplayPowerToggle => '自动关闭显示器';

  @override
  String get settingsAutomaticDisplayPowerToggleDescription =>
      '检测到键盘或指针活动时，计时器会重置。';

  @override
  String get settingsAvailable => '可用';

  @override
  String get settingsAvailableNetworksDescription => '附近和已保存的 Wi-Fi 网络。';

  @override
  String get settingsAvailableNetworksTitle => '可用网络';

  @override
  String get settingsBatteryChargeCycles => '充电循环';

  @override
  String get settingsBatteryChargeEnd => '停止';

  @override
  String get settingsBatteryChargeLevel => '电量';

  @override
  String get settingsBatteryChargeLimit => '充电限制';

  @override
  String get settingsBatteryChargeLimitDescription => '限制充满电量，以减少电池损耗。';

  @override
  String settingsBatteryChargeLimitEndDescription(int percent) {
    return '充至 $percent% 时停止，以减少电池损耗。';
  }

  @override
  String get settingsBatteryChargeLimitLevelsReadOnly =>
      '阈值由系统提供，在 UPower 中为只读。';

  @override
  String get settingsBatteryChargeLimitOptimizedDescription =>
      '由固件选择有助于保护电池的充电方式。';

  @override
  String settingsBatteryChargeLimitStartEndDescription(int start, int end) {
    return '低于 $start% 时恢复充电，达到 $end% 时停止，以减少电池损耗。';
  }

  @override
  String get settingsBatteryChargeStart => '开始';

  @override
  String get settingsBatteryCritical => '电池电量严重不足';

  @override
  String get settingsBatteryDevice => '设备';

  @override
  String settingsBatteryDuration(int hours, int minutes) {
    return '$hours 小时 $minutes 分钟';
  }

  @override
  String get settingsBatteryEmpty => '电量耗尽';

  @override
  String get settingsBatteryFirmwareOptimized => '固件优化';

  @override
  String get settingsBatteryFullCapacity => '充满容量';

  @override
  String settingsBatteryFullCapacityValue(String full, String design) {
    return '$full / $design Wh';
  }

  @override
  String get settingsBatteryFullyCharged => '已充满';

  @override
  String get settingsBatteryHealth => '健康度';

  @override
  String get settingsBatteryInformationTitle => '电池信息';

  @override
  String get settingsBatteryLeadAcid => '铅酸';

  @override
  String get settingsBatteryLithiumIon => '锂离子';

  @override
  String get settingsBatteryLithiumIronPhosphate => '磷酸铁锂';

  @override
  String get settingsBatteryLithiumPolymer => '锂聚合物';

  @override
  String get settingsBatteryLoading => '正在读取电池信息…';

  @override
  String get settingsBatteryLow => '电池电量低';

  @override
  String get settingsBatteryNickelCadmium => '镍镉';

  @override
  String get settingsBatteryNickelMetalHydride => '镍氢';

  @override
  String get settingsBatteryNoSystemBattery => '未检测到系统电池。';

  @override
  String get settingsBatteryOnBatteryPower => '使用电池供电';

  @override
  String get settingsBatteryPendingCharge => '等待充电';

  @override
  String get settingsBatteryPendingDischarge => '等待放电';

  @override
  String get settingsBatteryPluggedIn => '已接通电源';

  @override
  String get settingsBatteryPowerRate => '功率';

  @override
  String get settingsBatteryRefreshing => '正在刷新…';

  @override
  String get settingsBatterySerial => '序列号';

  @override
  String get settingsBatteryServiceUnavailable => 'UPower 电池信息不可用。';

  @override
  String get settingsBatteryStoredEnergy => '当前电量';

  @override
  String get settingsBatteryTechnology => '电池类型';

  @override
  String get settingsBatteryTemperature => '温度';

  @override
  String get settingsBatteryTimeRemaining => '剩余时间';

  @override
  String get settingsBatteryTimeToFull => '充满所需时间';

  @override
  String get settingsBatteryUnknownDevice => '系统电池';

  @override
  String get settingsBatteryUpdateFailed => 'UPower 无法刷新或更改电池设置。';

  @override
  String get settingsBatteryVoltage => '电压';

  @override
  String settingsBatteryWattHours(String value) {
    return '$value Wh';
  }

  @override
  String get settingsBackdropBlur => '背景模糊';

  @override
  String get settingsBackdropBlurDescription => '柔化半透明窗口和面板后的内容。质量越高，GPU 占用越多。';

  @override
  String get settingsBackdropBlurEnabled => '启用背景模糊';

  @override
  String get settingsBackdropBlurEnabledDescription => '仅在透明内容能够显示下方桌面的位置进行模糊。';

  @override
  String get settingsBackdropBlurIntensity => '模糊质量';

  @override
  String get settingsBackdropBlurLevelShitty => '糟糕';

  @override
  String get settingsBackdropBlurLevelFast => '快速';

  @override
  String get settingsBackdropBlurLevelGood => '良好';

  @override
  String get settingsBackdropBlurLevelBest => '最佳';

  @override
  String get settingsBackdropBlurOpacityThreshold => '模糊的最低像素不透明度';

  @override
  String get settingsBackdropDimming => '背景变暗';

  @override
  String get settingsBarGeometryDescription => '调整桌面系统栏预留的空间。';

  @override
  String get settingsBarGeometryTitle => '系统栏尺寸';

  @override
  String get settingsBarThickness => '系统栏厚度';

  @override
  String get settingsBluetoothAdapterDescription => '当前适配器';

  @override
  String get settingsBluetoothDescription => '管理蓝牙并连接已配对或附近的设备。';

  @override
  String get settingsBluetoothDevicesDescription => '已配对和附近的蓝牙设备。';

  @override
  String get settingsBluetoothDevicesTitle => '设备';

  @override
  String get settingsBluetoothEnabled => '蓝牙已启用';

  @override
  String get settingsBluetoothEnabledDescription => '允许 Denial 发现并连接蓝牙设备。';

  @override
  String get settingsBluetoothRadioTitle => '蓝牙无线电';

  @override
  String get settingsBluetoothSection => '蓝牙';

  @override
  String get settingsBluetoothTitle => '蓝牙设备。';

  @override
  String get settingsBluetoothUnavailable => '蓝牙控件不可用。';

  @override
  String get settingsBrightness => '亮度';

  @override
  String get settingsCardOpacity => '卡片不透明度';

  @override
  String get settingsClockScale => '时钟缩放';

  @override
  String get settingsCloseEffectExplosion => '爆炸';

  @override
  String get settingsCloseEffectFade => '淡出';

  @override
  String get settingsCloseEffectImplode => '内爆';

  @override
  String get settingsCloseEffectNone => '无';

  @override
  String get settingsColorPickerCloseSemanticsLabel => '关闭颜色选择器';

  @override
  String get settingsColorPickerDone => '完成';

  @override
  String get settingsColorPickerInstructions => '拖动以选择颜色。使用方向键进行微调。';

  @override
  String get settingsColorPickerReset => '重置';

  @override
  String get settingsColorPickerRouteLabel => 'Shell 强调色选择器';

  @override
  String get settingsColorPickerTitle => '强调色';

  @override
  String get settingsColorWheelNextHue => '下一个色相';

  @override
  String get settingsColorWheelPreviousHue => '上一个色相';

  @override
  String get settingsColorWheelSemanticsLabel => 'Shell 强调色';

  @override
  String get settingsConnect => '连接';

  @override
  String get settingsConnected => '已连接';

  @override
  String get settingsConnectedDisplaysDescription => '每个输出的分辨率、刷新率和缩放。';

  @override
  String get settingsConnectedDisplaysTitle => '已连接显示器';

  @override
  String get settingsCursorSize => '光标大小';

  @override
  String get settingsCursorTitle => '光标';

  @override
  String get settingsCursorTheme => '光标主题';

  @override
  String get settingsCursorImport => '导入光标 ZIP';

  @override
  String get settingsCursorImporting => '正在导入…';

  @override
  String get settingsCursorImportFailed => '无法导入光标主题。';

  @override
  String get settingsCursorRemove => '移除导入的光标主题';

  @override
  String get settingsCursorRemoveFailed => '无法移除导入的光标主题。';

  @override
  String get settingsCursorAllowApplications => '允许应用显示自己的光标';

  @override
  String get settingsCursorAllowApplicationsDescription =>
      'Wayland 和 X11 应用可以提供光标图像。关闭后将始终使用所选的 Denial 主题。';

  @override
  String get settingsDashboardOverlayDescription => '设置桌面仪表板的位置。';

  @override
  String get settingsDashboardOverlayTitle => '仪表板';

  @override
  String get settingsDisconnect => '断开连接';

  @override
  String get settingsApplying => '正在应用…';

  @override
  String get settingsApplyDisplayConfiguration => '应用更改';

  @override
  String get settingsDisplayApplyPersistentHint =>
      '保留更改后会更新当前会话和 outputs.conf。';

  @override
  String get settingsDisplayApplySessionHint => '保留更改后仅用于当前会话。';

  @override
  String get settingsDisplayConfirmationTitle => '保留这些显示设置吗？';

  @override
  String settingsDisplayConfirmationMessage(int seconds) {
    return '将在 $seconds 秒后自动恢复之前的显示设置。';
  }

  @override
  String get settingsDisplayKeepChanges => '保留更改';

  @override
  String get settingsDisplayRevertNow => '立即恢复';

  @override
  String get settingsDisplayArrangementSemantics => '显示器排列编辑器';

  @override
  String get settingsDisplayCanvasPanHint => '拖动空白区域以移动画布。使用鼠标滚轮进行缩放。';

  @override
  String get settingsDisplayCanvasPanSemantics => '可平移的显示器画布';

  @override
  String get settingsDisplayArrangementTitle => '显示器配置';

  @override
  String get settingsDisplayBrightnessDescription => '调节主显示器亮度。';

  @override
  String get settingsDisplayBrightnessTitle => '亮度';

  @override
  String settingsDisplayDetails(
    int width,
    int height,
    String refreshRate,
    String scale,
  ) {
    return '$width × $height · $refreshRate Hz · $scale×';
  }

  @override
  String get settingsDisplayInformationUnavailable => '显示信息不可用。';

  @override
  String get settingsDisplaysDescription => '查看已连接的输出并控制屏幕亮度。';

  @override
  String get settingsDisplaysSection => '显示器与视频';

  @override
  String get settingsDisplaysTitle => '显示器与视频。';

  @override
  String settingsDisplayPosition(int x, int y) {
    return '位置 $x, $y';
  }

  @override
  String get settingsDisplayPrimary => '主显示器';

  @override
  String get settingsDisplayPrimaryAutomatic => '自动（最高刷新率）';

  @override
  String get settingsDisplayPrimaryHint =>
      'Shell 界面会在主显示器上打开。自动模式会使用刷新率最高的已连接显示器。';

  @override
  String get settingsDisplayRefreshRate => '刷新率';

  @override
  String get settingsDisplayResolution => '分辨率';

  @override
  String get settingsDisplayRotation => '旋转';

  @override
  String get settingsDisplayRotationNormal => '横向';

  @override
  String get settingsDisplayRotation90 => '顺时针 90°';

  @override
  String get settingsDisplayRotation180 => '倒置';

  @override
  String get settingsDisplayRotation270 => '逆时针 90°';

  @override
  String get settingsDisplayScale => '缩放';

  @override
  String get settingsDisplayVariableRefreshRate => '可变刷新率 (VRR)';

  @override
  String get settingsDisplayVariableRefreshRateDescription =>
      '使此显示器的刷新率与渲染内容相匹配。';

  @override
  String get settingsDisplayZoomFit => '适应所有显示器';

  @override
  String get settingsDisplayZoomIn => '放大';

  @override
  String settingsDisplayZoomLevel(int percent) {
    return '画布缩放 $percent%';
  }

  @override
  String get settingsDisplayZoomOut => '缩小';

  @override
  String get settingsLoadingDisplays => '正在加载显示器配置…';

  @override
  String get settingsMonitorDragHint => '拖动以排列，或使用方向键移动。';

  @override
  String settingsMonitorSemantics(String name) {
    return '显示器 $name';
  }

  @override
  String get settingsEdgeDistance => '边缘距离';

  @override
  String get settingsFocusedWindows => '聚焦窗口';

  @override
  String get settingsFocusedWindowBorder => '高亮聚焦窗口边框';

  @override
  String get settingsFocusedWindowBorderDescription =>
      '关闭后，聚焦与未聚焦窗口将使用相同的边框颜色。';

  @override
  String get settingsHeaderContext => 'DENIAL / 系统';

  @override
  String get settingsHeaderLogoSemanticsLabel => 'Denial';

  @override
  String get settingsHeight => '高度';

  @override
  String get settingsHoverTrigger => '悬停屏幕边缘时打开';

  @override
  String get settingsHoverTriggerDescription => '当指针到达对应屏幕边缘时显示此面板。';

  @override
  String get settingsHudOverlayDescription => '设置音量和亮度反馈的位置。';

  @override
  String get settingsHudOverlayTitle => '系统级显示';

  @override
  String get settingsIdleInhibitDescription => '遵循应用暂时阻止显示器关闭的请求。';

  @override
  String get settingsIdleInhibitSemantics => '应用可以让显示器保持唤醒';

  @override
  String get settingsInactivityTimeout => '无活动超时';

  @override
  String get settingsLauncherOverlayDescription => '设置应用启动器的位置。';

  @override
  String get settingsLauncherOverlayTitle => '应用';

  @override
  String get settingsLanguageDescription => '“跟随系统”会使用桌面语言。更改会立即生效。';

  @override
  String get settingsLanguageEnglish => 'English';

  @override
  String get settingsLanguageInterfaceTitle => '界面语言';

  @override
  String get settingsLanguageSection => '语言';

  @override
  String get settingsLanguageSelectorSemantics => 'Denial 界面语言';

  @override
  String get settingsLanguageSimplifiedChinese => '简体中文';

  @override
  String get settingsLanguageSystemDefault => '跟随系统';

  @override
  String get settingsLanguageTitle => '选择 Denial 使用的语言。';

  @override
  String get settingsKeyboardSection => '输入';

  @override
  String get settingsKeyboardTitle => '配置 Flutter、Wayland 和 Xwayland 共用的物理键盘。';

  @override
  String get settingsKeyboardLayoutsTitle => '布局与变体';

  @override
  String get settingsKeyboardLayoutsDescription =>
      '按切换顺序输入布局。变体写在冒号后，例如 us, de:nodeadkeys。';

  @override
  String get settingsKeyboardLayoutsLabel => '布局';

  @override
  String get settingsKeyboardLayoutsHint => 'us, de:nodeadkeys';

  @override
  String get settingsKeyboardOptionsLabel => 'XKB 选项';

  @override
  String get settingsKeyboardOptionsHint => 'compose:menu, caps:escape';

  @override
  String get settingsKeyboardOptionsDescription =>
      '用逗号分隔选项，可启用 Compose、其他布局切换快捷键、Caps 重映射等 XKB 行为。';

  @override
  String get settingsKeyboardRepeatTitle => '按键重复';

  @override
  String get settingsKeyboardRepeatDelay => '延迟';

  @override
  String get settingsKeyboardRepeatRate => '速率';

  @override
  String get settingsKeyboardSwitchingTitle => '布局切换';

  @override
  String get settingsKeyboardActiveLayout => '当前布局';

  @override
  String get settingsKeyboardSwitchingShortcut =>
      'Super+空格切换到下一个布局；同时按 Shift 切换到上一个。';

  @override
  String get settingsKeyboardApply => '应用键盘设置';

  @override
  String get settingsKeyboardApplying => '正在应用…';

  @override
  String get settingsKeyboardLoading => '正在读取合成器键盘配置…';

  @override
  String get settingsKeyboardInvalidLayouts => '请输入至少一个有效的 XKB 布局。';

  @override
  String get settingsTouchpadSection => '输入';

  @override
  String get settingsTouchpadTitle => '在整个桌面上使用触控板。';

  @override
  String get settingsTouchpadTapToClick => '轻触点击';

  @override
  String get settingsTouchpadTapToClickDescription => '轻触触控板即可按下鼠标主键。';

  @override
  String get settingsTouchpadNaturalScroll => '反向双指滚动';

  @override
  String get settingsTouchpadNaturalScrollDescription => '让内容沿手指移动的方向滚动。';

  @override
  String get settingsTouchpadScrollSpeed => '手指滚动速度';

  @override
  String get settingsShortcutsSection => '快捷键';

  @override
  String get settingsShortcutsTitle => '选择按下快捷键时 Denial 执行的操作。';

  @override
  String settingsShortcutsConfigured(int count) {
    return '$count 个快捷键';
  }

  @override
  String get settingsShortcutsAdd => '添加快捷键';

  @override
  String get settingsShortcutsLoading => '正在从合成器读取快捷键…';

  @override
  String get settingsShortcutsUnavailable => '合成器快捷键配置不可用。';

  @override
  String get settingsShortcutsRetry => '重试';

  @override
  String get settingsShortcutsEmpty => '尚未配置快捷键。添加一个即可更快触发操作。';

  @override
  String settingsShortcutsRowSemantics(String shortcut, String action) {
    return '$shortcut，$action';
  }

  @override
  String settingsShortcutsDeleteTooltip(String shortcut) {
    return '删除 $shortcut';
  }

  @override
  String get settingsShortcutEditorAddTitle => '添加快捷键';

  @override
  String get settingsShortcutEditorEditTitle => '编辑快捷键';

  @override
  String get settingsShortcutEditorDescription => '输入快捷键并选择其运行内容，保存前由合成器检查。';

  @override
  String get settingsShortcutEditorShortcutLabel => '快捷键';

  @override
  String get settingsShortcutEditorShortcutHint => 'Super+K';

  @override
  String get settingsShortcutEditorShortcutExample =>
      '示例：Super+K · Ctrl+Alt+Backspace · ThreeFingerSwipeLeft';

  @override
  String get settingsShortcutEditorSupportedInputs => '支持的输入';

  @override
  String get settingsShortcutEditorTargetLabel => '运行';

  @override
  String get settingsShortcutEditorTargetAction => 'Denial 操作';

  @override
  String get settingsShortcutEditorTargetApplication => '应用';

  @override
  String get settingsShortcutEditorTargetProgram => '程序';

  @override
  String get settingsShortcutEditorTargetShell => 'Shell 命令';

  @override
  String get settingsShortcutEditorProgramDescription =>
      '直接运行程序，不经过 Shell。每个参数都会按原样传递。';

  @override
  String get settingsShortcutEditorProgramLabel => '程序';

  @override
  String get settingsShortcutEditorProgramHint => 'foot';

  @override
  String get settingsShortcutEditorArgumentsLabel => '参数';

  @override
  String get settingsShortcutEditorAddArgument => '添加参数';

  @override
  String get settingsShortcutEditorNoArguments => '无参数';

  @override
  String settingsShortcutEditorArgumentLabel(int index) {
    return '参数 $index';
  }

  @override
  String get settingsShortcutEditorArgumentHint => '--option';

  @override
  String settingsShortcutEditorRemoveArgument(int index) {
    return '移除参数 $index';
  }

  @override
  String get settingsShortcutEditorShellDescription =>
      '通过 sh -c 运行一条命令。支持 Shell 变量、管道、重定向和命令串联。';

  @override
  String get settingsShortcutEditorShellCommandLabel => 'Shell 命令';

  @override
  String get settingsShortcutEditorShellCommandHint =>
      'grim -g \"\$(slurp)\" ~/Pictures/capture.png';

  @override
  String get settingsShortcutEditorChooseAction => '选择操作';

  @override
  String get settingsShortcutEditorChooseApplication => '选择应用';

  @override
  String settingsShortcutApplicationTarget(String desktopFileId) {
    return '应用 · $desktopFileId';
  }

  @override
  String get settingsShortcutEditorValidating => '正在通过合成器检查…';

  @override
  String settingsShortcutEditorValid(String shortcut) {
    return '识别为 $shortcut';
  }

  @override
  String settingsShortcutEditorConflict(String shortcut, String action) {
    return '$shortcut 已分配给“$action”。';
  }

  @override
  String get settingsShortcutEditorSearch => '搜索';

  @override
  String get settingsShortcutEditorNoResults => '没有匹配的项目。';

  @override
  String get settingsShortcutEditorBack => '返回快捷键编辑器';

  @override
  String get settingsShortcutEditorDone => '完成';

  @override
  String get settingsShortcutEditorCancel => '取消';

  @override
  String get settingsShortcutEditorSave => '保存';

  @override
  String get settingsShortcutEditorSaving => '正在保存…';

  @override
  String get settingsShortcutEditorDelete => '删除';

  @override
  String get settingsShortcutGestureThreeFingerSwipeUp => '三指向上轻扫';

  @override
  String get settingsShortcutGestureThreeFingerSwipeLeft => '三指向左轻扫';

  @override
  String get settingsShortcutGestureThreeFingerSwipeRight => '三指向右轻扫';

  @override
  String get settingsShortcutInputCategoryModifier => '修饰键';

  @override
  String get settingsShortcutInputCategoryNavigation => '导航';

  @override
  String get settingsShortcutInputCategoryEditing => '编辑';

  @override
  String get settingsShortcutInputCategoryPunctuation => '标点';

  @override
  String get settingsShortcutInputCategoryFunction => '功能键';

  @override
  String get settingsShortcutInputCategoryMedia => '媒体';

  @override
  String get settingsShortcutInputCategoryHardware => '硬件';

  @override
  String get settingsShortcutInputCategorySpecial => '特殊键';

  @override
  String get settingsShortcutInputCategoryGesture => '手势';

  @override
  String get settingsShortcutActionShutdown => '关机';

  @override
  String get settingsShortcutActionOpenApplications => '打开应用列表';

  @override
  String get settingsShortcutActionOpenDashboard => '打开仪表板';

  @override
  String get settingsShortcutActionOpenSettings => '打开设置';

  @override
  String get settingsShortcutActionOpenOverview => '打开概览';

  @override
  String get settingsShortcutActionToggleVerticalMaximize => '垂直最大化';

  @override
  String get settingsShortcutActionWindowSwitcher => '切换窗口';

  @override
  String get settingsShortcutActionOpenClipboard => '打开剪贴板';

  @override
  String get settingsShortcutActionCaptureRegion => '截取区域';

  @override
  String get settingsShortcutActionCloseWindow => '关闭窗口';

  @override
  String get settingsShortcutActionMinimizeWindow => '最小化窗口';

  @override
  String get settingsShortcutActionMinimizeAllWindows => '最小化所有窗口';

  @override
  String get settingsShortcutActionToggleMaximize => '最大化或还原';

  @override
  String get settingsShortcutActionToggleFullscreen => '进入或退出全屏';

  @override
  String get settingsShortcutActionReleasePointer => '释放指针';

  @override
  String get settingsShortcutActionLockScreen => '锁定屏幕';

  @override
  String get settingsShortcutActionVolumeUp => '增大音量';

  @override
  String get settingsShortcutActionVolumeDown => '减小音量';

  @override
  String get settingsShortcutActionVolumeMute => '静音或取消静音';

  @override
  String get settingsShortcutActionBrightnessUp => '提高亮度';

  @override
  String get settingsShortcutActionBrightnessDown => '降低亮度';

  @override
  String get settingsShortcutActionNextKeyboardLayout => '下一个键盘布局';

  @override
  String get settingsShortcutActionPreviousKeyboardLayout => '上一个键盘布局';

  @override
  String get settingsLayoutDescription => '控制普通窗口和最大化窗口周围的预留间距。';

  @override
  String get settingsLayoutSection => '桌面布局';

  @override
  String get settingsLayoutTitle => '给每个窗口留出呼吸空间。';

  @override
  String get settingsLiveBadge => '实时';

  @override
  String get settingsLiveChangesSemanticsLabel => '更改会实时应用';

  @override
  String get settingsLoadingAudio => '正在加载应用音频…';

  @override
  String get settingsLockBackdropDescription => '控制锁定时的壁纸暗度和模糊。';

  @override
  String get settingsLockBackdropTitle => '背景';

  @override
  String get settingsLockInformationDescription => '选择登录前仍可显示的有用信息。';

  @override
  String get settingsLockInformationTitle => '桌面状态';

  @override
  String get settingsLockMotionDescription => '在桌面锁屏出现时播放动画。';

  @override
  String get settingsLockMotionTitle => '锁屏动效';

  @override
  String get settingsLockPreviewDate => '7月23日 星期四';

  @override
  String get settingsLockPreviewSemantics => '锁屏预览';

  @override
  String get settingsLockPreviewStatus => 'CPU 18% · GPU 12% · 52°C';

  @override
  String get settingsLockPreviewTime => '22:41';

  @override
  String get settingsLockScreenDescription => '主显示器呈现专门的登录界面，辅助显示器则保持安静并显示信息。';

  @override
  String get settingsLockScreenSection => '锁屏';

  @override
  String get settingsLockScreenTitle => '桌面锁屏，而不是拉伸的手机界面。';

  @override
  String get settingsMasterOutputDescription => '设置当前桌面的输出音量。';

  @override
  String get settingsMasterOutputTitle => '主输出';

  @override
  String get settingsMaximizedSpacingDescription => '在最大化窗口周围保留少量边距。';

  @override
  String get settingsMaximizedSpacingTitle => '最大化间距';

  @override
  String get settingsDeveloperAutoReloadDescription =>
      '让 Denial 监视工作区，并在源代码更改成功后重新加载。需要安装原生工具桥接。';

  @override
  String get settingsDeveloperAutoReloadTitle => '文件更改时重新加载';

  @override
  String get settingsDeveloperBuildOptimized => '构建并激活优化版本';

  @override
  String get settingsDeveloperBuildRecoveryDescription =>
      '将当前工作区提升为优化版 Shell，或在不重启 Wayland 会话的情况下恢复到已知可用的 UI。';

  @override
  String get settingsDeveloperBuildRecoveryTitle => '构建与恢复';

  @override
  String get settingsDeveloperDescription =>
      '编辑完整的 Flutter 桌面、实时重新加载，然后提升为优化构建。';

  @override
  String get settingsDeveloperDiagnosticsTitle => '连接与诊断';

  @override
  String get settingsDeveloperEditorAttachDescription =>
      '在 VSCodium 中打开 Flutter Shell 工作区，在“运行和调试”中选择“Attach to Denial live UI”，然后保存修改的 Dart 文件以重新加载桌面。原生合成器更改需要正常重建。';

  @override
  String get settingsDeveloperEnableDescription =>
      '运行所选工作区并开放 Dart VM 服务，供 VSCodium 和 Flutter 工具使用。';

  @override
  String get settingsDeveloperEnableTitle => '启用实时 UI 开发';

  @override
  String get settingsDeveloperGeneration => '代次';

  @override
  String get settingsDeveloperHotReload => '热重载';

  @override
  String get settingsDeveloperHotRestart => '热重启';

  @override
  String get settingsDeveloperLiveControlsTitle => '实时会话';

  @override
  String get settingsDeveloperModeCustom => '自定义优化版';

  @override
  String get settingsDeveloperModeLive => '实时开发';

  @override
  String get settingsDeveloperModeOfficial => '官方优化版';

  @override
  String get settingsDeveloperModeUnavailable => '正在连接';

  @override
  String get settingsDeveloperNoDiagnostics => '没有诊断信息。';

  @override
  String get settingsDeveloperPerformanceWarning =>
      '实时开发使用 JIT Flutter 引擎和调试检查。恢复优化构建前，帧节奏和游戏性能会较低。';

  @override
  String get settingsDeveloperRefreshStatus => '刷新状态';

  @override
  String get settingsDeveloperRestoreOfficial => '恢复官方 UI';

  @override
  String get settingsDeveloperRevertLastWorking => '恢复上一个可用版本';

  @override
  String get settingsDeveloperRuntimeTitle => 'Flutter Shell 运行时';

  @override
  String get settingsDeveloperSection => '开发者';

  @override
  String get settingsDeveloperSetupAction => '创建并启动可编辑 UI';

  @override
  String get settingsDeveloperSetupDescription =>
      '从 GitHub 克隆与版本匹配的 Denial 源码到 ~/DenialUI，使用固定工具链准备，然后进入实时开发。';

  @override
  String get settingsDeveloperSetupRunning => '正在准备可编辑 UI。准备就绪后 Shell 会自动切换…';

  @override
  String get settingsDeveloperSetupUnavailable =>
      '安装 denial-ui-development 以启用自动设置。';

  @override
  String get settingsDeveloperUseWorkspace => '使用此工作区';

  @override
  String get settingsDeveloperVmServiceTitle => 'Dart VM 服务';

  @override
  String get settingsDeveloperWaitingForStatus => '正在等待原生运行时状态…';

  @override
  String get settingsDeveloperWorkspaceDescription =>
      '选择包含 pubspec.yaml 和 lib/main.dart 的 Flutter 项目。源代码更改可以替换不需要新原生协议的任何 Shell UI。';

  @override
  String get settingsDeveloperWorkspaceFieldLabel => 'Flutter 源码工作区';

  @override
  String get settingsDeveloperWorkspaceHint => '/home/you/DenialUI/dart_shell';

  @override
  String get settingsDeveloperWorkspaceNotReady => '需要设置';

  @override
  String get settingsDeveloperWorkspaceReady => '就绪';

  @override
  String get settingsDeveloperWorkspaceTitle => '源码工作区';

  @override
  String get settingsEnvironmentAdd => '添加';

  @override
  String get settingsEnvironmentAddedStatus => '已添加到启动的应用';

  @override
  String get settingsEnvironmentAddModeDescription =>
      'Denial 执行应用时注入字面值。空值会保留为空字符串。';

  @override
  String get settingsEnvironmentAllApplications => '所有应用';

  @override
  String get settingsEnvironmentAllApplicationsDescription => '默认启动环境';

  @override
  String settingsEnvironmentApplicationInherited(int count) {
    return '继承 $count 条所有应用规则';
  }

  @override
  String get settingsEnvironmentApplicationSearchHint => '搜索应用或桌面 ID';

  @override
  String get settingsEnvironmentApplicationsTitle => '应用';

  @override
  String get settingsEnvironmentApplicationsUnavailable => '无法加载已安装的应用。';

  @override
  String get settingsEnvironmentBackToApplications => '返回应用列表';

  @override
  String get settingsEnvironmentCancel => '取消';

  @override
  String get settingsEnvironmentClearScope => '清除';

  @override
  String settingsEnvironmentDeleteVariable(String variable) {
    return '删除 $variable';
  }

  @override
  String settingsEnvironmentEditVariable(String variable) {
    return '编辑 $variable';
  }

  @override
  String get settingsEnvironmentEditorDescription =>
      '设置一个值；留空会传递空字符串；选择“移除”则不会把该变量传给子进程。';

  @override
  String settingsEnvironmentEditorEditTitle(String variable) {
    return '编辑 $variable';
  }

  @override
  String get settingsEnvironmentEditorTitle => '添加覆盖项';

  @override
  String get settingsEnvironmentEmptyDescription => '在上方添加变量，以更改之后启动的应用环境。';

  @override
  String get settingsEnvironmentEmptyTitle => '没有覆盖项';

  @override
  String get settingsEnvironmentEmptyValue => '空字符串';

  @override
  String get settingsEnvironmentHiddenStatus => '已对启动的应用隐藏';

  @override
  String get settingsEnvironmentHide => '隐藏';

  @override
  String get settingsEnvironmentHideModeDescription =>
      '在 exec 前移除继承的变量。应用会像从未导出过该名称一样运行。';

  @override
  String get settingsEnvironmentNameDuplicate => '该变量已有覆盖项。';

  @override
  String get settingsEnvironmentNameHint => '例如 MOZ_ENABLE_WAYLAND';

  @override
  String get settingsEnvironmentNameInvalid => '仅使用字母、数字和下划线，并以字母或下划线开头。';

  @override
  String get settingsEnvironmentNameLabel => '变量名';

  @override
  String get settingsEnvironmentNameRequired => '请输入变量名。';

  @override
  String get settingsEnvironmentOverridesDefault => '覆盖所有应用规则';

  @override
  String get settingsEnvironmentModeAdd => '添加变量';

  @override
  String get settingsEnvironmentModeHide => '隐藏变量';

  @override
  String get settingsEnvironmentRemoveDescription => 'Denial 会在启动应用前移除继承的这个变量。';

  @override
  String get settingsEnvironmentRemoveLabel => '从启动的应用中移除';

  @override
  String get settingsEnvironmentRemovedValue => '已从子进程环境中移除';

  @override
  String get settingsEnvironmentScopeDescription =>
      '这些覆盖项仅应用于由 Denial 启动的应用和快捷键命令，并在之后的启动中生效；不会影响 XDG 自启动项、systemd 服务、D-Bus 服务或 Denial 本身。';

  @override
  String get settingsEnvironmentScopeTitle => '启动范围';

  @override
  String get settingsEnvironmentSection => '应用';

  @override
  String get settingsEnvironmentTitle => '自定义由 Denial 启动的应用环境。';

  @override
  String get settingsEnvironmentUpdate => '更新变量';

  @override
  String get settingsEnvironmentUnavailableApplication => '不可用的应用';

  @override
  String get settingsEnvironmentValueHint => '例如 1';

  @override
  String get settingsEnvironmentValueLabel => '值';

  @override
  String get settingsEnvironmentValueNul => '值不能包含 NUL 字符。';

  @override
  String get settingsEnvironmentValueTooLong => '该值过长。';

  @override
  String settingsEnvironmentVariablesStatus(int count) {
    return '已配置 $count 项';
  }

  @override
  String get settingsEnvironmentVariablesTitle => '已配置的覆盖项';

  @override
  String settingsMinutes(int minutes) {
    return '$minutes 分钟';
  }

  @override
  String get settingsNavigationAbout => '关于';

  @override
  String get settingsNavigationAnimations => '动画';

  @override
  String get settingsNavigationAppearance => '外观';

  @override
  String get settingsNavigationAudio => '音频';

  @override
  String get settingsNavigationBluetooth => '蓝牙';

  @override
  String get settingsNavigationDesktopLayout => '桌面布局';

  @override
  String get settingsNavigationDeveloper => '开发者';

  @override
  String get settingsNavigationEnvironment => '应用环境';

  @override
  String get settingsNavigationDisplays => '显示器与视频';

  @override
  String get settingsNavigationLanguage => '语言';

  @override
  String get settingsNavigationKeyboard => '键盘';

  @override
  String get settingsNavigationTouchpad => '触控板';

  @override
  String get settingsNavigationShortcuts => '快捷键';

  @override
  String get settingsNavigationLockScreen => '锁屏';

  @override
  String get settingsNavigationNetwork => '网络';

  @override
  String get settingsNavigationOverlays => '浮层';

  @override
  String get settingsNavigationPower => '电源';

  @override
  String get settingsNavigationSection => '设置';

  @override
  String get settingsNetworkDescription => '管理 Wi-Fi 并连接附近的网络。';

  @override
  String get settingsNetworkSection => '网络';

  @override
  String get settingsNetworkStatusCaptivePortal => '需要登录';

  @override
  String get settingsNetworkStatusConnecting => '正在连接…';

  @override
  String get settingsNetworkStatusDisabled => 'Wi-Fi 已关闭';

  @override
  String get settingsNetworkStatusDisconnected => '已断开连接';

  @override
  String get settingsNetworkStatusLimited => '连接受限';

  @override
  String get settingsNetworkStatusLocal => '仅本地网络';

  @override
  String get settingsNetworkStatusOnline => '在线';

  @override
  String get settingsNetworkStatusUnavailable => '网络不可用';

  @override
  String get settingsNetworkTitle => '网络连接。';

  @override
  String get settingsNetworkUnavailable => '网络控件不可用。';

  @override
  String get settingsNoApplicationAudio => '没有应用正在播放音频。';

  @override
  String get settingsNoBluetoothDevices => '未找到蓝牙设备。';

  @override
  String get settingsNoNetworks => '未找到网络。';

  @override
  String get settingsNotificationOverlayDescription => '设置通知横幅的位置。';

  @override
  String get settingsNotificationOverlayTitle => '通知';

  @override
  String get settingsOneHour => '1 小时';

  @override
  String get settingsOuterPadding => '外边距';

  @override
  String get settingsOutputVolume => '输出音量';

  @override
  String get settingsOverlaysDescription => '选择启动器、通知和系统反馈的位置与大小。';

  @override
  String get settingsOverlaysSection => '浮层';

  @override
  String get settingsOverlaysTitle => '将 Shell 控件放到合适的位置。';

  @override
  String get settingsPaired => '已配对';

  @override
  String get settingsPanelMotionDescription => '调整启动器和仪表板过渡的速度与移动距离。';

  @override
  String get settingsPanelMotionTitle => '面板动效';

  @override
  String get settingsPanelOpacity => '面板不透明度';

  @override
  String get settingsPanelTravel => '面板移动距离';

  @override
  String get settingsPasswordRequired => '需要密码';

  @override
  String settingsPercent(int percent) {
    return '$percent%';
  }

  @override
  String settingsPixels(int pixels) {
    return '$pixels 像素';
  }

  @override
  String get settingsPowerDescription => '控制显示器超时行为和空闲抑制。';

  @override
  String get settingsPowerSection => '电源';

  @override
  String get settingsPowerTitle => '尊重工作流程的电源管理。';

  @override
  String get settingsRefresh => '刷新';

  @override
  String get settingsResetPage => '重置页面';

  @override
  String get settingsScan => '扫描';

  @override
  String get settingsScanning => '正在扫描…';

  @override
  String get settingsScreenAnchor => '屏幕锚点';

  @override
  String get settingsShapeDescription => '统一缩放窗口、面板、卡片和控件的所有圆角。';

  @override
  String get settingsShapeTitle => '形状';

  @override
  String get settingsCornerRoundness => '全局圆角';

  @override
  String get settingsColorSchemeTitle => '配色方案';

  @override
  String get settingsColorSchemeDark => '深色';

  @override
  String get settingsColorSchemeLight => '浅色';

  @override
  String get settingsColorSchemeNoPreference => '无偏好';

  @override
  String get settingsColorSchemeDescription => '在 Denial 和支持的应用中使用相同的配色方案。';

  @override
  String get settingsColorSchemeNoPreferenceDescription =>
      'Denial 保持默认深色外观，应用可自行选择配色方案。';

  @override
  String get settingsShellAccentChoose => '选择强调色';

  @override
  String get settingsShellAccentCustom => '自定义颜色';

  @override
  String get settingsShellAccentDescription => '强调色用于聚焦窗口、控件和活动的 Shell 界面。';

  @override
  String get settingsShellAccentTitle => 'Shell 强调色';

  @override
  String get settingsShellAccentWallpaper => '来自壁纸';

  @override
  String get settingsShowSystemStatus => '显示性能和电源状态';

  @override
  String get settingsShowSystemStatusDescription => '在桌面锁屏上显示 CPU、GPU、电池和温度信息。';

  @override
  String settingsSignalStrength(int strength) {
    return '信号：$strength%';
  }

  @override
  String get settingsStorageLocation => '设置存储在\n~/.config/denial/settings.json';

  @override
  String get settingsSystemBarCloneHint => '每个选中的显示器都有自己的系统栏。系统栏不会跨越显示器。';

  @override
  String get settingsSystemBarDescription => '将系统栏放在任意边缘，并在每个选中的显示器上显示独立副本。';

  @override
  String settingsSystemBarDisplayDetails(int width, int height, String scale) {
    return '$width × $height · $scale×';
  }

  @override
  String settingsSystemBarDisplayNotSelectedSemantics(String displayName) {
    return '$displayName 上未显示系统栏';
  }

  @override
  String settingsSystemBarDisplaySelectedSemantics(String displayName) {
    return '$displayName 上已显示系统栏';
  }

  @override
  String get settingsSystemBarDisplaysLabel => '显示器';

  @override
  String settingsSystemBarDisplaysSelected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已选择 $count 个显示器',
    );
    return '$_temp0';
  }

  @override
  String get settingsSystemBarEdgeBottom => '底部';

  @override
  String get settingsSystemBarEdgeLabel => '边缘';

  @override
  String get settingsSystemBarEdgeLeft => '左侧';

  @override
  String get settingsSystemBarEdgeRight => '右侧';

  @override
  String get settingsSystemBarEdgeTop => '顶部';

  @override
  String get settingsSystemBarLastDisplayHint => '移除此显示器前，请先选择另一个显示器。';

  @override
  String get settingsSystemBarMainDisplay => '主显示器';

  @override
  String get settingsSystemBarTitle => '桌面系统栏';

  @override
  String get settingsSystemBarUnavailable => '显示信息尚不可用。';

  @override
  String get settingsTwoHours => '2 小时';

  @override
  String get settingsUnfocusedWindows => '未聚焦窗口';

  @override
  String get settingsUseSystemWallpaper => '使用系统壁纸';

  @override
  String get settingsUseSystemWallpaperDescription => '锁屏会跟随壁纸更改和各输出的分配。';

  @override
  String get settingsWallpaperChoose => '选择壁纸';

  @override
  String get settingsWallpaperDescription => '选择在 Shell 后方和锁屏上显示的图像。';

  @override
  String get settingsWallpaperPreviewSemantics => '当前壁纸预览';

  @override
  String get settingsWallpaperTitle => '壁纸';

  @override
  String get settingsWidth => '宽度';

  @override
  String get settingsWifiEnabled => 'Wi-Fi 已启用';

  @override
  String get settingsWifiEnabledDescription => '允许 Denial 扫描并连接无线网络。';

  @override
  String get settingsWifiTitle => 'Wi-Fi';

  @override
  String get settingsWindowCloseEffectDescription => '选择桌面窗口关闭时使用的动画。';

  @override
  String get settingsWindowCloseEffectTitle => '窗口关闭效果';

  @override
  String get settingsWindowOpacityDescription => '控制聚焦和未聚焦窗口的不透明度。';

  @override
  String get settingsWindowOpacityTitle => '窗口不透明度';

  @override
  String shortDate(String weekday, int day, String month) {
    return '$month$day日 $weekday';
  }

  @override
  String statusBarLiveTime(String time) {
    return '$time · 实时';
  }

  @override
  String get statusUnknown => '未知';

  @override
  String get statusWaiting => '等待中';

  @override
  String temperatureCelsius(int temperature) {
    return '$temperature°C';
  }

  @override
  String get thermalSensorCpu => 'CPU';

  @override
  String get thermalSensorExp2 => 'EXP2';

  @override
  String get thermalSensorPmic => 'PMIC';

  @override
  String get thermalSensorSvooc => 'SVOOC';

  @override
  String timeHoursMinutes(String hour, String minute) {
    return '$hour:$minute';
  }

  @override
  String get valueUnavailable => '--.-';

  @override
  String voltageVolts(String voltage) {
    return '$voltage V';
  }

  @override
  String get volumeTitle => '音量';

  @override
  String get wallpaperAlignBottom => '底部';

  @override
  String get wallpaperAlignHorizontalCenter => '水平居中';

  @override
  String get wallpaperAlignLeft => '左侧';

  @override
  String get wallpaperAlignRight => '右侧';

  @override
  String get wallpaperAlignTop => '顶部';

  @override
  String get wallpaperAlignVerticalCenter => '垂直居中';

  @override
  String get wallpaperAllDisplays => '所有显示器';

  @override
  String get wallpaperApplyAllDisplays => '应用到所有显示器';

  @override
  String wallpaperApplyCandidate(String wallpaperName) {
    return '应用 $wallpaperName';
  }

  @override
  String wallpaperApplyDisplay(String displayName) {
    return '应用到 $displayName';
  }

  @override
  String get wallpaperCloseSelector => '关闭壁纸选择器';

  @override
  String get wallpaperDarkness => '壁纸暗度';

  @override
  String get wallpaperDarknessShort => '暗度';

  @override
  String get wallpaperDecodeError => '无法解码此壁纸。';

  @override
  String get wallpaperDefault => '默认';

  @override
  String wallpaperDimensions(int width, int height) {
    return '$width × $height';
  }

  @override
  String get wallpaperFinding => '正在查找壁纸…';

  @override
  String get wallpaperMobileBackToSelection => '返回壁纸选择';

  @override
  String get wallpaperMobileCenterPosition => '居中';

  @override
  String get wallpaperMobileChoose => '选择壁纸';

  @override
  String get wallpaperMobileDone => '完成';

  @override
  String get wallpaperMobileHideControls => '隐藏控件';

  @override
  String get wallpaperMobileHorizontalPosition => '水平';

  @override
  String get wallpaperMobilePosition => '位置';

  @override
  String get wallpaperMobilePositionHint => '拖动壁纸，然后微调其位置';

  @override
  String get wallpaperMobileShowControls => '显示控件';

  @override
  String get wallpaperMobileTitle => '壁纸';

  @override
  String get wallpaperMobileVerticalPosition => '垂直';

  @override
  String get wallpaperNoneFound => '未找到壁纸';

  @override
  String get wallpaperSearchHint => '搜索壁纸';

  @override
  String get wallpaperSearchSemantics => '搜索壁纸';

  @override
  String get wallpaperServiceUnavailable => '壁纸服务不可用';

  @override
  String get wallpaperSpanAlignment => '图像位置';

  @override
  String get wallpaperTarget => '目标';

  @override
  String get weekdayFriday => '星期五';

  @override
  String get weekdayMonday => '星期一';

  @override
  String get weekdaySaturday => '星期六';

  @override
  String get weekdaySunday => '星期日';

  @override
  String get weekdayThursday => '星期四';

  @override
  String get weekdayTuesday => '星期二';

  @override
  String get weekdayWednesday => '星期三';

  @override
  String get wifiAuthorizationMayBeRequired => '可能需要授权。';

  @override
  String get wifiCloseDetails => '关闭 Wi-Fi 详情';

  @override
  String wifiConnectNetwork(String networkName, String status, int strength) {
    return '连接到 $networkName，$status，信号 $strength%';
  }

  @override
  String wifiDisconnectNetwork(String networkName) {
    return '断开与 $networkName 的连接';
  }

  @override
  String get wifiDismissError => '关闭 Wi-Fi 错误';

  @override
  String wifiForgetNetwork(String networkName) {
    return '忘记 $networkName';
  }

  @override
  String get wifiHardwareBlocked => 'Wi-Fi 被硬件阻止';

  @override
  String get wifiHardwareBlockedDescription => '请打开无线硬件开关以继续。';

  @override
  String get wifiHardwareDisabled => 'Wi-Fi 硬件已禁用';

  @override
  String get wifiLimitedConnection => '连接受限';

  @override
  String get wifiLoadingService => '正在加载网络服务…';

  @override
  String get wifiLocalConnection => '本地网络';

  @override
  String get wifiLocalOnly => '仅本地';

  @override
  String wifiNamedStatus(String networkName, String status) {
    return '$networkName · $status';
  }

  @override
  String get wifiNoAdapter => '没有 Wi-Fi 适配器';

  @override
  String get wifiNoAdapterDescription => '适配器可用后，Wi-Fi 控件会出现。';

  @override
  String get wifiNoNetworks => '未找到网络';

  @override
  String get wifiNoNetworksDescription => '开始扫描以查找附近的网络。';

  @override
  String get wifiOff => 'Wi-Fi 已关闭';

  @override
  String get wifiOffDescription => '开启 Wi-Fi 以查看附近的网络。';

  @override
  String get wifiOperationFailed => 'Wi-Fi 无法完成请求。';

  @override
  String wifiPasswordField(String networkName) {
    return '$networkName 的密码';
  }

  @override
  String wifiPasswordFor(String networkName) {
    return '输入 $networkName 的密码';
  }

  @override
  String get wifiPasswordRequirements => '请输入至少包含 8 个字符的密码。';

  @override
  String get wifiPermissionLimited => '网络权限受限。';

  @override
  String get wifiSavedOutOfRange => '已保存 · 超出范围';

  @override
  String wifiSavedWithSecurity(String security) {
    return '已保存 · $security';
  }

  @override
  String get wifiScanNetworks => '扫描 Wi-Fi 网络';

  @override
  String get wifiScanningDescription => '附近的网络将自动出现。';

  @override
  String get wifiScanningNetworks => '正在扫描 Wi-Fi 网络…';

  @override
  String get wifiSecurityEnhancedOpen => '增强开放';

  @override
  String get wifiSecurityEnterprise => '企业级';

  @override
  String get wifiSecurityOpen => '开放';

  @override
  String get wifiSecurityUnsupported => '不支持的安全类型';

  @override
  String get wifiSecurityWep => 'WEP';

  @override
  String get wifiSecurityWpa3Personal => 'WPA3 个人版';

  @override
  String get wifiSecurityWpaPersonal => 'WPA/WPA2 个人版';

  @override
  String get wifiServiceUnavailable => '网络服务不可用';

  @override
  String get wifiServiceUnavailableDescription => '网络服务启动后，Wi-Fi 控件将恢复。';

  @override
  String get wifiServiceUnavailableShort => '网络不可用';

  @override
  String get wifiSignInRequired => '需要登录';

  @override
  String get wifiTurnOff => '关闭 Wi-Fi';

  @override
  String get wifiTurnOn => '开启 Wi-Fi';

  @override
  String get wifiWepRequirements => 'WEP 密钥必须包含 5 到 64 个字符。';

  @override
  String windowSwitcherPosition(int position, int total) {
    return '$position / $total';
  }

  @override
  String windowSwitcherSelected(String windowTitle) {
    return '已选择 $windowTitle';
  }

  @override
  String windowUntitled(int windowId) {
    return '窗口 $windowId';
  }
}
