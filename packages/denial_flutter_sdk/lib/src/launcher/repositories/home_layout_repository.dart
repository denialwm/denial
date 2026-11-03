import 'dart:convert';

import '../runtime_paths.dart';
import '../models/home_grid_item.dart';

/// The saved home layouts.
class HomeSavedLayouts {
  const HomeSavedLayouts({this.layouts = const {}, this.unassigned});

  final Map<HomeOrientation, List<HomeLayoutSlot?>> layouts;

  /// A layout not yet shown in any orientation, as in files from before
  /// orientations: it belongs to whichever orientation home shows first.
  final List<HomeLayoutSlot?>? unassigned;
}

class HomeLayoutRepository {
  const HomeLayoutRepository({required this._paths});

  final RuntimePaths _paths;

  Future<HomeSavedLayouts> readSavedLayouts() async {
    try {
      final file = await _paths.layoutFile();
      if (!await file.exists()) {
        return const HomeSavedLayouts();
      }

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const HomeSavedLayouts();
      }

      List<HomeLayoutSlot?>? read(String key) => switch (decoded[key]) {
        final List rawSlots =>
          rawSlots.map(_decodeSlot).toList(growable: false),
        _ => null,
      };
      return HomeSavedLayouts(
        layouts: {
          for (final orientation in HomeOrientation.values)
            orientation: ?read(orientation.name),
        },
        unassigned: read('slots'),
      );
    } on Object {
      return const HomeSavedLayouts();
    }
  }

  Future<void> saveLayouts(HomeSavedLayouts saved) async {
    List<Object?> encode(List<HomeLayoutSlot?> slots) =>
        slots.map(_encodeSlot).toList(growable: false);
    try {
      final file = await _paths.layoutFile();
      final payload = jsonEncode({
        'version': 4,
        for (final MapEntry(:key, :value) in saved.layouts.entries)
          key.name: encode(value),
        if (saved.unassigned case final slots?) 'slots': encode(slots),
      });
      await file.writeAsString('$payload\n', flush: true);
    } on Object {
      // Layout persistence is best effort; the in-memory layout remains valid.
    }
  }

  HomeLayoutSlot? _decodeSlot(Object? item) {
    if (item is String && item.isNotEmpty) {
      return HomeLayoutSlot(id: item);
    }

    if (item is Map) {
      final id = item['id'];
      if (id is! String || id.isEmpty) {
        return null;
      }
      final colSpan = item['colSpan'];
      final rowSpan = item['rowSpan'];
      final name = item['name'];
      final apps = item['apps'];
      return HomeLayoutSlot(
        id: id,
        colSpan: colSpan is int ? colSpan : null,
        rowSpan: rowSpan is int ? rowSpan : null,
        name: name is String ? name : null,
        children: apps is List
            ? List<String>.unmodifiable(apps.whereType<String>())
            : null,
      );
    }

    return null;
  }

  Object? _encodeSlot(HomeLayoutSlot? slot) {
    if (slot == null) {
      return null;
    }

    if (slot.children case final apps?) {
      return {'id': slot.id, 'name': slot.name, 'apps': apps};
    }
    if (slot.colSpan != null || slot.rowSpan != null) {
      return {'id': slot.id, 'colSpan': slot.colSpan, 'rowSpan': slot.rowSpan};
    }
    return slot.id;
  }
}
