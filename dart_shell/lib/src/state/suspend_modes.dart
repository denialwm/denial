import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/suspend_mode.dart';

final suspendModeCapabilitiesProvider = FutureProvider<SuspendModeCapabilities>(
  (ref) async {
    try {
      final contents = await File('/sys/power/mem_sleep').readAsString();
      return SuspendModeCapabilities.parse(contents);
    } on FileSystemException {
      return const SuspendModeCapabilities.unavailable();
    }
  },
);
