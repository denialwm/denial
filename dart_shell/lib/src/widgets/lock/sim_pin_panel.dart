import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../input/shell_interaction_registry.dart';
import '../../services/mobile_network_service.dart';
import '../../theme/shell_theme.dart';

/// Retains SIM interaction across every device-unlock path, including native
/// fingerprint success. Device authentication must not implicitly defer a SIM.
class MobileSimPromptStage extends StatelessWidget {
  const MobileSimPromptStage({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Stack(fit: StackFit.expand, children: [child, const SimPinPanel()]);
}

/// SIM authentication is separate from desktop authentication: dismissing or
/// unlocking a SIM never authenticates the user or unlocks the desktop.
class SimPinPanel extends ConsumerStatefulWidget {
  const SimPinPanel({super.key});
  @override
  ConsumerState<SimPinPanel> createState() => _SimPinPanelState();
}

class _SimPinPanelState extends ConsumerState<SimPinPanel> {
  final _pin = TextEditingController();
  String? _dismissed;
  String? _sim;
  bool _busy = false;
  bool _failed = false;

  @override
  void dispose() {
    _pin.clear();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state =
        ref.watch(mobileNetworkProvider).value ?? const MobileNetworkSnapshot();
    if (_sim != state.simPath) {
      _sim = state.simPath;
      _pin.clear();
      _failed = false;
    }
    if (!state.pinRequired) _pin.clear();
    if (!state.locked || state.simPath == null || _dismissed == state.simPath) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    return Positioned.fill(
      child: ShellInputRegion(
        debugLabel: 'SIM PIN prompt',
        pointerPolicy: ShellPointerPolicy.fullScene,
        keyboardPolicy: ShellKeyboardPolicy.capture,
        compositorPolicy: ShellCompositorPolicy.exclusive,
        child: Theme(
          data: context.shellTheme.toMaterialTheme(),
          child: Builder(
            builder: (context) => GestureDetector(
              onTap: () {},
              onPanStart: (_) {},
              child: ColoredBox(
                color: Theme.of(
                  context,
                ).colorScheme.scrim.withValues(alpha: 0.65),
                child: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        24,
                        24,
                        MediaQuery.viewInsetsOf(context).bottom + 24,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  l10n.simPinTitle,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 16),
                                if (state.pinRequired) ...[
                                  if (state.pinRetries != null)
                                    Text(l10n.simPinRetries(state.pinRetries!)),
                                  TextField(
                                    controller: _pin,
                                    obscureText: true,
                                    enableSuggestions: false,
                                    autocorrect: false,
                                    enableIMEPersonalizedLearning: false,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly,
                                      LengthLimitingTextInputFormatter(8),
                                    ],
                                    decoration: InputDecoration(
                                      labelText: l10n.simPinLabel,
                                    ),
                                    enabled: !_busy && state.pinRetries != 0,
                                    onChanged: (_) => setState(() {}),
                                    onSubmitted: (_) => _submit(state),
                                  ),
                                  if (_failed)
                                    Text(
                                      l10n.simPinFailed,
                                      semanticsLabel: l10n.simPinFailed,
                                    ),
                                  const SizedBox(height: 16),
                                  FilledButton(
                                    onPressed:
                                        !_busy &&
                                            _pin.text.length >= 4 &&
                                            state.pinRetries != 0
                                        ? () => _submit(state)
                                        : null,
                                    child: Text(
                                      _busy
                                          ? l10n.commonLoading
                                          : l10n.simPinUnlock,
                                    ),
                                  ),
                                ] else
                                  Text(
                                    state.unlockRequired == 4
                                        ? l10n.simPukRequired
                                        : l10n.simLocked,
                                  ),
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => setState(() {
                                          _pin.clear();
                                          _dismissed = state.simPath;
                                        }),
                                  child: Text(l10n.simPinLater),
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
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit(MobileNetworkSnapshot state) async {
    if (_busy ||
        !state.pinRequired ||
        state.pinRetries == 0 ||
        _pin.text.length < 4) {
      return;
    }
    final pin = _pin.text;
    _pin.clear();
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await ref.read(mobileNetworkServiceProvider).sendPin(state.simPath!, pin);
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
