import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/system_tray_item.dart';
import '../platform/denial_bridge.dart';
import '../services/status_notifier_service.dart';
import 'shell_controller.dart';

final statusNotifierServiceProvider = Provider<StatusNotifierService>((ref) {
  final service = StatusNotifierService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final systemTrayProvider =
    NotifierProvider<SystemTrayController, List<SystemTrayItem>>(
      SystemTrayController.new,
    );

class SystemTrayController extends Notifier<List<SystemTrayItem>> {
  @override
  List<SystemTrayItem> build() {
    _bridge = ref.watch(denialBridgeProvider);
    _statusNotifier = ref.watch(statusNotifierServiceProvider);
    _statusItems = const <SystemTrayItem>[];
    _xembedItems = Map<int, SystemTrayItem>.of(_bridge.xembedTrayItems);
    _statusSubscription = _statusNotifier.snapshots.listen((items) {
      if (ref.mounted) {
        _statusItems = items;
        _publish();
      }
    });
    _xembedSubscription = _bridge.xembedTrayEvents.listen((event) {
      if (!ref.mounted) {
        return;
      }
      if (event.kind == XEmbedTrayEventKind.removed) {
        _xembedItems.remove(event.windowId);
      } else if (event.item case final item?) {
        _xembedItems[event.windowId] = item;
      }
      _publish();
    });
    ref.onDispose(() {
      unawaited(_statusSubscription?.cancel());
      unawaited(_xembedSubscription?.cancel());
    });
    scheduleMicrotask(() async {
      try {
        await _statusNotifier.start();
        if (ref.mounted) {
          _statusItems = _statusNotifier.current;
          _publish();
        }
      } on Object {
        // XEmbed remains usable when the session bus is unavailable or a
        // stricter host already owns the watcher name.
      }
    });
    return _combinedItems();
  }

  late DenialBridge _bridge;
  late StatusNotifierService _statusNotifier;
  StreamSubscription<List<SystemTrayItem>>? _statusSubscription;
  StreamSubscription<XEmbedTrayEvent>? _xembedSubscription;
  List<SystemTrayItem> _statusItems = const <SystemTrayItem>[];
  Map<int, SystemTrayItem> _xembedItems = <int, SystemTrayItem>{};

  Future<bool> invoke(
    SystemTrayItem item,
    SystemTrayAction action,
    Offset position,
  ) async {
    if (item.source == SystemTrayItemSource.statusNotifier) {
      return _statusNotifier.invoke(item, action, position);
    }
    final prefix = 'xembed:';
    final windowId = item.id.startsWith(prefix)
        ? int.tryParse(item.id.substring(prefix.length))
        : null;
    if (windowId != null) {
      _bridge.invokeXEmbedTrayAction(windowId, action, position);
      return true;
    }
    return false;
  }

  Future<List<SystemTrayMenuEntry>?> loadMenu(SystemTrayItem item) {
    if (item.source != SystemTrayItemSource.statusNotifier) {
      return Future<List<SystemTrayMenuEntry>?>.value(null);
    }
    return _statusNotifier.loadMenu(item);
  }

  Future<bool> activateMenuEntry(SystemTrayItem item, int entryId) {
    if (item.source != SystemTrayItemSource.statusNotifier) {
      return Future<bool>.value(false);
    }
    return _statusNotifier.activateMenuEntry(item, entryId);
  }

  void _publish() {
    state = _combinedItems();
  }

  List<SystemTrayItem> _combinedItems() {
    final items = <SystemTrayItem>[..._statusItems, ..._xembedItems.values]
      ..sort((left, right) {
        final byStatus = _statusPriority(
          left.status,
        ).compareTo(_statusPriority(right.status));
        if (byStatus != 0) {
          return byStatus;
        }
        return left.title.toLowerCase().compareTo(right.title.toLowerCase());
      });
    return List<SystemTrayItem>.unmodifiable(items);
  }
}

int _statusPriority(SystemTrayStatus status) => switch (status) {
  SystemTrayStatus.needsAttention => 0,
  SystemTrayStatus.active => 1,
  SystemTrayStatus.passive => 2,
};
