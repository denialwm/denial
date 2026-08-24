import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../models/output_configuration.dart';
import '../../state/display_brightness.dart';
import '../../state/display_layout.dart';
import '../../state/output_configuration.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';
import '../monitor_arrangement.dart';
import 'settings_controls.dart';

const settingsMonitorLayoutEditorKey = ValueKey<String>(
  'settings-monitor-layout-editor',
);
const settingsMonitorCanvasKey = ValueKey<String>('settings-monitor-canvas');
const settingsMonitorCanvasPanSurfaceKey = ValueKey<String>(
  'settings-monitor-canvas-pan-surface',
);
const settingsMonitorZoomOutKey = ValueKey<String>('settings-monitor-zoom-out');
const settingsMonitorZoomFitKey = ValueKey<String>('settings-monitor-zoom-fit');
const settingsMonitorZoomInKey = ValueKey<String>('settings-monitor-zoom-in');
const settingsApplyDisplayConfigurationKey = ValueKey<String>(
  'settings-apply-display-configuration',
);
const settingsPrimaryDisplaySelectorKey = ValueKey<String>(
  'settings-primary-display-selector',
);
const settingsVariableRefreshRateToggleKey = ValueKey<String>(
  'settings-variable-refresh-rate-toggle',
);
const settingsDisplayConfirmationDialogKey = ValueKey<String>(
  'settings-display-confirmation-dialog',
);
const settingsKeepDisplayConfigurationKey = ValueKey<String>(
  'settings-keep-display-configuration',
);

class SettingsDisplaysPage extends ConsumerWidget {
  const SettingsDisplaysPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(outputConfigurationProvider);
    final controller = ref.read(outputConfigurationProvider.notifier);
    return SettingsPageLayout(
      icon: Icons.monitor_rounded,
      eyebrow: l10n.settingsDisplaysSection,
      title: l10n.settingsDisplaysTitle,
      onReset: controller.discard,
      children: <Widget>[
        SettingsCardGroup(
          children: <Widget>[
            SettingsSection(
              title: l10n.settingsDisplayArrangementTitle,
              trailing: SettingsTextButton(
                label: l10n.settingsRefresh,
                onPressed: state.applying ? null : controller.refresh,
              ),
              child: _OutputConfigurationBody(
                state: state,
                controller: controller,
              ),
            ),
          ],
        ),
        const _DisplayBrightnessCard(),
      ],
    );
  }
}

class SettingsDisplayConfirmationDialog extends StatefulWidget {
  const SettingsDisplayConfirmationDialog({
    required this.confirmation,
    required this.busy,
    required this.onKeep,
    required this.onRevert,
    required this.onExpired,
    super.key,
  });

  final DenialOutputConfirmation confirmation;
  final bool busy;
  final VoidCallback onKeep;
  final VoidCallback onRevert;
  final VoidCallback onExpired;

  @override
  State<SettingsDisplayConfirmationDialog> createState() =>
      _SettingsDisplayConfirmationDialogState();
}

class _SettingsDisplayConfirmationDialogState
    extends State<SettingsDisplayConfirmationDialog> {
  Timer? _timer;
  late int _seconds;
  var _reportedExpiry = false;

  int _remainingSeconds() {
    final remaining =
        widget.confirmation.deadlineUnixMilliseconds -
        DateTime.now().millisecondsSinceEpoch;
    return math.max(0, (remaining + 999) ~/ 1000);
  }

  void _startTimer() {
    _timer?.cancel();
    _reportedExpiry = false;
    _seconds = _remainingSeconds();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final seconds = _remainingSeconds();
      if (mounted && seconds != _seconds) {
        setState(() => _seconds = seconds);
      }
      if (seconds == 0 && !_reportedExpiry) {
        _reportedExpiry = true;
        _timer?.cancel();
        widget.onExpired();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant SettingsDisplayConfirmationDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.confirmation.token != widget.confirmation.token ||
        oldWidget.confirmation.deadlineUnixMilliseconds !=
            widget.confirmation.deadlineUnixMilliseconds) {
      _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      key: settingsDisplayConfirmationDialogKey,
      container: true,
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: l10n.settingsDisplayConfirmationTitle,
      child: ColoredBox(
        color: const Color(0xA3000000),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 410),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ShellColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: ShellColors.hairline),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 28,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: accent.withAlpha(34),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(9),
                            child: Icon(
                              Icons.monitor_rounded,
                              color: accent,
                              size: 22,
                            ),
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Text(
                            l10n.settingsDisplayConfirmationTitle,
                            style: ShellText.cardTitle.copyWith(fontSize: 17),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.settingsDisplayConfirmationMessage(_seconds),
                        style: ShellText.base.copyWith(
                          color: ShellColors.textSecondary,
                          height: 1.45,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        SettingsTextButton(
                          label: l10n.settingsDisplayRevertNow,
                          onPressed: widget.busy ? null : widget.onRevert,
                        ),
                        const SizedBox(width: 10),
                        SettingsTextButton(
                          key: settingsKeepDisplayConfigurationKey,
                          label: l10n.settingsDisplayKeepChanges,
                          onPressed: widget.busy ? null : widget.onKeep,
                        ),
                      ],
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

class _OutputConfigurationBody extends StatelessWidget {
  const _OutputConfigurationBody({
    required this.state,
    required this.controller,
  });

  final OutputConfigurationState state;
  final OutputConfigurationController controller;

  @override
  Widget build(BuildContext context) {
    if (state.loading && state.configuration == null) {
      return _DisplayNotice(
        icon: Icons.sync_rounded,
        message: context.l10n.settingsLoadingDisplays,
      );
    }
    if (state.configuration == null || state.draftOutputs.isEmpty) {
      return _DisplayNotice(
        icon: Icons.monitor_outlined,
        message:
            state.error ?? context.l10n.settingsDisplayInformationUnavailable,
      );
    }
    final selected = state.selectedOutput!;
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (state.draftOutputs.length > 1) ...<Widget>[
            MonitorLayoutEditor(
              key: settingsMonitorLayoutEditorKey,
              outputs: state.draftOutputs,
              selectedName: selected.name,
              onSelected: controller.select,
              onPositionChanged: controller.setPosition,
            ),
            const SizedBox(height: 16),
          ],
          _PrimaryDisplayControl(
            outputs: state.draftOutputs,
            value: state.draftPrimaryOutput,
            enabled: !state.applying && state.configuration!.capabilities.apply,
            onChanged: controller.setPrimaryOutput,
          ),
          const SizedBox(height: 16),
          _MonitorControls(
            output: selected,
            capabilities: state.configuration!.capabilities,
            enabled: !state.applying,
            onModeChanged: (mode) => controller.setMode(selected.name, mode),
            onScaleChanged: (scale) =>
                controller.setScale(selected.name, scale),
            onTransformChanged: (transform) =>
                controller.setTransform(selected.name, transform),
            onAdaptiveSyncChanged: (value) =>
                controller.setAdaptiveSync(selected.name, value),
          ),
          if (state.error case final error?) ...<Widget>[
            const SizedBox(height: 12),
            _InlineError(message: error),
          ],
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  state.configuration!.capabilities.persistent
                      ? context.l10n.settingsDisplayApplyPersistentHint
                      : context.l10n.settingsDisplayApplySessionHint,
                  style: ShellText.base.copyWith(
                    color: ShellColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              SettingsTextButton(
                key: settingsApplyDisplayConfigurationKey,
                label: state.applying
                    ? context.l10n.settingsApplying
                    : context.l10n.settingsApplyDisplayConfiguration,
                onPressed: state.dirty && !state.applying
                    ? () => controller.apply()
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PrimaryDisplayControl extends StatelessWidget {
  const _PrimaryDisplayControl({
    required this.outputs,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final List<DenialOutput> outputs;
  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final choices = <SettingsChoice<String?>>[
      SettingsChoice<String?>(
        null,
        context.l10n.settingsDisplayPrimaryAutomatic,
      ),
      for (final output in outputs.where((output) => output.enabled))
        SettingsChoice<String?>(
          output.name,
          output.description == output.name
              ? output.name
              : '${output.description} (${output.name})',
        ),
      if (value != null &&
          !outputs.any((output) => output.enabled && output.name == value))
        SettingsChoice<String?>(value, value!),
    ];
    final selector = _DisplayDropdown<String?>(
      key: settingsPrimaryDisplaySelectorKey,
      label: context.l10n.settingsDisplayPrimary,
      value: value,
      enabled: enabled,
      choices: choices,
      onChanged: onChanged,
    );
    final hint = Text(
      context.l10n.settingsDisplayPrimaryHint,
      style: ShellText.base.copyWith(
        color: ShellColors.textTertiary,
        fontSize: 11,
        height: 1.4,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 620) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[selector, const SizedBox(height: 8), hint],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: selector),
            const SizedBox(width: 16),
            Expanded(flex: 2, child: hint),
          ],
        );
      },
    );
  }
}

class MonitorLayoutEditor extends StatefulWidget {
  const MonitorLayoutEditor({
    required this.outputs,
    required this.selectedName,
    required this.onSelected,
    required this.onPositionChanged,
    super.key,
  });

  final List<DenialOutput> outputs;
  final String selectedName;
  final ValueChanged<String> onSelected;
  final void Function(String name, int x, int y) onPositionChanged;

  @override
  State<MonitorLayoutEditor> createState() => _MonitorLayoutEditorState();
}

class _MonitorLayoutEditorState extends State<MonitorLayoutEditor> {
  static const _zoomSteps = <double>[
    0.01,
    0.02,
    0.03,
    0.04,
    0.05,
    0.06,
    0.07,
    0.08,
    0.09,
    0.10,
    0.15,
    0.20,
    0.25,
    0.30,
    0.35,
    0.40,
    0.45,
    0.50,
    0.55,
    0.60,
  ];

  var _viewScale = nwgDisplaysViewScale;
  var _panOffset = Offset.zero;
  var _panning = false;

  double? _nextZoom(bool zoomIn) {
    if (zoomIn) {
      for (final scale in _zoomSteps) {
        if (scale > _viewScale + 0.001) {
          return scale;
        }
      }
      return null;
    }
    for (final scale in _zoomSteps.reversed) {
      if (scale < _viewScale - 0.001) {
        return scale;
      }
    }
    return null;
  }

  void _setZoom({
    required double scale,
    required Size canvasSize,
    required Offset visiblePan,
    Offset? viewportAnchor,
  }) {
    setState(() {
      _panOffset = panMonitorCanvasForZoom(
        pan: visiblePan,
        viewportSize: canvasSize,
        oldScale: _viewScale,
        newScale: scale,
        viewportAnchor: viewportAnchor,
      );
      _viewScale = scale;
    });
  }

  void _handlePointerSignal(
    PointerSignalEvent event, {
    required Size canvasSize,
    required Offset visiblePan,
    required double padding,
  }) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) {
      return;
    }
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed && !keyboard.isMetaPressed) {
      return;
    }
    final scale = _nextZoom(event.scrollDelta.dy < 0);
    if (scale == null) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final local = event.localPosition - Offset(padding, padding);
      final anchor = Offset(
        local.dx.clamp(0.0, canvasSize.width).toDouble(),
        local.dy.clamp(0.0, canvasSize.height).toDouble(),
      );
      _setZoom(
        scale: scale,
        canvasSize: canvasSize,
        visiblePan: visiblePan,
        viewportAnchor: anchor,
      );
    });
  }

  void _fit({required Size canvasSize, required Size extent}) {
    final scale = fitMonitorCanvasScale(
      viewportSize: canvasSize,
      layoutExtent: extent,
    );
    setState(() {
      _viewScale = scale;
      _panOffset = centerMonitorCanvasPan(
        viewportSize: canvasSize,
        contentSize: Size(extent.width * scale, extent.height * scale),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      container: true,
      label: context.l10n.settingsDisplayArrangementSemantics,
      explicitChildNodes: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.max(240.0, constraints.maxWidth);
          const height = 360.0;
          const padding = 18.0;
          final canvasSize = Size(width - padding * 2, height - padding * 2);
          final extent = _layoutExtent(widget.outputs);
          final workspaceSize = denialMonitorWorkspaceSize(_viewScale);
          final visiblePan = _panOffset;
          final usableRect = Rect.fromLTWH(
            padding + visiblePan.dx,
            padding + visiblePan.dy,
            workspaceSize.width,
            workspaceSize.height,
          );
          final arrangement = <MonitorArrangementGeometry>[
            for (final output in widget.outputs)
              MonitorArrangementGeometry(
                name: output.name,
                x: output.x,
                y: output.y,
                logicalSize: output.draftLogicalSize,
              ),
          ];
          final zoomOut = _nextZoom(false);
          final zoomIn = _nextZoom(true);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      context.l10n.settingsDisplayCanvasPanHint,
                      style: ShellText.base.copyWith(
                        color: ShellColors.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _CanvasZoomButton(
                    key: settingsMonitorZoomOutKey,
                    icon: Icons.remove_rounded,
                    tooltip: context.l10n.settingsDisplayZoomOut,
                    onPressed: zoomOut == null
                        ? null
                        : () => _setZoom(
                            scale: zoomOut,
                            canvasSize: canvasSize,
                            visiblePan: visiblePan,
                          ),
                  ),
                  const SizedBox(width: 6),
                  Semantics(
                    label: context.l10n.settingsDisplayZoomLevel(
                      (_viewScale * 100).round(),
                    ),
                    child: SizedBox(
                      width: 48,
                      child: Text(
                        '${(_viewScale * 100).round()}%',
                        textAlign: TextAlign.center,
                        style: ShellText.base.copyWith(
                          color: ShellColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _CanvasZoomButton(
                    key: settingsMonitorZoomInKey,
                    icon: Icons.add_rounded,
                    tooltip: context.l10n.settingsDisplayZoomIn,
                    onPressed: zoomIn == null
                        ? null
                        : () => _setZoom(
                            scale: zoomIn,
                            canvasSize: canvasSize,
                            visiblePan: visiblePan,
                          ),
                  ),
                  const SizedBox(width: 6),
                  _CanvasZoomButton(
                    key: settingsMonitorZoomFitKey,
                    icon: Icons.fit_screen_rounded,
                    tooltip: context.l10n.settingsDisplayZoomFit,
                    onPressed: () =>
                        _fit(canvasSize: canvasSize, extent: extent),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ShellColors.surfaceContainerHigh.withValues(
                      alpha: 0.56,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: ShellColors.hairline),
                  ),
                  child: SizedBox(
                    key: settingsMonitorCanvasKey,
                    height: height,
                    child: Listener(
                      onPointerSignal: (event) => _handlePointerSignal(
                        event,
                        canvasSize: canvasSize,
                        visiblePan: visiblePan,
                        padding: padding,
                      ),
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: <Widget>[
                          Positioned.fill(
                            child: Semantics(
                              label: context
                                  .l10n
                                  .settingsDisplayCanvasPanSemantics,
                              hint: context.l10n.settingsDisplayCanvasPanHint,
                              child: MouseRegion(
                                cursor: ShellMouseCursors.move,
                                child: GestureDetector(
                                  key: settingsMonitorCanvasPanSurfaceKey,
                                  behavior: HitTestBehavior.opaque,
                                  dragStartBehavior: DragStartBehavior.down,
                                  onPanStart: (_) => setState(() {
                                    _panning = true;
                                  }),
                                  onPanUpdate: (details) => setState(() {
                                    _panOffset += details.delta;
                                  }),
                                  onPanEnd: (_) =>
                                      setState(() => _panning = false),
                                  onPanCancel: () =>
                                      setState(() => _panning = false),
                                  child: _LayoutGrid(
                                    offset: Offset(
                                      padding + visiblePan.dx,
                                      padding + visiblePan.dy,
                                    ),
                                    usableRect: usableRect,
                                    emphasized: _panning,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          for (final output in widget.outputs)
                            Positioned(
                              left:
                                  padding +
                                  visiblePan.dx +
                                  output.x * _viewScale,
                              top:
                                  padding +
                                  visiblePan.dy +
                                  output.y * _viewScale,
                              width: output.draftLogicalSize.width * _viewScale,
                              height:
                                  output.draftLogicalSize.height * _viewScale,
                              child: _MonitorTile(
                                key: ValueKey<String>('monitor-${output.name}'),
                                output: output,
                                selected: output.name == widget.selectedName,
                                accent: accent,
                                renderScale: _viewScale,
                                workspaceSize: workspaceSize,
                                arrangement: arrangement,
                                onSelected: () =>
                                    widget.onSelected(output.name),
                                onPositionChanged: (x, y) =>
                                    widget.onPositionChanged(output.name, x, y),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CanvasZoomButton extends StatelessWidget {
  const _CanvasZoomButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 18,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        foregroundColor: ShellColors.textSecondary,
        disabledForegroundColor: ShellColors.textTertiary.withAlpha(82),
        backgroundColor: ShellColors.surfaceContainerHigh,
        hoverColor: ShellColors.textSecondary.withAlpha(26),
        focusColor: ShellColors.textSecondary.withAlpha(26),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: ShellColors.hairline),
        ),
      ),
    );
  }
}

class _MonitorTile extends StatefulWidget {
  const _MonitorTile({
    required this.output,
    required this.selected,
    required this.accent,
    required this.renderScale,
    required this.workspaceSize,
    required this.arrangement,
    required this.onSelected,
    required this.onPositionChanged,
    super.key,
  });

  final DenialOutput output;
  final bool selected;
  final Color accent;
  final double renderScale;
  final Size workspaceSize;
  final List<MonitorArrangementGeometry> arrangement;
  final VoidCallback onSelected;
  final void Function(int x, int y) onPositionChanged;

  @override
  State<_MonitorTile> createState() => _MonitorTileState();
}

class _MonitorTileState extends State<_MonitorTile> {
  var _dragOffset = Offset.zero;
  var _dragStartX = 0;
  var _dragStartY = 0;
  var _lastDragX = 0;
  var _lastDragY = 0;
  var _focused = false;

  math.Point<int> _arrange(Offset candidateCanvasPosition) {
    return arrangeMonitorLikeNwgDisplays(
      movingName: widget.output.name,
      candidateCanvasPosition: candidateCanvasPosition,
      canvasSize: widget.workspaceSize,
      viewScale: widget.renderScale,
      monitors: widget.arrangement,
      snapThreshold: nwgDisplaysScaledSnapThreshold(widget.renderScale),
    );
  }

  void _moveWithKeyboard(_NudgeMonitorIntent intent) {
    final position = arrangeMonitorLikeNwgDisplays(
      movingName: widget.output.name,
      candidateCanvasPosition: Offset(
        (widget.output.x + intent.dx) * widget.renderScale,
        (widget.output.y + intent.dy) * widget.renderScale,
      ),
      canvasSize: widget.workspaceSize,
      viewScale: widget.renderScale,
      monitors: widget.arrangement,
      snapThreshold: 0,
    );
    widget.onPositionChanged(position.x, position.y);
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.output.effectiveMode;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: context.l10n.settingsMonitorSemantics(widget.output.name),
      hint: context.l10n.settingsMonitorDragHint,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.move,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _NudgeMonitorIntent(
            -10,
            0,
          ),
          SingleActivator(LogicalKeyboardKey.arrowRight): _NudgeMonitorIntent(
            10,
            0,
          ),
          SingleActivator(LogicalKeyboardKey.arrowUp): _NudgeMonitorIntent(
            0,
            -10,
          ),
          SingleActivator(LogicalKeyboardKey.arrowDown): _NudgeMonitorIntent(
            0,
            10,
          ),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSelected();
              return null;
            },
          ),
          _NudgeMonitorIntent: CallbackAction<_NudgeMonitorIntent>(
            onInvoke: (intent) {
              widget.onSelected();
              _moveWithKeyboard(intent);
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onTap: widget.onSelected,
          onPanDown: (_) => widget.onSelected(),
          onPanStart: (_) {
            _dragOffset = Offset.zero;
            _dragStartX = widget.output.x;
            _dragStartY = widget.output.y;
            _lastDragX = _dragStartX;
            _lastDragY = _dragStartY;
          },
          onPanUpdate: (details) {
            _dragOffset += details.delta;
            final position = _arrange(
              Offset(
                _dragStartX * widget.renderScale + _dragOffset.dx,
                _dragStartY * widget.renderScale + _dragOffset.dy,
              ),
            );
            if (position.x != _lastDragX || position.y != _lastDragY) {
              _lastDragX = position.x;
              _lastDragY = position.y;
              widget.onPositionChanged(position.x, position.y);
            }
          },
          child: AnimatedContainer(
            duration: Motion.tile,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: widget.selected
                  ? Color.alphaBlend(
                      widget.accent.withAlpha(72),
                      ShellColors.surfaceContainerHighest,
                    )
                  : ShellColors.surfaceContainerHighest,
              border: Border.all(
                color: widget.selected || _focused
                    ? widget.accent
                    : ShellColors.hairline,
                width: widget.selected ? 2 : 1,
              ),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.monitor_rounded,
                    size: 21,
                    color: ShellColors.textPrimary,
                  ),
                  const SizedBox(height: 4),
                  Text(widget.output.name, style: ShellText.cardTitle),
                  Text(
                    '${mode.width} × ${mode.height}',
                    style: ShellText.base.copyWith(
                      color: ShellColors.textTertiary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NudgeMonitorIntent extends Intent {
  const _NudgeMonitorIntent(this.dx, this.dy);

  final int dx;
  final int dy;
}

class _MonitorControls extends StatelessWidget {
  const _MonitorControls({
    required this.output,
    required this.capabilities,
    required this.enabled,
    required this.onModeChanged,
    required this.onScaleChanged,
    required this.onTransformChanged,
    required this.onAdaptiveSyncChanged,
  });

  final DenialOutput output;
  final DenialOutputCapabilities capabilities;
  final bool enabled;
  final ValueChanged<DenialOutputMode> onModeChanged;
  final ValueChanged<double> onScaleChanged;
  final ValueChanged<DenialOutputTransform> onTransformChanged;
  final ValueChanged<bool> onAdaptiveSyncChanged;

  @override
  Widget build(BuildContext context) {
    final resolutions = _resolutions(output.modes);
    final selectedMode = output.effectiveMode;
    final selectedResolution = _Resolution(
      selectedMode.width,
      selectedMode.height,
    );
    final refreshModes = output.modes
        .where(
          (mode) =>
              mode.width == selectedResolution.width &&
              mode.height == selectedResolution.height,
        )
        .toList(growable: false);
    final scales = <double>{..._commonScales, output.scale}.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(output.description, style: ShellText.base),
        const SizedBox(height: 4),
        Text(
          context.l10n.settingsDisplayPosition(output.x, output.y),
          style: ShellText.base.copyWith(
            color: ShellColors.textTertiary,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 620;
            final fields = <Widget>[
              _DisplayDropdown<_Resolution>(
                key: ValueKey<String>(
                  '${output.name}-resolution-${selectedResolution.width}x${selectedResolution.height}',
                ),
                label: context.l10n.settingsDisplayResolution,
                value: selectedResolution,
                enabled: enabled && capabilities.mode,
                choices: <SettingsChoice<_Resolution>>[
                  for (final resolution in resolutions)
                    SettingsChoice<_Resolution>(
                      resolution,
                      '${resolution.width} × ${resolution.height}',
                    ),
                ],
                onChanged: (resolution) {
                  final candidates = output.modes
                      .where(
                        (mode) =>
                            mode.width == resolution.width &&
                            mode.height == resolution.height,
                      )
                      .toList(growable: false);
                  final next = candidates.firstWhere(
                    (mode) =>
                        mode.refreshMillihz == selectedMode.refreshMillihz,
                    orElse: () => candidates.firstWhere(
                      (mode) => mode.preferred,
                      orElse: () => candidates.reduce(
                        (left, right) =>
                            left.refreshMillihz > right.refreshMillihz
                            ? left
                            : right,
                      ),
                    ),
                  );
                  onModeChanged(next);
                },
              ),
              _DisplayDropdown<DenialOutputMode>(
                key: ValueKey<String>(
                  '${output.name}-refresh-${selectedMode.refreshMillihz}',
                ),
                label: context.l10n.settingsDisplayRefreshRate,
                value: selectedMode,
                enabled: enabled && capabilities.mode,
                choices: <SettingsChoice<DenialOutputMode>>[
                  for (final mode in refreshModes)
                    SettingsChoice<DenialOutputMode>(
                      mode,
                      _refreshLabel(mode.refreshHz),
                    ),
                ],
                onChanged: onModeChanged,
              ),
              _DisplayDropdown<DenialOutputTransform>(
                key: ValueKey<String>(
                  '${output.name}-rotation-${output.transform.wireName}',
                ),
                label: context.l10n.settingsDisplayRotation,
                value: output.transform,
                enabled: enabled && capabilities.transform,
                choices: <SettingsChoice<DenialOutputTransform>>[
                  for (final transform in _rotations)
                    SettingsChoice<DenialOutputTransform>(
                      transform,
                      _rotationLabel(context, transform),
                    ),
                ],
                onChanged: onTransformChanged,
              ),
              _DisplayDropdown<double>(
                key: ValueKey<String>('${output.name}-scale-${output.scale}'),
                label: context.l10n.settingsDisplayScale,
                value: output.scale,
                enabled: enabled && capabilities.scale,
                choices: <SettingsChoice<double>>[
                  for (final scale in scales)
                    SettingsChoice<double>(scale, '${(scale * 100).round()}%'),
                ],
                onChanged: onScaleChanged,
              ),
            ];
            if (compact) {
              return Column(
                children: <Widget>[
                  for (
                    var index = 0;
                    index < fields.length;
                    index++
                  ) ...<Widget>[
                    fields[index],
                    if (index != fields.length - 1) const SizedBox(height: 10),
                  ],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (var index = 0; index < fields.length; index++) ...<Widget>[
                  Expanded(child: fields[index]),
                  if (index != fields.length - 1) const SizedBox(width: 10),
                ],
              ],
            );
          },
        ),
        if (capabilities.adaptiveSync &&
            output.adaptiveSyncSupported) ...<Widget>[
          const SizedBox(height: 14),
          SettingsToggle(
            key: settingsVariableRefreshRateToggleKey,
            label: context.l10n.settingsDisplayVariableRefreshRate,
            description:
                context.l10n.settingsDisplayVariableRefreshRateDescription,
            value: output.adaptiveSync,
            enabled: enabled,
            onChanged: onAdaptiveSyncChanged,
          ),
        ],
      ],
    );
  }
}

class _DisplayDropdown<T> extends StatefulWidget {
  const _DisplayDropdown({
    required this.label,
    required this.value,
    required this.enabled,
    required this.choices,
    required this.onChanged,
    super.key,
  });

  final String label;
  final T value;
  final bool enabled;
  final List<SettingsChoice<T>> choices;
  final ValueChanged<T> onChanged;

  @override
  State<_DisplayDropdown<T>> createState() => _DisplayDropdownState<T>();
}

class _DisplayDropdownState<T> extends State<_DisplayDropdown<T>> {
  final _layerLink = LayerLink();
  final _buttonKey = GlobalKey();
  final _buttonFocusNode = FocusNode();
  OverlayEntry? _menuEntry;
  var _expanded = false;
  var _focused = false;

  void _toggle() {
    if (!widget.enabled) {
      return;
    }
    if (_expanded) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    final target = _buttonKey.currentContext?.findRenderObject();
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject();
    if (target is! RenderBox || overlayBox is! RenderBox) {
      return;
    }

    final targetOffset = target.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    final targetSize = target.size;
    final desiredHeight = math.min(220.0, widget.choices.length * 40.0 + 10);
    final below = overlayBox.size.height - targetOffset.dy - targetSize.height;
    final above = targetOffset.dy;
    final showAbove = below < desiredHeight + 6 && above > below;
    final available = showAbove ? above : below;
    final maximumHeight = math.max(48.0, math.min(220.0, available - 8));
    final accent = ShellTheme.of(context).accent;

    setState(() => _expanded = true);
    _menuEntry = OverlayEntry(
      builder: (_) => _DisplayDropdownOverlay<T>(
        link: _layerLink,
        width: targetSize.width,
        maximumHeight: maximumHeight,
        showAbove: showAbove,
        choices: widget.choices,
        value: widget.value,
        accent: accent,
        onDismissed: _closeMenu,
        onSelected: _select,
      ),
    );
    overlay.insert(_menuEntry!);
  }

  void _closeMenu() {
    _menuEntry?.remove();
    _menuEntry = null;
    if (mounted && _expanded) {
      setState(() => _expanded = false);
    }
  }

  void _select(T value) {
    _closeMenu();
    _buttonFocusNode.requestFocus();
    widget.onChanged(value);
  }

  @override
  void didUpdateWidget(covariant _DisplayDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _expanded) {
      _closeMenu();
    } else {
      _menuEntry?.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _menuEntry?.remove();
    _buttonFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    final selected = widget.choices.firstWhere(
      (choice) => choice.value == widget.value,
    );
    return Semantics(
      button: true,
      enabled: widget.enabled,
      expanded: _expanded,
      label: widget.label,
      value: selected.label,
      child: AnimatedOpacity(
        duration: Motion.tile,
        opacity: widget.enabled ? 1 : 0.46,
        child: CompositedTransformTarget(
          link: _layerLink,
          child: KeyedSubtree(
            key: _buttonKey,
            child: FocusableActionDetector(
              focusNode: _buttonFocusNode,
              enabled: widget.enabled,
              mouseCursor: widget.enabled
                  ? ShellMouseCursors.link
                  : SystemMouseCursors.basic,
              onShowFocusHighlight: (focused) =>
                  setState(() => _focused = focused),
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.escape):
                    _CloseDisplayDropdownIntent(),
              },
              actions: <Type, Action<Intent>>{
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    _toggle();
                    return null;
                  },
                ),
                _CloseDisplayDropdownIntent:
                    CallbackAction<_CloseDisplayDropdownIntent>(
                      onInvoke: (_) {
                        _closeMenu();
                        return null;
                      },
                    ),
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.enabled ? _toggle : null,
                child: AnimatedContainer(
                  duration: Motion.tile,
                  padding: const EdgeInsets.fromLTRB(12, 8, 9, 9),
                  decoration: BoxDecoration(
                    color: ShellColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _expanded || _focused
                          ? accent
                          : ShellColors.hairline,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.base.copyWith(
                          color: ShellColors.textTertiary,
                          fontSize: 10,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              selected.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ShellText.cardTitle,
                            ),
                          ),
                          AnimatedRotation(
                            turns: _expanded ? 0.5 : 0,
                            duration: Motion.tile,
                            child: const Icon(
                              Icons.expand_more_rounded,
                              size: 18,
                              color: ShellColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DisplayDropdownOverlay<T> extends StatelessWidget {
  const _DisplayDropdownOverlay({
    required this.link,
    required this.width,
    required this.maximumHeight,
    required this.showAbove,
    required this.choices,
    required this.value,
    required this.accent,
    required this.onDismissed,
    required this.onSelected,
  });

  final LayerLink link;
  final double width;
  final double maximumHeight;
  final bool showAbove;
  final List<SettingsChoice<T>> choices;
  final T value;
  final Color accent;
  final VoidCallback onDismissed;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onDismissed,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: link,
            showWhenUnlinked: false,
            targetAnchor: showAbove ? Alignment.topLeft : Alignment.bottomLeft,
            followerAnchor: showAbove
                ? Alignment.bottomLeft
                : Alignment.topLeft,
            offset: Offset(0, showAbove ? -6 : 6),
            child: SizedBox(
              width: width,
              child: Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    onDismissed();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maximumHeight),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: ShellColors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: ShellColors.hairline),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x52000000),
                            blurRadius: 20,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            for (final choice in choices)
                              _DisplayDropdownOption<T>(
                                choice: choice,
                                selected: choice.value == value,
                                accent: accent,
                                onSelected: onSelected,
                              ),
                          ],
                        ),
                      ),
                    ),
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

class _CloseDisplayDropdownIntent extends Intent {
  const _CloseDisplayDropdownIntent();
}

class _DisplayDropdownOption<T> extends StatefulWidget {
  const _DisplayDropdownOption({
    required this.choice,
    required this.selected,
    required this.accent,
    required this.onSelected,
  });

  final SettingsChoice<T> choice;
  final bool selected;
  final Color accent;
  final ValueChanged<T> onSelected;

  @override
  State<_DisplayDropdownOption<T>> createState() =>
      _DisplayDropdownOptionState<T>();
}

class _DisplayDropdownOptionState<T> extends State<_DisplayDropdownOption<T>> {
  var _highlighted = false;

  @override
  Widget build(BuildContext context) {
    void select() => widget.onSelected(widget.choice.value);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.choice.label,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
        onShowFocusHighlight: (highlighted) =>
            setState(() => _highlighted = highlighted),
        onShowHoverHighlight: (highlighted) =>
            setState(() => _highlighted = highlighted),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              select();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: select,
          child: AnimatedContainer(
            duration: Motion.tile,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(
              color: widget.selected
                  ? widget.accent.withAlpha(42)
                  : _highlighted
                  ? ShellColors.surfaceContainerHigh
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.choice.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.cardTitle.copyWith(
                      color: widget.selected
                          ? widget.accent
                          : ShellColors.textSecondary,
                    ),
                  ),
                ),
                if (widget.selected) ...<Widget>[
                  const SizedBox(width: 6),
                  Icon(Icons.check_rounded, size: 16, color: widget.accent),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DisplayBrightnessCard extends ConsumerWidget {
  const _DisplayBrightnessCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final layout = ref.watch(displayLayoutProvider);
    final brightness = ref.watch(displayBrightnessProvider);
    final controller = ref.read(displayBrightnessProvider.notifier);
    return SettingsCardGroup(
      children: <Widget>[
        SettingsSection(
          title: l10n.settingsDisplayBrightnessTitle,
          child: layout == null || layout.outputs.isEmpty
              ? _DisplayNotice(
                  icon: Icons.brightness_6_outlined,
                  message: l10n.settingsDisplayInformationUnavailable,
                )
              : Column(
                  children: <Widget>[
                    for (
                      var index = 0;
                      index < layout.outputs.length;
                      index++
                    ) ...<Widget>[
                      Builder(
                        builder: (context) {
                          final output = layout.outputs[index];
                          final level =
                              brightness.levels[output.monitorId] ?? 0.72;
                          return SettingsSlider(
                            label: l10n.outputBrightnessSemantics(output.name),
                            value: level,
                            minimum: 0.01,
                            maximum: 1,
                            divisions: 99,
                            valueLabel: l10n.settingsPercent(
                              (level * 100).round(),
                            ),
                            enabled: !brightness.loading.contains(
                              output.monitorId,
                            ),
                            onChanged: (value) =>
                                controller.setLevel(output, value),
                            onChangeEnd: (value) =>
                                controller.commitLevel(output, value),
                          );
                        },
                      ),
                      if (index != layout.outputs.length - 1)
                        const Divider(
                          height: 18,
                          color: ShellColors.hairlineSoft,
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _DisplayNotice extends StatelessWidget {
  const _DisplayNotice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: ShellColors.textTertiary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: ShellText.base.copyWith(color: ShellColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShellColors.performanceBad.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: ShellColors.performanceBad.withValues(alpha: 0.42),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            message,
            style: ShellText.base.copyWith(
              color: ShellColors.performanceBad,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}

class _LayoutGrid extends StatelessWidget {
  const _LayoutGrid({
    required this.offset,
    required this.usableRect,
    required this.emphasized,
  });

  final Offset offset;
  final Rect usableRect;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _LayoutGridPainter(
        offset: offset,
        usableRect: usableRect,
        emphasized: emphasized,
      ),
    );
  }
}

class _LayoutGridPainter extends CustomPainter {
  const _LayoutGridPainter({
    required this.offset,
    required this.usableRect,
    required this.emphasized,
  });

  final Offset offset;
  final Rect usableRect;
  final bool emphasized;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ShellColors.hairlineSoft.withValues(
        alpha: emphasized ? 0.72 : 0.48,
      )
      ..strokeWidth = 1;
    const gap = 24.0;
    final startX = offset.dx % gap;
    final startY = offset.dy % gap;
    for (var x = startX; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = startY; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    final viewport = Offset.zero & size;
    final visibleUsableRect = usableRect.intersect(viewport);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(viewport);
    if (!visibleUsableRect.isEmpty) {
      outside.addRect(visibleUsableRect);
    }
    canvas.drawPath(
      outside,
      Paint()..color = ShellColors.background.withValues(alpha: 0.72),
    );
    if (!visibleUsableRect.isEmpty) {
      canvas.drawRect(
        visibleUsableRect,
        Paint()
          ..color = ShellColors.hairline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LayoutGridPainter oldDelegate) {
    return oldDelegate.offset != offset ||
        oldDelegate.usableRect != usableRect ||
        oldDelegate.emphasized != emphasized;
  }
}

Size _layoutExtent(List<DenialOutput> outputs) {
  var right = 0.0;
  var bottom = 0.0;
  for (final output in outputs) {
    right = math.max(right, output.x + output.draftLogicalSize.width);
    bottom = math.max(bottom, output.y + output.draftLogicalSize.height);
  }
  return Size(right, bottom);
}

List<_Resolution> _resolutions(List<DenialOutputMode> modes) {
  final result = <_Resolution>[];
  for (final mode in modes) {
    final resolution = _Resolution(mode.width, mode.height);
    if (!result.contains(resolution)) {
      result.add(resolution);
    }
  }
  return result;
}

String _refreshLabel(double refreshHz) {
  final rounded = refreshHz.roundToDouble();
  final value = (refreshHz - rounded).abs() < 0.005
      ? rounded.toStringAsFixed(0)
      : refreshHz.toStringAsFixed(3);
  return '$value Hz';
}

String _rotationLabel(BuildContext context, DenialOutputTransform transform) {
  final l10n = context.l10n;
  return switch (transform) {
    DenialOutputTransform.normal => l10n.settingsDisplayRotationNormal,
    DenialOutputTransform.rotate90 => l10n.settingsDisplayRotation90,
    DenialOutputTransform.rotate180 => l10n.settingsDisplayRotation180,
    DenialOutputTransform.rotate270 => l10n.settingsDisplayRotation270,
    _ => transform.wireName,
  };
}

const _rotations = <DenialOutputTransform>[
  DenialOutputTransform.normal,
  DenialOutputTransform.rotate90,
  DenialOutputTransform.rotate180,
  DenialOutputTransform.rotate270,
];

const _commonScales = <double>[
  0.25,
  0.5,
  0.75,
  1,
  1.25,
  1.5,
  1.75,
  2,
  2.5,
  3,
  4,
  6,
  8,
];

class _Resolution {
  const _Resolution(this.width, this.height);

  final int width;
  final int height;

  @override
  bool operator ==(Object other) {
    return other is _Resolution &&
        width == other.width &&
        height == other.height;
  }

  @override
  int get hashCode => Object.hash(width, height);
}
