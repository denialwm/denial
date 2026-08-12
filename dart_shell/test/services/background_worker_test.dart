import 'dart:isolate';

import 'package:denial_dart_shell/src/services/background_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reuses one persistent isolate across typed invocations', () async {
    final worker = BackgroundWorker(
      entrypoint: _testWorkerMain,
      debugName: 'denial-test-worker',
    );
    addTearDown(worker.close);

    Future<int> increment() => worker.invoke<int>(
      operation: 1,
      decode: (response) => response! as int,
    );

    expect(await increment(), 1);
    expect(await increment(), 2);
  });

  test(
    'returns remote operation failures without killing the worker',
    () async {
      final worker = BackgroundWorker(
        entrypoint: _testWorkerMain,
        debugName: 'denial-test-worker',
      );
      addTearDown(worker.close);

      await expectLater(
        worker.invoke<void>(operation: 2, decode: (_) {}),
        throwsA(isA<BackgroundWorkerException>()),
      );
      expect(
        await worker.invoke<int>(
          operation: 1,
          decode: (response) => response! as int,
        ),
        1,
      );
    },
  );
}

@pragma('vm:entry-point')
void _testWorkerMain(List<SendPort> bootstrap) {
  var count = 0;
  serveBackgroundWorker(bootstrap, (operation, _) {
    return switch (operation) {
      1 => ++count,
      2 => throw StateError('expected test failure'),
      _ => throw UnsupportedError('unknown test operation'),
    };
  });
}
