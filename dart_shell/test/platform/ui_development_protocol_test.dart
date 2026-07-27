import 'dart:convert';
import 'dart:typed_data';

import 'package:denial_dart_shell/src/models/ui_development.dart';
import 'package:denial_dart_shell/src/platform/ui_development_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encodes a bounded workspace command', () {
    final protocol = DenialUiDevelopmentProtocol();
    final packet = protocol.encodeCommand(
      command: DenialUiDevelopmentCommand.setWorkspace,
      requestId: 41,
      workspace: '/home/example/denial-ui',
    );

    expect(packet, isNotNull);
    final data = ByteData.sublistView(packet!);
    expect(data.getUint8(0), DenialUiDevelopmentProtocol.version);
    expect(data.getUint8(1), DenialUiDevelopmentCommand.setWorkspace.index);
    expect(data.getUint32(4, Endian.little), 41);
    expect(data.getUint16(8, Endian.little), 23);
  });

  test('rejects NUL and oversized workspace commands', () {
    final protocol = DenialUiDevelopmentProtocol();

    expect(
      protocol.encodeCommand(
        command: DenialUiDevelopmentCommand.setWorkspace,
        requestId: 1,
        workspace: '/tmp/a\u0000b',
      ),
      isNull,
    );
    expect(
      protocol.encodeCommand(
        command: DenialUiDevelopmentCommand.setWorkspace,
        requestId: 1,
        workspace: '/${'a' * 4097}',
      ),
      isNull,
    );
  });

  test('only auto-reload commands may carry the boolean command flag', () {
    final protocol = DenialUiDevelopmentProtocol();

    expect(
      protocol.encodeCommand(
        command: DenialUiDevelopmentCommand.query,
        requestId: 1,
        autoReload: true,
      ),
      isNull,
    );
    expect(
      protocol.encodeCommand(
        command: DenialUiDevelopmentCommand.setAutoReload,
        requestId: 2,
        autoReload: true,
      ),
      isNotNull,
    );
  });

  test('decodes native runtime state and diagnostics', () {
    final protocol = DenialUiDevelopmentProtocol();
    final workspace = utf8.encode('/home/example/denial-ui');
    final vmService = utf8.encode('http://127.0.0.1:1234/token=/');
    final status = utf8.encode('Live Flutter UI development is active.');
    final diagnosticPath = utf8.encode('lib/main.dart');
    final diagnosticMessage = utf8.encode('Expected a widget.');
    final packet =
        ByteData(
            40 +
                workspace.length +
                vmService.length +
                status.length +
                14 +
                diagnosticPath.length +
                diagnosticMessage.length,
          )
          ..setUint8(0, DenialUiDevelopmentProtocol.version)
          ..setUint8(1, DenialUiRuntimeMode.liveDevelopment.index)
          ..setUint8(2, DenialUiRuntimeMode.liveDevelopment.index)
          ..setUint8(3, DenialUiDevelopmentOperation.idle.index)
          ..setUint16(4, 0x009f, Endian.little)
          ..setUint16(6, 0xffff, Endian.little)
          ..setUint64(8, 7, Endian.little)
          ..setUint64(16, 9, Endian.little)
          ..setUint32(24, 11, Endian.little)
          ..setUint16(28, workspace.length, Endian.little)
          ..setUint16(30, vmService.length, Endian.little)
          ..setUint16(32, status.length, Endian.little)
          ..setUint16(34, 0, Endian.little)
          ..setUint16(36, 1, Endian.little);
    final bytes = packet.buffer.asUint8List();
    var offset = 40;
    for (final value in [workspace, vmService, status]) {
      bytes.setRange(offset, offset + value.length, value);
      offset += value.length;
    }
    packet
      ..setUint8(offset, DenialUiDiagnosticSeverity.error.index)
      ..setUint8(offset + 1, 0)
      ..setUint32(offset + 2, 18, Endian.little)
      ..setUint32(offset + 6, 7, Endian.little)
      ..setUint16(offset + 10, diagnosticPath.length, Endian.little)
      ..setUint16(offset + 12, diagnosticMessage.length, Endian.little);
    offset += 14;
    bytes.setRange(offset, offset + diagnosticPath.length, diagnosticPath);
    offset += diagnosticPath.length;
    bytes.setRange(
      offset,
      offset + diagnosticMessage.length,
      diagnosticMessage,
    );

    final state = protocol.decodeState(packet);
    expect(state, isNotNull);
    expect(state!.activeMode, DenialUiRuntimeMode.liveDevelopment);
    expect(state.workspace, '/home/example/denial-ui');
    expect(state.vmServiceAvailable, isTrue);
    expect(state.generation, 7);
    expect(state.progress, isNull);
    expect(state.diagnostics.single.line, 18);
    expect(state.diagnostics.single.message, 'Expected a widget.');
  });

  test('rejects unknown state flags and inconsistent VM service state', () {
    final protocol = DenialUiDevelopmentProtocol();
    final unknownFlags = ByteData(40)
      ..setUint8(0, DenialUiDevelopmentProtocol.version)
      ..setUint8(1, DenialUiRuntimeMode.officialOptimized.index)
      ..setUint8(2, DenialUiRuntimeMode.officialOptimized.index)
      ..setUint8(3, DenialUiDevelopmentOperation.idle.index)
      ..setUint16(4, 0x0200, Endian.little)
      ..setUint16(6, 0xffff, Endian.little);
    expect(protocol.decodeState(unknownFlags), isNull);

    final missingVmService = ByteData(40)
      ..setUint8(0, DenialUiDevelopmentProtocol.version)
      ..setUint8(1, DenialUiRuntimeMode.liveDevelopment.index)
      ..setUint8(2, DenialUiRuntimeMode.liveDevelopment.index)
      ..setUint8(3, DenialUiDevelopmentOperation.idle.index)
      ..setUint16(4, 0x0080, Endian.little)
      ..setUint16(6, 0xffff, Endian.little);
    expect(protocol.decodeState(missingVmService), isNull);
  });
}
