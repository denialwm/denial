import 'package:flutter/widgets.dart';
import '../state/fingerprint_scene.dart';

/// Fingerprint pixels belong to the same Flutter scene and damage lifecycle
/// as the shell. Native never modifies the completed scanout buffer.
class FingerprintStage extends StatefulWidget {
  const FingerprintStage({
    super.key,
    required this.scene,
    required this.locked,
    required this.onLaidOut,
    required this.child,
  });
  final FingerprintScene scene;
  final bool locked;
  final ValueChanged<int> onLaidOut;
  final Widget child;
  @override
  State<FingerprintStage> createState() => _FingerprintStageState();
}

class _FingerprintStageState extends State<FingerprintStage> {
  bool _retainBlack = false;
  Rect _blackRect = Rect.zero;
  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(covariant FingerprintStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene.epoch != widget.scene.epoch ||
        oldWidget.locked != widget.locked)
      _update();
  }

  void _update() {
    final scene = widget.scene;
    if (scene.black) {
      _retainBlack = true;
      _blackRect = scene.output;
    }
    // A cancelled wake returns to the lock immediately; only successful
    // authentication reveals home with a fade.
    if (!scene.black && !scene.fading) _retainBlack = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.scene.epoch == scene.epoch)
        widget.onLaidOut(scene.epoch);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.scene;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        // The black guard and target share one opacity animation, so home
        // is revealed as the fingerprint fades, without a blank interval.
        IgnorePointer(
          child: AnimatedOpacity(
            key: const ValueKey('fingerprint-reveal'),
            opacity: scene.fading && !widget.locked ? 0 : 1,
            duration:
                scene.fading &&
                    !widget.locked &&
                    !MediaQuery.disableAnimationsOf(context)
                ? const Duration(milliseconds: 220)
                : Duration.zero,
            onEnd: () {
              // Zero-duration animations can finish during widget update.
              // Retire the guard after that frame, and never retire a retry.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted &&
                    widget.scene.epoch == scene.epoch &&
                    !widget.scene.black &&
                    !widget.locked) {
                  setState(() => _retainBlack = false);
                }
              });
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_retainBlack)
                  Positioned.fromRect(
                    rect: _blackRect,
                    child: const ColoredBox(color: Color(0xff000000)),
                  ),
                if (scene.texture case final texture?)
                  Positioned.fromRect(
                    rect: scene.target,
                    child: Texture(
                      textureId: texture,
                      filterQuality: FilterQuality.none,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
