import 'dart:convert';
import 'dart:typed_data';

import '../models/ui_development.dart';

const denialUiDevelopmentControlChannel = 'denial/ui_development/control';
const denialUiDevelopmentStateChannel = 'denial/ui_development/state';

enum DenialUiDevelopmentCommand {
  query,
  enableLiveDevelopment,
  disableLiveDevelopment,
  setWorkspace,
  hotReload,
  hotRestart,
  buildAndActivateOptimized,
  restoreOfficial,
  revertLastWorking,
  setAutoReload,
}

class DenialUiDevelopmentProtocol {
  static const int version = 1;
  static const int _controlHeaderBytes = 12;
  static const int _stateHeaderBytes = 40;
  static const int maxPacketBytes = 64 * 1024;
  static const int maxWorkspaceBytes = 4096;
  static const int maxDiagnostics = 64;

  Uint8List? encodeCommand({
    required DenialUiDevelopmentCommand command,
    required int requestId,
    String workspace = '',
    bool autoReload = false,
  }) {
    if (requestId <= 0 || requestId > 0xffffffff) {
      return null;
    }
    final workspaceBytes = utf8.encode(workspace);
    if (workspaceBytes.length > maxWorkspaceBytes ||
        workspaceBytes.contains(0)) {
      return null;
    }
    if (command == DenialUiDevelopmentCommand.setWorkspace &&
        workspaceBytes.isEmpty) {
      return null;
    }
    if (command != DenialUiDevelopmentCommand.setWorkspace &&
        workspaceBytes.isNotEmpty) {
      return null;
    }
    if (command != DenialUiDevelopmentCommand.setAutoReload && autoReload) {
      return null;
    }

    final packet = ByteData(_controlHeaderBytes + workspaceBytes.length)
      ..setUint8(0, version)
      ..setUint8(1, command.index)
      ..setUint8(2, autoReload ? 1 : 0)
      ..setUint8(3, 0)
      ..setUint32(4, requestId, Endian.little)
      ..setUint16(8, workspaceBytes.length, Endian.little)
      ..setUint16(10, 0, Endian.little);
    packet.buffer.asUint8List().setRange(
      _controlHeaderBytes,
      packet.lengthInBytes,
      workspaceBytes,
    );
    return packet.buffer.asUint8List();
  }

  DenialUiDevelopmentState? decodeState(ByteData? packet) {
    if (packet == null ||
        packet.lengthInBytes < _stateHeaderBytes ||
        packet.lengthInBytes > maxPacketBytes ||
        packet.getUint8(0) != version) {
      return null;
    }

    final activeMode = _enumAt(DenialUiRuntimeMode.values, packet.getUint8(1));
    final desiredMode = _enumAt(DenialUiRuntimeMode.values, packet.getUint8(2));
    final operation = _enumAt(
      DenialUiDevelopmentOperation.values,
      packet.getUint8(3),
    );
    if (activeMode == null || desiredMode == null || operation == null) {
      return null;
    }

    final flags = packet.getUint16(4, Endian.little);
    final progressBasisPoints = packet.getUint16(6, Endian.little);
    final workspaceLength = packet.getUint16(28, Endian.little);
    final vmServiceLength = packet.getUint16(30, Endian.little);
    final statusLength = packet.getUint16(32, Endian.little);
    final errorLength = packet.getUint16(34, Endian.little);
    final diagnosticCount = packet.getUint16(36, Endian.little);
    if ((flags & ~0x01ff) != 0 ||
        (progressBasisPoints != 0xffff && progressBasisPoints > 10000) ||
        diagnosticCount > maxDiagnostics ||
        packet.getUint16(38, Endian.little) != 0) {
      return null;
    }

    var offset = _stateHeaderBytes;
    String readString(int length) {
      if (length < 0 || offset + length > packet.lengthInBytes) {
        throw const FormatException('truncated UI development packet');
      }
      final bytes = packet.buffer.asUint8List(
        packet.offsetInBytes + offset,
        length,
      );
      offset += length;
      return utf8.decode(bytes, allowMalformed: false);
    }

    try {
      final workspace = readString(workspaceLength);
      final vmServiceUri = readString(vmServiceLength);
      final status = readString(statusLength);
      final error = readString(errorLength);
      if (workspaceLength > maxWorkspaceBytes ||
          workspace.contains('\u0000') ||
          (((flags & 0x0080) != 0) != vmServiceUri.isNotEmpty)) {
        return null;
      }
      final diagnostics = <DenialUiDiagnostic>[];
      for (var index = 0; index < diagnosticCount; index += 1) {
        if (offset + 14 > packet.lengthInBytes) {
          return null;
        }
        final severity = _enumAt(
          DenialUiDiagnosticSeverity.values,
          packet.getUint8(offset),
        );
        if (severity == null || packet.getUint8(offset + 1) != 0) {
          return null;
        }
        final line = packet.getUint32(offset + 2, Endian.little);
        final column = packet.getUint32(offset + 6, Endian.little);
        final pathLength = packet.getUint16(offset + 10, Endian.little);
        final messageLength = packet.getUint16(offset + 12, Endian.little);
        offset += 14;
        final path = readString(pathLength);
        final message = readString(messageLength);
        diagnostics.add(
          DenialUiDiagnostic(
            severity: severity,
            message: message,
            path: path,
            line: line,
            column: column,
          ),
        );
      }
      if (offset != packet.lengthInBytes) {
        return null;
      }
      return DenialUiDevelopmentState(
        activeMode: activeMode,
        desiredMode: desiredMode,
        operation: operation,
        developerComponentsAvailable: flags & 0x0001 != 0,
        workspaceValid: flags & 0x0002 != 0,
        autoReload: flags & 0x0004 != 0,
        autoReloadSupported: flags & 0x0100 != 0,
        canHotReload: flags & 0x0008 != 0,
        canHotRestart: flags & 0x0010 != 0,
        canBuildOptimized: flags & 0x0020 != 0,
        canRevert: flags & 0x0040 != 0,
        vmServiceAvailable: flags & 0x0080 != 0,
        generation: packet.getUint64(8, Endian.little),
        revision: packet.getUint64(16, Endian.little),
        acknowledgedRequestId: packet.getUint32(24, Endian.little),
        workspace: workspace,
        vmServiceUri: vmServiceUri,
        status: status,
        error: error,
        diagnostics: List<DenialUiDiagnostic>.unmodifiable(diagnostics),
        progress: progressBasisPoints == 0xffff
            ? null
            : progressBasisPoints.clamp(0, 10000) / 10000,
      );
    } on FormatException {
      return null;
    }
  }

  T? _enumAt<T>(List<T> values, int index) {
    return index < values.length ? values[index] : null;
  }
}
