import 'dart:convert';
import 'dart:io';

import '../runtime_paths.dart';

class ScreenPowerService {
  const ScreenPowerService({
    required RuntimePaths paths,
  }) : _paths = paths;

  final RuntimePaths _paths;

  Future<void> screenOff({String reason = 'home-double-tap'}) async {
    final socketPath = _paths.powerdControlSocketPath;
    try {
      final socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: const Duration(milliseconds: 500),
      );
      socket.add(utf8.encode('screen-off $reason\n'));
      await socket.flush();
      await socket.close();
    } on Object {}
  }
}
