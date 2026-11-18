import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'model.dart';
import 'store.dart';

/// One detached worker per request, serialized by the store's OS lock. The GUI
/// is a client, never the lifetime owner of package resolution or compilation.
final class JobWorker {
  const JobWorker(this.store);
  final ManagerStore store;

  Future<String> submit(List<String> arguments) async {
    if (arguments.isEmpty ||
        !{
          'prepare',
          'initialize',
          'defaults',
          'refresh-catalog',
          'inspect',
          'add',
          'enable',
          'remove',
          'plan',
          'apply',
          'restore',
          'revert',
          'undo',
          'off',
          'update',
          'rebuild',
        }.contains(arguments.first)) {
      throw const CompositionException('Unsupported background operation');
    }
    final id = store.createJob(arguments.first, {'argv': arguments});
    try {
      final script = Platform.script;
      final packageConfig = await Isolate.packageConfig;
      final command = <String>[
        if (script.path.endsWith('.dart')) ...[
          if (packageConfig != null) '--packages=${packageConfig.toFilePath()}',
          script.toFilePath(),
        ],
        '--state',
        store.root.path,
        'worker',
        id,
      ];
      final process = await Process.start(
        Platform.resolvedExecutable,
        command,
        mode: ProcessStartMode.detached,
      );
      store.write('jobs/$id.spawn', {
        'pid': process.pid,
        'processStart': ManagerStore.processStart(process.pid),
      });
      // The worker owns all subsequent state; do not overwrite a fast result.
      return id;
    } catch (error) {
      store.updateJob(id, {'phase': 'failed', 'error': '$error'});
      rethrow;
    }
  }

  Future<void> run(
    String id,
    Future<Object?> Function(List<String>) operation,
  ) async {
    ManagerStore.validateId(id);
    final job = store.read('jobs/$id.json');
    if (job['phase'] != 'queued') {
      throw const CompositionException('Job has already started');
    }
    store.updateJob(id, {
      'phase': 'running',
      'pid': pid,
      'processStart': ManagerStore.processStart(pid),
    });
    final log = store.file('jobs/$id.log').openWrite();
    try {
      final arguments = (job['arguments']! as Map)['argv']! as List;
      final result = await operation(arguments.cast<String>());
      log.writeln(const JsonEncoder.withIndent('  ').convert(result));
      final progress = store.read('jobs/$id.json')['progress'] as Map?;
      store.updateJob(id, {
        'phase': 'succeeded',
        'result': result,
        if (progress != null)
          'progress': {
            ...progress,
            'completed': progress['total'],
            'label': 'Completed',
          },
      });
    } catch (error, stack) {
      log.writeln('$error\n$stack');
      store.updateJob(id, {'phase': 'failed', 'error': '$error'});
    } finally {
      await log.close();
    }
  }
}

/// Preserve multiline diagnostics without conflating them with progress output.
String operationFailure(List<String> lines, int exitCode) {
  const prefix = 'denial-plugins: ';
  final index = lines.lastIndexWhere((line) => line.startsWith(prefix));
  return index < 0
      ? 'The operation exited with code $exitCode. See the build log for details.'
      : lines.sublist(index).join('\n').substring(prefix.length).trim();
}
