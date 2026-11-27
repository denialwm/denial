import 'dart:async';

import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Black over every output, with a spinner in the middle of each, while the
/// session ends: deniald gives the apps a few seconds to quit before it exits.
/// It takes all pointer input and stays until deniald is gone.
class SessionEndingScreen extends ConsumerStatefulWidget {
  const SessionEndingScreen({super.key});

  @override
  ConsumerState<SessionEndingScreen> createState() =>
      _SessionEndingScreenState();
}

class _SessionEndingScreenState extends ConsumerState<SessionEndingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  StreamSubscription<void>? _endings;
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    final bridge = ref.read(denialBridgeProvider);
    _endings = bridge.sessionEnding.listen((_) => _begin());
    if (bridge.sessionEndingActive) {
      _ending = true;
      _fade.value = 1;
    }
  }

  void _begin() {
    if (!mounted || _ending) {
      return;
    }
    setState(() => _ending = true);
    unawaited(_fade.forward());
  }

  @override
  void dispose() {
    unawaited(_endings?.cancel());
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ending) {
      return const SizedBox.shrink();
    }
    final outputs = ref.watch(
      displayLayoutProvider.select(
        (layout) => [
          for (final output in layout?.outputs ?? const [])
            if (!output.inputOnly) output.logicalRect,
        ],
      ),
    );
    final spinner = SizedBox.square(
      dimension: 28,
      child: CircularProgressIndicator(
        strokeWidth: 2.5,
        color: ShellTheme.of(context).accent,
      ),
    );
    return FadeTransition(
      opacity: _fade,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        child: ColoredBox(
          color: const Color(0xff000000),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (outputs.isEmpty)
                Center(child: spinner)
              else
                for (final rect in outputs)
                  Positioned.fromRect(
                    rect: rect,
                    child: Center(child: spinner),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
