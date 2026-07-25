import 'dart:convert';

import '../runtime_paths.dart';
import '../models/home_grid_item.dart';

class HomeLayoutRepository {
  const HomeLayoutRepository({required this._paths});

  final RuntimePaths _paths;

  Future<List<HomeLayoutSlot?>?> readSavedLayout() async {
    try {
      final file = await _paths.layoutFile();
      if (!await file.exists()) {
        return null;
      }

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return null;
      }

      final rawSlots = decoded['slots'];
      if (rawSlots is! List) {
        return null;
      }

      return rawSlots.map(_decodeSlot).toList(growable: false);
    } on Object {
      return null;
    }
  }

  Future<void> saveLayout(List<HomeGridItem?> slots) async {
    try {
      final file = await _paths.layoutFile();
      final payload = jsonEncode({
        'version': 2,
        'slots': slots.map(_encodeSlot).toList(growable: false),
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
      return HomeLayoutSlot(
        id: id,
        colSpan: colSpan is int ? colSpan : null,
        rowSpan: rowSpan is int ? rowSpan : null,
      );
    }

    return null;
  }

  Object? _encodeSlot(HomeGridItem? item) {
    if (item == null) {
      return null;
    }

    if (item.resizable) {
      return {'id': item.id, 'colSpan': item.colSpan, 'rowSpan': item.rowSpan};
    }

    return item.id;
  }
}
