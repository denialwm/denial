import 'dart:async';

import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart' show denialBridgeProvider;
import 'package:denial_flutter_sdk/window_frames.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop_window_frame_painter.dart' show desktopWindowBorderColor;
import 'caption_button.dart';
import 'double_click.dart';
import 'frame_colors.dart';
import 'resize_zone.dart';

/// One window's frame: the border, and a title bar with the application's
/// icon, the title and the caption buttons.
///
/// Everything it does to the window is one of the compositor's own calls. The
/// desktop then shows what the compositor did; the frame keeps no window
/// state of its own.
class WindowsWindowFrame extends ConsumerStatefulWidget {
  const WindowsWindowFrame({required this.frame, super.key});

  final ShellWindowFrameContext frame;

  @override
  ConsumerState<WindowsWindowFrame> createState() => _WindowsWindowFrameState();
}

class _WindowsWindowFrameState extends ConsumerState<WindowsWindowFrame> {
  /// How far from an edge the pointer resizes, on the title bar's side.
  static const _resizeBand = 4.0;

  /// How far along an edge a corner reaches.
  static const _resizeCorner = 10.0;

  static const _iconSize = 18.0;

  final _clicks = DoubleClick();

  DenialBridge get _bridge => ref.read(denialBridgeProvider);

  DenialWindow get _window => widget.frame.window;

  void _toggleMaximized() {
    unawaited(
      _bridge.placeWindow(
        _window,
        widget.frame.maximized
            ? const DenialWindowPlace.restore()
            : const DenialWindowPlace.maximized(),
      ),
    );
  }

  void _titlePressed(PointerDownEvent event) {
    final mouse = event.kind == PointerDeviceKind.mouse;
    if (mouse && event.buttons != kPrimaryMouseButton) {
      return;
    }
    if (_clicks.press(event.timeStamp, event.position.dx, event.position.dy)) {
      _toggleMaximized();
      return;
    }
    // The compositor takes the press over, a button or a finger, raises the
    // window and moves it itself.
    _bridge.beginWindowMove(_window);
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    final margins = frame.margins;
    final theme = context.shellTheme;
    final colors = WindowFrameColors.of(theme.brightness, active: frame.active);
    final title = _window.title.isEmpty ? _window.appId : _window.title;
    // The border above the title bar is as wide as the one beside it. A
    // maximized window has no side margins and so no border.
    final topBorder = margins.left;
    // The window rounding setting rounds the frame as it does the desktop's
    // plain border; a maximized window is square. The desktop rounds the
    // content's lower corners and the shadow to match.
    final radius = frame.maximized ? 0.0 : theme.windowRadius;
    // As far as the content's rounded corners reach, with a unit to spare
    // for rounding to whole pixels; behind the content.
    final contentCorner = radius > topBorder ? radius - topBorder + 1.0 : 0.0;
    // The active window's border takes the accent when the setting asks for
    // it, as the plain border does.
    final borderColor = desktopWindowBorderColor(
      pinned: _window.pinned,
      active: frame.active,
      theme: theme,
      inactiveColor: colors.border,
    );
    // Only the margins are painted: a translucent window shows whatever lies
    // under its content.
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: margins.left,
            top: topBorder,
            right: margins.right,
            height: (margins.top - topBorder).clamp(0.0, double.infinity),
            child: ColoredBox(
              color: colors.bar,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _titlePressed,
                      child: Row(
                        children: [
                          const SizedBox(width: 12.0),
                          SizedBox.square(
                            dimension: _iconSize,
                            child: frame.services.buildApplicationIcon(
                              context,
                              _window.appId,
                            ),
                          ),
                          const SizedBox(width: 8.0),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: DefaultTextStyle.of(context).style
                                  .copyWith(
                                    color: colors.text,
                                    fontSize: 13.0,
                                    fontWeight: FontWeight.w400,
                                    decoration: TextDecoration.none,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 8.0),
                        ],
                      ),
                    ),
                  ),
                  CaptionButton(
                    glyph: CaptionGlyph.minimize,
                    label: 'Minimize',
                    colors: colors,
                    onPressed: () => _bridge.minimizeWindow(_window),
                  ),
                  CaptionButton(
                    glyph: frame.maximized
                        ? CaptionGlyph.restore
                        : CaptionGlyph.maximize,
                    label: frame.maximized ? 'Restore' : 'Maximize',
                    colors: colors,
                    onPressed: _toggleMaximized,
                  ),
                  CaptionButton(
                    glyph: CaptionGlyph.close,
                    label: 'Close',
                    colors: colors,
                    onPressed: () => _bridge.closeWindow(_window),
                  ),
                ],
              ),
            ),
          ),
          // The content's upper corners are rounded as its lower ones; the
          // bar's colour fills behind them so they meet the title bar.
          if (contentCorner > 0.0) ...[
            Positioned(
              left: margins.left,
              top: margins.top,
              width: contentCorner,
              height: contentCorner,
              child: ColoredBox(color: colors.bar),
            ),
            Positioned(
              right: margins.right,
              top: margins.top,
              width: contentCorner,
              height: contentCorner,
              child: ColoredBox(color: colors.bar),
            ),
          ],
          // The border goes over the title bar, so it follows the rounded
          // corners all the way round.
          if (topBorder > 0.0)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: borderColor, width: topBorder),
                    borderRadius: BorderRadius.circular(radius),
                  ),
                ),
              ),
            ),
          if (!frame.maximized) ..._resizeZones(margins),
        ],
      ),
    );
  }

  /// Where a press on the frame itself resizes the window: the borders, and
  /// a band along the top of the title bar. Corners come last, over the edges
  /// they join. The band outside the frame is [WindowsFrameReach].
  List<Widget> _resizeZones(DenialWindowFrameMargins margins) {
    return [
      ResizeZone(
        window: _window,
        edge: DenialWindowResizeEdge.top,
        left: 0.0,
        top: 0.0,
        right: 0.0,
        height: _resizeBand,
      ),
      if (margins.bottom > 0.0)
        ResizeZone(
          window: _window,
          edge: DenialWindowResizeEdge.bottom,
          left: 0.0,
          right: 0.0,
          bottom: 0.0,
          height: margins.bottom,
        ),
      if (margins.left > 0.0)
        ResizeZone(
          window: _window,
          edge: DenialWindowResizeEdge.left,
          left: 0.0,
          top: 0.0,
          bottom: 0.0,
          width: margins.left,
        ),
      if (margins.right > 0.0)
        ResizeZone(
          window: _window,
          edge: DenialWindowResizeEdge.right,
          top: 0.0,
          right: 0.0,
          bottom: 0.0,
          width: margins.right,
        ),
      ResizeZone(
        window: _window,
        edge: DenialWindowResizeEdge.topLeft,
        left: 0.0,
        top: 0.0,
        width: _resizeCorner,
        height: _resizeCorner,
      ),
      ResizeZone(
        window: _window,
        edge: DenialWindowResizeEdge.topRight,
        top: 0.0,
        right: 0.0,
        width: _resizeCorner,
        height: _resizeCorner,
      ),
      ResizeZone(
        window: _window,
        edge: DenialWindowResizeEdge.bottomLeft,
        left: 0.0,
        bottom: 0.0,
        width: _resizeCorner,
        height: _resizeCorner,
      ),
      ResizeZone(
        window: _window,
        edge: DenialWindowResizeEdge.bottomRight,
        right: 0.0,
        bottom: 0.0,
        width: _resizeCorner,
        height: _resizeCorner,
      ),
    ];
  }
}
