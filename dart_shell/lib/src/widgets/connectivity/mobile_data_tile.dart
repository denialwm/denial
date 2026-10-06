import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../services/mobile_network_service.dart';
import '../shade/quick_settings_tiles.dart';

class MobileDataTile extends ConsumerStatefulWidget {
  const MobileDataTile({super.key});
  @override
  ConsumerState<MobileDataTile> createState() => _MobileDataTileState();
}

class _MobileDataTileState extends ConsumerState<MobileDataTile> {
  bool _busy = false;
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final state =
        ref.watch(mobileNetworkProvider).value ?? const MobileNetworkSnapshot();
    final l10n = context.l10n;
    final subtitle = _failed
        ? l10n.mobileChangeFailed
        : state.modemPath == null
        ? l10n.mobileUnavailable
        : state.locked
        ? l10n.simLocked
        : !state.enabled
        ? l10n.commonOff
        : state.connected
        ? (state.operatorName.isEmpty
              ? l10n.mobileConnected
              : state.operatorName)
        : l10n.mobileDisconnected;
    return QuickTile(
      icon: Icons.network_cell_rounded,
      title: l10n.mobileData,
      subtitle: subtitle,
      active: state.enabled,
      enabled: state.canToggle && !_busy,
      busy: _busy,
      wide: true,
      onTap: () async {
        setState(() {
          _busy = true;
          _failed = false;
        });
        try {
          await ref
              .read(mobileNetworkServiceProvider)
              .setEnabled(!state.enabled);
        } on Object {
          if (mounted) setState(() => _failed = true);
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      },
    );
  }
}
